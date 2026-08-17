/// Vector-index planner integration: `Database.createVectorIndex` +
/// automatic use of registered indexes in `ORDER BY VEC_*(...) LIMIT k`
/// queries + invalidation on mutation.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _randomVec(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

Future<Database> _dbWithVectors(int dim, int n, math.Random rng) async {
  final db = await Database.open();
  await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
      'title TEXT, embedding BLOB)');
  for (var i = 0; i < n; i++) {
    final v = _randomVec(dim, rng);
    await db.execute(
      "INSERT INTO docs VALUES ($i, 'doc_$i', VEC('${v.toString()}'))",
    );
  }
  return db;
}

void main() {
  group('createVectorIndex / dropVectorIndex API', () {
    test('registers a flat index that appears in vectorIndexes', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        db.createVectorIndex(const VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 4,
        ));
        expect(db.vectorIndexes.length, 1);
        expect(db.vectorIndexes.single.table, 'docs');
        expect(db.vectorIndexes.single.column, 'embedding');
        expect(db.vectorIndexes.single.kind, VectorIndexKind.flat);
        expect(db.dropVectorIndex('docs', 'embedding'), isTrue);
        expect(db.vectorIndexes, isEmpty);
        expect(db.dropVectorIndex('docs', 'embedding'), isFalse);
      } finally {
        await db.close();
      }
    });

    test('unknown table / column throws', () async {
      final db = await Database.open();
      try {
        expect(
          () => db.createVectorIndex(const VectorIndexSpec(
            table: 'nope',
            column: 'x',
            dim: 3,
          )),
          throwsStateError,
        );
        await db.execute('CREATE TABLE t (a INTEGER)');
        expect(
          () => db.createVectorIndex(const VectorIndexSpec(
            table: 't',
            column: 'missing',
            dim: 3,
          )),
          throwsStateError,
        );
      } finally {
        await db.close();
      }
    });

    test('duplicate registration throws', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (v BLOB)');
        db.createVectorIndex(
          const VectorIndexSpec(table: 't', column: 'v', dim: 3),
        );
        expect(
          () => db.createVectorIndex(
            const VectorIndexSpec(table: 't', column: 'v', dim: 3),
          ),
          throwsStateError,
        );
      } finally {
        await db.close();
      }
    });
  });

  group('Planner fast path via registered vector index', () {
    test('flat index produces identical results to brute-force scan', () async {
      const dim = 8;
      const n = 40;
      final rng = math.Random(1);
      final db = await _dbWithVectors(dim, n, rng);
      try {
        // Brute-force baseline BEFORE index registration.
        final query = _randomVec(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final baseline = await db.execute(
          "SELECT id FROM docs ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        expect(baseline.rows.length, 5);

        // Register flat index → planner takes fast path, same answer.
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final fast = await db.execute(
          "SELECT id FROM docs ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        expect(fast.rows.map((r) => r[0]).toList(),
            baseline.rows.map((r) => r[0]).toList());
      } finally {
        await db.close();
      }
    });

    test('SELECT * projects full row via fast path', () async {
      const dim = 4;
      final rng = math.Random(5);
      final db = await _dbWithVectors(dim, 20, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          metric: VectorMetric.l2,
        ));
        final query = _randomVec(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final r = await db.execute(
          "SELECT * FROM docs ORDER BY VEC_L2(embedding, $qLit) LIMIT 3",
        );
        expect(r.columns, ['id', 'title', 'embedding']);
        expect(r.rows.length, 3);
        // Rows should include the id (int), title (String), embedding (blob).
        for (final row in r.rows) {
          expect(row.length, 3);
          expect(row[0], isA<int>());
          expect(row[1], isA<String>());
          expect(row[2], isA<List<int>>());
        }
      } finally {
        await db.close();
      }
    });

    test('metric mismatch bails to full-scan (still correct)', () async {
      const dim = 4;
      final rng = math.Random(7);
      final db = await _dbWithVectors(dim, 15, rng);
      try {
        // Register an IP-metric index — but query with VEC_L2.
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          metric: VectorMetric.innerProduct,
        ));
        final query = _randomVec(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        // Fast path bails on metric mismatch; brute force runs. The
        // result set must still be sorted-by-L2 correctly.
        final r = await db.execute(
          "SELECT id FROM docs ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 3",
        );
        expect(r.rows.length, 3);
        // Rebuild ground truth via a Dart-side FlatIndex on same data.
        final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
        final rows = await db.execute('SELECT id, embedding FROM docs');
        for (final row in rows.rows) {
          flat.add(row[0], decodeVectorBlob(row[1] as List<int>));
        }
        final truth = flat.search(query, 3).map((h) => h.id).toList();
        expect(r.rows.map((r0) => r0[0]).toList(), truth);
      } finally {
        await db.close();
      }
    });

    test('inner-product ranking picks largest', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute(
          "INSERT INTO docs VALUES (1, VEC('[1, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (2, VEC('[2, 3]'))", // ip w/ [1,1]=5
        );
        await db.execute(
          "INSERT INTO docs VALUES (3, VEC('[-1, -1]'))",
        );
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          metric: VectorMetric.innerProduct,
        ));
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_IP(embedding, VEC('[1, 1]')) DESC LIMIT 1",
        );
        expect(r.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });

    test('INSERT after index creation is visible on next query', () async {
      const dim = 3;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          metric: VectorMetric.l2,
        ));
        // Prime the index by running one query.
        await db.execute(
          "SELECT id FROM docs ORDER BY VEC_L2(embedding, VEC('[1,0,0]')) "
          "LIMIT 1",
        );
        // Insert a much closer vector to a new query.
        await db.execute("INSERT INTO docs VALUES (2, VEC('[10, 0, 0]'))");
        final r = await db.execute(
          "SELECT id FROM docs ORDER BY VEC_L2(embedding, VEC('[10, 0, 0]')) "
          "LIMIT 1",
        );
        expect(r.rows.single[0], 2,
            reason: 'invalidation should have rebuilt the index');
      } finally {
        await db.close();
      }
    });

    test('DELETE invalidates: removed row must not appear', () async {
      const dim = 2;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[0, 1]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          metric: VectorMetric.l2,
        ));
        await db.execute('DELETE FROM docs WHERE id = 1');
        final r = await db.execute(
          "SELECT id FROM docs ORDER BY VEC_L2(embedding, VEC('[1, 0]')) "
          "LIMIT 5",
        );
        expect(r.rows.map((r) => r[0]).toList(), [2]);
      } finally {
        await db.close();
      }
    });

    test('HNSW index registration produces reasonable-recall results',
        () async {
      const dim = 16;
      const n = 200;
      final rng = math.Random(2);
      final db = await _dbWithVectors(dim, n, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 16,
          efConstruction: 100,
          efSearch: 64,
        ));

        // Sample recall over several queries vs brute-force baseline.
        var hits = 0, total = 0;
        for (var q = 0; q < 10; q++) {
          final query = _randomVec(dim, rng);
          final qLit = "VEC('${query.toString()}')";
          // Baseline: pull all rows and rank via Dart-side FlatIndex
          // (the SQL fast path is now the HNSW one, so we can't use
          // the same query to get ground truth).
          final all = await db.execute('SELECT id, embedding FROM docs');
          final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
          for (final row in all.rows) {
            flat.add(row[0], decodeVectorBlob(row[1] as List<int>));
          }
          final truth = flat.search(query, 5).map((h) => h.id).toSet();
          final got = await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
          );
          final gotIds = got.rows.map((r) => r[0]).toSet();
          hits += truth.intersection(gotIds).length;
          total += truth.length;
        }
        final recall = hits / total;
        expect(recall, greaterThanOrEqualTo(0.75),
            reason: 'HNSW recall too low: $recall');
      } finally {
        await db.close();
      }
    });

    test('IVF index with too few rows falls back to Flat (still correct)',
        () async {
      const dim = 4;
      final rng = math.Random(3);
      // Only 3 rows but nlist=8 → fewer than nlist samples.
      final db = await _dbWithVectors(dim, 3, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.ivf,
          nlist: 8,
          nprobe: 8,
          metric: VectorMetric.l2,
        ));
        final query = _randomVec(dim, rng);
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
  });
}
