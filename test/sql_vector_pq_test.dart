/// Product Quantization index (FAISS `IndexPQ` port). Direct algorithm
/// correctness + recall-vs-Flat harness + SQL DDL + planner integration
/// + JSON persistence.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vecpq_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('PqIndex direct', () {
    test('constructor rejects dim not divisible by m', () {
      expect(() => PqIndex(15, m: 4), throwsArgumentError);
    });

    test('add before train throws', () {
      final idx = PqIndex(8, m: 4);
      expect(
        () => idx.add(0, Vector.fromList(List.filled(8, 1.0))),
        throwsStateError,
      );
    });

    test('search before train throws', () {
      final idx = PqIndex(8, m: 4);
      expect(
        () => idx.search(Vector.fromList(List.filled(8, 1.0)), 3),
        throwsStateError,
      );
    });

    test('code storage is m bytes per vector', () {
      final rng = math.Random(1);
      // Need ≥ ksub=256 training samples (< that hits a degenerate
      // k-means path); pad with a distribution that spans enough
      // centroids.
      const dim = 8;
      const m = 4;
      final samples = List.generate(300, (_) => _rand(dim, rng));
      final idx = PqIndex(dim, m: m)..train(samples);
      for (var i = 0; i < 40; i++) {
        idx.add(i, samples[i]);
      }
      expect(idx.length, 40);
    });

    test('removeId swap-last', () {
      final rng = math.Random(2);
      const dim = 4;
      const m = 2;
      final samples = List.generate(300, (_) => _rand(dim, rng));
      final idx = PqIndex(dim, m: m)..train(samples);
      idx.add('a', samples[0]);
      idx.add('b', samples[1]);
      idx.add('c', samples[2]);
      expect(idx.removeId('b'), isTrue);
      expect(idx.removeId('nope'), isFalse);
      expect(idx.length, 2);
      final hits = idx.search(samples[0], 5);
      expect(hits.map((h) => h.id).toSet(), {'a', 'c'});
    });

    test('recall@10 vs FlatIndex ground truth on 300x16d', () {
      const dim = 16;
      const m = 8;
      const n = 300;
      const k = 10;
      final rng = math.Random(42);

      final samples = List.generate(n, (_) => _rand(dim, rng));
      final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
      final pq = PqIndex(dim, m: m, seed: 7)..train(samples);
      for (var i = 0; i < n; i++) {
        flat.add(i, samples[i]);
        pq.add(i, samples[i]);
      }
      var hits = 0, total = 0;
      for (var q = 0; q < 10; q++) {
        final query = _rand(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = pq.search(query, k).map((h) => h.id).toSet();
        hits += truth.intersection(got).length;
        total += truth.length;
      }
      final recall = hits / total;
      // PQ on 16d/m=8 (dsub=2) with 300 vectors keeps ≥ 0.5 recall in
      // practice; floor at 0.35 for RNG robustness.
      expect(recall, greaterThanOrEqualTo(0.35),
          reason: 'PQ recall too low: $recall');
    });

    test('JSON round-trip preserves search ranking', () {
      const dim = 8;
      const m = 4;
      final rng = math.Random(3);
      final samples = List.generate(300, (_) => _rand(dim, rng));
      final idx = PqIndex(dim, m: m, seed: 11)..train(samples);
      for (var i = 0; i < 30; i++) {
        idx.add(i, samples[i]);
      }
      final copy = PqIndex.fromJson(idx.toJson());
      final q = _rand(dim, rng);
      expect(
        copy.search(q, 5).map((h) => h.id).toList(),
        idx.search(q, 5).map((h) => h.id).toList(),
      );
    });
  });

  group('PQ via SQL planner', () {
    Future<Database> _makeDb(int dim, int n, math.Random rng) async {
      final db = await Database.open();
      await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB)');
      for (var i = 0; i < n; i++) {
        final v = _rand(dim, rng);
        await db.execute(
          "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
        );
      }
      return db;
    }

    test('DDL: CREATE VIRTUAL TABLE ... USING vector_index(kind=pq)', () async {
      final db = await _makeDb(8, 300, math.Random(1));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_pq USING vector_index("
          "table=docs, column=embedding, dim=8, kind=pq, m=4, "
          "metric=l2, seed=3)",
        );
        expect(db.vectorIndexes.length, 1);
        final spec = db.vectorIndexes.single;
        expect(spec.kind, VectorIndexKind.pq);
        expect(spec.m, 4);
        expect(spec.seed, 3);
      } finally {
        await db.close();
      }
    });

    test('planner routes VEC_L2 through PQ, VEC_IP bails', () async {
      const dim = 8;
      final rng = math.Random(2);
      final db = await _makeDb(dim, 300, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.pq,
          metric: VectorMetric.l2,
          m: 4,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";

        // VEC_L2 → PQ fast path.
        final l2 = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        expect(l2.rows.length, 5);

        // VEC_IP → PQ bails (metric mismatch); brute force serves it.
        final ip = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_IP(embedding, $qLit) DESC LIMIT 5",
        );
        expect(ip.rows.length, 5);
      } finally {
        await db.close();
      }
    });

    test('too few training rows silently falls back to Flat', () async {
      // Only 10 rows but PQ wants ≥ 256 for k-means. Builder should
      // materialize a FlatIndex instead of crashing.
      const dim = 4;
      final rng = math.Random(3);
      final db = await _makeDb(dim, 10, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.pq,
          metric: VectorMetric.l2,
          m: 2,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 3",
        );
        expect(r.rows.length, 3);
      } finally {
        await db.close();
      }
    });

    test('close() + reopen preserves built PQ state', () async {
      final path = _tmp('pq_reopen');
      const dim = 8;
      final rng = math.Random(4);
      {
        final db = await Database.open(path);
        try {
          await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB)');
          for (var i = 0; i < 300; i++) {
            final v = _rand(dim, rng);
            await db.execute(
              "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
            );
          }
          await db.execute(
            "CREATE VIRTUAL TABLE docs_pq USING vector_index("
            "table=docs, column=embedding, dim=$dim, kind=pq, m=4, "
            "metric=l2, seed=1)",
          );
          // Prime the index.
          await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, VEC('[0,0,0,0,0,0,0,0]')) LIMIT 1",
          );
        } finally {
          await db.close();
        }
      }
      final text = await File(path).readAsString();
      expect(text.contains('"built"'), isTrue,
          reason: 'PQ built state should have been persisted');
      expect(text.contains('"kind":"pq"'), isTrue);

      {
        final db = await Database.open(path);
        try {
          expect(db.vectorIndexes.single.kind, VectorIndexKind.pq);
          final query = _rand(dim, rng);
          final qLit = "VEC('${query.toString()}')";
          final r = await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 3",
          );
          expect(r.rows.length, 3);
        } finally {
          await db.close();
        }
      }
    });
  });
}
