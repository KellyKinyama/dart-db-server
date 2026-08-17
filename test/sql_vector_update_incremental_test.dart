/// V23 incremental UPDATE-of-vector-column: for FlatIndex / IVF /
/// LSH / PQ / IvfPq we replay `removeId` + `add` for the affected
/// positions instead of rebuilding the whole index. HNSW still
/// full-invalidates to avoid tombstone bloat.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vecu23_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V23 UPDATE-vector-column: incremental for FlatIndex', () {
    test('single-row UPDATE reflects new ranking (built state survives)',
        () async {
      final path = _tmp('flat_single');
      {
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
            kind: VectorIndexKind.flat,
            metric: VectorMetric.l2,
          ));
          await db.warmVectorIndexes();

          // Now the built state IS on disk (V21 keeps it after warm).
          // Update id=2's embedding into a position very close to origin.
          await db.execute(
            "UPDATE docs SET embedding = VEC('[0.1, 0]') WHERE id = 2",
          );

          // Nearest to [0, 0] should now be id=2 (dist 0.1 vs 1.0 for id 1).
          final r = await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
          );
          expect(r.rows.single[0], 2);
        } finally {
          await db.close();
        }
      }

      // Post-mutation: built state should still be intact (V23 kept it).
      final text = await File(path).readAsString();
      expect(text.contains('"built"'), isTrue,
          reason: 'FlatIndex UPDATE should not have wiped built state');
    });

    test('multi-row UPDATE with WHERE re-adds each affected row', () async {
      final db = await Database.open();
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
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Update every tenant=0 row's embedding.
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

    test('correctness after mixed INSERT + UPDATE + query cycle', () async {
      const dim = 4;
      final rng = math.Random(1);
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 0; i < 10; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Interleave INSERT and UPDATE.
        for (var i = 10; i < 15; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
          );
        }
        await db.execute(
          "UPDATE docs SET embedding = VEC('[5, 5, 5, 5]') WHERE id = 3",
        );
        for (var i = 15; i < 20; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
          );
        }

        // Query near [5,5,5,5] — id=3 should now be the nearest.
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[5, 5, 5, 5]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 3);
      } finally {
        await db.close();
      }
    });
  });

  group('V24 UPDATE-vector-column: HNSW tombstone-and-re-add', () {
    test('HNSW UPDATE-vec-col keeps built state via tombstone+re-add',
        () async {
      final path = _tmp('hnsw_full');
      {
        final db = await Database.open(path);
        try {
          await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB)');
          for (var i = 0; i < 20; i++) {
            await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
          }
          db.createVectorIndex(VectorIndexSpec(
            table: 'docs',
            column: 'embedding',
            dim: 2,
            kind: VectorIndexKind.hnsw,
            metric: VectorMetric.l2,
            m: 8,
            efConstruction: 40,
            efSearch: 16,
          ));
          await db.warmVectorIndexes();

          await db.execute(
            "UPDATE docs SET embedding = VEC('[0.5, 0]') WHERE id = 10",
          );
          // Force query to apply the tombstone+re-add before persist.
          await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
          );
        } finally {
          await db.close();
        }
      }
      // V24: HNSW UPDATE-vec-col preserves built state — the JSON still
      // has a "built" block. A single tombstone is far below the 30 %
      // rebuild threshold so the graph survives.
      final text = await File(path).readAsString();
      expect(text.contains('"built"'), isTrue,
          reason: 'V24 HNSW UPDATE-vec-col keeps built state');
    });
  });
}
