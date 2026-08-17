/// IVF cell-probe index (FAISS IndexIVFFlat) — correctness on small
/// deterministic cases + recall-vs-Flat ground truth on random data.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _randomVec(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

void main() {
  group('IvfFlatIndex lifecycle', () {
    test('add before train throws', () {
      final idx = IvfFlatIndex(3, nlist: 2);
      expect(
        () => idx.add(1, Vector.fromList([1, 2, 3])),
        throwsStateError,
      );
    });

    test('search before train throws', () {
      final idx = IvfFlatIndex(3, nlist: 2);
      expect(
        () => idx.search(Vector.fromList([1, 2, 3]), 1),
        throwsStateError,
      );
    });

    test('train with fewer samples than nlist throws', () {
      final idx = IvfFlatIndex(2, nlist: 5);
      expect(
        () => idx.train([
          Vector.fromList([1, 1]),
          Vector.fromList([2, 2]),
        ]),
        throwsStateError,
      );
    });

    test('empty index (post-train) returns empty search', () {
      final idx = IvfFlatIndex(2, nlist: 2)
        ..train(List.generate(4, (i) => Vector.fromList([i.toDouble(), 0])));
      expect(idx.length, 0);
      final r = idx.search(Vector.fromList([0, 0]), 3);
      expect(r, isEmpty);
    });

    test('dim mismatch on add / search throws', () {
      final idx = IvfFlatIndex(3, nlist: 2)
        ..train(List.generate(4, (_) => Vector.fromList([1, 2, 3])));
      expect(() => idx.add(1, Vector.fromList([1, 2])), throwsStateError);
      idx.add(1, Vector.fromList([1, 2, 3]));
      expect(
        () => idx.search(Vector.fromList([1, 2]), 1),
        throwsStateError,
      );
    });
  });

  group('IvfFlatIndex basics', () {
    test('single vector search returns itself', () {
      final idx = IvfFlatIndex(2, nlist: 2)
        ..train(List.generate(4, (i) => Vector.fromList([i.toDouble(), 0])));
      idx.add('only', Vector.fromList([3, 4]));
      final hits = idx.search(Vector.fromList([3, 4]), 1, nprobe: 2);
      expect(hits.single.id, 'only');
      expect(hits.single.distance, 0.0);
    });

    test('L2 metric returns euclidean (not squared) distance', () {
      final idx = IvfFlatIndex(
        2,
        nlist: 2,
        defaultMetric: VectorMetric.l2,
      )..train(List.generate(4, (i) => Vector.fromList([i.toDouble(), 0])));
      idx.add('p', Vector.fromList([3, 4]));
      final r = idx.search(Vector.fromList([0, 0]), 1, nprobe: 2);
      expect(r.single.distance, closeTo(5.0, 1e-6));
    });

    test('inner-product ranking picks largest', () {
      final idx = IvfFlatIndex(
        2,
        nlist: 2,
        defaultMetric: VectorMetric.innerProduct,
      )..train(List.generate(6, (i) => Vector.fromList([i.toDouble(), 0])));
      idx.add('a', Vector.fromList([1, 0]));
      idx.add('b', Vector.fromList([2, 3])); // ip with [1,1] = 5
      idx.add('c', Vector.fromList([-1, -1]));
      final r = idx.search(Vector.fromList([1, 1]), 1, nprobe: 2);
      expect(r.single.id, 'b');
      expect(r.single.distance, closeTo(5.0, 1e-6));
    });

    test('removeId hides row from results', () {
      final samples = List.generate(6, (i) => Vector.fromList([i.toDouble()]));
      final idx = IvfFlatIndex(1, nlist: 2, nprobe: 2)..train(samples);
      idx.add(1, Vector.fromList([1]));
      idx.add(2, Vector.fromList([2]));
      idx.add(3, Vector.fromList([3]));
      expect(idx.removeId(2), isTrue);
      expect(idx.removeId(999), isFalse);
      expect(idx.length, 2);
      final r = idx.search(Vector.fromList([2]), 3);
      expect(r.map((h) => h.id).toSet(), {1, 3});
    });

    test('k larger than N returns all rows', () {
      final samples = List.generate(4, (i) => Vector.fromList([i.toDouble()]));
      final idx = IvfFlatIndex(1, nlist: 2, nprobe: 2)..train(samples);
      idx.add(1, Vector.fromList([1]));
      idx.add(2, Vector.fromList([2]));
      final r = idx.search(Vector.fromList([0]), 10);
      expect(r.length, 2);
    });
  });

  group('IvfFlatIndex recall vs FlatIndex ground truth', () {
    test('nprobe=nlist is exhaustive: equals FlatIndex ranking', () {
      const dim = 8;
      const n = 200;
      const k = 5;
      final rng = math.Random(1);

      final samples = List.generate(n, (_) => _randomVec(dim, rng));
      final flat = FlatIndex(dim);
      final ivf = IvfFlatIndex(dim, nlist: 8, seed: 2)..train(samples);

      for (var i = 0; i < n; i++) {
        flat.add(i, samples[i]);
        ivf.add(i, samples[i]);
      }

      // Full-probe should recover the exact top-k set every time.
      for (var q = 0; q < 10; q++) {
        final query = _randomVec(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = ivf.search(query, k, nprobe: 8).map((h) => h.id).toSet();
        expect(got, truth,
            reason: 'IVF with nprobe=nlist must match Flat exactly');
      }
    });

    test('L2 recall@10 on 500x16d with nprobe=8/16 is high', () {
      const dim = 16;
      const n = 500;
      const k = 10;
      final rng = math.Random(42);

      final samples = List.generate(n, (_) => _randomVec(dim, rng));
      final flat = FlatIndex(dim);
      final ivf = IvfFlatIndex(dim, nlist: 16, nprobe: 8, seed: 7)
        ..train(samples);

      for (var i = 0; i < n; i++) {
        flat.add(i, samples[i]);
        ivf.add(i, samples[i]);
      }

      var hits = 0, total = 0;
      for (var q = 0; q < 20; q++) {
        final query = _randomVec(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = ivf.search(query, k).map((h) => h.id).toSet();
        hits += truth.intersection(got).length;
        total += truth.length;
      }
      final recall = hits / total;
      // Probing half the cells on i.i.d. uniform-ish data yields
      // recall well above 0.8 in practice; keep threshold at 0.75 to
      // avoid RNG flakiness.
      expect(recall, greaterThanOrEqualTo(0.75),
          reason: 'recall too low: $recall');
    });

    test('recall improves as nprobe grows', () {
      const dim = 8;
      const n = 300;
      const k = 10;
      final rng = math.Random(3);

      final samples = List.generate(n, (_) => _randomVec(dim, rng));
      final flat = FlatIndex(dim);
      final ivf = IvfFlatIndex(dim, nlist: 12, nprobe: 1, seed: 5)
        ..train(samples);
      for (var i = 0; i < n; i++) {
        flat.add(i, samples[i]);
        ivf.add(i, samples[i]);
      }

      double recallAt(int p) {
        var hits = 0, total = 0;
        for (var q = 0; q < 10; q++) {
          final query = _randomVec(dim, rng);
          final truth = flat.search(query, k).map((h) => h.id).toSet();
          final got = ivf.search(query, k, nprobe: p).map((h) => h.id).toSet();
          hits += truth.intersection(got).length;
          total += truth.length;
        }
        return hits / total;
      }

      final rLow = recallAt(1);
      final rHigh = recallAt(12);
      expect(rHigh, greaterThanOrEqualTo(rLow),
          reason: 'recall should be monotone in nprobe: '
              'nprobe=1 → $rLow, nprobe=nlist → $rHigh');
      expect(rHigh, 1.0, reason: 'nprobe=nlist should give exact recall');
    });

    test('inner-product recall vs FlatIndex ground truth', () {
      const dim = 12;
      const n = 400;
      const k = 5;
      final rng = math.Random(9);

      final samples = List.generate(n, (_) => _randomVec(dim, rng));
      final flat = FlatIndex(dim, defaultMetric: VectorMetric.innerProduct);
      final ivf = IvfFlatIndex(
        dim,
        nlist: 12,
        nprobe: 6,
        defaultMetric: VectorMetric.innerProduct,
        seed: 11,
      )..train(samples);
      for (var i = 0; i < n; i++) {
        flat.add(i, samples[i]);
        ivf.add(i, samples[i]);
      }

      var hits = 0, total = 0;
      for (var q = 0; q < 15; q++) {
        final query = _randomVec(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = ivf.search(query, k).map((h) => h.id).toSet();
        hits += truth.intersection(got).length;
        total += truth.length;
      }
      final recall = hits / total;
      // Coarse quantizer is L2-based even for IP search (same as FAISS),
      // so IP recall trails L2 recall a bit — 0.55 keeps this robust.
      expect(recall, greaterThanOrEqualTo(0.55),
          reason: 'IP recall too low: $recall');
    });
  });
}
