/// Range search fast path: `SELECT ... FROM t WHERE VEC_L2|L2SQ(col, q)
/// < threshold [AND ...]` — no LIMIT required. Progressive doubling
/// retrieval with monotone-in-distance early termination.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

Future<Database> _seed(int dim, int n, math.Random rng) async {
  final db = await Database.open();
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
  group('Range search with FlatIndex', () {
    test('WHERE VEC_L2 < threshold returns exactly matching rows', () async {
      const dim = 4;
      final rng = math.Random(1);
      final db = await _seed(dim, 40, rng);
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
        // Ground truth via a Dart-side FlatIndex over all rows.
        final all = await db.execute('SELECT id, embedding FROM docs');
        final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
        for (final row in all.rows) {
          flat.add(row[0] as int, decodeVectorBlob(row[1] as List<int>));
        }
        // Pick a threshold that admits ~25% of the rows.
        final sortedDistances =
            flat.search(query, 40).map((h) => h.distance).toList();
        final th = sortedDistances[9]; // 10th distance
        final r = await db.execute(
          "SELECT id FROM docs WHERE VEC_L2(embedding, $qLit) < $th",
        );
        // Must include exactly the rows with distance < th (strict).
        final expected = <int>{};
        for (var i = 0; i < flat.length; i++) {
          final vec = flat.getVector(i);
          final d = vecL2(vec, query);
          if (d < th) expected.add(i);
        }
        expect(r.rows.map((row) => row[0]).toSet(), expected);
      } finally {
        await db.close();
      }
    });

    test('inclusive VEC_L2SQ <= threshold works too', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[0, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[3, 4]'))");
        // dist² from [0,0]: id 1 = 0, id 2 = 25.
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2sq,
        ));
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2SQ(embedding, VEC('[0, 0]')) <= 25",
        );
        expect(r.rows.map((r) => r[0]).toSet(), {1, 2});
      } finally {
        await db.close();
      }
    });

    test('AND-combined predicate: distance + tenant filter', () async {
      const dim = 4;
      final rng = math.Random(2);
      final db = await _seed(dim, 40, rng);
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
        // Large threshold → many candidates; filter to tenant 2 only.
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, $qLit) < 10.0 AND tenant = 2",
        );
        for (final row in r.rows) {
          expect((row[0] as int) % 4, 2);
        }
      } finally {
        await db.close();
      }
    });

    test('SELECT * with WHERE distance: full row projection', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'title TEXT, embedding BLOB)');
        await db
            .execute("INSERT INTO docs VALUES (1, 'near', VEC('[0.1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, 'far',  VEC('[10, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final r = await db.execute(
          "SELECT * FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0, 0]')) < 1.0",
        );
        expect(r.columns, ['id', 'title', 'embedding']);
        expect(r.rows.length, 1);
        expect(r.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('threshold that admits nothing returns empty', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[100, 100]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0, 0]')) < 0.5",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('empty table returns empty', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0, 0]')) < 1.0",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('Range search with HNSW (exact-ish)', () {
    test('HNSW-backed range query returns nearby rows', () async {
      const dim = 8;
      final rng = math.Random(3);
      final db = await _seed(dim, 60, rng);
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
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, $qLit) < 5.0",
        );
        // Every returned row must actually satisfy the threshold when
        // rescored on the raw blobs.
        for (final row in r.rows) {
          final rid = row[0] as int;
          final blob = await db.execute(
            'SELECT embedding FROM docs WHERE id = $rid',
          );
          final v = decodeVectorBlob(blob.rows.single[0] as List<int>);
          expect(vecL2(v, query), lessThan(5.0));
        }
      } finally {
        await db.close();
      }
    });
  });

  group('Range search: fast-path negative cases (bail cleanly)', () {
    test('LSH-backed index bails; generic executor still correct', () async {
      const dim = 8;
      final rng = math.Random(4);
      final db = await _seed(dim, 30, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.lsh,
          metric: VectorMetric.l2,
          nbits: 128,
        ));
        // Should not throw; correctness handled by generic scan.
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0,0,0,0,0,0,0,0]')) < 100.0",
        );
        expect(r.rows.length, greaterThan(0));
      } finally {
        await db.close();
      }
    });

    test('unregistered column: falls back to generic executor', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[10, 0]'))");
        // No createVectorIndex.
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0, 0]')) < 2.0",
        );
        expect(r.rows.map((r) => r[0]).toSet(), {1});
      } finally {
        await db.close();
      }
    });
  });
}
