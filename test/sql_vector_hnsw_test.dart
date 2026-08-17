/// HNSW graph index tests: correctness on small deterministic cases +
/// recall-vs-Flat ground truth on random data. Mirrors the recall
/// harness used by the sibling `dart-vector-store` package.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _randomVec(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

void main() {
  group('HnswIndex basics', () {
    test('empty index returns empty search', () {
      final idx = HnswIndex(3);
      final r = idx.search(Vector.fromList([1, 2, 3]), 5);
      expect(r, isEmpty);
    });

    test('single vector returns itself with distance 0', () {
      final idx = HnswIndex(3);
      final v = Vector.fromList([1, 2, 3]);
      idx.add('only', v);
      final hits = idx.search(v, 1);
      expect(hits.single.id, 'only');
      expect(hits.single.distance, 0.0);
    });

    test('dim mismatch on add / search throws', () {
      final idx = HnswIndex(3);
      expect(() => idx.add('x', Vector.fromList([1, 2])), throwsStateError);
      idx.add('y', Vector.fromList([1, 2, 3]));
      expect(
        () => idx.search(Vector.fromList([1, 2]), 1),
        throwsStateError,
      );
    });

    test('k larger than N returns all live rows', () {
      final idx = HnswIndex(2, m: 4, efConstruction: 20);
      idx.add(1, Vector.fromList([1, 1]));
      idx.add(2, Vector.fromList([2, 2]));
      idx.add(3, Vector.fromList([3, 3]));
      final r = idx.search(Vector.fromList([0, 0]), 10);
      expect(r.length, 3);
      // Non-decreasing L2 distance.
      for (var i = 1; i < r.length; i++) {
        expect(r[i - 1].distance, lessThanOrEqualTo(r[i].distance));
      }
    });

    test('removeId hides the tombstoned row from results', () {
      final idx = HnswIndex(1, m: 4, efConstruction: 20);
      idx.add(1, Vector.fromList([1]));
      idx.add(2, Vector.fromList([2]));
      idx.add(3, Vector.fromList([3]));
      expect(idx.removeId(2), isTrue);
      expect(idx.removeId(999), isFalse);
      final r = idx.search(Vector.fromList([2]), 3);
      expect(r.map((h) => h.id).toSet(), {1, 3});
    });

    test('L2 metric returns euclidean (not squared) distance', () {
      final idx = HnswIndex(
        2,
        m: 4,
        efConstruction: 20,
        defaultMetric: VectorMetric.l2,
      );
      idx.add('p', Vector.fromList([3, 4]));
      final r = idx.search(Vector.fromList([0, 0]), 1);
      expect(r.single.distance, closeTo(5.0, 1e-6));
    });

    test('inner-product ranking picks largest', () {
      final idx = HnswIndex(
        2,
        m: 8,
        efConstruction: 40,
        defaultMetric: VectorMetric.innerProduct,
      );
      idx.add('a', Vector.fromList([1, 0]));
      idx.add('b', Vector.fromList([2, 3])); // ip with [1,1] = 5 (best)
      idx.add('c', Vector.fromList([-1, -1]));
      final r = idx.search(Vector.fromList([1, 1]), 1);
      expect(r.single.id, 'b');
      expect(r.single.distance, closeTo(5.0, 1e-6));
    });
  });

  group('HnswIndex recall vs FlatIndex ground truth', () {
    test('recall@10 on 500 random 16-dim vectors is high', () {
      const dim = 16;
      const n = 500;
      const k = 10;
      final rng = math.Random(42);

      final flat = FlatIndex(dim);
      final hnsw = HnswIndex(
        dim,
        m: 16,
        efConstruction: 100,
        efSearch: 64,
        seed: 7,
      );

      for (var i = 0; i < n; i++) {
        final v = _randomVec(dim, rng);
        flat.add(i, v);
        hnsw.add(i, v);
      }

      // Query a batch of 20 random points; measure recall = fraction
      // of Flat's top-k that HNSW also returned.
      const nq = 20;
      var hits = 0;
      var total = 0;
      for (var q = 0; q < nq; q++) {
        final query = _randomVec(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = hnsw.search(query, k).map((h) => h.id).toSet();
        hits += truth.intersection(got).length;
        total += truth.length;
      }
      final recall = hits / total;
      // With M=16, efConstruction=100, efSearch=64 the reference
      // pkg reports recall well above 0.9 on this size; we require
      // >= 0.85 to keep the test robust to RNG order.
      expect(recall, greaterThanOrEqualTo(0.85),
          reason: 'recall too low: $recall');
    });

    test('recall improves as efSearch grows', () {
      const dim = 8;
      const n = 300;
      const k = 10;
      final rng = math.Random(1);

      final flat = FlatIndex(dim);
      final hnsw = HnswIndex(
        dim,
        m: 8,
        efConstruction: 40,
        efSearch: 8,
        seed: 3,
      );
      for (var i = 0; i < n; i++) {
        final v = _randomVec(dim, rng);
        flat.add(i, v);
        hnsw.add(i, v);
      }

      double recallAt(int ef) {
        var hits = 0, total = 0;
        for (var q = 0; q < 10; q++) {
          final query = _randomVec(dim, rng);
          final truth = flat.search(query, k).map((h) => h.id).toSet();
          final got = hnsw.search(query, k, ef: ef).map((h) => h.id).toSet();
          hits += truth.intersection(got).length;
          total += truth.length;
        }
        return hits / total;
      }

      final rLow = recallAt(8);
      final rHigh = recallAt(128);
      expect(rHigh, greaterThanOrEqualTo(rLow),
          reason: 'recall should be monotone non-decreasing in efSearch: '
              'ef=8 → $rLow, ef=128 → $rHigh');
      // At ef=128 with 300 vectors, recall should be near perfect.
      expect(rHigh, greaterThanOrEqualTo(0.95));
    });

    test('inner-product recall vs FlatIndex ground truth', () {
      const dim = 12;
      const n = 400;
      const k = 5;
      final rng = math.Random(9);

      final flat = FlatIndex(dim, defaultMetric: VectorMetric.innerProduct);
      final hnsw = HnswIndex(
        dim,
        m: 16,
        efConstruction: 100,
        efSearch: 64,
        defaultMetric: VectorMetric.innerProduct,
        seed: 11,
      );
      for (var i = 0; i < n; i++) {
        final v = _randomVec(dim, rng);
        flat.add(i, v);
        hnsw.add(i, v);
      }

      var hits = 0, total = 0;
      for (var q = 0; q < 15; q++) {
        final query = _randomVec(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = hnsw.search(query, k).map((h) => h.id).toSet();
        hits += truth.intersection(got).length;
        total += truth.length;
      }
      final recall = hits / total;
      // IP recall is typically a bit lower than L2 because the graph
      // topology is built on L2. 0.7 is the reference package's floor.
      expect(recall, greaterThanOrEqualTo(0.7),
          reason: 'IP recall too low: $recall');
    });
  });
}
