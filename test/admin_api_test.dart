import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

/// End-to-end tests for [AdminApiServer] against an in-memory [Database].
void main() {
  group('AdminApiServer', () {
    late Database db;
    late AdminApiServer api;
    late String origin;

    Future<_Res> get(String path, {String? token}) =>
        _request('GET', '$origin$path', token: token);
    Future<_Res> post(String path, Object? body, {String? token}) =>
        _request('POST', '$origin$path', body: body, token: token);

    setUp(() async {
      db = await Database.open();
      api = AdminApiServer(db, port: 0, nativeConnections: () => 7);
      await api.start();
      origin = 'http://127.0.0.1:${api.boundPort}';
    });

    tearDown(() async {
      await api.stop();
      await db.close();
    });

    test('GET /api/health', () async {
      final r = await get('/api/health');
      expect(r.status, 200);
      expect(r.json['ok'], true);
    });

    test('GET /api/info', () async {
      final r = await get('/api/info');
      expect(r.status, 200);
      expect(r.json['inMemory'], true);
      expect(r.json['adminApiVersion'], isNotEmpty);
    });

    test('GET /api/routes lists the endpoints', () async {
      final r = await get('/api/routes');
      expect(r.status, 200);
      final paths = [
        for (final route in r.json['routes'] as List) route['path'],
      ];
      expect(
        paths,
        containsAll(<String>[
          '/api/health',
          '/api/query',
          '/api/tables',
          '/api/events',
        ]),
      );
    });

    test('GET /api/status', () async {
      final r = await get('/api/status');
      expect(r.status, 200);
      expect(r.json['role'], isNotNull);
    });

    test('POST /api/query runs DDL/DML/SELECT', () async {
      await post('/api/query', {
        'sql': 'CREATE TABLE t(id INTEGER, name TEXT);'
            "INSERT INTO t VALUES (1,'a'),(2,'b');",
      });
      final r = await post('/api/query', {'sql': 'SELECT * FROM t ORDER BY id;'});
      expect(r.status, 200);
      final results = r.json['results'] as List;
      final select = results.last as Map;
      expect(select['columns'], ['id', 'name']);
      expect(select['rows'], [
        [1, 'a'],
        [2, 'b'],
      ]);
    });

    test('POST /api/query caps rows with maxRows', () async {
      await post('/api/query', {
        'sql': 'CREATE TABLE big(n INTEGER);'
            'INSERT INTO big VALUES (1),(2),(3),(4),(5);',
      });
      final r =
          await post('/api/query', {'sql': 'SELECT * FROM big;', 'maxRows': 2});
      final result = (r.json['results'] as List).first as Map;
      expect((result['rows'] as List).length, 2);
      expect(result['truncated'], true);
      expect(result['totalRows'], 5);
    });

    test('POST /api/query returns SQL errors in-band (200 + error)', () async {
      final r = await post('/api/query', {'sql': 'SELECT * FROM missing;'});
      expect(r.status, 200);
      expect(r.json['error'], isNotNull);
    });

    test('POST /api/query rejects empty sql with 400', () async {
      final r = await post('/api/query', {'sql': '   '});
      expect(r.status, 400);
    });

    test('GET /api/tables and /api/views', () async {
      await post('/api/query', {
        'sql': 'CREATE TABLE emp(id INTEGER);'
            'CREATE VIEW v AS SELECT id FROM emp;',
      });
      final tables = await get('/api/tables');
      expect(tables.json['tables'], contains('emp'));
      final views = await get('/api/views');
      expect(views.json['views'], contains('v'));
    });

    test('GET /api/tables/{name} returns columns', () async {
      await post('/api/query', {'sql': 'CREATE TABLE emp(id INTEGER, name TEXT);'});
      final r = await get('/api/tables/emp');
      expect(r.status, 200);
      expect(r.json['table'], 'emp');
      final cols = (r.json['columns'] as Map)['rows'] as List;
      final names = [for (final row in cols) (row as List)[3]];
      expect(names, containsAll(['id', 'name']));
    });

    test('GET /api/tables/{name} rejects invalid identifiers', () async {
      final r = await get('/api/tables/1bad;DROP');
      expect(r.status, 400);
    });

    test('GET /api/stats counts tables and views', () async {
      await post('/api/query', {
        'sql': 'CREATE TABLE a(x INTEGER);CREATE TABLE b(x INTEGER);'
            'CREATE VIEW va AS SELECT x FROM a;',
      });
      final r = await get('/api/stats');
      expect(r.json['tableCount'], 2);
      expect(r.json['viewCount'], 1);
    });

    test('GET /api/sessions reports native connections', () async {
      final r = await get('/api/sessions');
      expect(r.json['nativeConnections'], 7);
      expect(r.json['eventSubscribers'], 0);
    });

    test('GET /api/metrics tracks request counters', () async {
      await get('/api/health');
      await get('/api/health');
      final r = await get('/api/metrics');
      expect(r.json['requests'], greaterThanOrEqualTo(3));
      expect((r.json['byPath'] as Map)['/api/health'], greaterThanOrEqualTo(2));
    });

    test('POST /api/echo echoes the request', () async {
      final r = await post('/api/echo', {'hello': 'world'});
      expect(r.status, 200);
      expect(r.json['method'], 'POST');
      expect(r.json['path'], '/api/echo');
      expect(r.json['body'], contains('world'));
    });

    test('unknown path returns 404', () async {
      final r = await get('/api/nope');
      expect(r.status, 404);
    });

    test('WS /api/events sends hello then heartbeat and request events',
        () async {
      final ws = await WebSocket.connect('ws://127.0.0.1:${api.boundPort}/api/events');
      final events = <Map<String, Object?>>[];
      final sub = ws.listen(
          (data) => events.add(jsonDecode('$data') as Map<String, Object?>));

      // Trigger a 'request' broadcast.
      await get('/api/health');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events.first['type'], 'hello');
      expect(events.any((e) => e['type'] == 'request'), isTrue);

      await sub.cancel();
      await ws.close();
    });

    group('with --admin-token', () {
      late Database tdb;
      late AdminApiServer tapi;
      late String torigin;

      setUp(() async {
        tdb = await Database.open();
        tapi = AdminApiServer(tdb, port: 0, token: 'sekret');
        await tapi.start();
        torigin = 'http://127.0.0.1:${tapi.boundPort}';
      });

      tearDown(() async {
        await tapi.stop();
        await tdb.close();
      });

      test('rejects missing/wrong token with 401, accepts correct', () async {
        expect((await _request('GET', '$torigin/api/health')).status, 401);
        expect(
          (await _request('GET', '$torigin/api/health', token: 'nope')).status,
          401,
        );
        final ok = await _request('GET', '$torigin/api/health', token: 'sekret');
        expect(ok.status, 200);
        expect(ok.json['ok'], true);
      });
    });
  });
}

class _Res {
  _Res(this.status, this.body);
  final int status;
  final String body;
  Map<String, Object?> get json =>
      body.isEmpty ? const {} : jsonDecode(body) as Map<String, Object?>;
}

Future<_Res> _request(String method, String url,
    {Object? body, String? token}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return _Res(res.statusCode, text);
  } finally {
    client.close(force: true);
  }
}
