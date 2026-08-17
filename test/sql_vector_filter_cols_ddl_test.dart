/// V38 DDL syntax for VectorIndexSpec.filterColumns — expose V36's
/// payload-filter pruning to pure-SQL users via both the inline
/// `VECTOR(..., filter_cols='col1,col2')` column attribute and the
/// `CREATE VIRTUAL TABLE ... USING vector_index(..., filter_cols=...)`
/// form.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec38_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V38 filter_cols in DDL', () {
    test('inline VECTOR(filter_cols=...) applies payload pruning', () async {
      final db = await Database.open(_tmp('inline'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, kind=flat, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 20; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 4}, "
            "VEC('[${i / 20.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT id, tenant FROM docs WHERE tenant = 2 "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 3",
        );
        expect(r.rows.length, 3);
        for (final row in r.rows) {
          expect(row[1], 2);
        }
      } finally {
        await db.close();
      }
    });

    test('multi-column filter_cols split accepts commas', () async {
      final db = await Database.open(_tmp('multi'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          'kind INTEGER, embedding BLOB '
          "VECTOR(dim=2, filter_cols='tenant,kind'))",
        );
        // 40 rows across 4 tenants × 2 kinds → 5 rows per (tenant,kind).
        for (var i = 1; i <= 40; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 4}, ${i % 2}, "
            "VEC('[${i / 40.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT id, tenant, kind FROM docs "
          "WHERE tenant = 1 AND kind = 0 "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 5",
        );
        for (final row in r.rows) {
          expect(row[1], 1);
          expect(row[2], 0);
        }
      } finally {
        await db.close();
      }
    });

    test('CREATE VIRTUAL TABLE with filter_cols works', () async {
      final db = await Database.open(_tmp('cvt'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'tenant INTEGER, embedding BLOB)',
        );
        await db.execute(
          'CREATE VIRTUAL TABLE docs_idx USING vector_index('
          "table='docs', column='embedding', dim='2', "
          "filter_cols='tenant')",
        );
        for (var i = 1; i <= 10; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 3}, "
            "VEC('[${i / 10.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 0 "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 2",
        );
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 3, 0);
        }
      } finally {
        await db.close();
      }
    });

    test('filter_cols empty by default (backwards compat)', () async {
      final db = await Database.open(_tmp('nofilter'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB VECTOR(dim=2))',
        );
        final r = await db.execute('PRAGMA vector_index_list');
        expect(r.rows.length, 1);
        // Should register without complaint; filterColumns=[] means
        // the payload path is a no-op.
      } finally {
        await db.close();
      }
    });

    test('filter_cols persists across close+reopen', () async {
      final path = _tmp('persist');
      {
        final db = await Database.open(path);
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
        } finally {
          await db.close();
        }
      }
      final db = await Database.open(path);
      try {
        // Payload pruning must still work; the binding was reloaded
        // with filterColumns=['tenant'] and its payload index rebuilt.
        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 0 "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.length, 1);
        final id = r.rows.single[0] as int;
        expect(id % 2, 0);
      } finally {
        await db.close();
      }
    });
  });
}
