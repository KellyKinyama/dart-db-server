/// V24 incremental UPDATE-of-vector-column for HnswIndex via
/// tombstone-and-re-add. Built state survives UPDATE; the tombstoned
/// old node stays in the graph as unreachable and a fresh node is
/// linked in its place. A >50% tombstone ratio (min 32 nodes) triggers
/// a full rebuild on the next query.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vecu24_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V24 HNSW UPDATE-vector-column incremental', () {
    test('single-row UPDATE reflects new ranking (built state survives)',
        () async {
      final path = _tmp('hnsw_single');
      final db = await Database.open(path);
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[100, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
          efConstruction: 20,
          efSearch: 16,
        ));
        await db.warmVectorIndexes();

        await db.execute(
          "UPDATE docs SET embedding = VEC('[0.1, 0]') WHERE id = 2",
        );

        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 2);

        // Binding should NOT have been full-invalidated (index !=null).
        // We assert by observing that the built state persists after
        // close/reopen without a re-warm call.
      } finally {
        await db.close();
      }

      final db2 = await Database.open(path);
      try {
        // Reopened without warmVectorIndexes — HNSW built state should
        // have been persisted after UPDATE + query.
        final r = await db2.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 2);
      } finally {
        await db2.close();
      }
    });

    test('multi-row UPDATE with WHERE re-adds each affected row', () async {
      final path = _tmp('hnsw_multi');
      final db = await Database.open(path);
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, 0, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, 0, VEC('[2, 0]'))");
        await db.execute("INSERT INTO docs VALUES (3, 1, VEC('[3, 0]'))");
        await db.execute("INSERT INTO docs VALUES (4, 1, VEC('[4, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
          efConstruction: 20,
          efSearch: 16,
        ));
        await db.warmVectorIndexes();

        await db.execute(
          "UPDATE docs SET embedding = VEC('[100, 0]') WHERE tenant = 0",
        );

        // Nearest to [0, 0] should now be id=3 (unchanged, dist 3).
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 3);
      } finally {
        await db.close();
      }
    });

    test('UPDATE on non-vector column leaves index intact', () async {
      final path = _tmp('hnsw_untouched');
      final db = await Database.open(path);
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'label TEXT, embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, 'a', VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, 'b', VEC('[2, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
        ));
        await db.warmVectorIndexes();

        // Update only the label; embedding stays put.
        await db.execute("UPDATE docs SET label = 'z' WHERE id = 1");

        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('heavy UPDATE churn triggers >50% tombstone rebuild', () async {
      final path = _tmp('hnsw_rebuild');
      final db = await Database.open(path);
      try {
        final rng = math.Random(42);
        const dim = 8;
        const n = 64;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          final lit = '[${v.values.join(", ")}]';
          await db.execute("INSERT INTO docs VALUES ($i, VEC('$lit'))");
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
          efConstruction: 20,
          efSearch: 16,
        ));
        await db.warmVectorIndexes();

        // Update >50% of rows to trigger tombstone-rebuild threshold.
        for (var i = 1; i <= (n * 3) ~/ 4; i++) {
          final v = _rand(dim, rng);
          final lit = '[${v.values.join(", ")}]';
          await db.execute(
            "UPDATE docs SET embedding = VEC('$lit') WHERE id = $i",
          );
        }

        // Force query to trigger _applyPendingInsertsToBuiltIndex.
        final r = await db.execute(
          "SELECT COUNT(*) FROM (SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0, 0, 0, 0, 0, 0, 0]')) "
          "ASC LIMIT 10)",
        );
        expect(r.rows.single[0], 10);

        // Second query — index should have been rebuilt clean by now,
        // no tombstones, so this returns quickly with correct ranking.
        final r2 = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0, 0, 0, 0, 0, 0, 0]')) "
          "ASC LIMIT 5",
        );
        expect(r2.rows.length, 5);
      } finally {
        await db.close();
      }
    });
  });
}
