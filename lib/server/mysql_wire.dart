/// Minimal MySQL classic wire protocol front-end for [Database].
///
/// Speaks enough of the protocol that the official `mysql` CLI, MySQL
/// Workbench and standard drivers (JDBC, `package:mysql_client`, etc.)
/// can connect, log in with `mysql_native_password`, run text
/// `COM_QUERY` statements, and read text-protocol result sets.
///
/// Scope of this scaffold:
///   * Handshake v10 + `mysql_native_password` (empty or SHA1-challenged).
///   * `COM_QUERY`, `COM_PING`, `COM_QUIT`, `COM_INIT_DB`, `COM_STATISTICS`,
///     `COM_FIELD_LIST` (minimal).
///   * `COM_STMT_*` (prepared statements), SSL/`COM_SSL_REQUEST`,
///     `caching_sha2_password`, compression, and the X protocol are all
///     TODO — clients that demand them will receive an ERR packet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'database.dart';
import 'prepared.dart';
import 'result.dart';
import 'schema.dart' show storageToJsonValue;

// ---------------------------------------------------------------------------
// Protocol constants
// ---------------------------------------------------------------------------

class _Cap {
  static const longPassword = 0x00000001;
  static const foundRows = 0x00000002;
  static const longFlag = 0x00000004;
  static const connectWithDb = 0x00000008;
  static const protocol41 = 0x00000200;
  static const transactions = 0x00002000;
  static const secureConnection = 0x00008000;
  static const multiStatements = 0x00010000;
  static const multiResults = 0x00020000;
  static const psMultiResults = 0x00040000;
  static const ssl = 0x00000800;
  static const pluginAuth = 0x00080000;
  static const pluginAuthLenEncClientData = 0x00200000;
  static const deprecateEof = 0x01000000;
}

class _Cmd {
  static const quit = 0x01;
  static const initDb = 0x02;
  static const query = 0x03;
  static const fieldList = 0x04;
  static const ping = 0x0e;
  static const statistics = 0x09;
  static const stmtPrepare = 0x16;
  static const stmtExecute = 0x17;
  static const stmtClose = 0x19;
  static const stmtReset = 0x1a;
}

class _FieldType {
  static const tiny = 0x01;
  static const short_ = 0x02;
  static const long_ = 0x03;
  static const float_ = 0x04;
  static const double_ = 0x05;
  static const null_ = 0x06;
  static const timestamp = 0x07;
  static const longlong = 0x08;
  static const date = 0x0a;
  static const time = 0x0b;
  static const datetime = 0x0c;
  static const newDecimal = 0xf6;
  static const blob = 0xfc;
  static const varString = 0xfd;
  static const string_ = 0xfe;
}

const int _statusAutocommit = 0x0002;
const int _utf8mb4Collation = 255;
const String _serverVersion = '8.0.0-dart_db_server';

// ---------------------------------------------------------------------------
// Public server
// ---------------------------------------------------------------------------

/// MySQL classic-protocol server fronting a [Database].
///
/// Pass [password] to require `mysql_native_password` auth; leave it null
/// (or empty) to accept any client unconditionally.
class MySqlServer {
  final Database db;
  final InternetAddress address;
  final int port;
  final String? password;
  /// Optional TLS context; if non-null the server advertises CLIENT_SSL
  /// in the handshake and accepts an SSLRequest packet to upgrade the
  /// connection to TLS before reading the real HandshakeResponse.
  final SecurityContext? tlsContext;
  ServerSocket? _socket;
  final Set<_Conn> _conns = <_Conn>{};
  int _nextThreadId = 1;
  void Function(String msg)? onLog;

  MySqlServer(
    this.db, {
    InternetAddress? address,
    this.port = 3306,
    this.password,
    this.tlsContext,
  }) : address = address ?? InternetAddress.loopbackIPv4;

  Future<void> start() async {
    _socket = await ServerSocket.bind(address, port);
    _log('listening on ${address.address}:${_socket!.port} (mysql wire)');
    _socket!.listen(_accept);
  }

  /// The actual port bound by [start]; useful when [port] was 0.
  int get boundPort => _socket?.port ?? port;

  Future<void> stop() async {
    for (final c in _conns.toList()) {
      await c.close();
    }
    await _socket?.close();
  }

  void _accept(Socket socket) {
    final id = _nextThreadId++;
    final conn = _Conn(this, socket, id);
    _conns.add(conn);
    conn.start();
  }

  void _log(String msg) => (onLog ?? print).call('[mysql] $msg');
}

// ---------------------------------------------------------------------------
// Per-connection state machine
// ---------------------------------------------------------------------------

enum _Phase { handshake, command }

class _Conn {
  final MySqlServer server;
  Socket socket;
  final int threadId;
  final BytesBuilder _in = BytesBuilder(copy: false);
  late final Uint8List _scramble;
  _Phase _phase = _Phase.handshake;
  int _seq = 0;
  StreamSubscription<Uint8List>? _sub;
  bool _tlsActive = false;

  /// Active prepared statements keyed by statement id (1-based).
  final Map<int, _Prepared> _prepared = <int, _Prepared>{};
  int _nextStmtId = 1;

  _Conn(this.server, this.socket, this.threadId);

  void start() {
    _scramble = _randomScramble();
    _sendHandshake();
    _sub = socket.listen(
      _onData,
      onError: (Object e, StackTrace st) {
        server._log('conn $threadId error: $e');
      },
      onDone: () {
        server._conns.remove(this);
      },
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    await _sub?.cancel();
    await socket.close();
    server._conns.remove(this);
  }

  void _onData(List<int> chunk) {
    _in.add(chunk);
    // Try to consume as many full packets as available.
    while (true) {
      final pkt = _tryReadPacket();
      if (pkt == null) return;
      // unawaited; errors are reported as ERR packets inside.
      _handlePacket(pkt);
    }
  }

  ({Uint8List payload, int seq})? _tryReadPacket() {
    final buf = _in.toBytes();
    if (buf.length < 4) return null;
    final len = buf[0] | (buf[1] << 8) | (buf[2] << 16);
    final seq = buf[3];
    if (buf.length < 4 + len) return null;
    final payload = Uint8List.sublistView(buf, 4, 4 + len);
    // Re-buffer the remainder.
    _in.clear();
    if (buf.length > 4 + len) {
      _in.add(Uint8List.sublistView(buf, 4 + len));
    }
    _seq = (seq + 1) & 0xff;
    return (payload: payload, seq: seq);
  }

  Future<void> _handlePacket(({Uint8List payload, int seq}) pkt) async {
    try {
      switch (_phase) {
        case _Phase.handshake:
          if (!_tlsActive && _looksLikeSslRequest(pkt.payload)) {
            await _upgradeToTls();
            // Stay in handshake phase; the real HandshakeResponse arrives
            // on the TLS-wrapped socket as the next packet.
            break;
          }
          await _handleHandshakeResponse(pkt.payload);
          _phase = _Phase.command;
          break;
        case _Phase.command:
          // Each command starts a new packet sequence at 0; the reply
          // continues from seq 1 onward.
          _seq = 1;
          await _handleCommand(pkt.payload);
          break;
      }
    } catch (e) {
      _sendErr(1064, '42000', e.toString());
    }
  }

  /// An SSLRequest packet is a HandshakeResponse41 truncated after the
  /// 23-byte reserved field: 4 caps + 4 max_packet + 1 charset + 23 = 32
  /// bytes, with the CLIENT_SSL capability bit set.
  bool _looksLikeSslRequest(Uint8List payload) {
    if (server.tlsContext == null) return false;
    if (payload.length != 32) return false;
    final caps = payload[0] |
        (payload[1] << 8) |
        (payload[2] << 16) |
        (payload[3] << 24);
    return (caps & _Cap.ssl) != 0;
  }

  Future<void> _upgradeToTls() async {
    final ctx = server.tlsContext!;
    final oldSub = _sub;
    // Pause (do not cancel) the existing listener: cancelling can close
    // the underlying socket before SecureSocket.secureServer detaches it.
    oldSub?.pause();
    final buffered = _in.toBytes();
    _in.clear();
    final oldSocket = socket;
    final secure = await SecureSocket.secureServer(
      oldSocket,
      ctx,
      bufferedData: buffered.isEmpty ? null : buffered,
    );
    await oldSub?.cancel();
    socket = secure;
    _tlsActive = true;
    _sub = secure.listen(
      _onData,
      onError: (Object e, StackTrace st) {
        server._log('conn $threadId tls error: $e');
      },
      onDone: () {
        server._conns.remove(this);
      },
      cancelOnError: false,
    );
  }

  // -------------------------------------------------------------------------
  // Handshake
  // -------------------------------------------------------------------------

  void _sendHandshake() {
    final b = _PacketBuilder();
    b.u8(10); // protocol version
    b.cstr(_serverVersion);
    b.u32(threadId);
    b.bytes(_scramble.sublist(0, 8));
    b.u8(0); // filler
    final caps = _Cap.longPassword |
        _Cap.foundRows |
        _Cap.longFlag |
        _Cap.connectWithDb |
        _Cap.protocol41 |
        _Cap.transactions |
        _Cap.secureConnection |
        _Cap.pluginAuth |
        _Cap.deprecateEof |
        (server.tlsContext != null ? _Cap.ssl : 0);
    b.u16(caps & 0xffff);
    b.u8(_utf8mb4Collation);
    b.u16(_statusAutocommit);
    b.u16((caps >> 16) & 0xffff);
    b.u8(21); // auth plugin data length
    b.bytes(Uint8List(10)); // reserved
    // Remaining 13 bytes: last 12 scramble bytes + NUL.
    b.bytes(_scramble.sublist(8, 20));
    b.u8(0);
    b.cstr('mysql_native_password');
    _writePacket(b.build(), seq: 0);
  }

  Future<void> _handleHandshakeResponse(Uint8List payload) async {
    final p = _PacketReader(payload);
    final clientCaps = p.u32();
    p.u32(); // max packet
    p.u8(); // charset
    p.skip(23);
    final username = p.cstr();
    Uint8List authResp;
    if ((clientCaps & _Cap.pluginAuthLenEncClientData) != 0) {
      final n = p.lenencInt();
      authResp = p.bytes(n);
    } else if ((clientCaps & _Cap.secureConnection) != 0) {
      final n = p.u8();
      authResp = p.bytes(n);
    } else {
      authResp = p.cstrBytes();
    }
    String? initDb;
    if ((clientCaps & _Cap.connectWithDb) != 0 && p.remaining > 0) {
      initDb = p.cstr();
    }
    String pluginName = 'mysql_native_password';
    if ((clientCaps & _Cap.pluginAuth) != 0 && p.remaining > 0) {
      pluginName = p.cstr();
    }

    server._log(
      'conn $threadId login user=$username db=${initDb ?? ""} '
      'plugin=$pluginName',
    );

    if (pluginName == 'mysql_native_password') {
      if (!_checkNativePassword(authResp)) {
        _sendErr(1045, '28000', "Access denied for user '$username'");
        await close();
        return;
      }
      _sendOk();
    } else if (pluginName == 'caching_sha2_password') {
      if (!_checkCachingSha2Password(authResp)) {
        _sendErr(1045, '28000', "Access denied for user '$username'");
        await close();
        return;
      }
      // Fast-auth success: AuthMoreData(0x01) + 0x03 byte, then OK.
      _sendAuthMoreData(Uint8List.fromList([0x03]));
      _sendOk();
    } else {
      _sendErr(
        2059,
        'HY000',
        'Authentication plugin "$pluginName" not supported '
            '(use mysql_native_password or caching_sha2_password)',
      );
      await close();
      return;
    }
  }

  bool _checkCachingSha2Password(Uint8List clientResp) {
    final pwd = server.password;
    if (pwd == null || pwd.isEmpty) {
      // Empty password: client sends a zero-length scramble response.
      return clientResp.isEmpty;
    }
    if (clientResp.length != 32) return false;
    // SHA256(password) XOR SHA256( SHA256(SHA256(password)) || scramble )
    final pwdBytes = utf8.encode(pwd);
    final h1 = sha256.convert(pwdBytes).bytes;
    final h2 = sha256.convert(h1).bytes;
    final mixInput = Uint8List(h2.length + 20)
      ..setRange(0, h2.length, h2)
      ..setRange(h2.length, h2.length + 20, _scramble.sublist(0, 20));
    final mix = sha256.convert(mixInput).bytes;
    for (var i = 0; i < 32; i++) {
      if ((h1[i] ^ mix[i]) != clientResp[i]) return false;
    }
    return true;
  }

  void _sendAuthMoreData(Uint8List data) {
    final b = _PacketBuilder();
    b.u8(0x01);
    b.bytes(data);
    _writePacket(b.build());
  }

  bool _checkNativePassword(Uint8List clientResp) {
    final pwd = server.password;
    if (pwd == null || pwd.isEmpty) {
      // No password required; client may still have sent one — accept either.
      return true;
    }
    if (clientResp.isEmpty) return false;
    // SHA1(password) XOR SHA1( scramble || SHA1( SHA1(password) ) )
    final pwdBytes = utf8.encode(pwd);
    final hash1 = sha1.convert(pwdBytes).bytes;
    final hash2 = sha1.convert(hash1).bytes;
    final scrambleHashInput =
        Uint8List(_scramble.length - 1 + hash2.length) // drop trailing NUL
          ..setRange(0, 20, _scramble.sublist(0, 20))
          ..setRange(20, 20 + hash2.length, hash2);
    final scrambleHash = sha1.convert(scrambleHashInput).bytes;
    if (clientResp.length != 20) return false;
    for (var i = 0; i < 20; i++) {
      if ((hash1[i] ^ scrambleHash[i]) != clientResp[i]) return false;
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  Future<void> _handleCommand(Uint8List payload) async {
    if (payload.isEmpty) {
      _sendErr(1047, 'HY000', 'Empty command');
      return;
    }
    final cmd = payload[0];
    switch (cmd) {
      case _Cmd.quit:
        await close();
        return;
      case _Cmd.ping:
        _sendOk();
        return;
      case _Cmd.initDb:
        // We don't model multiple databases; just ack.
        _sendOk();
        return;
      case _Cmd.statistics:
        const stats = 'Uptime: 0  dart-db-server';
        _writePacket(Uint8List.fromList(utf8.encode(stats)));
        return;
      case _Cmd.fieldList:
        // Minimal: report no columns (EOF / OK with deprecate-eof).
        _sendEofOrOk();
        return;
      case _Cmd.query:
        final sql = utf8.decode(payload.sublist(1));
        await _executeQuery(sql);
        return;
      case _Cmd.stmtPrepare:
        final sql = utf8.decode(payload.sublist(1));
        await _handleStmtPrepare(sql);
        return;
      case _Cmd.stmtExecute:
        await _handleStmtExecute(payload);
        return;
      case _Cmd.stmtClose:
        if (payload.length >= 5) {
          final id = payload[1] |
              (payload[2] << 8) |
              (payload[3] << 16) |
              (payload[4] << 24);
          _prepared.remove(id);
        }
        // COM_STMT_CLOSE has no reply.
        return;
      case _Cmd.stmtReset:
        // We have no long-data buffers to flush; just OK.
        _sendOk();
        return;
      default:
        _sendErr(1047, 'HY000', 'Unknown command 0x${cmd.toRadixString(16)}');
        return;
    }
  }

  Future<void> _executeQuery(String sql) async {
    List<QueryResult> results;
    try {
      results = await server.db.executeScript(sql);
    } catch (e) {
      _sendErr(1064, '42000', e.toString());
      return;
    }
    final last = results.isEmpty ? QueryResult.empty : results.last;
    if (last.columns.isEmpty) {
      _sendOk(affected: last.affected, info: last.message);
      return;
    }
    _sendResultSet(last);
  }

  // -------------------------------------------------------------------------
  // Prepared statements (COM_STMT_PREPARE / EXECUTE / CLOSE / RESET)
  // -------------------------------------------------------------------------

  Future<void> _handleStmtPrepare(String sql) async {
    PreparedStatement ps;
    try {
      ps = server.db.prepare(sql);
    } catch (e) {
      _sendErr(1064, '42000', e.toString());
      return;
    }
    final id = _nextStmtId++;
    final numParams = ps.positionalCount;
    _prepared[id] = _Prepared(id: id, ps: ps, numParams: numParams);

    // Prepare-OK: we report 0 columns up-front and let the EXECUTE response
    // carry the actual result-set metadata. Standard drivers tolerate this.
    final b = _PacketBuilder();
    b.u8(0x00); // status
    b.u32(id);
    b.u16(0); // num_columns
    b.u16(numParams);
    b.u8(0); // reserved
    b.u16(0); // warning_count
    _writePacket(b.build());

    // Per-parameter column defs (all reported as VAR_STRING), terminated
    // by an EOF unless DEPRECATE_EOF is set (we always negotiate it).
    if (numParams > 0) {
      for (var i = 0; i < numParams; i++) {
        _writePacket(_columnDef('?', _FieldType.varString));
      }
    }
  }

  Future<void> _handleStmtExecute(Uint8List payload) async {
    final r = _PacketReader(payload);
    r.u8(); // command byte
    final id = r.u32();
    final prep = _prepared[id];
    if (prep == null) {
      _sendErr(1243, 'HY000', 'Unknown prepared statement handler');
      return;
    }
    r.u8(); // flags (cursor type) — ignored
    r.u32(); // iteration_count — always 1

    final n = prep.numParams;
    final positional = <Object?>[];
    if (n > 0) {
      // NULL bitmap, offset = 0 for execute.
      final bitmapBytes = (n + 7) ~/ 8;
      final nullBitmap = r.bytes(bitmapBytes);
      final newBound = r.u8();
      if (newBound == 1) {
        // Param types are sent (2 bytes each).
        final types = <int>[];
        final unsigned = <bool>[];
        for (var i = 0; i < n; i++) {
          final t = r.u8();
          final flag = r.u8();
          types.add(t);
          unsigned.add((flag & 0x80) != 0);
        }
        prep.paramTypes = types;
        prep.paramUnsigned = unsigned;
      }
      // Read values for non-null params.
      for (var i = 0; i < n; i++) {
        final isNull = (nullBitmap[i ~/ 8] & (1 << (i % 8))) != 0;
        if (isNull) {
          positional.add(null);
          continue;
        }
        final type = prep.paramTypes != null && i < prep.paramTypes!.length
            ? prep.paramTypes![i]
            : _FieldType.varString;
        final unsigned =
            prep.paramUnsigned != null && i < prep.paramUnsigned!.length
                ? prep.paramUnsigned![i]
                : false;
        positional.add(_readBinaryValue(r, type, unsigned: unsigned));
      }
    }

    QueryResult result;
    try {
      // Bind positionals 1..n: PreparedStatement.execute uses 1-based.
      // The list is passed positionally; index 0 corresponds to `?1`.
      result = await prep.ps.execute(positional: positional);
    } catch (e) {
      _sendErr(1064, '42000', e.toString());
      return;
    }

    if (result.columns.isEmpty) {
      _sendOk(affected: result.affected, info: result.message);
      return;
    }
    _sendBinaryResultSet(result);
  }

  /// Decode a single MySQL binary-protocol parameter value at the
  /// current position of [r].
  Object? _readBinaryValue(_PacketReader r, int type, {bool unsigned = false}) {
    switch (type) {
      case _FieldType.tiny:
        final v = r.u8();
        return unsigned ? v : (v & 0x80 != 0 ? v - 0x100 : v);
      case _FieldType.short_:
        final v = r.u16();
        return unsigned ? v : (v & 0x8000 != 0 ? v - 0x10000 : v);
      case _FieldType.long_:
        final v = r.u32();
        return unsigned ? v : (v & 0x80000000 != 0 ? v - 0x100000000 : v);
      case _FieldType.longlong:
        var v = 0;
        for (var i = 0; i < 8; i++) {
          v |= r.u8() << (8 * i);
        }
        return v;
      case _FieldType.float_:
        final bytes = r.bytes(4);
        return ByteData.sublistView(bytes).getFloat32(0, Endian.little);
      case _FieldType.double_:
        final bytes = r.bytes(8);
        return ByteData.sublistView(bytes).getFloat64(0, Endian.little);
      case _FieldType.null_:
        return null;
      case _FieldType.date:
      case _FieldType.datetime:
      case _FieldType.timestamp:
        {
          final len = r.u8();
          if (len == 0) return null;
          final y = r.u16();
          final mo = r.u8();
          final d = r.u8();
          var h = 0, mi = 0, s = 0, us = 0;
          if (len >= 7) {
            h = r.u8();
            mi = r.u8();
            s = r.u8();
          }
          if (len >= 11) {
            us = r.u32();
          }
          String two(int v) => v.toString().padLeft(2, '0');
          final date = '${y.toString().padLeft(4, '0')}-${two(mo)}-${two(d)}';
          if (type == _FieldType.date) return date;
          final time = '${two(h)}:${two(mi)}:${two(s)}';
          if (us == 0) return '$date $time';
          return '$date $time.${us.toString().padLeft(6, '0')}';
        }
      case _FieldType.time:
        {
          final len = r.u8();
          if (len == 0) return '00:00:00';
          final isNeg = r.u8();
          r.u32(); // days
          final h = r.u8();
          final mi = r.u8();
          final s = r.u8();
          var us = 0;
          if (len >= 12) us = r.u32();
          String two(int v) => v.toString().padLeft(2, '0');
          final sign = isNeg == 1 ? '-' : '';
          if (us == 0) return '$sign${two(h)}:${two(mi)}:${two(s)}';
          return '$sign${two(h)}:${two(mi)}:${two(s)}.${us.toString().padLeft(6, '0')}';
        }
      case _FieldType.varString:
      case _FieldType.string_:
      case _FieldType.blob:
      case _FieldType.newDecimal:
      default:
        // Length-encoded string (varchar/blob/decimal/...).
        final len = r.lenencInt();
        final bytes = r.bytes(len);
        if (type == _FieldType.blob) return Uint8List.fromList(bytes);
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  void _sendBinaryResultSet(QueryResult r) {
    final cc = _PacketBuilder()..lenencInt(r.columns.length);
    _writePacket(cc.build());
    final types = <int>[for (final c in r.columns) _inferType(r, c)];
    for (var i = 0; i < r.columns.length; i++) {
      _writePacket(_columnDef(r.columns[i], types[i]));
    }
    for (final row in r.rows) {
      _writePacket(_buildBinaryRow(row, types));
    }
    _sendEofOrOk();
  }

  Uint8List _buildBinaryRow(List<Object?> row, List<int> types) {
    final b = _PacketBuilder();
    b.u8(0x00); // binary row packet header
    final n = row.length;
    final bitmapBytes = (n + 9) ~/ 8;
    final nullBitmap = Uint8List(bitmapBytes);
    for (var i = 0; i < n; i++) {
      if (row[i] == null) {
        final bitIdx = i + 2;
        nullBitmap[bitIdx ~/ 8] |= 1 << (bitIdx % 8);
      }
    }
    b.bytes(nullBitmap);
    for (var i = 0; i < n; i++) {
      final v = row[i];
      if (v == null) continue;
      _writeBinaryValue(b, v, types[i]);
    }
    return b.build();
  }

  void _writeBinaryValue(_PacketBuilder b, Object v, int type) {
    switch (type) {
      case _FieldType.tiny:
        b.u8(v is bool ? (v ? 1 : 0) : (v as num).toInt() & 0xff);
        return;
      case _FieldType.longlong:
        final n = (v as num).toInt();
        for (var i = 0; i < 8; i++) {
          b.u8((n >> (8 * i)) & 0xff);
        }
        return;
      case _FieldType.double_:
        final bytes = Uint8List(8);
        ByteData.sublistView(bytes)
            .setFloat64(0, (v as num).toDouble(), Endian.little);
        b.bytes(bytes);
        return;
      case _FieldType.blob:
        final bytes = v is List<int> ? v : utf8.encode(v.toString());
        b.lenencInt(bytes.length);
        b.bytes(bytes);
        return;
      case _FieldType.varString:
      default:
        b.lenencStr(_renderText(v));
        return;
    }
  }



  void _sendResultSet(QueryResult r) {
    // 1) column count
    final cc = _PacketBuilder()..lenencInt(r.columns.length);
    _writePacket(cc.build());
    // 2) column defs
    for (final name in r.columns) {
      final type = _inferType(r, name);
      _writePacket(_columnDef(name, type));
    }
    // (EOF after columns is omitted under CLIENT_DEPRECATE_EOF.)
    // 3) rows (text protocol)
    for (final row in r.rows) {
      final b = _PacketBuilder();
      for (final v in row) {
        if (v == null) {
          b.u8(0xfb);
        } else {
          final s = _renderText(v);
          b.lenencStr(s);
        }
      }
      _writePacket(b.build());
    }
    // 4) terminator (OK with EOF header under DEPRECATE_EOF)
    _sendEofOrOk();
  }

  int _inferType(QueryResult r, String col) {
    final idx = r.columns.indexOf(col);
    for (final row in r.rows) {
      final v = row[idx];
      if (v == null) continue;
      if (v is bool) return _FieldType.tiny;
      if (v is int) return _FieldType.longlong;
      if (v is double) return _FieldType.double_;
      if (v is List<int>) return _FieldType.blob;
      return _FieldType.varString;
    }
    return _FieldType.null_;
  }

  String _renderText(Object v) {
    if (v is bool) return v ? '1' : '0';
    if (v is num) return v.toString();
    if (v is List<int>) return utf8.decode(v, allowMalformed: true);
    final j = storageToJsonValue(v);
    return j is String ? j : j.toString();
  }

  // -------------------------------------------------------------------------
  // Packet senders
  // -------------------------------------------------------------------------

  void _sendOk({int affected = 0, int lastInsertId = 0, String? info}) {
    final b = _PacketBuilder();
    b.u8(0x00);
    b.lenencInt(affected);
    b.lenencInt(lastInsertId);
    b.u16(_statusAutocommit);
    b.u16(0); // warnings
    if (info != null && info.isNotEmpty) {
      b.bytes(Uint8List.fromList(utf8.encode(info)));
    }
    _writePacket(b.build());
  }

  void _sendEofOrOk() {
    // Under CLIENT_DEPRECATE_EOF, terminator is an OK packet with the 0xFE
    // header (length < 9). Older clients see this as a classic EOF.
    final b = _PacketBuilder();
    b.u8(0xfe);
    b.lenencInt(0); // affected
    b.lenencInt(0); // insert id
    b.u16(_statusAutocommit);
    b.u16(0); // warnings
    _writePacket(b.build());
  }

  void _sendErr(int code, String sqlState, String msg) {
    final b = _PacketBuilder();
    b.u8(0xff);
    b.u16(code);
    b.u8(0x23); // '#'
    b.bytes(Uint8List.fromList(sqlState.padRight(5, '0').codeUnits));
    b.bytes(Uint8List.fromList(utf8.encode(msg)));
    _writePacket(b.build());
  }

  Uint8List _columnDef(String name, int type) {
    final b = _PacketBuilder();
    b.lenencStr('def'); // catalog
    b.lenencStr(''); // schema
    b.lenencStr(''); // table
    b.lenencStr(''); // org_table
    b.lenencStr(name);
    b.lenencStr(name); // org_name
    b.lenencInt(0x0c); // length of fixed-length fields
    b.u16(_utf8mb4Collation);
    b.u32(0xffffffff); // column length
    b.u8(type);
    b.u16(0); // flags
    b.u8(0x1f); // decimals
    b.u16(0); // filler
    return b.build();
  }

  void _writePacket(Uint8List payload, {int? seq}) {
    final s = seq ?? _seq;
    _seq = (s + 1) & 0xff;
    final len = payload.length;
    final header = Uint8List(4);
    header[0] = len & 0xff;
    header[1] = (len >> 8) & 0xff;
    header[2] = (len >> 16) & 0xff;
    header[3] = s & 0xff;
    socket.add(header);
    socket.add(payload);
  }

  static final _rng = Random.secure();

  Uint8List _randomScramble() {
    // 20 bytes of non-zero random + trailing NUL slot.
    final out = Uint8List(21);
    for (var i = 0; i < 20; i++) {
      var b = 0;
      while (b == 0) {
        b = _rng.nextInt(256);
      }
      out[i] = b;
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Packet builder / reader
// ---------------------------------------------------------------------------

class _Prepared {
  final int id;
  final PreparedStatement ps;
  final int numParams;
  List<int>? paramTypes;
  List<bool>? paramUnsigned;
  _Prepared({required this.id, required this.ps, required this.numParams});
}

class _PacketBuilder {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v & 0xff);

  void u16(int v) {
    _b.addByte(v & 0xff);
    _b.addByte((v >> 8) & 0xff);
  }

  void u32(int v) {
    _b.addByte(v & 0xff);
    _b.addByte((v >> 8) & 0xff);
    _b.addByte((v >> 16) & 0xff);
    _b.addByte((v >> 24) & 0xff);
  }

  void bytes(List<int> b) => _b.add(b);

  void cstr(String s) {
    _b.add(utf8.encode(s));
    _b.addByte(0);
  }

  void lenencInt(int v) {
    if (v < 0xfb) {
      _b.addByte(v);
    } else if (v < 0x10000) {
      _b.addByte(0xfc);
      u16(v);
    } else if (v < 0x1000000) {
      _b.addByte(0xfd);
      _b.addByte(v & 0xff);
      _b.addByte((v >> 8) & 0xff);
      _b.addByte((v >> 16) & 0xff);
    } else {
      _b.addByte(0xfe);
      for (var i = 0; i < 8; i++) {
        _b.addByte((v >> (8 * i)) & 0xff);
      }
    }
  }

  void lenencStr(String s) {
    final bytes = utf8.encode(s);
    lenencInt(bytes.length);
    _b.add(bytes);
  }

  Uint8List build() => _b.toBytes();
}

class _PacketReader {
  final Uint8List _buf;
  int _pos = 0;

  _PacketReader(this._buf);

  int get remaining => _buf.length - _pos;

  int u8() => _buf[_pos++];

  int u16() {
    final v = _buf[_pos] | (_buf[_pos + 1] << 8);
    _pos += 2;
    return v;
  }

  int u32() {
    final v =
        _buf[_pos] |
        (_buf[_pos + 1] << 8) |
        (_buf[_pos + 2] << 16) |
        (_buf[_pos + 3] << 24);
    _pos += 4;
    return v;
  }

  void skip(int n) => _pos += n;

  Uint8List bytes(int n) {
    final out = Uint8List.sublistView(_buf, _pos, _pos + n);
    _pos += n;
    return out;
  }

  Uint8List cstrBytes() {
    final start = _pos;
    while (_pos < _buf.length && _buf[_pos] != 0) {
      _pos++;
    }
    final out = Uint8List.sublistView(_buf, start, _pos);
    if (_pos < _buf.length) _pos++; // skip NUL
    return out;
  }

  String cstr() => utf8.decode(cstrBytes());

  int lenencInt() {
    final h = u8();
    if (h < 0xfb) return h;
    if (h == 0xfc) return u16();
    if (h == 0xfd) {
      final v = _buf[_pos] | (_buf[_pos + 1] << 8) | (_buf[_pos + 2] << 16);
      _pos += 3;
      return v;
    }
    if (h == 0xfe) {
      var v = 0;
      for (var i = 0; i < 8; i++) {
        v |= _buf[_pos + i] << (8 * i);
      }
      _pos += 8;
      return v;
    }
    throw FormatException('invalid lenenc int header 0x${h.toRadixString(16)}');
  }
}
