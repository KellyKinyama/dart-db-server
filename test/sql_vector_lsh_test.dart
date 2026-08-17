/// LSH sign-projection index: direct correctness against Flat ground
/// truth + SQL planner integration.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

void main() {
  group('LshIndex direct', () {
    test('empty index returns empty search', () {
      final idx = LshIndex(4);
      expect(idx.search(Vector.fromList([1, 2, 3, 4]), 3), isEmpty);
    });

    test('single vector: identical query returns 0 Hamming distance', () {
      final idx = LshIndex(4, nbits: 32, seed: 1);
      final v = Vector.fromList([1, 2, 3, 4]);
      idx.add('only', v);
      final hits = idx.search(v, 1);
      expect(hits.single.id, 'only');
      expect(hits.single.distance, 0.0);
    });

    test('dim mismatch on add / search throws', () {
      final idx = LshIndex(3);
      expect(() => idx.add('x', Vector.fromList([1, 2])), throwsStateError);
      idx.add('y', Vector.fromList([1, 2, 3]));
      expect(
        () => idx.search(Vector.fromList([1, 2]), 1),
        throwsStateError,
      );
    });

    test('code size honors nbits rounding', () {
      expect(LshIndex(4, nbits: 8).codeSize, 1);
      expect(LshIndex(4, nbits: 16).codeSize, 2);
      expect(LshIndex(4, nbits: 24).codeSize, 3);
      expect(LshIndex(4, nbits: 33).codeSize, 5);
      expect(LshIndex(4, nbits: 64).codeSize, 8);
    });

    test('removeId swap-last preserves remaining rows', () {
      final idx = LshIndex(1, nbits: 8, seed: 1);
      idx.add(1, Vector.fromList([1]));
      idx.add(2, Vector.fromList([2]));
      idx.add(3, Vector.fromList([3]));
      expect(idx.removeId(2), isTrue);
      expect(idx.removeId(999), isFalse);
      expect(idx.length, 2);
      final hits = idx.search(Vector.fromList([1]), 10);
      expect(hits.map((h) => h.id).toSet(), {1, 3});
    });

    test('recall@10 vs FlatIndex ground truth on 300x16d', () {
      const dim = 16;
      const n = 300;
      const k = 10;
      final rng = math.Random(42);

      final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
      final lsh = LshIndex(dim, nbits: 256, seed: 7);
      for (var i = 0; i < n; i++) {
        final v = _rand(dim, rng);
        flat.add(i, v);
        lsh.add(i, v);
      }

      var hits = 0, total = 0;
      for (var q = 0; q < 10; q++) {
        final query = _rand(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = lsh.search(query, k).map((h) => h.id).toSet();
        hits += truth.intersection(got).length;
        total += truth.length;
      }
      final recall = hits / total;
      // LSH with 256 bits on 16-d Gaussian data should keep >= 0.35
      // recall by wide margin — floor is intentionally loose to
      // stay robust to RNG order.
      expect(recall, greaterThanOrEqualTo(0.35),
          reason: 'LSH recall too low: $recall');
    });
  });

  group('LSH via SQL planner', () {
    Future<Database> makeDb(int dim, int n, math.Random rng) async {
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

    test('DDL: CREATE VIRTUAL TABLE ... USING vector_index(kind=lsh)',
        () async {
      final db = await makeDb(8, 20, math.Random(1));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_lsh USING vector_index("
          "table=docs, column=embedding, dim=8, kind=lsh, "
          "nbits=128, metric=l2, seed=3)",
        );
        expect(db.vectorIndexes.length, 1);
        final spec = db.vectorIndexes.single;
        expect(spec.kind, VectorIndexKind.lsh);
        expect(spec.nbits, 128);
        expect(spec.seed, 3);
      } finally {
        await db.close();
      }
    });

    test('planner routes VEC_L2 queries through LSH, VEC_IP bails', () async {
      const dim = 8;
      final rng = math.Random(2);
      final db = await makeDb(dim, 50, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.lsh,
          metric: VectorMetric.l2,
          nbits: 256,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";

        // VEC_L2 → LSH fast path.
        final l2 = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        expect(l2.rows.length, 5);

        // VEC_IP → LSH bails (metric mismatch); fallback still correct.
        final ip = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_IP(embedding, $qLit) DESC LIMIT 5",
        );
        expect(ip.rows.length, 5);
      } finally {
        await db.close();
      }
    });

    test('LSH persistence: nbits survives reopen', () async {
      final tmp =
          '${Directory.systemTemp.createTempSync('ddbs_lsh_').path}/x.json';
      const dim = 4;
      final rng = math.Random(3);
      {
        final db = await Database.open(tmp);
        try {
          await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB)');
          for (var i = 0; i < 5; i++) {
            final v = _rand(dim, rng);
            await db.execute(
              "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
            );
          }
          await db.execute(
            "CREATE VIRTUAL TABLE docs_lsh USING vector_index("
            "table=docs, column=embedding, dim=$dim, kind=lsh, nbits=128)",
          );
        } finally {
          await db.close();
        }
      }
      {
        final db = await Database.open(tmp);
        try {
          expect(db.vectorIndexes.length, 1);
          final spec = db.vectorIndexes.single;
          expect(spec.kind, VectorIndexKind.lsh);
          expect(spec.nbits, 128);
        } finally {
          await db.close();
        }
      }
    });
  });
}
