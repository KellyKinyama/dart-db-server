import 'dart:convert';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('JSON1 mutators', () {
    test('json_set overwrites existing key, creates missing', () async {
      final r = await db.execute(
          "SELECT json_set('{\"a\":1,\"b\":2}', '\$.a', 9, '\$.c', 3) AS s");
      expect(jsonDecode(r.rows.first[0] as String), {'a': 9, 'b': 2, 'c': 3});
    });

    test('json_insert never overwrites existing keys', () async {
      final r = await db.execute(
          "SELECT json_insert('{\"a\":1}', '\$.a', 9, '\$.b', 2) AS s");
      expect(jsonDecode(r.rows.first[0] as String), {'a': 1, 'b': 2});
    });

    test('json_replace only updates existing keys', () async {
      final r = await db.execute(
          "SELECT json_replace('{\"a\":1}', '\$.a', 9, '\$.b', 2) AS s");
      expect(jsonDecode(r.rows.first[0] as String), {'a': 9});
    });

    test('json_remove deletes keys', () async {
      final r = await db
          .execute("SELECT json_remove('{\"a\":1,\"b\":2}', '\$.a') AS s");
      expect(jsonDecode(r.rows.first[0] as String), {'b': 2});
    });

    test('json_patch (RFC 7396) merges and removes via null', () async {
      final r = await db.execute(
          "SELECT json_patch('{\"a\":1,\"b\":2}', '{\"a\":9,\"b\":null,\"c\":3}') AS p");
      expect(jsonDecode(r.rows.first[0] as String), {'a': 9, 'c': 3});
    });

    test('json_quote wraps value as a JSON literal', () async {
      final r =
          await db.execute("SELECT json_quote('hi') AS s, json_quote(42) AS n");
      expect(r.rows.first, ['"hi"', '42']);
    });
  });

  group('JSON1 aggregates', () {
    setUp(() async {
      await db.execute('CREATE TABLE t(g TEXT, v INTEGER)');
      await db.execute("INSERT INTO t VALUES ('a',1),('a',2),('b',3),('b',4)");
    });

    test('json_group_array collects values per group', () async {
      final r = await db.execute(
          'SELECT g, json_group_array(v) AS arr FROM t GROUP BY g ORDER BY g');
      expect(jsonDecode(r.rows[0][1] as String), [1, 2]);
      expect(jsonDecode(r.rows[1][1] as String), [3, 4]);
    });

    test('json_group_object builds an object', () async {
      final r = await db
          .execute('SELECT json_group_object(g, v) AS obj FROM t WHERE v < 3');
      expect(jsonDecode(r.rows.first[0] as String), {'a': 2});
    });
  });

  group('json_each / json_tree (table-valued)', () {
    test('json_each iterates array elements', () async {
      final r =
          await db.execute("SELECT key, value FROM json_each('[10, 20, 30]')");
      expect(r.rows, [
        [0, 10],
        [1, 20],
        [2, 30],
      ]);
    });

    test('json_each iterates object entries', () async {
      final r = await db
          .execute("SELECT key, value FROM json_each('{\"a\":1,\"b\":2}')");
      // map order preserved
      expect(r.rows, [
        ['a', 1],
        ['b', 2],
      ]);
    });

    test('json_tree visits nested values', () async {
      final r = await db.execute(
          "SELECT count(*) AS n FROM json_tree('{\"a\":{\"b\":1,\"c\":[2,3]}}')");
      // root entry "a" + b + c (array) + 2 + 3 = 5
      expect(r.rows.first.first, 5);
    });
  });
}
