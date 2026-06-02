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
  static const longlong = 0x08;
  static const double_ = 0x05;
  static const null_ = 0x06;
  static const blob = 0xfc;
  static const varString = 0xfd;
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
  ServerSocket? _socket;
  final Set<_Conn> _conns = <_Conn>{};
  int _nextThreadId = 1;
  void Function(String msg)? onLog;

  MySqlServer(
    this.db, {
    InternetAddress? address,
    this.port = 3306,
    this.password,
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
  final Socket socket;
  final int threadId;
  final BytesBuilder _in = BytesBuilder(copy: false);
  late final Uint8List _scramble;
  _Phase _phase = _Phase.handshake;
  int _seq = 0;
  StreamSubscription<List<int>>? _sub;

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
    const caps =
        _Cap.longPassword |
        _Cap.foundRows |
        _Cap.longFlag |
        _Cap.connectWithDb |
        _Cap.protocol41 |
        _Cap.transactions |
        _Cap.secureConnection |
        _Cap.pluginAuth |
        _Cap.deprecateEof;
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

    if (pluginName != 'mysql_native_password') {
      _sendErr(
        2059,
        'HY000',
        'Authentication plugin "$pluginName" not supported (use mysql_native_password)',
      );
      await close();
      return;
    }

    if (!_checkNativePassword(authResp)) {
      _sendErr(1045, '28000', "Access denied for user '$username'");
      await close();
      return;
    }
    _sendOk();
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
      case _Cmd.stmtExecute:
      case _Cmd.stmtClose:
      case _Cmd.stmtReset:
        _sendErr(
          1295,
          'HY000',
          'Prepared statements not yet supported by dart-db-server mysql wire',
        );
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
