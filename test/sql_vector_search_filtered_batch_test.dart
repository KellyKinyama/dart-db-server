/// V43 vec_search_filtered_batch — batch companion to V39. Payload
/// filter set is computed once and reused across every query.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec43_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V43 vec_search_filtered_batch', () {
    test('two queries share a single filter, get per-query results', () async {
      final db = await Database.open(_tmp('two'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 20; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 4}, "
            "VEC('[${i / 20.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT query_idx, rowid FROM vec_search_filtered_batch("
          "'docs', 'embedding', '[[0, 0], [1, 0]]', 3, "
          r"""'{"tenant":2}')""",
        );
        expect(r.rows.length, greaterThan(0));
        // Each row's rowid must be a tenant=2 row.
        for (final row in r.rows) {
          final id = row[1] as int;
          expect(id % 4, 2);
        }
        // Query indices must be 0 and 1 (both queries produced results).
        final ids = r.rows.map((r) => r[0]).toSet();
        expect(ids, {0, 1});
      } finally {
        await db.close();
      }
    });

    test('dim-mismatch entry is skipped but query_idx numbering holds',
        () async {
      final db = await Database.open(_tmp('mismatch'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 8; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, "
            "VEC('[${i / 8.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        // First query has wrong dim (3 elements), second is valid.
        final r = await db.execute(
          "SELECT query_idx FROM vec_search_filtered_batch("
          "'docs', 'embedding', '[[1, 2, 3], [0, 0]]', 2, "
          r"""'{"tenant":0}')""",
        );
        // Only query_idx=1 (the valid one) should appear.
        for (final row in r.rows) {
          expect(row[0], 1);
        }
      } finally {
        await db.close();
      }
    });

    test('paged tables work with the batch filter path (V40 shape)', () async {
      final db = await Database.open(_tmp('paged'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 12; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 3}, "
            "VEC('[${i / 12.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT query_idx, rowid FROM vec_search_filtered_batch("
          "'docs', 'embedding', '[[0, 0], [1, 0]]', 2, "
          r"""'{"tenant":1}')""",
        );
        for (final row in r.rows) {
          final id = row[1] as int;
          expect(id % 3, 1);
        }
      } finally {
        await db.close();
      }
    });

    test('empty filter returns nothing (batch refuses fallback)', () async {
      final db = await Database.open(_tmp('empty_filter'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 5; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, "
            "VEC('[${i / 5.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_search_filtered_batch("
          "'docs', 'embedding', '[[0, 0]]', 2, '{}')",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('distance is monotone within each query block', () async {
      final db = await Database.open(_tmp('monotone'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 12; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, "
            "VEC('[${i.toDouble()}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT query_idx, distance FROM vec_search_filtered_batch("
          "'docs', 'embedding', '[[0, 0]]', 4, "
          r"""'{"tenant":1}')""",
        );
        for (var i = 1; i < r.rows.length; i++) {
          expect(r.rows[i][0], r.rows[i - 1][0]);
          final prev = (r.rows[i - 1][1] as num).toDouble();
          final curr = (r.rows[i][1] as num).toDouble();
          expect(curr, greaterThanOrEqualTo(prev));
        }
      } finally {
        await db.close();
      }
    });
  });
}
