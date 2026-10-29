/// HTTP + (future) WebSocket management API for the dart-db engine.
///
/// Embeds a live [Database] and exposes a small JSON REST surface for the
/// `dart-db-admin` Flutter tool. Dependency-free (`dart:io` [HttpServer]); binds
/// to loopback by default. Enable from the server entry point with
/// `--admin-port <n>` (and optionally `--admin-token <t>`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'database.dart';
import 'oracle_wire.dart';

/// Management API version (independent of the engine package version).
const String adminApiVersion = '0.1.0';

/// Serves the management REST API over HTTP for an admin GUI.
class AdminApiServer {
  AdminApiServer(
    this.db, {
    InternetAddress? address,
    this.port = 8088,
    this.token,
    this.nativeConnections,
    this.oracleServer,
  }) : address = address ?? InternetAddress.loopbackIPv4;

  final Database db;
  final InternetAddress address;
  final int port;

  /// When non-null, requests must send `Authorization: Bearer <token>`.
  final String? token;

  /// Optional probe for the native TCP server's live connection count.
  final int Function()? nativeConnections;

  /// Optional Oracle wire server, enabling the `/api/oracle*` endpoints.
  final OracleServer? oracleServer;

  HttpServer? _server;

  final DateTime _startedAt = DateTime.now();
  int _requestCount = 0;
  final Map<String, int> _pathCounts = <String, int>{};
  final Set<WebSocket> _eventClients = <WebSocket>{};
  Timer? _heartbeat;

  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    final server = await HttpServer.bind(address, port);
    _server = server;
    server.listen(_handle, onError: (_) {});
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      _broadcast({'type': 'heartbeat', 'status': db.haStatus().toJson()});
    });
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    for (final ws in _eventClients.toList()) {
      await ws.close();
    }
    _eventClients.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    // Permissive CORS (harmless for a desktop client; eases a future web build).
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    if (req.method == 'OPTIONS') {
      res.statusCode = HttpStatus.noContent;
      await res.close();
      return;
    }
    if (token != null && req.headers.value('authorization') != 'Bearer $token') {
      await _json(res, HttpStatus.unauthorized, {'error': 'unauthorized'});
      return;
    }

    final path = req.uri.path;
    _requestCount++;
    _pathCounts[path] = (_pathCounts[path] ?? 0) + 1;
    _broadcast({'type': 'request', 'method': req.method, 'path': path});
    try {
      if (path == '/api/events' && WebSocketTransformer.isUpgradeRequest(req)) {
        await _handleEvents(req);
        return;
      }
      if (req.method == 'GET' && path == '/api/routes') {
        await _json(res, HttpStatus.ok, {'routes': _routes});
        return;
      }
      if (req.method == 'GET' && path == '/api/health') {
        await _json(res, HttpStatus.ok, {'ok': true});
        return;
      }
      if (req.method == 'GET' && path == '/api/info') {
        await _json(res, HttpStatus.ok, _info());
        return;
      }
      if (req.method == 'GET' && path == '/api/status') {
        await _json(res, HttpStatus.ok, db.haStatus().toJson());
        return;
      }
      if (req.method == 'GET' && path == '/api/metrics') {
        await _json(res, HttpStatus.ok, _metrics());
        return;
      }
      if (req.method == 'GET' && path == '/api/stats') {
        await _json(res, HttpStatus.ok, await _stats());
        return;
      }
      if (req.method == 'GET' && path == '/api/sessions') {
        await _json(res, HttpStatus.ok, _sessions());
        return;
      }
      if (req.method == 'GET' && path == '/api/oracle') {
        await _json(res, HttpStatus.ok, _oracle());
        return;
      }
      if (req.method == 'GET' && path == '/api/oracle/users') {
        await _json(res, HttpStatus.ok, _oracleUsers());
        return;
      }
      if (req.method == 'POST' && path == '/api/oracle/users') {
        await _addOracleUser(req, res);
        return;
      }
      if (req.method == 'POST' && path == '/api/echo') {
        await _echo(req, res);
        return;
      }
      if (req.method == 'GET' && path == '/api/tables') {
        await _json(res, HttpStatus.ok, await _tables());
        return;
      }
      if (req.method == 'GET' && path == '/api/views') {
        await _json(res, HttpStatus.ok, await _views());
        return;
      }
      if (req.method == 'GET' && path == '/api/vector/indexes') {
        await _json(res, HttpStatus.ok, await _vectorIndexes());
        return;
      }
      if (req.method == 'GET' && path == '/api/vector/stats') {
        await _json(res, HttpStatus.ok, await _vectorStats());
        return;
      }
      if (req.method == 'GET' && path.startsWith('/api/tables/')) {
        await _tableColumns(res, Uri.decodeComponent(path.substring('/api/tables/'.length)));
        return;
      }
      if (req.method == 'POST' && path == '/api/query') {
        await _query(req, res);
        return;
      }
      await _json(res, HttpStatus.notFound, {'error': 'not found', 'path': path});
    } catch (e) {
      await _json(res, HttpStatus.internalServerError, {'error': '$e'});
    }
  }

  /// Self-describing route catalog, consumed by the admin tool's API probe.
  static const List<Map<String, Object?>> _routes = [
    {'method': 'GET', 'path': '/api/routes', 'description': 'List available endpoints'},
    {'method': 'GET', 'path': '/api/health', 'description': 'Liveness probe'},
    {'method': 'GET', 'path': '/api/info', 'description': 'Engine metadata'},
    {'method': 'GET', 'path': '/api/status', 'description': 'HA / replication status'},
    {'method': 'GET', 'path': '/api/metrics', 'description': 'Admin API uptime + request counters'},
    {'method': 'GET', 'path': '/api/stats', 'description': 'Table / view counts'},
    {'method': 'GET', 'path': '/api/sessions', 'description': 'Active connection counts'},
    {'method': 'GET', 'path': '/api/oracle', 'description': 'Oracle wire status (enabled, port, connections, users)'},
    {'method': 'GET', 'path': '/api/oracle/users', 'description': 'List Oracle users'},
    {
      'method': 'POST',
      'path': '/api/oracle/users',
      'description': 'Add an Oracle user',
      'sampleBody': {'username': 'scott', 'password': 'tiger', 'pbkdf2': true},
    },
    {'method': 'GET', 'path': '/api/tables', 'description': 'List table names'},
    {'method': 'GET', 'path': '/api/tables/{name}', 'description': 'Columns of a table'},
    {'method': 'GET', 'path': '/api/views', 'description': 'List view names'},
    {'method': 'GET', 'path': '/api/vector/indexes', 'description': 'Registered vector indexes (PRAGMA vector_index_list)'},
    {'method': 'GET', 'path': '/api/vector/stats', 'description': 'Vector index stats (PRAGMA vector_index_stats)'},
    {
      'method': 'POST',
      'path': '/api/echo',
      'description': 'Echo the request back (probe aid)',
      'sampleBody': {'hello': 'world'},
    },
    {
      'method': 'POST',
      'path': '/api/query',
      'description': 'Run one or more SQL statements',
      'sampleBody': {'sql': 'SELECT 1 AS answer;', 'maxRows': 1000},
    },
    {'method': 'WS', 'path': '/api/events', 'description': 'Live event stream (heartbeat + requests)'},
  ];

  Map<String, Object?> _info() => {
        'adminApiVersion': adminApiVersion,
        'path': db.path,
        'inMemory': db.path == null,
        'isReplica': db.isReplica,
      };

  Map<String, Object?> _metrics() => {
        'startedAt': _startedAt.toIso8601String(),
        'uptimeMs': DateTime.now().difference(_startedAt).inMilliseconds,
        'requests': _requestCount,
        'byPath': Map<String, int>.from(_pathCounts),
        'eventClients': _eventClients.length,
      };

  Future<Map<String, Object?>> _stats() async {
    final tables = (await _tables())['tables'] as List;
    final views = (await _views())['views'] as List;
    // `SHOW TABLES` includes views; exclude them from the table count.
    final viewNames = views.toSet();
    final tableCount = tables.where((t) => !viewNames.contains(t)).length;
    return {'tableCount': tableCount, 'viewCount': views.length};
  }

  Map<String, Object?> _sessions() => {
        'nativeConnections': nativeConnections?.call(),
        'eventSubscribers': _eventClients.length,
      };

  Map<String, Object?> _oracle() {
    final o = oracleServer;
    return {
      'enabled': o != null,
      'port': o?.boundPort,
      'connections': o?.connectionCount,
      'userCount': o?.userStore.usernames.length,
    };
  }

  Map<String, Object?> _oracleUsers() {
    final o = oracleServer;
    return {'users': o == null ? <String>[] : o.userStore.usernames.toList()};
  }

  Future<void> _addOracleUser(HttpRequest req, HttpResponse res) async {
    final o = oracleServer;
    if (o == null) {
      await _json(res, HttpStatus.serviceUnavailable,
          {'error': 'oracle wire not enabled'});
      return;
    }
    final body = await utf8.decoder.bind(req).join();
    final decoded = body.isEmpty ? null : jsonDecode(body);
    final username = decoded is Map ? decoded['username'] : null;
    final password = decoded is Map ? decoded['password'] : null;
    if (username is! String ||
        username.trim().isEmpty ||
        password is! String ||
        password.isEmpty) {
      await _json(res, HttpStatus.badRequest,
          {'error': 'username and password required'});
      return;
    }
    final pbkdf2 = decoded is Map && decoded['pbkdf2'] == true;
    if (pbkdf2) {
      o.userStore.addPbkdf2User(username.trim(), password);
    } else {
      o.userStore.addUser(username.trim(), password);
    }
    await _json(res, HttpStatus.ok, {
      'ok': true,
      'users': o.userStore.usernames.toList(),
    });
  }

  Future<Map<String, Object?>> _vectorIndexes() async {
    final results = await db.executeScript('PRAGMA vector_index_list');
    return {'indexes': results.isEmpty ? null : results.first.toJson()};
  }

  Future<Map<String, Object?>> _vectorStats() async {
    final results = await db.executeScript('PRAGMA vector_index_stats');
    return {'stats': results.isEmpty ? null : results.first.toJson()};
  }

  Future<void> _echo(HttpRequest req, HttpResponse res) async {
    final body = await utf8.decoder.bind(req).join();
    await _json(res, HttpStatus.ok, {
      'method': req.method,
      'path': req.uri.path,
      'query': req.uri.queryParameters,
      'body': body,
    });
  }

  Future<void> _handleEvents(HttpRequest req) async {
    final ws = await WebSocketTransformer.upgrade(req);
    _eventClients.add(ws);
    ws.add(jsonEncode({'type': 'hello', 'adminApiVersion': adminApiVersion}));
    ws.listen(
      (_) {},
      onDone: () => _eventClients.remove(ws),
      onError: (_) => _eventClients.remove(ws),
      cancelOnError: true,
    );
  }

  void _broadcast(Map<String, Object?> event) {
    if (_eventClients.isEmpty) return;
    final msg = jsonEncode(event);
    for (final ws in _eventClients.toList()) {
      try {
        ws.add(msg);
      } catch (_) {
        _eventClients.remove(ws);
      }
    }
  }

  Future<void> _query(HttpRequest req, HttpResponse res) async {
    final body = await utf8.decoder.bind(req).join();
    final Object? decoded = body.isEmpty ? null : jsonDecode(body);
    final sql = (decoded is Map ? decoded['sql'] : null);
    if (sql is! String || sql.trim().isEmpty) {
      await _json(res, HttpStatus.badRequest, {'error': 'missing "sql"'});
      return;
    }
    final maxRows =
        (decoded is Map && decoded['maxRows'] is int) ? decoded['maxRows'] as int : null;
    final sw = Stopwatch()..start();
    try {
      final results = await db.executeScript(sql);
      sw.stop();
      await _json(res, HttpStatus.ok, {
        'elapsedMs': sw.elapsedMilliseconds,
        'results': [
          for (final r in results)
            _capRows(r.toJson(), maxRows),
        ],
      });
    } catch (e) {
      sw.stop();
      await _json(res, HttpStatus.ok, {
        'elapsedMs': sw.elapsedMilliseconds,
        'error': '$e',
      });
    }
  }

  /// Caps a serialized result's row list to [maxRows] (null = unlimited),
  /// adding `truncated`/`totalRows` markers when it trims.
  Map<String, Object?> _capRows(Map<String, Object?> result, int? maxRows) {
    if (maxRows == null) return result;
    final rows = result['rows'];
    if (rows is List && rows.length > maxRows) {
      return {
        ...result,
        'rows': rows.sublist(0, maxRows),
        'truncated': true,
        'totalRows': rows.length,
      };
    }
    return result;
  }

  Future<Map<String, Object?>> _tables() async {
    final results = await db.executeScript('SHOW TABLES');
    final names = <String>[];
    if (results.isNotEmpty) {
      for (final row in results.first.rows) {
        if (row.isNotEmpty && row.first != null) names.add('${row.first}');
      }
    }
    names.sort();
    return {'tables': names};
  }

  Future<Map<String, Object?>> _views() async {
    final results = await db.executeScript(
        "SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name");
    final names = <String>[];
    if (results.isNotEmpty) {
      for (final row in results.first.rows) {
        if (row.isNotEmpty && row.first != null) names.add('${row.first}');
      }
    }
    return {'views': names};
  }

  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  Future<void> _tableColumns(HttpResponse res, String name) async {
    if (!_identifier.hasMatch(name)) {
      await _json(res, HttpStatus.badRequest, {'error': 'invalid table name'});
      return;
    }
    final results = await db.executeScript(
        "SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$name'");
    await _json(res, HttpStatus.ok, {
      'table': name,
      'columns': results.isEmpty ? <Object?>[] : results.first.toJson(),
    });
  }

  Future<void> _json(HttpResponse res, int status, Object? body) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }
}
