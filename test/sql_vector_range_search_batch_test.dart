/// V55 vec_range_search_batch + PRAGMA vector_index_warm_all.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec55_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V55 vec_range_search_batch', () {
    test('returns rows within threshold per query, preserving query_idx',
        () async {
      final db = await Database.open(_tmp('two'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 20; i++) {
          await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT query_idx, rowid, distance FROM vec_range_search_batch("
          "'docs', 'embedding', '[[0,0],[10,0]]', 3)",
        );

        final byQ = <int, Set<int>>{};
        for (final row in r.rows) {
          byQ.putIfAbsent(row[0] as int, () => {}).add(row[1] as int);
        }
        expect(byQ[0], {1, 2, 3});
        expect(byQ[1], {7, 8, 9, 10, 11, 12, 13});
      } finally {
        await db.close();
      }
    });

    test('rejects LSH bindings entirely (non-monotone metric)', () async {
      final db = await Database.open(_tmp('lsh_reject'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=4, kind=lsh))',
        );
        for (var i = 1; i <= 8; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('[$i, 0, 0, 0]'))",
          );
        }
        await db.warmVectorIndexes();
        final r = await db.execute(
          "SELECT * FROM vec_range_search_batch("
          "'docs', 'embedding', '[[0,0,0,0]]', 100)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('paged tables via drained index', () async {
      final db = await Database.open(_tmp('paged'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 8; i++) {
          await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT query_idx, rowid FROM vec_range_search_batch("
          "'docs', 'embedding', '[[0,0],[8,0]]', 2)",
        );
        final byQ = <int, Set<int>>{};
        for (final row in r.rows) {
          byQ.putIfAbsent(row[0] as int, () => {}).add(row[1] as int);
        }
        expect(byQ[0], {1, 2});
        expect(byQ[1], {6, 7, 8});
      } finally {
        await db.close();
      }
    });

    test('dim-mismatched query entries are skipped, preserve numbering',
        () async {
      final db = await Database.open(_tmp('mismatch'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 5; i++) {
          await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
        }
        await db.warmVectorIndexes();

        // Entry 0 is dim=3 (bad), entry 1 is dim=2 (good).
        final r = await db.execute(
          "SELECT query_idx FROM vec_range_search_batch("
          "'docs', 'embedding', '[[0,0,0],[0,0]]', 3)",
        );
        final indices = r.rows.map((r) => r[0] as int).toSet();
        expect(indices, {1});
      } finally {
        await db.close();
      }
    });

    test('filter_json argument intersects payload buckets once', () async {
      final db = await Database.open(_tmp('filter'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 16; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 4}, VEC('[$i, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT query_idx, rowid FROM vec_range_search_batch("
          "'docs', 'embedding', '[[0,0],[8,0]]', 12, 'l2', "
          "'{\"tenant\":2}')",
        );
        for (final row in r.rows) {
          expect((row[1] as int) % 4, 2);
        }
      } finally {
        await db.close();
      }
    });
  });

  group('V55 PRAGMA vector_index_warm_all', () {
    test('warms every registered paged binding', () async {
      final db = await Database.open(_tmp('warm_all'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE a (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute(
          'CREATE TABLE b (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=3, metric=l2))',
        );
        await db.execute("INSERT INTO a VALUES (1, VEC('[1,0]'))");
        await db.execute("INSERT INTO b VALUES (1, VEC('[1,0,0]'))");

        final r = await db.execute('PRAGMA vector_index_warm_all');
        expect(r.message, contains('vector_index_warm_all:'));
        expect(r.message, contains('2 total'));

        // Post-warm, targeted TVFs must return real rows.
        final ra = await db.execute(
          "SELECT rowid FROM vec_search('a', 'embedding', VEC('[1,0]'), 1)",
        );
        expect(ra.rows, isNotEmpty);
      } finally {
        await db.close();
      }
    });

    test('idempotent on a fully-warmed set', () async {
      final db = await Database.open(_tmp('idempotent'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1,0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute('PRAGMA vector_index_warm_all');
        expect(r.message, contains('1 total'));
      } finally {
        await db.close();
      }
    });

    test('appears in pragma_list', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA pragma_list');
        final names = r.rows.map((row) => row[0]).toSet();
        expect(names, contains('vector_index_warm_all'));
      } finally {
        await db.close();
      }
    });
  });
}
