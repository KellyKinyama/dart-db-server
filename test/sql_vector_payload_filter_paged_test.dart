/// V40 payload-filter pruning for paged tables. Extends V36/V38/V39
/// so `vec_search_filtered` works on `PRAGMA default_table_kind =
/// paged` tables via a per-binding payload index keyed by PK.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec40_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V40 paged payload-filter', () {
    test('single-key filter returns only matching rows on paged', () async {
      final db = await Database.open(_tmp('single'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
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
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 3, '{\"tenant\":2}')",
        );
        expect(r.rows.length, 3);
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 4, 2);
        }
      } finally {
        await db.close();
      }
    });

    test('INSERT after warm keeps paged payload index in sync', () async {
      final db = await Database.open(_tmp('insert'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        await db.execute("INSERT INTO docs VALUES (1, 1, VEC('[1, 0]'))");
        await db.warmVectorIndexes();

        // Insert a fresh row after warm — V29 captures the delta; V40
        // must also update the payload index so filter queries see it.
        await db.execute("INSERT INTO docs VALUES (2, 7, VEC('[0.5, 0]'))");

        final r = await db.execute(
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 1, '{\"tenant\":7}')",
        );
        expect(r.rows.length, 1);
        expect(r.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });

    test('UPDATE of paged filter column moves pk between buckets', () async {
      final db = await Database.open(_tmp('update'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        await db.execute("INSERT INTO docs VALUES (1, 0, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, 1, VEC('[2, 0]'))");
        await db.warmVectorIndexes();

        // Move id=1 to tenant=1.
        await db.execute("UPDATE docs SET tenant = 1 WHERE id = 1");

        final r = await db.execute(
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 5, '{\"tenant\":1}')",
        );
        expect(r.rows.length, 2);
        final ids = r.rows.map((r) => r[0]).toSet();
        expect(ids, {1, 2});
      } finally {
        await db.close();
      }
    });

    test('DELETE removes pk from paged payload buckets', () async {
      final db = await Database.open(_tmp('delete'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 4; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, "
            "VEC('[${i / 4.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        await db.execute("DELETE FROM docs WHERE id = 1");

        final r = await db.execute(
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 5, '{\"tenant\":1}')",
        );
        expect(r.rows.length, 1);
        expect(r.rows.single[0], 3);
      } finally {
        await db.close();
      }
    });

    test('multi-key filter intersects across paged buckets', () async {
      final db = await Database.open(_tmp('multi'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          'kind INTEGER, embedding BLOB '
          "VECTOR(dim=2, filter_cols='tenant,kind'))",
        );
        for (var i = 1; i <= 12; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 3}, ${i % 2}, "
            "VEC('[${i / 12.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 5, "
          "'{\"tenant\":1, \"kind\":0}')",
        );
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 3, 1);
          expect(id % 2, 0);
        }
      } finally {
        await db.close();
      }
    });
  });
}
