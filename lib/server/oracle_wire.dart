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
import 'oracle_lob.dart';
import 'oracle_native_auth.dart';
import 'oracle_native_datatypes.dart';
import 'oracle_native_execute.dart';
import 'oracle_native_replay.dart';
import 'oracle_tns.dart';
import 'oracle_ttc.dart';
import 'lexer.dart';
import 'result.dart';

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
    this.securityContext,
  })  : address = address ?? InternetAddress.loopbackIPv4,
        userStore = _buildUserStore(users);

  final Database db;
  final InternetAddress address;
  final int port;

  /// When set, the listener binds a [SecureServerSocket] so clients connect
  /// over TLS (`tcps://host:port/service`). TLS wraps the whole connection
  /// from the first byte; the TNS/TTC layers above the socket are unchanged.
  /// When null, the listener is plain TCP (`tcp://`).
  final SecurityContext? securityContext;

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
    final tls = securityContext != null;
    _log('listening on ${address.address}:${_socket!.port} '
        '(oracle wire${tls ? ', TLS' : ''})');
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
    final ctx = securityContext;
    if (ctx == null) {
      _register(socket);
      return;
    }
    // Oracle TCPS: upgrade the raw socket to TLS before any TNS bytes, the
    // server mirror of the client's `SecureSocket.secure` on connect.
    unawaited(SecureSocket.secureServer(socket, ctx).then(
      _register,
      onError: (Object e) {
        _log('TLS handshake failed: $e');
        socket.destroy();
      },
    ));
  }

  void _register(Socket socket) {
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

  /// Per-connection temporary-LOB store (session-scoped), driven by the
  /// client's `ttcLobOp` RPC and resolved when a locator is bound.
  final LobStore _lobStore = LobStore();

  int _version = tnsServerVersion;

  /// Negotiated Session Data Unit: the max DATA-packet size. Large TTC
  /// responses are split across packets of at most this size.
  int _sdu = tnsDefaultSdu;

  /// Whether post-ACCEPT packets use the 4-byte large-SDU length header
  /// (negotiated version >= 315). CONNECT/ACCEPT always use 2-byte framing.
  bool _useLargeSdu = false;

  /// Whether the peer is a native (thick) OCI/OCCI client, detected from the
  /// large connect-descriptor overflow flow. Native clients need a real 23ai
  /// listener's byte-exact TTC PROTOCOL response (full charset map + caps).
  bool _nativeClient = false;

  /// When a CONNECT announces a descriptor that isn't inline, the native client
  /// follows it with a DATA packet carrying the descriptor; the ACCEPT is held
  /// until that packet arrives. This is the pre-built ACCEPT to send then.
  Uint8List? _pendingAccept;

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
      final frameLen = TnsPacket.frameLength(_buffered, _buffered.length,
          largeSdu: _useLargeSdu);
      if (frameLen == null || _buffered.length < frameLen) return;
      final raw = Uint8List.sublistView(_buffered, 0, frameLen);
      _buffered = Uint8List.sublistView(_buffered, frameLen);
      try {
        _handleFrame(raw);
      } on TnsException catch (e) {
        server._log('conn $id bad frame: $e');
        unawaited(close());
        return;
      } catch (e) {
        // A malformed or unsupported client message (e.g. a native OCI/OCCI
        // client's AUTH marshaling, which this server does not yet parse) must
        // not take down the connection handler uncaught.
        server._log('conn $id frame error: $e');
        unawaited(close());
        return;
      }
    }
  }

  void _handleFrame(Uint8List raw) {
    final packet = TnsPacket.decode(raw, largeSdu: _useLargeSdu);
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
    // Native (thick) OCI/OCCI clients send the connect descriptor in a separate
    // DATA packet after the CONNECT (the "overflow" flow); thin clients inline
    // it. They also probe an out-of-band break below version 320, so negotiate
    // 320 with them (Dart sockets can't service that probe otherwise).
    final overflow = req.connectData.isEmpty && req.connectDataLength > 0;
    _nativeClient = overflow;
    _version = negotiateVersion(req,
        serverVersion: overflow ? tnsServerVersionNative : tnsServerVersion);
    _sdu = req.sdu == 0 ? tnsDefaultSdu : req.sdu;
    server._log(
      'conn $id CONNECT v=${req.versionDesired}/${req.versionMinimum} '
      'sdu=${req.sdu} -> negotiated v=$_version'
      '${req.connectData.isNotEmpty ? ' desc="${req.connectData}"' : ''}',
    );
    // A real listener does NOT offer FAST_AUTH to these native clients, and
    // doing so makes them reject the ACCEPT, so only advertise it when the
    // descriptor arrives inline.
    final accept = buildAcceptPacket(
      version: _version,
      sdu: _sdu,
      // 0xFFFF is the "real value is in the 32-bit field" sentinel, not a TDU;
      // never echo it back as the negotiated TDU.
      tdu: (req.tdu == 0 || req.tdu == 0xffff) ? tnsDefaultTdu : req.tdu,
      // Advertise FAST_AUTH (23ai single-round-trip handshake) only to thin
      // clients, once the negotiated version carries the flag2 word. Native
      // clients get the real 23ai v320 flag2 word instead.
      flag2: overflow
          ? tnsAcceptFlagsNativeV320
          : (_version >= tnsVersionMinDataFlags ? tnsAcceptFlagFastAuth : 0),
      // Echo the client's requested service options (native OCI/OCCI clients
      // validate these), but clear PACKET_IO (0x400): a real listener does, and
      // leaving it set makes the native client pick async I/O, which triggers a
      // connect-time out-of-band (urgent TCP) break probe that Dart sockets
      // can't receive — the client then aborts after AUTH_PHASE_ONE. Do NOT
      // echo the connect flags: the 0x41 bits ask for Advanced Networking
      // (ANO/SNS), which this server does not implement. Returning 0 tells the
      // client no native services are active, so it proceeds to the TTC
      // protocol handshake.
      serviceOptions: req.serviceOptions & ~0x400,
      connectFlags0: 0,
      connectFlags1: 0,
      // Native clients require the real 23ai listener's ACCEPT byte layout.
      nativeClient: overflow,
    );
    // Hold the ACCEPT until the descriptor DATA packet arrives (keeping 2-byte
    // framing for it); thin clients get the ACCEPT immediately.
    if (overflow) {
      _pendingAccept = accept;
      return;
    }
    _useLargeSdu = _version >= tnsVersionMinLargeSdu;
    _phase = OraclePhase.negotiate;
    _send(accept);
  }

  void _handleMarker(TnsPacket packet) {
    // Oracle marker packets carry a 3-byte body `[0x01, 0x00, type]`. The
    // native client runs a break/reset OOB self-test during connection setup
    // (and on real query breaks once ready): it sends a break marker, then a
    // RESET marker, then blocks until the server sends a RESET marker back.
    // Reply to the RESET marker only — one marker in, one marker out — so the
    // stream stays synchronized for the packets that follow. Break/attention
    // probe markers are consumed without an in-band reply, which would desync
    // the client's read of the next handshake response.
    final body = packet.payload;
    final markerType = body.length >= 3 ? body[2] : (body.isEmpty ? 0 : body.last);
    if (markerType == tnsMarkerTypeReset) {
      _send(buildMarkerPacket(
        const [1, 0, tnsMarkerTypeReset],
        largeSdu: _useLargeSdu,
      ));
    }
  }

  void _handleData(TnsPacket packet) {
    // While a CONNECT's ACCEPT is deferred, the first DATA packet carries the
    // connect descriptor (not TTC). Consume it and release the ACCEPT, then
    // switch to the negotiated post-ACCEPT framing.
    final pending = _pendingAccept;
    if (pending != null) {
      _pendingAccept = null;
      _useLargeSdu = _version >= tnsVersionMinLargeSdu;
      _phase = OraclePhase.negotiate;
      _send(pending);
      return;
    }
    if (packet.payload.isEmpty) return; // no TTC body
    // Native (thick) clients marshal the post-auth call packets (piggybacks +
    // OALL8) in an OCI-RPC layout the thin piggyback walker can't step over, so
    // route them to a dedicated handler once authenticated.
    if (_nativeClient && _phase == OraclePhase.ready) {
      unawaited(_handleNativeCall(packet.payload));
      return;
    }
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
        _sendTtc(buildProtocolResponse(nativeClient: _nativeClient));
        break;
      case _ttcDataTypes:
        server._log('conn $id TTC DATA TYPES request -> response');
        _phase = OraclePhase.auth;
        // Native clients need the full negotiated type-mapping list a real
        // listener returns; thin clients accept an empty terminator.
        _sendTtc(_nativeClient
            ? nativeDataTypesResponse
            : buildDataTypesResponse());
        break;
      case ttcMsgTypeFastAuth:
        _handleFastAuth(body);
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

  /// Handles the 23ai FAST_AUTH envelope (message type 34): PROTOCOL +
  /// DATA-TYPES + AUTH_PHASE_ONE batched in one message. Skips the embedded
  /// protocol and data-types blocks to reach AUTH_PHASE_ONE, then replies with
  /// all three responses in a single DATA packet (the client reads one packet
  /// back and parses the three messages sequentially).
  void _handleFastAuth(ReadBuffer body) {
    if (_nativeClient) {
      _handleNativeFastAuth(body);
      return;
    }
    // Envelope header: version, flag1, flag2.
    body.readUint8(); // fast-auth version
    body.readUint8(); // flag 1
    body.readUint8(); // flag 2

    // Embedded PROTOCOL content: type, version, array terminator, then the
    // null-terminated driver name.
    body.readUint8(); // ttcMsgProtocol (1)
    body.readUint8(); // protocol version
    body.readUint8(); // array terminator
    while (body.readUint8() != 0) {} // driver name up to its null byte

    // Server charset fields + the FAST_AUTH field version.
    body.readUint16BE(); // server charset
    body.readUint8(); // server charset flag
    body.readUint16BE(); // server national charset
    body.readUint8(); // field version

    // Embedded DATA-TYPES content: type, two charset slots, encoding flags,
    // length-prefixed compile + runtime caps, then 8-byte data-type triples
    // until a zero-dataType terminator.
    body.readUint8(); // ttcMsgDataTypes (2)
    body.readUint16LE(); // primary charset
    body.readUint16LE(); // national charset
    body.readUint8(); // encoding flags
    body.skip(body.readUint8()); // compile caps
    body.skip(body.readUint8()); // runtime caps
    while (body.readUint16BE() != 0) {
      body.skip(6); // the rest of this 8-byte data-type entry
    }

    // Embedded AUTH_PHASE_ONE, with its function header.
    body.readUint8(); // ttcMsgTypeFunction (3)
    body.readUint8(); // function code (AUTH_PHASE_ONE)
    body.readUint8(); // sequence
    final auth = handleAuthPhaseOne(body, server.userStore, _auth);
    _phase = OraclePhase.auth;
    _auth.viaFastAuth = true;
    server._log('conn $id FAST_AUTH user=${_auth.username ?? '?'}');

    // One DATA packet carrying PROTOCOL + DATA-TYPES + AUTH_PHASE_ONE replies.
    final combined = WriteBuffer()
      ..writeBytes(buildProtocolResponse())
      ..writeBytes(buildDataTypesResponseFastAuth())
      ..writeBytes(auth.bytes);
    _sendTtc(combined.toBytes());
  }

  /// Handles the native (thick OCI/OCCI) FAST_AUTH envelope. A real 23ai
  /// listener DECLINES the fast path for these clients: it replies with a
  /// protocol-only response (message type 28), and the client then runs the
  /// classical DATA-TYPES + AUTH_PHASE_ONE/TWO exchange. Emulating the decline
  /// keeps our existing classical native-auth handlers on the hot path.
  void _handleNativeFastAuth(ReadBuffer body) {
    _phase = OraclePhase.negotiate;
    server._log('conn $id native FAST_AUTH declined -> protocol response');
    _sendTtc(nativeProtocolResponse28);
  }

  /// Dispatches a TTC FUNCTION (message type 3) call by its function code.
  void _handleFunction(ReadBuffer body) {
    final functionCode = body.readUint8();
    body.readUint8(); // sequence number
    switch (functionCode) {
      case ttcAuthPhaseOne:
        if (_nativeClient) {
          final username = parseNativeAuthUsername(body);
          _auth.username = username;
          final verifier = server.userStore.lookup(username);
          if (verifier == null) {
            server._log('conn $id native AUTH_PHASE_ONE unknown user=$username');
            _sendTtc(buildTtcError(oraInvalidCredentials,
                'invalid username/password; logon denied'));
          } else {
            server._log('conn $id native AUTH_PHASE_ONE user=$username');
            _sendTtc(buildNativeAuthPhaseOneResponse(verifier, _auth),
                dataFlags: 0x2000);
          }
          break;
        }
        final resp = handleAuthPhaseOne(body, server.userStore, _auth);
        server._log('conn $id AUTH_PHASE_ONE user=${_auth.username ?? '?'}');
        _sendTtc(resp.bytes);
        break;
      case ttcAuthPhaseTwo:
        if (_nativeClient) {
          final pairs = parseNativeAuthPairs(body);
          final ok = verifyO5LogonProof(
              _auth, pairs['AUTH_SESSKEY'], pairs['AUTH_PASSWORD']);
          if (ok) {
            _phase = OraclePhase.ready;
            server._log(
                'conn $id native authenticated user=${_auth.username ?? '?'}');
            _sendTtc(buildNativeAuthSuccess(comboKey: _auth.comboKey!),
                dataFlags: 0x2000);
          } else {
            server._log(
                'conn $id native auth failed user=${_auth.username ?? '?'}');
            _sendTtc(buildTtcError(oraInvalidCredentials,
                'invalid username/password; logon denied'));
          }
          break;
        }
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
      case ttcFuncLobOp:
        _sendTtc(handleLobOp(body, _lobStore));
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
  /// Handles a native (thick) client's post-auth call packet. If it carries a
  /// statement (OALL8 with inline SQL) it runs as an execute; otherwise it is a
  /// control call (commit / close / logoff) answered with a status terminal.
  Future<void> _handleNativeCall(Uint8List payload) async {
    final info = decodeNativeExecuteRequest(payload);
    if (info.sql.isEmpty) {
      _sendTtc(buildNativeStatusOk(), dataFlags: 0x2000);
      return;
    }
    await _handleExecute(ReadBuffer(payload));
  }

  Future<void> _handleExecute(ReadBuffer body) async {
    final ExecuteRequestInfo info;
    try {
      info = _nativeClient
          ? decodeNativeExecuteRequest(body.readBytes(body.remaining))
          : decodeExecuteRequest(body, lobStore: _lobStore);
    } catch (e) {
      server._log('conn $id EXECUTE decode error: $e');
      _sendTtc(buildExecuteError(600, 'internal error decoding execute'));
      return;
    }
    if (_phase != OraclePhase.ready) {
      _sendTtc(buildExecuteError(1012, 'not logged on'));
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
    server._log('conn $id EXECUTE [cursor $cursorId] "$sql"'
        '${info.hasBinds ? ' binds=${info.binds}' : ''}');
    // Free the previous query's fetched column LOBs; the client has already
    // read them (via ttcLobOp) before issuing this statement.
    _lobStore.clearColumnLobs();
    final response = await _guarded<Uint8List>(sql, () async {
      try {
        // Serve the client's connect-time data-dictionary probes synthetically;
        // the SQL engine has no Oracle system catalog.
        final QueryResult result;
        final sys = _systemQueryResult(sql);
        if (sys != null) {
          result = sys;
        } else if (info.hasBinds) {
          result = await _executeWithBinds(sql, info.binds);
        } else {
          result = await server.db.execute(sql);
        }
        if (_nativeClient && result.columns.isNotEmpty) {
          return canEncodeNativeQuery(result)
              ? buildNativeQueryResponse(result)
              : buildExecuteError(900,
                  'ORA-00000: native result shape not yet supported');
        }
        if (_nativeClient) {
          return buildNativeDmlResponse(result.affected);
        }
        return result.columns.isNotEmpty
            ? buildQueryResponse(result, cursorId: cursorId, lobStore: _lobStore)
            : buildDmlResponse(result, cursorId: cursorId);
      } catch (e) {
        return buildExecuteError(900, _oraErrorText(e));
      }
    });
    _sendTtc(response, dataFlags: _nativeClient ? 0x2000 : 0);
  }

  /// Binds the wire's positional [binds] to the SQL's placeholders (in
  /// first-appearance order) and runs it. Oracle sends bind values positionally;
  /// the engine tokenizes `:name` / `:1` as named and `?` as positional.
  Future<QueryResult> _executeWithBinds(String sql, List<Object?> binds) {
    final positional = <Object?>[];
    final named = <String, Object?>{};
    final seen = <String>{};
    var i = 0;
    for (final tok in Lexer(sql).tokenize()) {
      if (tok.type != TokType.param || !seen.add(tok.text)) continue;
      final value = i < binds.length ? binds[i] : null;
      i++;
      if (tok.text.startsWith('?')) {
        final idx = tok.text == '?'
            ? positional.length + 1
            : int.parse(tok.text.substring(1));
        while (positional.length < idx) {
          positional.add(null);
        }
        positional[idx - 1] = value;
      } else {
        named[tok.text.substring(1)] = value; // strip the sigil
      }
    }
    return server.db.executeWith(sql, positional: positional, named: named);
  }

  /// Wraps a TTC message body in one or more TNS DATA packets (split at the
  /// negotiated SDU) and sends them. The client reassembles the packets into a
  /// single TTC stream, so large result sets are not bounded by one packet.
  void _sendTtc(Uint8List ttcBody, {int dataFlags = 0}) {
    final maxPayload = _sdu - tnsHeaderSize - 2; // header + 2 data-flag bytes
    if (ttcBody.length <= maxPayload) {
      _send(buildDataPacket(ttcBody,
          largeSdu: _useLargeSdu, flags: dataFlags));
      return;
    }
    for (var offset = 0; offset < ttcBody.length; offset += maxPayload) {
      final end = (offset + maxPayload < ttcBody.length)
          ? offset + maxPayload
          : ttcBody.length;
      _send(buildDataPacket(Uint8List.sublistView(ttcBody, offset, end),
          largeSdu: _useLargeSdu, flags: dataFlags));
    }
  }

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

/// Synthesizes results for the Oracle data-dictionary probes a thin client
/// issues at connect time (the SQL engine has no Oracle system catalog).
/// Returns null for anything else so the real engine handles it.
QueryResult? _systemQueryResult(String sql) {
  final s = sql.toLowerCase();
  if (s.contains('nls_database_parameters') ||
      s.contains('nls_session_parameters')) {
    // The driver reads NLS_CHARACTERSET / NLS_NCHAR_CHARACTERSET to pick its
    // codecs; report the UTF-8 / UTF-16 pair the negotiation already advertised.
    return const QueryResult(
      columns: ['PARAMETER', 'VALUE'],
      rows: [
        ['NLS_CHARACTERSET', 'AL32UTF8'],
        ['NLS_NCHAR_CHARACTERSET', 'AL16UTF16'],
      ],
    );
  }
  return null;
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
