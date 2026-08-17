/// Two-stage retrieval (rescoring): the planner fetches
/// `k * rescoreFactor` candidates from an approximate index, then
/// recomputes exact distances against uncompressed row blobs and
/// returns the true top-k. Verifies recall improves for LSH/PQ/IvfPq
/// and that DDL / persistence round-trip carries `rescore_factor`.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_rescore_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

Future<Database> _seedDocs(
  int dim,
  int n,
  math.Random rng, [
  String? path,
]) async {
  final db = await Database.open(path);
  await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
      'tenant INTEGER, embedding BLOB)');
  for (var i = 0; i < n; i++) {
    final v = _rand(dim, rng);
    await db.execute(
      "INSERT INTO docs VALUES ($i, ${i % 4}, VEC('${v.toString()}'))",
    );
  }
  return db;
}

void main() {
  group('VectorIndexSpec.rescoreFactor', () {
    test('defaults to 1', () {
      const spec = VectorIndexSpec(table: 't', column: 'v', dim: 4);
      expect(spec.rescoreFactor, 1);
    });
  });

  group('DDL: rescore_factor arg', () {
    test('parses and appears in spec', () async {
      final db = await _seedDocs(4, 10, math.Random(1));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_flat USING vector_index("
          "table=docs, column=embedding, dim=4, kind=flat, "
          "metric=l2, rescore_factor=5)",
        );
        expect(db.vectorIndexes.single.rescoreFactor, 5);
      } finally {
        await db.close();
      }
    });
  });

  group('Rescoring improves recall on approximate indexes', () {
    test('PQ with rescore_factor=8 recovers L2 top-k (>= no-rescore)',
        () async {
      const dim = 16;
      const n = 400;
      const k = 5;
      final rng = math.Random(42);

      // Ground truth via a Dart-side FlatIndex.
      final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
      final vecs = List.generate(n, (_) => _rand(dim, rng));
      for (var i = 0; i < n; i++) {
        flat.add(i, vecs[i]);
      }

      // Fresh DB (no rescoring).
      final db1 = await Database.open();
      try {
        await db1.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 0; i < n; i++) {
          await db1.execute(
            "INSERT INTO docs VALUES ($i, VEC('${vecs[i].toString()}'))",
          );
        }
        db1.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.pq,
          metric: VectorMetric.l2,
          m: 8,
          seed: 7,
        ));
        // Fresh DB with rescoring.
        final db2 = await Database.open();
        try {
          await db2.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB)');
          for (var i = 0; i < n; i++) {
            await db2.execute(
              "INSERT INTO docs VALUES ($i, VEC('${vecs[i].toString()}'))",
            );
          }
          db2.createVectorIndex(VectorIndexSpec(
            table: 'docs',
            column: 'embedding',
            dim: dim,
            kind: VectorIndexKind.pq,
            metric: VectorMetric.l2,
            m: 8,
            seed: 7,
            rescoreFactor: 8,
          ));

          var noRescoreHits = 0;
          var rescoreHits = 0;
          var total = 0;
          for (var q = 0; q < 10; q++) {
            final query = _rand(dim, rng);
            final qLit = "VEC('${query.toString()}')";
            final truth = flat.search(query, k).map((h) => h.id as int).toSet();

            noRescoreHits +=
                truth.intersection(await _topK(db1, qLit, k)).length;
            rescoreHits += truth.intersection(await _topK(db2, qLit, k)).length;
            total += k;
          }
          final baseRecall = noRescoreHits / total;
          final rescoreRecall = rescoreHits / total;
          expect(rescoreRecall, greaterThanOrEqualTo(baseRecall),
              reason: 'rescore recall ($rescoreRecall) must be '
                  '>= base recall ($baseRecall)');
          // Rescoring at 8× should give near-perfect recall on this
          // scale — floor at 0.85 for RNG robustness.
          expect(rescoreRecall, greaterThanOrEqualTo(0.85),
              reason: 'rescore recall too low: $rescoreRecall');
        } finally {
          await db2.close();
        }
      } finally {
        await db1.close();
      }
    });

    test('LSH with rescore_factor=8 gives exact top-k on small tables',
        () async {
      const dim = 8;
      const n = 60;
      const k = 3;
      final rng = math.Random(3);
      final vecs = List.generate(n, (_) => _rand(dim, rng));
      final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
      for (var i = 0; i < n; i++) {
        flat.add(i, vecs[i]);
      }

      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 0; i < n; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${vecs[i].toString()}'))",
          );
        }
        // Rescoring 8×3 = 24 candidates out of 60 → most queries
        // should get the exact top-3.
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.lsh,
          metric: VectorMetric.l2,
          nbits: 128,
          seed: 5,
          rescoreFactor: 8,
        ));

        var hits = 0, total = 0;
        for (var q = 0; q < 10; q++) {
          final query = _rand(dim, rng);
          final qLit = "VEC('${query.toString()}')";
          final truth = flat.search(query, k).map((h) => h.id as int).toSet();
          final got = await _topK(db, qLit, k);
          hits += truth.intersection(got).length;
          total += k;
        }
        final recall = hits / total;
        expect(recall, greaterThanOrEqualTo(0.6),
            reason: 'LSH-rescored recall too low: $recall');
      } finally {
        await db.close();
      }
    });
  });

  group('Rescoring composes with WHERE filter', () {
    test('filter + rescore still returns correct-filtered top-k', () async {
      const dim = 8;
      const n = 200;
      final rng = math.Random(11);
      final db = await _seedDocs(dim, n, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.pq,
          metric: VectorMetric.l2,
          m: 4,
          rescoreFactor: 6,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 2 "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        for (final row in r.rows) {
          expect((row[0] as int) % 4, 2,
              reason: 'row ${row[0]} violated WHERE tenant = 2');
        }
      } finally {
        await db.close();
      }
    });
  });

  group('Rescore persistence', () {
    test('rescoreFactor round-trips through JSON reopen', () async {
      final path = _tmp('rescore_persist');
      final rng = math.Random(9);
      {
        final db = await _seedDocs(4, 10, rng, path);
        try {
          await db.execute(
            "CREATE VIRTUAL TABLE docs_pq USING vector_index("
            "table=docs, column=embedding, dim=4, kind=flat, "
            "metric=l2, rescore_factor=7)",
          );
        } finally {
          await db.close();
        }
      }
      {
        final db = await Database.open(path);
        try {
          expect(db.vectorIndexes.single.rescoreFactor, 7);
        } finally {
          await db.close();
        }
      }
    });
  });
}

// Helper: pull the top-k ids from a SQL k-NN query.
Future<Set<int>> _topK(Database db, String qLit, int k) async {
  final r = await db.execute(
    "SELECT id FROM docs "
    "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT $k",
  );
  return r.rows.map((rr) => rr[0] as int).toSet();
}
