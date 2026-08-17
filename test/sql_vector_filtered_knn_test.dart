/// Filtered vector-KNN queries: `SELECT ... FROM t WHERE ... ORDER BY
/// VEC_L2(col, q) LIMIT k` must combine index-accelerated k-NN with
/// per-row filter evaluation. Fast path over-fetches (4k → 16k → bail)
/// and post-filters. Verified against brute-force ground truth.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

Future<Database> _makeDb(int dim, int n, math.Random rng) async {
  final db = await Database.open();
  await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
      'tenant INTEGER, tag TEXT, embedding BLOB)');
  for (var i = 0; i < n; i++) {
    final v = _rand(dim, rng);
    final tenant = i % 4; // ~25% per tenant
    final tag = i % 5 == 0 ? 'featured' : 'normal'; // ~20% featured
    await db.execute(
      "INSERT INTO docs VALUES ($i, $tenant, '$tag', "
      "VEC('${v.toString()}'))",
    );
  }
  return db;
}

/// Compute ground-truth top-k using a brute-force FlatIndex over the
/// rows that satisfy `predicate(row)`.
List<int> _bruteTopK(
  List<List<Object?>> rows,
  int embeddingCol,
  Vector query,
  int k,
  bool Function(List<Object?>) predicate,
) {
  final flat = FlatIndex(query.dim, defaultMetric: VectorMetric.l2);
  for (var i = 0; i < rows.length; i++) {
    if (!predicate(rows[i])) continue;
    final blob = rows[i][embeddingCol] as List<int>;
    flat.add(rows[i][0] as int, decodeVectorBlob(blob));
  }
  return flat.search(query, k).map((h) => h.id as int).toList();
}

void main() {
  group('Filtered vector KNN via planner fast path', () {
    test('WHERE with permissive filter (~75% pass): index still serves',
        () async {
      const dim = 8;
      const n = 300;
      final rng = math.Random(1);
      final db = await _makeDb(dim, n, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";

        // Filter: tenant IN (0, 1, 2) → 3 out of 4 tenants (~75%).
        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant != 3 "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        expect(r.rows.length, 5);
        // Every returned row must satisfy the filter.
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 4, isNot(3),
              reason: 'row $id violates WHERE tenant != 3');
        }

        // Ground truth over the same filter.
        final all = await db.execute('SELECT id, embedding FROM docs');
        final truth = _bruteTopK(
          all.rows.toList(),
          1,
          query,
          5,
          (row) => (row[0] as int) % 4 != 3,
        );
        expect(r.rows.map((rr) => rr[0]).toList(), truth);
      } finally {
        await db.close();
      }
    });

    test('WHERE with selective filter (~25% pass): still correct', () async {
      const dim = 8;
      const n = 300;
      final rng = math.Random(2);
      final db = await _makeDb(dim, n, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";

        // Filter: tenant = 2 → 25% of rows.
        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 2 "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        expect(r.rows.length, 5);
        for (final row in r.rows) {
          expect((row[0] as int) % 4, 2);
        }
      } finally {
        await db.close();
      }
    });

    test('multi-column WHERE (AND) evaluated per row', () async {
      const dim = 8;
      const n = 300;
      final rng = math.Random(3);
      final db = await _makeDb(dim, n, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";

        // ~5% pass (~15 rows out of 300) — small but non-empty result.
        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 1 AND tag = 'featured' "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 3",
        );
        // Might be < 3 if selectivity is too high and fast path bails,
        // in which case generic executor takes over and result is
        // still valid — the assertion is just correctness.
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 4, 1);
          expect(id % 5, 0);
        }
      } finally {
        await db.close();
      }
    });

    test('WHERE with HNSW index also works (approximate ranking)', () async {
      const dim = 16;
      const n = 300;
      final rng = math.Random(4);
      final db = await _makeDb(dim, n, rng);
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
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";

        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 0 "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );
        // Correctness only — HNSW recall isn't strict enough to compare
        // to brute force here. Filter must hold on every returned row.
        for (final row in r.rows) {
          expect((row[0] as int) % 4, 0);
        }
        // We should get at least 1 result (tenant 0 has ~75 rows).
        expect(r.rows.length, greaterThan(0));
      } finally {
        await db.close();
      }
    });

    test('SELECT * with WHERE: full row projection preserved', () async {
      const dim = 4;
      final db = await _makeDb(dim, 40, math.Random(5));
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final r = await db.execute(
          "SELECT * FROM docs WHERE tenant = 0 "
          "ORDER BY VEC_L2(embedding, VEC('[0,0,0,0]')) LIMIT 2",
        );
        expect(r.columns, ['id', 'tenant', 'tag', 'embedding']);
        expect(r.rows.length, 2);
        for (final row in r.rows) {
          expect(row[1], 0);
        }
      } finally {
        await db.close();
      }
    });

    test('WHERE that filters out EVERYTHING: fast path bails, correct result',
        () async {
      const dim = 4;
      final db = await _makeDb(dim, 20, math.Random(6));
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        // No row has tenant = 99; fast path returns null after both
        // budgets exhaust; generic executor produces an empty result.
        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 99 "
          "ORDER BY VEC_L2(embedding, VEC('[0,0,0,0]')) LIMIT 5",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('WHERE with NULL comparison uses SQL 3VL', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'label TEXT, embedding BLOB)');
        await db.execute(
          "INSERT INTO docs VALUES "
          "(1, 'a', VEC('[1,0]')), "
          "(2, NULL, VEC('[2,0]')), "
          "(3, 'b', VEC('[3,0]'))",
        );
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        // `label = 'a'` on a NULL row evaluates to NULL, not TRUE,
        // so row 2 must not appear.
        final r = await db.execute(
          "SELECT id FROM docs WHERE label = 'a' "
          "ORDER BY VEC_L2(embedding, VEC('[0,0]')) LIMIT 5",
        );
        expect(r.rows.map((rr) => rr[0]).toList(), [1]);
      } finally {
        await db.close();
      }
    });
  });
}
