/// Explicit table-valued function `vec_search(table, column, query, k)`.
/// Returns (rowid, distance) pairs sorted best-first — composes cleanly
/// in JOINs, exposes the distance value, and always uses the registered
/// vector index when one exists.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

Future<Database> _seedDocs(int dim, int n, math.Random rng) async {
  final db = await Database.open();
  await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
      'title TEXT, embedding BLOB)');
  for (var i = 0; i < n; i++) {
    final v = _rand(dim, rng);
    await db.execute(
      "INSERT INTO docs VALUES ($i, 'doc_$i', VEC('${v.toString()}'))",
    );
  }
  return db;
}

void main() {
  group('vec_search TVF: no index registered', () {
    test('builds ad-hoc FlatIndex and returns top-k', () async {
      const dim = 4;
      final rng = math.Random(1);
      final db = await _seedDocs(dim, 20, rng);
      try {
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final r = await db.execute(
          "SELECT rowid, distance FROM vec_search('docs', 'embedding', "
          "$qLit, 5)",
        );
        expect(r.rows.length, 5);
        // Non-decreasing L2² distance (default metric).
        for (var i = 1; i < r.rows.length; i++) {
          expect(r.rows[i - 1][1] as double,
              lessThanOrEqualTo(r.rows[i][1] as double));
        }
      } finally {
        await db.close();
      }
    });

    test('respects the optional metric override arg', () async {
      const dim = 4;
      final db = await _seedDocs(dim, 10, math.Random(2));
      try {
        // L2 vs L2² should give the same ranking but different distances.
        final l2 = await db.execute(
          "SELECT rowid, distance FROM vec_search('docs', 'embedding', "
          "VEC('[0,0,0,0]'), 3, 'l2')",
        );
        final l2sq = await db.execute(
          "SELECT rowid, distance FROM vec_search('docs', 'embedding', "
          "VEC('[0,0,0,0]'), 3, 'l2sq')",
        );
        expect(
          l2.rows.map((r) => r[0]).toList(),
          l2sq.rows.map((r) => r[0]).toList(),
        );
        // sqrt(l2sq) should equal l2 (within f32 rounding).
        for (var i = 0; i < 3; i++) {
          final sq = l2sq.rows[i][1] as double;
          final linear = l2.rows[i][1] as double;
          expect(math.sqrt(sq), closeTo(linear, 1e-3));
        }
      } finally {
        await db.close();
      }
    });

    test('returns rowid = primary key of the source table', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (100, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (200, VEC('[0, 1]'))");
        await db.execute("INSERT INTO docs VALUES (300, VEC('[-1, 0]'))");
        final r = await db.execute(
          "SELECT rowid FROM vec_search('docs', 'embedding', "
          "VEC('[1, 0]'), 1)",
        );
        expect(r.rows.single[0], 100);
      } finally {
        await db.close();
      }
    });

    test('unknown table / column returns empty', () async {
      final db = await _seedDocs(4, 5, math.Random(3));
      try {
        final r1 = await db.execute(
          "SELECT rowid FROM vec_search('nope', 'embedding', VEC('[0,0,0,0]'), 3)",
        );
        expect(r1.rows, isEmpty);
        final r2 = await db.execute(
          "SELECT rowid FROM vec_search('docs', 'nope', VEC('[0,0,0,0]'), 3)",
        );
        expect(r2.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('k <= 0 returns empty', () async {
      final db = await _seedDocs(4, 5, math.Random(4));
      try {
        final r = await db.execute(
          "SELECT rowid FROM vec_search('docs', 'embedding', VEC('[0,0,0,0]'), 0)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('vec_search TVF: registered index', () {
    test('uses HNSW when registered', () async {
      const dim = 8;
      final rng = math.Random(5);
      final db = await _seedDocs(dim, 100, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 16,
          efConstruction: 80,
          efSearch: 32,
        ));
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final r = await db.execute(
          "SELECT rowid, distance FROM vec_search('docs', 'embedding', "
          "$qLit, 5)",
        );
        expect(r.rows.length, 5);
      } finally {
        await db.close();
      }
    });

    test('uses PQ when registered (approximate distances)', () async {
      const dim = 8;
      final rng = math.Random(6);
      final db = await _seedDocs(dim, 300, rng);
      try {
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.pq,
          metric: VectorMetric.l2,
          m: 4,
        ));
        final r = await db.execute(
          "SELECT rowid, distance FROM vec_search('docs', 'embedding', "
          "VEC('[0,0,0,0,0,0,0,0]'), 3)",
        );
        expect(r.rows.length, 3);
        // PQ returns approximate distances; just verify non-decreasing.
        for (var i = 1; i < r.rows.length; i++) {
          expect(r.rows[i - 1][1] as double,
              lessThanOrEqualTo(r.rows[i][1] as double));
        }
      } finally {
        await db.close();
      }
    });
  });

  group('vec_search TVF: composition', () {
    test('JOIN back to source table returns full projection', () async {
      const dim = 4;
      final rng = math.Random(7);
      final db = await _seedDocs(dim, 20, rng);
      try {
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final r = await db.execute(
          "SELECT d.id, d.title, v.distance "
          "FROM vec_search('docs', 'embedding', $qLit, 3) v "
          "JOIN docs d ON d.id = v.rowid "
          "ORDER BY v.distance ASC",
        );
        expect(r.columns, ['d.id', 'd.title', 'v.distance']);
        expect(r.rows.length, 3);
        for (final row in r.rows) {
          expect(row[0], isA<int>());
          expect(row[1], isA<String>());
          expect(row[2], isA<double>());
        }
      } finally {
        await db.close();
      }
    });
  });
}
