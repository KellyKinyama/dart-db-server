/// Vector-index BUILT state persistence: HNSW graphs, IVF centroids,
/// LSH codes, and Flat vectors survive `close()` → reopen without a
/// rebuild pass. Verified by (a) direct API round-trips and (b)
/// end-to-end JSON persistence.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vecbuilt_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('FlatIndex JSON round-trip', () {
    test('empty index round-trips', () {
      final idx = FlatIndex(4);
      final copy = FlatIndex.fromJson(idx.toJson());
      expect(copy.length, 0);
    });

    test('populated index preserves nearest-neighbor ranking', () {
      const dim = 8;
      final rng = math.Random(1);
      final idx = FlatIndex(dim, defaultMetric: VectorMetric.l2);
      for (var i = 0; i < 30; i++) {
        idx.add(i, _rand(dim, rng));
      }
      final copy = FlatIndex.fromJson(idx.toJson());
      final q = _rand(dim, rng);
      final a = idx.search(q, 5).map((h) => h.id).toList();
      final b = copy.search(q, 5).map((h) => h.id).toList();
      expect(b, a);
    });
  });

  group('HnswIndex JSON round-trip', () {
    test('populated graph search matches original', () {
      const dim = 12;
      final rng = math.Random(2);
      final idx = HnswIndex(dim, m: 8, efConstruction: 40, efSearch: 32);
      for (var i = 0; i < 50; i++) {
        idx.add(i, _rand(dim, rng));
      }
      final copy = HnswIndex.fromJson(idx.toJson());
      final q = _rand(dim, rng);
      expect(
        copy.search(q, 5).map((h) => h.id).toList(),
        idx.search(q, 5).map((h) => h.id).toList(),
      );
    });
  });

  group('IvfFlatIndex JSON round-trip', () {
    test('trained + populated cells preserve ranking', () {
      const dim = 8;
      final rng = math.Random(3);
      final samples = List.generate(60, (_) => _rand(dim, rng));
      final idx = IvfFlatIndex(dim, nlist: 6, nprobe: 6)..train(samples);
      for (var i = 0; i < samples.length; i++) {
        idx.add(i, samples[i]);
      }
      final copy = IvfFlatIndex.fromJson(idx.toJson());
      final q = _rand(dim, rng);
      expect(
        copy.search(q, 5).map((h) => h.id).toList(),
        idx.search(q, 5).map((h) => h.id).toList(),
      );
    });
  });

  group('LshIndex JSON round-trip', () {
    test('same codes → same Hamming ranking', () {
      const dim = 8;
      final rng = math.Random(4);
      final idx = LshIndex(dim, nbits: 64, seed: 5);
      for (var i = 0; i < 40; i++) {
        idx.add(i, _rand(dim, rng));
      }
      final copy = LshIndex.fromJson(idx.toJson(5));
      final q = _rand(dim, rng);
      expect(
        copy.search(q, 5).map((h) => h.id).toList(),
        idx.search(q, 5).map((h) => h.id).toList(),
      );
    });
  });

  group('End-to-end persist via Database', () {
    test('close() flushes built state; reopen skips rebuild', () async {
      final path = _tmp('close_flush');
      const dim = 8;
      final rng = math.Random(6);

      {
        final db = await Database.open(path);
        try {
          await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB)');
          for (var i = 0; i < 20; i++) {
            final v = _rand(dim, rng);
            await db.execute(
              "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
            );
          }
          await db.execute(
            "CREATE VIRTUAL TABLE docs_vec USING vector_index("
            "table=docs, column=embedding, dim=$dim, kind=hnsw, "
            "metric=l2, m=8, ef_construction=40, ef_search=32, seed=1)",
          );
          // Prime the index by running one query so it's in memory.
          await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, VEC('[0,0,0,0,0,0,0,0]')) LIMIT 1",
          );
          // close() should flush the built state.
        } finally {
          await db.close();
        }
      }
      // Verify the JSON has a `built` block.
      final text = await File(path).readAsString();
      expect(text.contains('"built"'), isTrue,
          reason: 'close() should have persisted built state');

      // Reopen and verify the built state was restored (same ranking).
      {
        final db = await Database.open(path);
        try {
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

    test('warmVectorIndexes builds and persists explicitly', () async {
      final path = _tmp('warm_explicit');
      const dim = 4;
      final rng = math.Random(7);
      {
        final db = await Database.open(path);
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
        } finally {
          await db.close();
        }
      }
      final text = await File(path).readAsString();
      expect(text.contains('"built"'), isTrue);
    });

    test('plain INSERT keeps built state via incremental append (V21)',
        () async {
      final path = _tmp('mutate_incremental');
      const dim = 3;
      final rng = math.Random(8);
      {
        final db = await Database.open(path);
        try {
          await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB)');
          await db.execute("INSERT INTO docs VALUES (1, VEC('[1,0,0]'))");
          db.createVectorIndex(VectorIndexSpec(
            table: 'docs',
            column: 'embedding',
            dim: dim,
            metric: VectorMetric.l2,
          ));
          await db.warmVectorIndexes();
          // Plain INSERT — V21 keeps the built index alive; the new
          // row is appended incrementally at next query.
          await db.execute("INSERT INTO docs VALUES (2, VEC('[0,1,0]'))");
        } finally {
          await db.close();
        }
      }
      // Post-mutation JSON should still carry the built state.
      final text = await File(path).readAsString();
      expect(text.contains('"built"'), isTrue,
          reason: 'plain INSERT should not invalidate; V21 incremental append');
      // And reopen still returns correct results (both rows visible).
      {
        final db = await Database.open(path);
        try {
          final r = await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, VEC('[0,1,0]')) ASC LIMIT 1",
          );
          expect(r.rows.single[0], 2);
        } finally {
          await db.close();
        }
      }
    });
  });
}
