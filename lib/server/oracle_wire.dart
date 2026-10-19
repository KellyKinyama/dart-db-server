/// Oracle (TNS/TTC) wire-protocol server front-end for [Database].
///
/// Lets unmodified Oracle thin clients (node-oracledb, python-oracledb, the
/// pure-Dart `oracledb` driver) connect to `dart_db_server`, mirroring the way
/// [MySqlServer] fronts the engine for MySQL clients. This is the inverse of
/// the sibling client in `../dart-oracledb`: every frame the client *encodes*
/// we *decode* here, and vice-versa.
///
/// Status: Phase 0/1 of `doc/oracle-wire-protocol-plan.md` — TNS transport.
/// The listener accepts connections, parses the CONNECT packet, negotiates a
/// protocol version, and answers with ACCEPT; DATA frames carrying TTC are
/// decoded to their function code and dispatched to [_handleTtc], where later
/// phases (negotiation, auth, execute/fetch) hang off.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'database.dart';
import 'oracle_auth.dart';
import 'oracle_codec.dart';
import 'oracle_execute.dart';
import 'oracle_tns.dart';
import 'oracle_ttc.dart';

// TTC message types (first byte of a TTC message body). Full set lives in the
// client's `protocol/constants.dart`; only the ones the transport, negotiation
// and auth phases need are named here.
const int _ttcProtocol = ttcMsgProtocol; // 1: protocol negotiation
const int _ttcDataTypes = ttcMsgDataTypes; // 2: data-type negotiation
const int _ttcFunction = ttcMsgTypeFunction; // 3: RPC function call

/// Oracle TNS/TTC server fronting a [Database].
class OracleServer {
  OracleServer(
    this.db, {
    InternetAddress? address,
    this.port = 1521,
    Map<String, String> users = const <String, String>{},
  })  : address = address ?? InternetAddress.loopbackIPv4,
        userStore = _buildUserStore(users);

  final Database db;
  final InternetAddress address;
  final int port;

  /// Registered database users (verifier side). Add more with
  /// [OracleUserStore.addUser].
  final OracleUserStore userStore;

  /// Serializes only what must be serialized. A statement outside a transaction
  /// takes a SHARED lock, so reads (and writes, which the engine's own lock
  /// serializes) run concurrently across sessions. A session that opens a
  /// transaction takes the EXCLUSIVE lock and holds it for the transaction's
  /// whole lifetime, so other sessions' statements block until it commits or
  /// rolls back — the shared engine keeps a single global transaction
  /// snapshot, so this is what makes uncommitted work invisible to another
  /// session (serializable isolation) without serializing the common
  /// no-transaction read path.
  final _SessionGate _gate = _SessionGate();

  static OracleUserStore _buildUserStore(Map<String, String> users) {
    final store = OracleUserStore();
    users.forEach(store.addUser);
    return store;
  }

  ServerSocket? _socket;
  final Set<OracleConnection> _conns = <OracleConnection>{};
  int _nextId = 1;
  void Function(String msg)? onLog;

  Future<void> start() async {
    _socket = await ServerSocket.bind(address, port);
    _log('listening on ${address.address}:${_socket!.port} (oracle wire)');
    _socket!.listen(_accept);
  }

  /// The actual bound port (useful when [port] was 0).
  int get boundPort => _socket?.port ?? port;

  Future<void> stop() async {
    for (final c in _conns.toList()) {
      await c.close();
    }
    await _socket?.close();
  }

  void _accept(Socket socket) {
    final conn = OracleConnection(this, socket, _nextId++);
    _conns.add(conn);
    conn._start();
  }

  void _log(String msg) => (onLog ?? print).call('[oracle] $msg');
}

/// Connection phases for the TNS/TTC state machine.
enum OraclePhase { connect, negotiate, auth, ready, closed }

/// Per-connection state machine. Buffers inbound bytes, reassembles TNS
/// frames, and advances the handshake.
class OracleConnection {
  OracleConnection(this.server, this.socket, this.id);

  final OracleServer server;
  final Socket socket;
  final int id;

  Uint8List _buffered = Uint8List(0);
  StreamSubscription<Uint8List>? _sub;
  OraclePhase _phase = OraclePhase.connect;
  final AuthPhaseState _auth = AuthPhaseState();

  /// Server-side statement cursors: cursor id -> SQL text. Lets the client's
  /// transparent statement cache re-execute a statement by id with no SQL on
  /// the wire.
  final Map<int, String> _cursors = <int, String>{};
  int _nextCursorId = 1;

  int _version = tnsServerVersion;

  void _start() {
    server._log('conn $id connected from '
        '${socket.remoteAddress.address}:${socket.remotePort}');
    _sub = socket.listen(
      _onData,
      onError: (Object e, StackTrace st) {
        server._log('conn $id error: $e');
      },
      onDone: close,
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    if (_phase == OraclePhase.closed) return;
    _phase = OraclePhase.closed;
    // A session that disconnects mid-transaction must roll back and release the
    // exclusive lock, or it would block every other session forever.
    if (identical(server._gate.owner, this)) {
      server._gate.owner = null;
      try {
        if (server.db.inTransaction) await server.db.execute('ROLLBACK');
      } catch (_) {}
      server._gate.releaseExclusive();
    }
    await _sub?.cancel();
    try {
      await socket.close();
    } catch (_) {}
    server._conns.remove(this);
    server._log('conn $id disconnected');
  }

  void _onData(Uint8List chunk) {
    // Append to the running buffer.
    if (_buffered.isEmpty) {
      _buffered = Uint8List.fromList(chunk);
    } else {
      final merged = Uint8List(_buffered.length + chunk.length)
        ..setRange(0, _buffered.length, _buffered)
        ..setRange(_buffered.length, _buffered.length + chunk.length, chunk);
      _buffered = merged;
    }
    _drain();
  }

  /// Consumes as many whole TNS frames as the buffer currently holds.
  void _drain() {
    while (true) {
      final frameLen = TnsPacket.frameLength(_buffered, _buffered.length);
      if (frameLen == null || _buffered.length < frameLen) return;
      final raw = Uint8List.sublistView(_buffered, 0, frameLen);
      _buffered = Uint8List.sublistView(_buffered, frameLen);
      try {
        _handleFrame(raw);
      } on TnsException catch (e) {
        server._log('conn $id bad frame: $e');
        unawaited(close());
        return;
      }
    }
  }

  void _handleFrame(Uint8List raw) {
    final packet = TnsPacket.decode(raw);
    switch (packet.type) {
      case tnsPacketConnect:
        _handleConnect(raw);
        break;
      case tnsPacketData:
        _handleData(packet);
        break;
      case tnsPacketResend:
        // Client asking us to resend — nothing buffered to resend yet.
        break;
      case tnsPacketMarker:
        _handleMarker(packet);
        break;
      case tnsPacketAbort:
        unawaited(close());
        break;
      default:
        server._log('conn $id ignoring packet type ${packet.type}');
    }
  }

  void _handleConnect(Uint8List raw) {
    final req = ConnectRequest.parse(raw);
    _version = negotiateVersion(req);
    server._log(
      'conn $id CONNECT v=${req.versionDesired}/${req.versionMinimum} '
      'sdu=${req.sdu} -> negotiated v=$_version'
      '${req.connectData.isNotEmpty ? ' desc="${req.connectData}"' : ''}',
    );
    final accept = buildAcceptPacket(
      version: _version,
      sdu: req.sdu == 0 ? tnsDefaultSdu : req.sdu,
      tdu: req.tdu == 0 ? tnsDefaultTdu : req.tdu,
      // flag2 = 0: classical (non-FAST_AUTH) handshake for now.
    );
    _phase = OraclePhase.negotiate;
    _send(accept);
  }

  void _handleMarker(TnsPacket packet) {
    // Echo an ATTENTION/MARKER acknowledgement by replying with the same
    // marker body (break/reset handling is a later phase).
    _send(TnsPacket(type: tnsPacketMarker, payload: packet.payload).encode());
  }

  void _handleData(TnsPacket packet) {
    if (packet.payload.isEmpty) return; // no TTC body
    final ttc = ReadBuffer(packet.payload);
    // The client may prepend piggyback control messages (e.g. close-cursors)
    // before the real function call; consume them first.
    while (ttc.hasRemaining) {
      final messageType = ttc.readUint8();
      if (messageType == ttcMsgTypePiggyback) {
        _skipPiggyback(ttc);
        continue;
      }
      _handleTtc(messageType, ttc);
      return; // one real message per DATA packet
    }
  }

  /// Consumes a piggyback message. Only close-cursors (105) has a body we can
  /// walk; it frees the listed cursors from the cache.
  void _skipPiggyback(ReadBuffer body) {
    final functionCode = body.readUint8();
    body.readUint8(); // sequence
    body.readUB8(); // token number (field version >= 18)
    if (functionCode == ttcFuncCloseCursors) {
      body.readUint8(); // pointer
      final count = body.readUB4();
      for (var i = 0; i < count; i++) {
        _cursors.remove(body.readUB4());
      }
      server._log('conn $id closed $count cursor(s) via piggyback');
    } else {
      server._log('conn $id ignoring piggyback function $functionCode');
    }
  }

  void _handleTtc(int messageType, ReadBuffer body) {
    switch (messageType) {
      case _ttcProtocol:
        server._log('conn $id TTC PROTOCOL request -> response');
        _phase = OraclePhase.negotiate;
        _sendTtc(buildProtocolResponse());
        break;
      case _ttcDataTypes:
        server._log('conn $id TTC DATA TYPES request -> response');
        _phase = OraclePhase.auth;
        _sendTtc(buildDataTypesResponse());
        break;
      case _ttcFunction:
        _handleFunction(body);
        break;
      default:
        server._log('conn $id TTC message type $messageType (phase $_phase, '
            'not yet implemented)');
    }
    // Execute/fetch responses are implemented in the next phase of
    // doc/oracle-wire-protocol-plan.md.
  }

  /// Dispatches a TTC FUNCTION (message type 3) call by its function code.
  void _handleFunction(ReadBuffer body) {
    final functionCode = body.readUint8();
    body.readUint8(); // sequence number
    switch (functionCode) {
      case ttcAuthPhaseOne:
        final resp = handleAuthPhaseOne(body, server.userStore, _auth);
        server._log('conn $id AUTH_PHASE_ONE user=${_auth.username ?? '?'}');
        _sendTtc(resp.bytes);
        break;
      case ttcAuthPhaseTwo:
        final resp = handleAuthPhaseTwo(body, _auth);
        if (resp.authenticated) {
          _phase = OraclePhase.ready;
          server._log('conn $id authenticated user=${_auth.username ?? '?'}');
        } else {
          server._log('conn $id auth failed user=${_auth.username ?? '?'}');
        }
        _sendTtc(resp.bytes);
        break;
      case ttcFuncExecute:
        unawaited(_handleExecute(body));
        break;
      case ttcFuncCommit:
        unawaited(_handleCommit());
        break;
      case ttcFuncRollback:
        unawaited(_handleRollback());
        break;
      case ttcFuncPing:
        _sendTtc(buildStatusOk());
        break;
      default:
        server._log('conn $id TTC function $functionCode (phase $_phase, '
            'not yet implemented)');
    }
  }

  /// COMMIT: ends this session's transaction when it owns one, otherwise a
  /// no-op acknowledgement.
  Future<void> _handleCommit() async {
    server._log('conn $id COMMIT');
    final response = await _guarded<Uint8List>('COMMIT', () async {
      try {
        if (server.db.inTransaction) await server.db.execute('COMMIT');
        return buildStatusOk();
      } catch (e) {
        return buildExecuteError(900, _oraErrorText(e));
      }
    });
    _sendTtc(response);
  }

  /// ROLLBACK: undoes this session's transaction when it owns one, otherwise a
  /// no-op acknowledgement.
  Future<void> _handleRollback() async {
    server._log('conn $id ROLLBACK');
    final response = await _guarded<Uint8List>('ROLLBACK', () async {
      try {
        if (server.db.inTransaction) await server.db.execute('ROLLBACK');
        return buildStatusOk();
      } catch (e) {
        return buildExecuteError(900, _oraErrorText(e));
      }
    });
    _sendTtc(response);
  }

  /// Runs [action] under the session gate. A statement that opens a transaction
  /// takes the exclusive lock and — if it does open one — keeps it (becoming
  /// the gate owner) until commit/rollback; the owner's later statements run
  /// reentrantly under that held lock. Every other statement takes the shared
  /// lock so reads run concurrently.
  Future<T> _guarded<T>(String sql, Future<T> Function() action) async {
    // The owner already holds the exclusive lock; release it only when the
    // transaction ends.
    if (identical(server._gate.owner, this)) {
      try {
        return await action();
      } finally {
        if (!server.db.inTransaction) {
          server._gate.owner = null;
          server._gate.releaseExclusive();
        }
      }
    }
    if (_opensTransaction(sql)) {
      await server._gate.acquireExclusive();
      var keep = false;
      try {
        final r = await action();
        if (server.db.inTransaction) {
          server._gate.owner = this; // hold the lock across the transaction
          keep = true;
        }
        return r;
      } finally {
        if (!keep) server._gate.releaseExclusive();
      }
    }
    await server._gate.acquireShared();
    try {
      return await action();
    } finally {
      server._gate.releaseShared();
    }
  }

  /// Whether [sql] opens a transaction (and so must take the exclusive lock).
  static bool _opensTransaction(String sql) {
    final s = sql.trimLeft().toUpperCase();
    return s.startsWith('BEGIN') || s.startsWith('START TRANSACTION');
  }

  /// Decodes and runs a TTC EXECUTE (function 94) against the database, then
  /// replies with a query result set or a DML/DDL status.
  Future<void> _handleExecute(ReadBuffer body) async {
    final ExecuteRequestInfo info;
    try {
      info = decodeExecuteRequest(body);
    } catch (e) {
      server._log('conn $id EXECUTE decode error: $e');
      _sendTtc(buildExecuteError(600, 'internal error decoding execute'));
      return;
    }
    if (_phase != OraclePhase.ready) {
      _sendTtc(buildExecuteError(1012, 'not logged on'));
      return;
    }
    if (info.hasBinds) {
      server._log('conn $id EXECUTE with ${info.numParams} binds (unsupported)');
      _sendTtc(buildExecuteError(600, 'bind variables are not yet supported'));
      return;
    }
    // Resolve the SQL and cursor id: a fresh statement (cursor 0) is assigned a
    // new id and cached; a cached re-execute (cursor != 0) carries no SQL and
    // is looked up by id.
    final String sql;
    final int cursorId;
    if (info.cursorId == 0) {
      cursorId = _nextCursorId++;
      sql = info.sql;
      _cursors[cursorId] = sql;
    } else {
      cursorId = info.cursorId;
      final cached = _cursors[cursorId];
      if (cached == null) {
        _sendTtc(buildExecuteError(1001, 'invalid cursor'));
        return;
      }
      sql = cached;
    }
    server._log('conn $id EXECUTE [cursor $cursorId] "$sql"');
    final response = await _guarded<Uint8List>(sql, () async {
      try {
        final result = await server.db.execute(sql);
        return result.columns.isNotEmpty
            ? buildQueryResponse(result, cursorId: cursorId)
            : buildDmlResponse(result, cursorId: cursorId);
      } catch (e) {
        return buildExecuteError(900, _oraErrorText(e));
      }
    });
    _sendTtc(response);
  }

  /// Wraps a TTC message body in a TNS DATA packet and sends it.
  void _sendTtc(Uint8List ttcBody) => _send(buildDataPacket(ttcBody));
  void _send(Uint8List bytes) {
    try {
      socket.add(bytes);
    } catch (e) {
      server._log('conn $id send failed: $e');
    }
  }
}

/// Flattens an error into a single-line message for a TTC error reply.
String _oraErrorText(Object e) {
  final text = e.toString().replaceAll('\n', ' ').trim();
  return text.length > 512 ? text.substring(0, 512) : text;
}

/// A FIFO async gate that also tracks the connection currently holding an open
/// transaction. The owner keeps the gate across multiple statements; everyone
/// else queues.
/// A fair multi-reader / single-writer gate that also tracks the connection
/// holding an open transaction (which keeps the write lock across statements).
class _SessionGate {
  int _readers = 0;
  bool _writer = false;
  final List<Completer<void>> _readWaiters = <Completer<void>>[];
  final List<Completer<void>> _writeWaiters = <Completer<void>>[];

  /// The connection that owns the in-progress transaction, if any.
  OracleConnection? owner;

  Future<void> acquireShared() {
    if (!_writer && _writeWaiters.isEmpty) {
      _readers++;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _readWaiters.add(c);
    return c.future;
  }

  void releaseShared() {
    _readers--;
    _drain();
  }

  Future<void> acquireExclusive() {
    if (!_writer && _readers == 0) {
      _writer = true;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _writeWaiters.add(c);
    return c.future;
  }

  void releaseExclusive() {
    _writer = false;
    _drain();
  }

  void _drain() {
    // Prefer a waiting writer to avoid writer starvation.
    if (!_writer && _readers == 0 && _writeWaiters.isNotEmpty) {
      _writer = true;
      _writeWaiters.removeAt(0).complete();
      return;
    }
    if (!_writer && _readWaiters.isNotEmpty) {
      while (_readWaiters.isNotEmpty) {
        _readers++;
        _readWaiters.removeAt(0).complete();
      }
    }
  }
}
