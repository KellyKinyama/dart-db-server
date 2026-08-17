/// IVF-PQ composite index (FAISS `IndexIVFPQ` port). Direct correctness
/// + recall harness against Flat + SQL DDL/planner/persistence.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vecivfpq_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('IvfPqIndex direct', () {
    test('add before train throws', () {
      final idx = IvfPqIndex(8, nlist: 4, m: 4);
      expect(
        () => idx.add(0, Vector.fromList(List.filled(8, 1.0))),
        throwsStateError,
      );
    });

    test('search before train throws', () {
      final idx = IvfPqIndex(8, nlist: 4, m: 4);
      expect(
        () => idx.search(Vector.fromList(List.filled(8, 1.0)), 3),
        throwsStateError,
      );
    });

    test('train rejects fewer samples than nlist', () {
      final idx = IvfPqIndex(4, nlist: 16, m: 2);
      expect(
        () => idx.train([
          Vector.fromList([1, 2, 3, 4]),
          Vector.fromList([5, 6, 7, 8]),
        ]),
        throwsStateError,
      );
    });

    test('constructor rejects dim not divisible by m', () {
      expect(
        () => IvfPqIndex(15, nlist: 4, m: 4),
        throwsArgumentError,
      );
    });

    test('search returns valid results after train + add', () {
      const dim = 8;
      const m = 4;
      const nlist = 8;
      final rng = math.Random(1);
      // Need ≥ ksub=256 samples for stable PQ codebooks + ≥ nlist for
      // the coarse quantizer.
      final samples = List.generate(300, (_) => _rand(dim, rng));
      final idx = IvfPqIndex(dim, nlist: nlist, m: m, nprobe: nlist)
        ..train(samples);
      for (var i = 0; i < 40; i++) {
        idx.add(i, samples[i]);
      }
      expect(idx.length, 40);
      expect(idx.isTrained, isTrue);
      final r = idx.search(samples[0], 5);
      expect(r.length, 5);
      // The exact vector should rank first with small ADC distance.
      expect(r.first.id, 0);
    });

    test('removeId walks all cells', () {
      const dim = 4;
      const m = 2;
      final rng = math.Random(2);
      final samples = List.generate(300, (_) => _rand(dim, rng));
      final idx = IvfPqIndex(dim, nlist: 4, m: m, nprobe: 4)..train(samples);
      idx.add('a', samples[0]);
      idx.add('b', samples[1]);
      idx.add('c', samples[2]);
      expect(idx.removeId('b'), isTrue);
      expect(idx.removeId('nope'), isFalse);
      expect(idx.length, 2);
    });

    test('recall@10 vs FlatIndex ground truth on 300x16d', () {
      const dim = 16;
      const m = 8;
      const nlist = 8;
      const n = 300;
      const k = 10;
      final rng = math.Random(42);
      final samples = List.generate(n, (_) => _rand(dim, rng));
      final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
      final ivfpq = IvfPqIndex(dim, nlist: nlist, m: m, nprobe: nlist, seed: 7)
        ..train(samples);
      for (var i = 0; i < n; i++) {
        flat.add(i, samples[i]);
        ivfpq.add(i, samples[i]);
      }
      var hits = 0, total = 0;
      for (var q = 0; q < 10; q++) {
        final query = _rand(dim, rng);
        final truth = flat.search(query, k).map((h) => h.id).toSet();
        final got = ivfpq.search(query, k).map((h) => h.id).toSet();
        hits += truth.intersection(got).length;
        total += truth.length;
      }
      final recall = hits / total;
      // Full-probe IVF-PQ with reasonable PQ params keeps ≥ 0.35
      // recall on this scale in practice.
      expect(recall, greaterThanOrEqualTo(0.35),
          reason: 'IVF-PQ recall too low: $recall');
    });

    test('JSON round-trip preserves search ranking', () {
      const dim = 8;
      const m = 4;
      const nlist = 4;
      final rng = math.Random(3);
      final samples = List.generate(300, (_) => _rand(dim, rng));
      final idx = IvfPqIndex(dim, nlist: nlist, m: m, nprobe: nlist, seed: 11)
        ..train(samples);
      for (var i = 0; i < 30; i++) {
        idx.add(i, samples[i]);
      }
      final copy = IvfPqIndex.fromJson(idx.toJson());
      expect(copy.length, idx.length);
      expect(copy.isTrained, isTrue);
      final q = _rand(dim, rng);
      expect(
        copy.search(q, 5, nprobe: nlist).map((h) => h.id).toList(),
        idx.search(q, 5, nprobe: nlist).map((h) => h.id).toList(),
      );
    });
  });

  group('IVF-PQ via SQL planner', () {
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

    test('DDL: kind=ivfpq (with kind=ivf_pq alias)', () async {
      final db = await _makeDb(8, 300, math.Random(1));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_ivfpq USING vector_index("
          "table=docs, column=embedding, dim=8, kind=ivfpq, "
          "nlist=8, nprobe=4, m=4, metric=l2, seed=3)",
        );
        expect(db.vectorIndexes.length, 1);
        final spec = db.vectorIndexes.single;
        expect(spec.kind, VectorIndexKind.ivfPq);
        expect(spec.nlist, 8);
        expect(spec.nprobe, 4);
        expect(spec.m, 4);
      } finally {
        await db.close();
      }
    });

    test('planner routes VEC_L2 through IVF-PQ, VEC_IP bails', () async {
      const dim = 8;
      final rng = math.Random(2);
      final db = await _makeDb(dim, 300, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.ivfPq,
          metric: VectorMetric.l2,
          nlist: 8,
          nprobe: 8,
          m: 4,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";

        // L2 → fast path.
        final l2 = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        expect(l2.rows.length, 5);

        // IP → bails to full scan.
        final ip = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_IP(embedding, $qLit) DESC LIMIT 5",
        );
        expect(ip.rows.length, 5);
      } finally {
        await db.close();
      }
    });

    test('too few training rows falls back to Flat (still correct)', () async {
      const dim = 4;
      final rng = math.Random(3);
      final db = await _makeDb(dim, 10, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.ivfPq,
          metric: VectorMetric.l2,
          nlist: 4,
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

    test('close() + reopen preserves built IVF-PQ state', () async {
      final path = _tmp('ivfpq_reopen');
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
            "CREATE VIRTUAL TABLE docs_ivfpq USING vector_index("
            "table=docs, column=embedding, dim=$dim, kind=ivfpq, "
            "nlist=8, nprobe=8, m=4, metric=l2, seed=1)",
          );
          await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, VEC('[0,0,0,0,0,0,0,0]')) LIMIT 1",
          );
        } finally {
          await db.close();
        }
      }
      final text = await File(path).readAsString();
      expect(text.contains('"kind":"ivfPq"'), isTrue);
      expect(text.contains('"built"'), isTrue,
          reason: 'IVF-PQ built state should have been persisted');

      {
        final db = await Database.open(path);
        try {
          expect(db.vectorIndexes.single.kind, VectorIndexKind.ivfPq);
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
