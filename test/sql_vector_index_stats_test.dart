/// V28 Vector index statistics — `PRAGMA vector_index_list` and
/// `PRAGMA vector_index_stats(tbl.col)` surface per-binding info
/// (kind, metric, dim, n, live/tombstones, approx memory).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec28_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V28 vector_index_list / vector_index_stats', () {
    test('vector_index_list surfaces every registered binding', () async {
      final db = await Database.open(_tmp('list_bindings'));
      try {
        await db.execute('CREATE TABLE a (id INTEGER PRIMARY KEY, e BLOB)');
        await db.execute('CREATE TABLE b (id INTEGER PRIMARY KEY, e BLOB)');
        db.createVectorIndex(VectorIndexSpec(
          table: 'a',
          column: 'e',
          dim: 4,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        db.createVectorIndex(VectorIndexSpec(
          table: 'b',
          column: 'e',
          dim: 8,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.cosine,
          m: 8,
        ));

        final r = await db.execute('PRAGMA vector_index_list');
        expect(r.columns,
            containsAll(['tbl', 'col', 'dim', 'kind', 'metric', 'built', 'n']));
        expect(r.rows.length, 2);

        // Both unbuilt initially.
        for (final row in r.rows) {
          expect(row[5], 0); // built
          expect(row[6], 0); // n
        }
      } finally {
        await db.close();
      }
    });

    test('vector_index_stats reports n and live/tombstones after warm',
        () async {
      final db = await Database.open(_tmp('stats_flat'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[2, 0]'))");
        await db.execute("INSERT INTO docs VALUES (3, VEC('[3, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute('PRAGMA vector_index_stats');
        expect(r.rows.length, 1);
        final row = r.rows.single;
        expect(row[0], 'docs'); // tbl
        expect(row[1], 'embedding'); // col
        expect(row[2], 'flat'); // kind
        expect(row[3], 'l2'); // metric
        expect(row[4], 2); // dim
        expect(row[5], 3); // n
        expect(row[6], 3); // live
        expect(row[7], 0); // tombstones (Flat: always 0)
        expect(row[8], 3 * 2 * 4); // approx_bytes
      } finally {
        await db.close();
      }
    });

    test('HNSW tombstones surface after UPDATE', () async {
      final db = await Database.open(_tmp('stats_hnsw'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[2, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
        ));
        await db.warmVectorIndexes();

        // Trigger UPDATE + query to bake tombstones.
        await db.execute(
          "UPDATE docs SET embedding = VEC('[9, 9]') WHERE id = 1",
        );
        await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );

        final r =
            await db.execute("PRAGMA vector_index_stats('docs.embedding')");
        expect(r.rows.length, 1);
        final row = r.rows.single;
        // After 1 UPDATE: 1 tombstone + 1 re-added node + 1 untouched.
        expect(row[5], 3); // n = live + tomb
        expect(row[6], 2); // live
        expect(row[7], 1); // tombstones
      } finally {
        await db.close();
      }
    });

    test('vector_index_stats with unknown target returns empty', () async {
      final db = await Database.open(_tmp('stats_none'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final r =
            await db.execute("PRAGMA vector_index_stats('other.something')");
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('pragma_list includes both new pragmas', () async {
      final db = await Database.open(_tmp('pragma_list'));
      try {
        final r = await db.execute('PRAGMA pragma_list');
        final names = r.rows.map((row) => row[0]).toSet();
        expect(names, contains('vector_index_list'));
        expect(names, contains('vector_index_stats'));
      } finally {
        await db.close();
      }
    });
  });
}
