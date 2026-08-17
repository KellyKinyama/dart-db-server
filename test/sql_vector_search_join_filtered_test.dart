/// V61 vec_search_join_filtered: payload-filtered table-to-table k-NN.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec61_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V61 vec_search_join_filtered', () {
    test('filter restricts every query row to matching target rows', () async {
      final db = await Database.open(_tmp('basic'));
      try {
        await db.execute(
          'CREATE TABLE products (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 20; i++) {
          await db.execute(
            "INSERT INTO products VALUES ($i, ${i % 3}, VEC('[$i, 0]'))",
          );
        }
        await db.execute(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, '
          'preference BLOB VECTOR(dim=2))',
        );
        // Two queries: id=100 at [3,0], id=101 at [15,0].
        await db.execute("INSERT INTO users VALUES (100, VEC('[3, 0]'))");
        await db.execute("INSERT INTO users VALUES (101, VEC('[15, 0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute('''
          SELECT query_rowid, rowid, distance FROM vec_search_join_filtered(
            'products', 'embedding',
            'users', 'preference',
            5,
            '{"tenant": 2}'
          )
          ORDER BY query_rowid, distance
        ''');

        final byQuery = <int, List<int>>{};
        for (final row in r.rows) {
          byQuery.putIfAbsent(row[0] as int, () => []).add(row[1] as int);
        }
        // All returned target ids must be tenant=2 → id % 3 == 2.
        for (final list in byQuery.values) {
          for (final id in list) {
            expect(id % 3, 2);
          }
        }
        // Each query got its own top-k list.
        expect(byQuery.keys.toSet(), {100, 101});
      } finally {
        await db.close();
      }
    });

    test('binding without filter_cols returns empty', () async {
      final db = await Database.open(_tmp('no_filter'));
      try {
        await db.execute(
          'CREATE TABLE products (id INTEGER PRIMARY KEY, '
          'embedding BLOB VECTOR(dim=2))',
        );
        await db.execute("INSERT INTO products VALUES (1, VEC('[1, 0]'))");
        await db.execute(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, '
          'preference BLOB VECTOR(dim=2))',
        );
        await db.execute("INSERT INTO users VALUES (100, VEC('[1, 0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute('''
          SELECT * FROM vec_search_join_filtered(
            'products', 'embedding',
            'users', 'preference',
            5,
            '{"tenant": 1}'
          )
        ''');
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('empty filter intersection returns zero rows without probing',
        () async {
      final db = await Database.open(_tmp('empty_intersect'));
      try {
        await db.execute(
          'CREATE TABLE products (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        await db.execute(
          "INSERT INTO products VALUES (1, 1, VEC('[1, 0]'))",
        );
        await db.execute(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, '
          'preference BLOB VECTOR(dim=2))',
        );
        await db.execute("INSERT INTO users VALUES (100, VEC('[1, 0]'))");
        await db.warmVectorIndexes();

        // tenant=999 matches nothing.
        final r = await db.execute('''
          SELECT * FROM vec_search_join_filtered(
            'products', 'embedding', 'users', 'preference',
            5, '{"tenant": 999}'
          )
        ''');
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('dim-mismatched query rows are silently skipped', () async {
      final db = await Database.open(_tmp('dim_skip'));
      try {
        await db.execute(
          'CREATE TABLE products (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        await db.execute(
          "INSERT INTO products VALUES (1, 1, VEC('[1, 0]'))",
        );
        // Query column NOT wrapped in VECTOR — dim=3 mismatches.
        await db.execute(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, '
          'preference BLOB VECTOR(dim=3))',
        );
        await db.execute("INSERT INTO users VALUES (100, VEC('[1, 0, 0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute('''
          SELECT * FROM vec_search_join_filtered(
            'products', 'embedding', 'users', 'preference',
            5, '{"tenant": 1}'
          )
        ''');
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('preserves query PK as query_rowid', () async {
      final db = await Database.open(_tmp('pk_rowid'));
      try {
        await db.execute(
          'CREATE TABLE products (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 6; i++) {
          await db.execute(
            "INSERT INTO products VALUES ($i, 1, VEC('[$i, 0]'))",
          );
        }
        await db.execute(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, '
          'preference BLOB VECTOR(dim=2))',
        );
        // Sparse PKs → make sure we see 42, 77 (not 0, 1).
        await db.execute("INSERT INTO users VALUES (42, VEC('[2, 0]'))");
        await db.execute("INSERT INTO users VALUES (77, VEC('[5, 0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute('''
          SELECT query_rowid FROM vec_search_join_filtered(
            'products', 'embedding', 'users', 'preference',
            1, '{"tenant": 1}'
          )
        ''');
        final ids = r.rows.map((row) => row[0] as int).toSet();
        expect(ids, {42, 77});
      } finally {
        await db.close();
      }
    });
  });
}
