/// V39 vec_search_filtered TVF — like vec_search but with a payload
/// filter map for JOIN / subquery contexts where the fast path
/// wouldn't fire (or where paged tables would otherwise scan).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec39_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V39 vec_search_filtered TVF', () {
    test('single-key filter returns only matching rows', () async {
      final db = await Database.open(_tmp('single'));
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
          "SELECT rowid, distance FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 3, '{\"tenant\":2}')",
        );
        expect(r.rows.length, 3);
        // Every returned id must be a tenant=2 row (i % 4 == 2).
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 4, 2);
        }
      } finally {
        await db.close();
      }
    });

    test('multi-key filter intersects sets', () async {
      final db = await Database.open(_tmp('multi'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          'kind INTEGER, embedding BLOB '
          "VECTOR(dim=2, filter_cols='tenant,kind'))",
        );
        for (var i = 1; i <= 40; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 4}, ${i % 2}, "
            "VEC('[${i / 40.0}, 0]'))",
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
          expect(id % 4, 1);
          expect(id % 2, 0);
        }
      } finally {
        await db.close();
      }
    });

    test('empty filter matches vec_search semantics', () async {
      final db = await Database.open(_tmp('empty'));
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
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 2, '{}')",
        );
        expect(r.rows.length, 2);
      } finally {
        await db.close();
      }
    });

    test('unknown filter key returns empty', () async {
      final db = await Database.open(_tmp('unknown'));
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
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 2, '{\"stripe\":1}')",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('binding without filter_cols returns empty', () async {
      final db = await Database.open(_tmp('nofilter'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          'embedding BLOB VECTOR(dim=2))',
        );
        await db.execute("INSERT INTO docs VALUES (1, 0, VEC('[1, 0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 1, '{\"tenant\":0}')",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('composes with JOIN on the source table', () async {
      final db = await Database.open(_tmp('join'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          'title TEXT, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 10; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 3}, 'doc$i', "
            "VEC('[${i / 10.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT d.id, d.title FROM vec_search_filtered("
          "'docs', 'embedding', VEC('[0, 0]'), 2, '{\"tenant\":1}') v "
          "JOIN docs d ON d.id = v.rowid "
          "ORDER BY v.distance ASC",
        );
        expect(r.rows.length, 2);
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 3, 1);
        }
      } finally {
        await db.close();
      }
    });
  });
}
