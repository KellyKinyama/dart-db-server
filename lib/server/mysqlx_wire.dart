/// Minimal MySQL X Protocol (DevAPI, port 33060) front-end for [Database].
///
/// The X Protocol is a protobuf-framed, message-oriented protocol — a second
/// front-end alongside the classic protocol in [MySqlServer]. Each message on
/// the wire is framed as:
///
/// ```
/// [4 bytes little-endian length] [1 byte message type] [length-1 bytes payload]
/// ```
///
/// where the payload is a protobuf-encoded `Mysqlx.*` message. This file
/// hand-rolls the small protobuf subset needed (varint / length-delimited /
/// fixed64) rather than depending on `package:protobuf` + generated code.
///
/// Implemented:
///   * `Connection.CapabilitiesGet/Set` (advertises auth mechanisms; TLS off).
///   * `Session.AuthenticateStart/Continue` with `MYSQL41` / `SHA256_MEMORY`
///     (challenge-response) and `PLAIN` mechanisms.
///   * `Sql.StmtExecute` (namespace `sql`) → `Resultset.ColumnMetaData` / `Row`
///     / `FetchDone` / `StmtExecuteOk`, with a `rows_affected` notice for DML.
///   * `Crud.Find/Insert/Update/Delete` (TABLE data model) translated to SQL.
///   * `Session.Reset`, `Session.Close`, `Connection.Close`.
///
/// Not yet supported (clients asking for these get an `Error`):
///   * CRUD document (collection) operations and document-path expressions.
///   * X-protocol TLS (`CapabilitiesSet tls=1`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'database.dart';
import 'result.dart';

// ---------------------------------------------------------------------------
// Protocol message-type constants
// ---------------------------------------------------------------------------

/// Client → server message types (`Mysqlx.ClientMessages.Type`).
class _ClientMsg {
  static const capabilitiesGet = 1;
  static const capabilitiesSet = 2;
  static const connectionClose = 3;
  static const authenticateStart = 4;
  static const authenticateContinue = 5;
  static const sessionReset = 6;
  static const sessionClose = 7;
  static const stmtExecute = 12;
  static const crudFind = 17;
  static const crudInsert = 18;
  static const crudUpdate = 19;
  static const crudDelete = 20;
}

/// Server → client message types (`Mysqlx.ServerMessages.Type`).
class _ServerMsg {
  static const ok = 0;
  static const error = 1;
  static const capabilities = 2;
  static const authenticateContinue = 3;
  static const authenticateOk = 4;
  static const notice = 11;
  static const columnMetaData = 12;
  static const row = 13;
  static const fetchDone = 14;
  static const stmtExecuteOk = 17;
}

/// `Resultset.ColumnMetaData.FieldType` values used here.
class _ColType {
  static const sint = 1;
  static const uint = 2;
  static const double_ = 5;
  static const bytes = 7;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

/// A MySQL X Protocol server exposing [db] on [port] (default 33060).
///
/// Pass [password] to require authentication (`MYSQL41` or `PLAIN`); leave it
/// null or empty to accept any client, mirroring [MySqlServer].
class MysqlxServer {
  final Database db;
  final InternetAddress address;
  final int port;
  final String? password;
  ServerSocket? _socket;
  final Set<_XConn> _conns = <_XConn>{};
  int _nextId = 1;
  void Function(String msg)? onLog;

  MysqlxServer(
    this.db, {
    InternetAddress? address,
    this.port = 33060,
    this.password,
  }) : address = address ?? InternetAddress.loopbackIPv4;

  Future<void> start() async {
    _socket = await ServerSocket.bind(address, port);
    _log('listening on ${address.address}:${_socket!.port} (mysqlx wire)');
    _socket!.listen(_accept);
  }

  /// The actual bound port; useful when [port] was 0.
  int get boundPort => _socket?.port ?? port;

  Future<void> stop() async {
    for (final c in _conns.toList()) {
      await c.close();
    }
    await _socket?.close();
  }

  void _accept(Socket socket) {
    final conn = _XConn(this, socket, _nextId++);
    _conns.add(conn);
    conn.start();
  }

  void _log(String msg) => (onLog ?? print).call('[mysqlx] $msg');
}

// ---------------------------------------------------------------------------
// Per-connection state machine
// ---------------------------------------------------------------------------

enum _XPhase { preAuth, authContinue, ready }

class _XConn {
  final MysqlxServer server;
  final Socket socket;
  final int id;
  final BytesBuilder _in = BytesBuilder(copy: false);
  StreamSubscription<Uint8List>? _sub;
  _XPhase _phase = _XPhase.preAuth;
  Uint8List? _salt; // MYSQL41 / SHA256_MEMORY challenge nonce
  String _authMech = ''; // the mechanism of an in-progress challenge

  _XConn(this.server, this.socket, this.id);

  void start() {
    _sub = socket.listen(
      _onData,
      onError: (Object e, StackTrace st) =>
          server._log('conn $id error: $e'),
      onDone: () => server._conns.remove(this),
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    await _sub?.cancel();
    await socket.close();
    server._conns.remove(this);
  }

  // -------------------------------------------------------------------------
  // Framing
  // -------------------------------------------------------------------------

  void _onData(List<int> chunk) {
    _in.add(chunk);
    while (true) {
      final msg = _tryReadMessage();
      if (msg == null) return;
      _handleMessage(msg.type, msg.payload);
    }
  }

  ({int type, Uint8List payload})? _tryReadMessage() {
    final buf = _in.toBytes();
    if (buf.length < 4) return null;
    final len = buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24);
    if (len < 1) {
      // Malformed; drop the connection.
      _in.clear();
      return null;
    }
    if (buf.length < 4 + len) return null;
    final type = buf[4];
    final payload = Uint8List.sublistView(buf, 5, 4 + len);
    final copy = Uint8List.fromList(payload);
    _in.clear();
    if (buf.length > 4 + len) {
      _in.add(Uint8List.sublistView(buf, 4 + len));
    }
    return (type: type, payload: copy);
  }

  void _writeMessage(int type, Uint8List payload) {
    final len = payload.length + 1;
    final header = Uint8List(5);
    header[0] = len & 0xff;
    header[1] = (len >> 8) & 0xff;
    header[2] = (len >> 16) & 0xff;
    header[3] = (len >> 24) & 0xff;
    header[4] = type & 0xff;
    socket.add(header);
    socket.add(payload);
  }

  // -------------------------------------------------------------------------
  // Dispatch
  // -------------------------------------------------------------------------

  Future<void> _handleMessage(int type, Uint8List payload) async {
    try {
      switch (type) {
        case _ClientMsg.capabilitiesGet:
          _writeMessage(_ServerMsg.capabilities, _buildCapabilities());
          return;
        case _ClientMsg.capabilitiesSet:
          // We advertise no settable capabilities (no X-protocol TLS); accept
          // the no-op so clients that probe can proceed.
          _writeMessage(_ServerMsg.ok, _Pb().build());
          return;
        case _ClientMsg.authenticateStart:
          _handleAuthStart(payload);
          return;
        case _ClientMsg.authenticateContinue:
          _handleAuthContinue(payload);
          return;
        case _ClientMsg.stmtExecute:
          if (_phase != _XPhase.ready) {
            _sendError(1045, 'HY000', 'Not authenticated');
            return;
          }
          await _handleStmtExecute(payload);
          return;
        case _ClientMsg.crudFind:
        case _ClientMsg.crudInsert:
        case _ClientMsg.crudUpdate:
        case _ClientMsg.crudDelete:
          if (_phase != _XPhase.ready) {
            _sendError(1045, 'HY000', 'Not authenticated');
            return;
          }
          await _handleCrud(type, payload);
          return;
        case _ClientMsg.sessionReset:
          _writeMessage(_ServerMsg.ok, _Pb().build());
          return;
        case _ClientMsg.sessionClose:
          _writeMessage(_ServerMsg.ok, (_Pb()..stringField(1, 'bye!')).build());
          return;
        case _ClientMsg.connectionClose:
          _writeMessage(_ServerMsg.ok, (_Pb()..stringField(1, 'bye!')).build());
          await close();
          return;
        default:
          _sendError(5000, 'HY000', 'Unexpected message type $type');
          return;
      }
    } catch (e) {
      _sendError(1064, '42000', e.toString());
    }
  }

  // -------------------------------------------------------------------------
  // Authentication
  // -------------------------------------------------------------------------

  void _handleAuthStart(Uint8List payload) {
    // AuthenticateStart { string mech_name = 1; bytes auth_data = 2;
    //                     bytes initial_response = 3; }
    String mech = '';
    Uint8List initial = Uint8List(0);
    final r = _PbReader(payload);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      switch (field) {
        case 1:
          mech = utf8.decode(r.bytes());
        case 2:
        case 3:
          initial = r.bytes();
        default:
          r.skip(wire);
      }
    }
    switch (mech.toUpperCase()) {
      case 'MYSQL41':
      case 'SHA256_MEMORY':
        final salt = _randomSalt();
        _salt = salt;
        _authMech = mech.toUpperCase();
        _phase = _XPhase.authContinue;
        _writeMessage(
          _ServerMsg.authenticateContinue,
          (_Pb()..bytesField(1, salt)).build(),
        );
      case 'PLAIN':
        if (_verifyPlain(initial)) {
          _authSucceeded();
        } else {
          _sendError(1045, 'HY000', 'Access denied');
        }
      default:
        _sendError(
          1251,
          'HY000',
          'Invalid authentication method $mech '
              '(use MYSQL41, SHA256_MEMORY or PLAIN)',
        );
    }
  }

  void _handleAuthContinue(Uint8List payload) {
    if (_phase != _XPhase.authContinue) {
      _sendError(1045, 'HY000', 'Unexpected authentication continuation');
      return;
    }
    // AuthenticateContinue { bytes auth_data = 1; }
    Uint8List authData = Uint8List(0);
    final r = _PbReader(payload);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      if (field == 1) {
        authData = r.bytes();
      } else {
        r.skip(wire);
      }
    }
    final ok = _authMech == 'SHA256_MEMORY'
        ? _verifySha256Memory(authData)
        : _verifyMysql41(authData);
    if (ok) {
      _authSucceeded();
    } else {
      _sendError(1045, 'HY000', 'Access denied');
    }
  }

  void _authSucceeded() {
    _phase = _XPhase.ready;
    _salt = null;
    _authMech = '';
    _writeMessage(_ServerMsg.authenticateOk, _Pb().build());
  }

  /// MYSQL41 response: `schema\0user\0*HEX40` where the hash is
  /// `SHA1(pwd) XOR SHA1(salt + SHA1(SHA1(pwd)))`.
  bool _verifyMysql41(Uint8List authData) {
    final pwd = server.password;
    final parts = _splitNul(authData);
    if (pwd == null || pwd.isEmpty) return true;
    if (parts.length < 3) return false;
    final response = parts[2];
    if (!response.startsWith('*')) return false;
    final salt = _salt ?? Uint8List(0);
    final h1 = sha1.convert(utf8.encode(pwd)).bytes;
    final h2 = sha1.convert(h1).bytes;
    final t = sha1.convert([...salt, ...h2]).bytes;
    final token = <int>[for (var i = 0; i < 20; i++) h1[i] ^ t[i]];
    final expected = token
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return response.substring(1).toUpperCase() == expected;
  }

  /// SHA256_MEMORY response: `schema\0user\0HEX64` where the hash is
  /// `SHA256(pwd) XOR SHA256(SHA256(SHA256(pwd)) + salt)`.
  bool _verifySha256Memory(Uint8List authData) {
    final pwd = server.password;
    final parts = _splitNul(authData);
    if (pwd == null || pwd.isEmpty) return true;
    if (parts.length < 3) return false;
    final response = parts[2];
    final salt = _salt ?? Uint8List(0);
    final h1 = sha256.convert(utf8.encode(pwd)).bytes;
    final h2 = sha256.convert(h1).bytes;
    final t = sha256.convert([...h2, ...salt]).bytes;
    final token = <int>[for (var i = 0; i < 32; i++) h1[i] ^ t[i]];
    final expected = token
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return response.toUpperCase() == expected;
  }

  /// PLAIN response: `authzid\0authcid\0password`.
  bool _verifyPlain(Uint8List authData) {
    final pwd = server.password;
    if (pwd == null || pwd.isEmpty) return true;
    final parts = _splitNul(authData);
    if (parts.length < 3) return false;
    return parts[2] == pwd;
  }

  List<String> _splitNul(Uint8List data) {
    final out = <String>[];
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] == 0) {
        out.add(utf8.decode(data.sublist(start, i)));
        start = i + 1;
      }
    }
    out.add(utf8.decode(data.sublist(start)));
    return out;
  }

  static final _rng = Random.secure();

  Uint8List _randomSalt() {
    final out = Uint8List(20);
    for (var i = 0; i < 20; i++) {
      var b = 0;
      while (b == 0) {
        b = _rng.nextInt(256);
      }
      out[i] = b;
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // SQL execution
  // -------------------------------------------------------------------------

  Future<void> _handleStmtExecute(Uint8List payload) async {
    // StmtExecute { bytes stmt = 1; repeated Any args = 2;
    //               string namespace = 3; }
    Uint8List? stmt;
    String namespace = 'sql';
    final args = <Object?>[];
    final r = _PbReader(payload);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      switch (field) {
        case 1:
          stmt = r.bytes();
        case 2:
          args.add(_decodeAny(r.bytes()));
        case 3:
          namespace = utf8.decode(r.bytes());
        default:
          r.skip(wire);
      }
    }
    if (namespace != 'sql') {
      _sendError(1047, 'HY000', 'Unsupported namespace "$namespace"');
      return;
    }
    final sql = utf8.decode(stmt ?? Uint8List(0));
    QueryResult result;
    try {
      result =
          args.isEmpty ? await server.db.execute(sql) : await server.db
              .executeWith(sql, positional: args);
    } catch (e) {
      _sendError(1064, '42000', e.toString());
      return;
    }
    if (result.columns.isNotEmpty) {
      _sendResultSet(result);
    } else {
      _sendRowsAffected(result.affected);
    }
    _writeMessage(_ServerMsg.stmtExecuteOk, _Pb().build());
  }

  // -------------------------------------------------------------------------
  // CRUD (Crud.Find / Insert / Update / Delete) — TABLE data model only.
  // Each message is translated to SQL and run through the shared engine.
  // -------------------------------------------------------------------------

  Future<void> _handleCrud(int type, Uint8List payload) async {
    final String sql;
    try {
      sql = switch (type) {
        _ClientMsg.crudFind => _crudFindSql(payload),
        _ClientMsg.crudInsert => _crudInsertSql(payload),
        _ClientMsg.crudUpdate => _crudUpdateSql(payload),
        _ClientMsg.crudDelete => _crudDeleteSql(payload),
        _ => throw StateError('Unsupported CRUD message $type'),
      };
    } catch (e) {
      _sendError(5014, 'HY000', 'CRUD translation failed: $e');
      return;
    }
    QueryResult result;
    try {
      result = await server.db.execute(sql);
    } catch (e) {
      _sendError(1064, '42000', e.toString());
      return;
    }
    if (result.columns.isNotEmpty) {
      _sendResultSet(result);
    } else {
      _sendRowsAffected(result.affected);
    }
    _writeMessage(_ServerMsg.stmtExecuteOk, _Pb().build());
  }

  String _crudFindSql(Uint8List payload) {
    // Find { collection=2; data_model=3; projection=4; criteria=5; limit=6;
    //        order=7; args=10 }
    String? table;
    final projections = <String>[];
    final orders = <String>[];
    Uint8List? criteria;
    int? limit;
    int? offset;
    final args = <Object?>[];
    final r = _PbReader(payload);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      switch (field) {
        case 2:
          table = _decodeCollection(r.bytes());
        case 4:
          projections.add(_decodeProjection(r.bytes(), args));
        case 5:
          criteria = r.bytes();
        case 6:
          final (rc, off) = _decodeLimit(r.bytes());
          limit = rc;
          offset = off;
        case 7:
          orders.add(_decodeOrder(r.bytes(), args));
        case 10:
          args.add(_decodeScalar(r.bytes()));
        default:
          r.skip(wire);
      }
    }
    final cols = projections.isEmpty ? '*' : projections.join(', ');
    final sb = StringBuffer('SELECT $cols FROM ${_requireTable(table)}');
    if (criteria != null) sb.write(' WHERE ${_exprToSql(criteria, args)}');
    if (orders.isNotEmpty) sb.write(' ORDER BY ${orders.join(', ')}');
    if (limit != null) {
      sb.write(' LIMIT $limit');
      if (offset != null && offset > 0) sb.write(' OFFSET $offset');
    }
    return sb.toString();
  }

  String _crudInsertSql(Uint8List payload) {
    // Insert { collection=1; data_model=2; projection(Column)=3; row=4; args=5 }
    String? table;
    final columns = <String>[];
    final rows = <Uint8List>[];
    final args = <Object?>[];
    final r = _PbReader(payload);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      switch (field) {
        case 1:
          table = _decodeCollection(r.bytes());
        case 3:
          columns.add(_decodeInsertColumn(r.bytes()));
        case 4:
          rows.add(r.bytes());
        case 5:
          args.add(_decodeScalar(r.bytes()));
        default:
          r.skip(wire);
      }
    }
    final colList = columns.isEmpty ? '' : ' (${columns.join(', ')})';
    final valueRows = <String>[];
    for (final row in rows) {
      // TypedRow { repeated Expr field = 1 }
      final fields = <String>[];
      final rr = _PbReader(row);
      while (rr.hasMore) {
        final (f, w) = rr.tag();
        if (f == 1) {
          fields.add(_exprToSql(rr.bytes(), args));
        } else {
          rr.skip(w);
        }
      }
      valueRows.add('(${fields.join(', ')})');
    }
    return 'INSERT INTO ${_requireTable(table)}$colList VALUES '
        '${valueRows.join(', ')}';
  }

  String _crudUpdateSql(Uint8List payload) {
    // Update { collection=2; data_model=3; criteria=4; limit=5; order=6;
    //          operation=7; args=8 }
    String? table;
    Uint8List? criteria;
    final sets = <String>[];
    final args = <Object?>[];
    final r = _PbReader(payload);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      switch (field) {
        case 2:
          table = _decodeCollection(r.bytes());
        case 4:
          criteria = r.bytes();
        case 7:
          sets.add(_decodeUpdateOperation(r.bytes(), args));
        case 8:
          args.add(_decodeScalar(r.bytes()));
        default:
          r.skip(wire);
      }
    }
    final sb = StringBuffer('UPDATE ${_requireTable(table)} SET '
        '${sets.join(', ')}');
    if (criteria != null) sb.write(' WHERE ${_exprToSql(criteria, args)}');
    return sb.toString();
  }

  String _crudDeleteSql(Uint8List payload) {
    // Delete { collection=1; data_model=2; criteria=3; limit=4; order=5; args=6 }
    String? table;
    Uint8List? criteria;
    final args = <Object?>[];
    final r = _PbReader(payload);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      switch (field) {
        case 1:
          table = _decodeCollection(r.bytes());
        case 3:
          criteria = r.bytes();
        case 6:
          args.add(_decodeScalar(r.bytes()));
        default:
          r.skip(wire);
      }
    }
    final sb = StringBuffer('DELETE FROM ${_requireTable(table)}');
    if (criteria != null) sb.write(' WHERE ${_exprToSql(criteria, args)}');
    return sb.toString();
  }

  String _requireTable(String? table) {
    if (table == null || table.isEmpty) {
      throw StateError('CRUD message has no collection name');
    }
    return table;
  }

  /// Collection { name=1; schema=2 } → `schema.name` or `name`.
  String _decodeCollection(Uint8List bytes) {
    final r = _PbReader(bytes);
    String? name;
    String? schema;
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          name = utf8.decode(r.bytes());
        case 2:
          schema = utf8.decode(r.bytes());
        default:
          r.skip(w);
      }
    }
    return schema == null || schema.isEmpty ? '$name' : '$schema.$name';
  }

  /// Projection { source(Expr)=1; alias=2 } → `expr [AS alias]`.
  String _decodeProjection(Uint8List bytes, List<Object?> args) {
    final r = _PbReader(bytes);
    String source = '*';
    String? alias;
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          source = _exprToSql(r.bytes(), args);
        case 2:
          alias = utf8.decode(r.bytes());
        default:
          r.skip(w);
      }
    }
    return alias == null ? source : '$source AS $alias';
  }

  /// Order { expr(Expr)=1; direction=2 (ASC=1/DESC=2) } → `expr [DESC]`.
  String _decodeOrder(Uint8List bytes, List<Object?> args) {
    final r = _PbReader(bytes);
    String expr = '';
    int dir = 1;
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          expr = _exprToSql(r.bytes(), args);
        case 2:
          dir = r.varint();
        default:
          r.skip(w);
      }
    }
    return dir == 2 ? '$expr DESC' : expr;
  }

  /// Limit { row_count=1; offset=2 }.
  (int, int?) _decodeLimit(Uint8List bytes) {
    final r = _PbReader(bytes);
    int rowCount = 0;
    int? offset;
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          rowCount = r.varint();
        case 2:
          offset = r.varint();
        default:
          r.skip(w);
      }
    }
    return (rowCount, offset);
  }

  /// Insert.Column { name=1 } → column name.
  String _decodeInsertColumn(Uint8List bytes) {
    final r = _PbReader(bytes);
    String name = '';
    while (r.hasMore) {
      final (f, w) = r.tag();
      if (f == 1) {
        name = utf8.decode(r.bytes());
      } else {
        r.skip(w);
      }
    }
    return name;
  }

  /// UpdateOperation { source(ColumnIdentifier)=1; operation=2; value(Expr)=3 }
  /// → `col = value` (table SET).
  String _decodeUpdateOperation(Uint8List bytes, List<Object?> args) {
    final r = _PbReader(bytes);
    String col = '';
    String value = 'NULL';
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          col = _decodeColumnIdentifier(r.bytes());
        case 3:
          value = _exprToSql(r.bytes(), args);
        default:
          r.skip(w);
      }
    }
    return '$col = $value';
  }

  /// Translate a `Mysqlx.Expr.Expr` to a SQL fragment. Supports identifiers,
  /// literals, placeholders (bound from [args]), operators and function calls.
  String _exprToSql(Uint8List bytes, List<Object?> args) {
    // Expr { type=1; identifier=2; literal=4; function_call=5; operator=6;
    //        position=7 }
    final r = _PbReader(bytes);
    int type = 0;
    Uint8List? identifier;
    Uint8List? literal;
    Uint8List? functionCall;
    Uint8List? operator;
    int? position;
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          type = r.varint();
        case 2:
          identifier = r.bytes();
        case 4:
          literal = r.bytes();
        case 5:
          functionCall = r.bytes();
        case 6:
          operator = r.bytes();
        case 7:
          position = r.varint();
        default:
          r.skip(w);
      }
    }
    switch (type) {
      case 1: // IDENT
        return _decodeColumnIdentifier(identifier ?? Uint8List(0));
      case 2: // LITERAL
        return _scalarToSql(_decodeScalar(literal ?? Uint8List(0)));
      case 4: // FUNC_CALL
        return _decodeFunctionCall(functionCall ?? Uint8List(0), args);
      case 5: // OPERATOR
        return _decodeOperator(operator ?? Uint8List(0), args);
      case 6: // PLACEHOLDER
        final i = position ?? 0;
        return _scalarToSql(i < args.length ? args[i] : null);
      default:
        return 'NULL';
    }
  }

  /// ColumnIdentifier { name=2; table_name=3; schema_name=4 }.
  String _decodeColumnIdentifier(Uint8List bytes) {
    final r = _PbReader(bytes);
    String? name;
    String? tableName;
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 2:
          name = utf8.decode(r.bytes());
        case 3:
          tableName = utf8.decode(r.bytes());
        default:
          r.skip(w);
      }
    }
    if (name == null) return '*';
    return tableName == null ? name : '$tableName.$name';
  }

  /// Operator { name=1; param(Expr)=2 }. Infix for binary/logical operators,
  /// prefix for `not`, special-cased `between`/`in`/`like`.
  String _decodeOperator(Uint8List bytes, List<Object?> args) {
    final r = _PbReader(bytes);
    String name = '';
    final params = <String>[];
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          name = utf8.decode(r.bytes());
        case 2:
          params.add(_exprToSql(r.bytes(), args));
        default:
          r.skip(w);
      }
    }
    switch (name) {
      case '==':
        return '(${params[0]} = ${params[1]})';
      case '!=':
        return '(${params[0]} <> ${params[1]})';
      case '&&':
        return '(${params.join(' AND ')})';
      case '||':
        return '(${params.join(' OR ')})';
      case 'not':
        return '(NOT ${params[0]})';
      case 'like':
        return '(${params[0]} LIKE ${params[1]})';
      case 'in':
        return '(${params[0]} IN (${params.skip(1).join(', ')}))';
      case 'between':
        return '(${params[0]} BETWEEN ${params[1]} AND ${params[2]})';
      case 'is':
        return '(${params[0]} IS ${params[1]})';
      case '>':
      case '>=':
      case '<':
      case '<=':
      case '+':
      case '-':
      case '*':
      case '/':
      case '%':
        if (params.length == 1) return '($name${params[0]})';
        return '(${params[0]} $name ${params[1]})';
      default:
        return '($name(${params.join(', ')}))';
    }
  }

  /// FunctionCall { name(Identifier)=1; param(Expr)=2 }.
  String _decodeFunctionCall(Uint8List bytes, List<Object?> args) {
    final r = _PbReader(bytes);
    String fname = '';
    final params = <String>[];
    while (r.hasMore) {
      final (f, w) = r.tag();
      switch (f) {
        case 1:
          fname = _decodeIdentifierName(r.bytes());
        case 2:
          params.add(_exprToSql(r.bytes(), args));
        default:
          r.skip(w);
      }
    }
    return '$fname(${params.join(', ')})';
  }

  /// Identifier { name=1; schema_name=2 }.
  String _decodeIdentifierName(Uint8List bytes) {
    final r = _PbReader(bytes);
    String name = '';
    while (r.hasMore) {
      final (f, w) = r.tag();
      if (f == 1) {
        name = utf8.decode(r.bytes());
      } else {
        r.skip(w);
      }
    }
    return name;
  }

  /// Render a Dart value as a SQL literal.
  String _scalarToSql(Object? v) {
    if (v == null) return 'NULL';
    if (v is bool) return v ? '1' : '0';
    if (v is num) return v.toString();
    if (v is Uint8List) {
      return "x'${v.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'";
    }
    return "'${v.toString().replaceAll("'", "''")}'";
  }

  void _sendResultSet(QueryResult r) {
    final colTypes = <int>[
      for (var i = 0; i < r.columns.length; i++) _inferColType(r, i),
    ];
    for (var i = 0; i < r.columns.length; i++) {
      _writeMessage(
        _ServerMsg.columnMetaData,
        _buildColumnMeta(r.columns[i], colTypes[i]),
      );
    }
    for (final row in r.rows) {
      _writeMessage(_ServerMsg.row, _buildRow(row, colTypes));
    }
    _writeMessage(_ServerMsg.fetchDone, _Pb().build());
  }

  void _sendRowsAffected(int affected) {
    // Notice.Frame { type=3 SessionStateChanged; scope=1 GLOBAL; payload }
    // payload: SessionStateChanged { param=4 ROWS_AFFECTED; value=Scalar }
    final scalar = (_Pb()
          ..varint(1, 2) // Scalar.Type.V_UINT
          ..varint(3, affected))
        .build();
    final stateChanged = (_Pb()
          ..varint(1, 4) // Parameter.ROWS_AFFECTED
          ..message(2, scalar))
        .build();
    final frame = (_Pb()
          ..varint(1, 3) // Frame.Type SESSION_STATE_CHANGED
          ..varint(2, 1) // Scope.GLOBAL
          ..message(3, stateChanged))
        .build();
    _writeMessage(_ServerMsg.notice, frame);
  }

  int _inferColType(QueryResult r, int idx) {
    var sawValue = false;
    var allInt = true;
    var allNum = true;
    for (final row in r.rows) {
      final v = row[idx];
      if (v == null) continue;
      sawValue = true;
      if (v is! num || v is bool) {
        allInt = false;
        allNum = false;
        break;
      }
      if (v is! int) allInt = false;
    }
    if (!sawValue) return _ColType.bytes;
    if (allInt) return _ColType.sint;
    if (allNum) return _ColType.double_;
    return _ColType.bytes;
  }

  Uint8List _buildColumnMeta(String name, int type) {
    final pb = _Pb()
      ..varint(1, type)
      ..bytesField(2, utf8.encode(name))
      ..bytesField(3, utf8.encode(name));
    // Mark text columns with utf8mb4 so clients don't treat BYTES as binary.
    if (type == _ColType.bytes) pb.varint(8, 255);
    return pb.build();
  }

  Uint8List _buildRow(List<Object?> row, List<int> colTypes) {
    final pb = _Pb();
    for (var i = 0; i < row.length; i++) {
      pb.bytesField(1, _encodeField(row[i], colTypes[i]));
    }
    return pb.build();
  }

  /// Encodes one result field. A NULL is a zero-length `bytes`; other types
  /// use the X-protocol per-type raw encoding.
  Uint8List _encodeField(Object? v, int colType) {
    if (v == null) return Uint8List(0);
    switch (colType) {
      case _ColType.sint:
        return _rawZigzag((v as num).toInt());
      case _ColType.uint:
        return _rawVarintBytes((v as num).toInt());
      case _ColType.double_:
        final bd = ByteData(8)..setFloat64(0, (v as num).toDouble(), Endian.little);
        return bd.buffer.asUint8List();
      case _ColType.bytes:
      default:
        if (v is Uint8List) return Uint8List.fromList([...v, 0]);
        if (v is List<int>) return Uint8List.fromList([...v, 0]);
        final s = v is bool ? (v ? '1' : '0') : v.toString();
        return Uint8List.fromList([...utf8.encode(s), 0]);
    }
  }

  static Uint8List _rawVarintBytes(int value) {
    final b = BytesBuilder();
    var x = value;
    while (true) {
      final part = x & 0x7f;
      x = x >>> 7;
      if (x != 0) {
        b.addByte(part | 0x80);
      } else {
        b.addByte(part);
        break;
      }
    }
    return b.toBytes();
  }

  static Uint8List _rawZigzag(int value) =>
      _rawVarintBytes((value << 1) ^ (value >> 63));

  // -------------------------------------------------------------------------
  // Capabilities
  // -------------------------------------------------------------------------

  Uint8List _buildCapabilities() {
    // Capabilities { repeated Capability capabilities = 1; }
    final pb = _Pb();
    pb.message(
      1,
      _capability(
        'authentication.mechanisms',
        _anyStringArray(const ['MYSQL41', 'PLAIN', 'SHA256_MEMORY']),
      ),
    );
    pb.message(1, _capability('tls', _anyBool(false)));
    pb.message(1, _capability('doc.formats', _anyString('text')));
    pb.message(1, _capability('node_type', _anyString('mysql')));
    return pb.build();
  }

  Uint8List _capability(String name, Uint8List anyValue) =>
      (_Pb()..stringField(1, name)..message(2, anyValue)).build();

  Uint8List _anyScalar(Uint8List scalar) =>
      (_Pb()..varint(1, 1)..message(2, scalar)).build(); // Any.Type.SCALAR

  Uint8List _anyString(String s) => _anyScalar(_scalarString(s));

  Uint8List _anyBool(bool b) => _anyScalar(
        (_Pb()..varint(1, 7)..varint(7, b ? 1 : 0)).build(), // V_BOOL
      );

  Uint8List _anyStringArray(List<String> xs) {
    final arr = _Pb();
    for (final s in xs) {
      arr.message(1, _anyString(s));
    }
    return (_Pb()..varint(1, 3)..message(4, arr.build())).build(); // ARRAY
  }

  Uint8List _scalarString(String s) {
    final strMsg = (_Pb()..bytesField(1, utf8.encode(s))).build();
    return (_Pb()..varint(1, 8)..message(8, strMsg)).build(); // V_STRING
  }

  // -------------------------------------------------------------------------
  // Datatypes.Any decoding (for StmtExecute args)
  // -------------------------------------------------------------------------

  Object? _decodeAny(Uint8List bytes) {
    // Any { Type type = 1; Scalar scalar = 2; Object obj = 3; Array array = 4 }
    final r = _PbReader(bytes);
    Uint8List? scalar;
    while (r.hasMore) {
      final (field, wire) = r.tag();
      if (field == 2) {
        scalar = r.bytes();
      } else {
        r.skip(wire);
      }
    }
    return scalar == null ? null : _decodeScalar(scalar);
  }

  Object? _decodeScalar(Uint8List bytes) {
    // Scalar { Type type=1; sint64 v_signed_int=2; uint64 v_unsigned_int=3;
    //          Octets v_octets=4; double v_double=5; bool v_bool=7;
    //          String v_string=8; }
    final r = _PbReader(bytes);
    int? scalarType;
    Object? value;
    while (r.hasMore) {
      final (field, wire) = r.tag();
      switch (field) {
        case 1:
          scalarType = r.varint();
        case 2:
          value = r.zigzag();
        case 3:
          value = r.varint();
        case 4:
          value = _decodeOctets(r.bytes());
        case 5:
          value = r.fixed64Double();
        case 7:
          value = r.varint() != 0;
        case 8:
          value = _decodeStringScalar(r.bytes());
        default:
          r.skip(wire);
      }
    }
    if (scalarType == 3) return null; // V_NULL
    return value;
  }

  Object? _decodeOctets(Uint8List bytes) {
    final r = _PbReader(bytes);
    Uint8List? value;
    while (r.hasMore) {
      final (field, wire) = r.tag();
      if (field == 1) {
        value = r.bytes();
      } else {
        r.skip(wire);
      }
    }
    return value == null ? null : Uint8List.fromList(value);
  }

  String _decodeStringScalar(Uint8List bytes) {
    final r = _PbReader(bytes);
    Uint8List value = Uint8List(0);
    while (r.hasMore) {
      final (field, wire) = r.tag();
      if (field == 1) {
        value = r.bytes();
      } else {
        r.skip(wire);
      }
    }
    return utf8.decode(value);
  }

  // -------------------------------------------------------------------------
  // Error
  // -------------------------------------------------------------------------

  void _sendError(int code, String sqlState, String msg) {
    // Error { Severity severity=1; uint32 code=2; string msg=3;
    //         string sql_state=4; }
    final pb = _Pb()
      ..varint(1, 0) // Severity.ERROR
      ..varint(2, code)
      ..stringField(3, msg)
      ..stringField(4, sqlState);
    _writeMessage(_ServerMsg.error, pb.build());
  }
}

// ---------------------------------------------------------------------------
// Minimal protobuf writer / reader
// ---------------------------------------------------------------------------

/// Writes a protobuf message field-by-field. Supports the wire types used by
/// the X-protocol subset: varint (0), 64-bit (1) and length-delimited (2).
class _Pb {
  final BytesBuilder _b = BytesBuilder();

  void _tag(int field, int wire) => _rawVarint((field << 3) | wire);

  void _rawVarint(int value) {
    var x = value;
    while (true) {
      final part = x & 0x7f;
      x = x >>> 7;
      if (x != 0) {
        _b.addByte(part | 0x80);
      } else {
        _b.addByte(part);
        break;
      }
    }
  }

  void varint(int field, int value) {
    _tag(field, 0);
    _rawVarint(value);
  }

  void bytesField(int field, List<int> data) {
    _tag(field, 2);
    _rawVarint(data.length);
    _b.add(data);
  }

  void stringField(int field, String s) => bytesField(field, utf8.encode(s));

  void message(int field, Uint8List msg) => bytesField(field, msg);

  Uint8List build() => _b.toBytes();
}

/// Reads protobuf fields from [data].
class _PbReader {
  final Uint8List data;
  int _p = 0;
  _PbReader(this.data);

  bool get hasMore => _p < data.length;

  int _rawVarint() {
    var shift = 0;
    var result = 0;
    while (true) {
      final b = data[_p++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }

  (int, int) tag() {
    final key = _rawVarint();
    return (key >> 3, key & 7);
  }

  int varint() => _rawVarint();

  int zigzag() {
    final v = _rawVarint();
    return (v >>> 1) ^ -(v & 1);
  }

  Uint8List bytes() {
    final len = _rawVarint();
    final out = Uint8List.sublistView(data, _p, _p + len);
    _p += len;
    return out;
  }

  double fixed64Double() {
    final bd = ByteData.sublistView(data, _p, _p + 8);
    _p += 8;
    return bd.getFloat64(0, Endian.little);
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        _rawVarint();
      case 1:
        _p += 8;
      case 2:
        _p += _rawVarint();
      case 5:
        _p += 4;
    }
  }
}
