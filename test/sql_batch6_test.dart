import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('JSON1 functions', () {
    test('json_extract pulls scalar via path', () async {
      final r = await db.execute(
          "SELECT json_extract('{\"a\": 1, \"b\": [10, 20]}', '\$.a') AS x, "
          "json_extract('{\"a\": 1, \"b\": [10, 20]}', '\$.b[1]') AS y");
      expect(r.rows.first, [1, 20]);
    });

    test('json_extract returns JSON text for arrays/objects', () async {
      final r = await db
          .execute("SELECT json_extract('{\"a\": [1, 2]}', '\$.a') AS x");
      expect(r.rows.first, ['[1,2]']);
    });

    test('json_array / json_object build JSON', () async {
      final r = await db.execute("SELECT json_array(1, 2, 'x') AS a, "
          "json_object('k', 1, 'v', 'hi') AS o");
      expect(r.rows.first[0], '[1,2,"x"]');
      expect(r.rows.first[1], '{"k":1,"v":"hi"}');
    });

    test('json_type and json_valid', () async {
      final r = await db.execute(
          "SELECT json_type('[1,2]') AS t, json_valid('not json') AS v, "
          "json_valid('{\"x\":1}') AS w");
      expect(r.rows.first, ['array', 0, 1]);
    });

    test('-> and ->> operators', () async {
      final r =
          await db.execute("SELECT '{\"a\":42, \"b\":[10,20]}' -> 'a' AS jt, "
              "'{\"a\":42, \"b\":[10,20]}' ->> 'a' AS sql, "
              "'[10,20,30]' ->> 1 AS idx");
      expect(r.rows.first, ['42', 42, 20]);
    });
  });

  group('ATTACH DATABASE', () {
    test('attaches an existing JSON database file under an alias', () async {
      // Build a sibling DB on disk, populate it, persist, close.
      final tmp = File('${Directory.systemTemp.path}/dart_db_attach_test.json');
      if (tmp.existsSync()) tmp.deleteSync();
      final aux = await Database.open(tmp.path);
      await aux.execute('CREATE TABLE notes(id INTEGER, body TEXT)');
      await aux.execute("INSERT INTO notes VALUES (1, 'hello')");
      await aux.flush();

      // Attach into our main DB and query via qualified name.
      await db.execute("ATTACH DATABASE '${tmp.path}' AS aux");
      final r = await db.execute('SELECT id, body FROM aux.notes');
      expect(r.rows, [
        [1, 'hello'],
      ]);

      final list = await db.execute('PRAGMA database_list');
      expect(list.rows.length, 2);
      expect(list.rows[1][1], 'aux');

      await db.execute('DETACH DATABASE aux');
      final list2 = await db.execute('PRAGMA database_list');
      expect(list2.rows.length, 1);

      tmp.deleteSync();
    });
  });
}
