/// V29 paged incremental append/UPDATE/DELETE — closes the loop on V22
/// (paged read-side). Captured deltas apply at vec_search time without
/// requiring an explicit `warmVectorIndexes()` re-run.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec29_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V29 paged incremental', () {
    test('paged UPDATE incrementally refreshes built index', () async {
      final db = await Database.open(_tmp('update'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, 0, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, 0, VEC('[5, 0]'))");
        await db.execute("INSERT INTO docs VALUES (3, 1, VEC('[3, 0]'))");
        db.createVectorIndex(const VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Move id=2 to nearly the origin.
        await db.execute(
          "UPDATE docs SET embedding = VEC('[0.1, 0]') WHERE id = 2",
        );

        final r = await db.execute(
          "SELECT rowid FROM vec_search('docs', 'embedding', "
          "VEC('[0, 0]'), 1)",
        );
        expect(r.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });

    test('paged DELETE removes from built index', () async {
      final db = await Database.open(_tmp('delete'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[2, 0]'))");
        await db.execute("INSERT INTO docs VALUES (3, VEC('[3, 0]'))");
        db.createVectorIndex(const VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        await db.execute("DELETE FROM docs WHERE id = 1");

        // Deleted id=1 should NOT appear in results.
        final r = await db.execute(
          "SELECT rowid FROM vec_search('docs', 'embedding', "
          "VEC('[0, 0]'), 3)",
        );
        final ids = r.rows.map((row) => row[0]).toList();
        expect(ids, isNot(contains(1)));
        expect(ids.length, 2);
      } finally {
        await db.close();
      }
    });

    test('paged incremental deltas persist across close+reopen', () async {
      final path = _tmp('persist');
      {
        final db = await Database.open(path);
        try {
          await db.execute('PRAGMA default_table_kind = paged');
          await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB)');
          await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
          db.createVectorIndex(const VectorIndexSpec(
            table: 'docs',
            column: 'embedding',
            dim: 2,
            kind: VectorIndexKind.flat,
            metric: VectorMetric.l2,
          ));
          await db.warmVectorIndexes();

          // Insert without re-warm; then close.
          await db.execute("INSERT INTO docs VALUES (2, VEC('[0, 1]'))");
        } finally {
          await db.close();
        }
      }

      // Reopen without warmVectorIndexes — the delta should have been
      // folded into the persisted index at close.
      {
        final db = await Database.open(path);
        try {
          final r = await db.execute(
            "SELECT rowid FROM vec_search('docs', 'embedding', "
            "VEC('[0, 1]'), 1)",
          );
          expect(r.rows.single[0], 2);
        } finally {
          await db.close();
        }
      }
    });

    test('paged INSERT + UPDATE + DELETE combined in a run', () async {
      final db = await Database.open(_tmp('combined'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        db.createVectorIndex(const VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        await db.execute("INSERT INTO docs VALUES (2, VEC('[5, 5]'))");
        await db.execute("INSERT INTO docs VALUES (3, VEC('[0.1, 0]'))");
        await db.execute(
          "UPDATE docs SET embedding = VEC('[9, 9]') WHERE id = 1",
        );
        await db.execute("DELETE FROM docs WHERE id = 2");

        final r = await db.execute(
          "SELECT rowid FROM vec_search('docs', 'embedding', "
          "VEC('[0, 0]'), 3)",
        );
        final ids = r.rows.map((row) => row[0]).toList();
        expect(ids, isNot(contains(2))); // deleted
        expect(ids.first, 3); // nearest via [0.1, 0]
      } finally {
        await db.close();
      }
    });
  });
}
