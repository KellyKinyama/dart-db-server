/// Batch vector search TVF: `vec_search_batch(table, column, queries,
/// k[, metric])`. One call → N×K results, amortizing per-query setup.
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
  group('parseVectorBatchText', () {
    test('parses a 2D JSON array of vectors', () {
      final vs = parseVectorBatchText('[[1,2,3],[4,5,6]]');
      expect(vs.length, 2);
      expect(vs[0].values, [1.0, 2.0, 3.0]);
      expect(vs[1].values, [4.0, 5.0, 6.0]);
    });

    test('single flat literal is wrapped in a singleton list', () {
      final vs = parseVectorBatchText('[1, 2, 3]');
      expect(vs.length, 1);
      expect(vs[0].values, [1.0, 2.0, 3.0]);
    });

    test('empty array returns empty list', () {
      expect(parseVectorBatchText('[]'), isEmpty);
    });

    test('dim mismatch across entries throws', () {
      expect(
        () => parseVectorBatchText('[[1,2,3], [1,2]]'),
        throwsFormatException,
      );
    });

    test('non-numeric element throws', () {
      expect(
        () => parseVectorBatchText('[[1, "x"]]'),
        throwsFormatException,
      );
    });
  });

  group('vec_search_batch TVF: no index', () {
    test('N queries produce N result groups sorted by query_idx', () async {
      const dim = 4;
      final rng = math.Random(1);
      final db = await _seedDocs(dim, 30, rng);
      try {
        final q1 = _rand(dim, rng);
        final q2 = _rand(dim, rng);
        final batch = '[${q1.toString()},${q2.toString()}]';
        final r = await db.execute(
          "SELECT query_idx, rowid, distance FROM vec_search_batch("
          "'docs', 'embedding', '$batch', 3)",
        );
        expect(r.rows.length, 6);
        // Rows for query 0 come first, then query 1.
        final firstThree = r.rows.take(3).map((r) => r[0]).toList();
        final lastThree = r.rows.skip(3).map((r) => r[0]).toList();
        expect(firstThree, [0, 0, 0]);
        expect(lastThree, [1, 1, 1]);
        // Non-decreasing distance within each query group.
        for (var i = 1; i < 3; i++) {
          expect(r.rows[i - 1][2] as double,
              lessThanOrEqualTo(r.rows[i][2] as double));
          expect(r.rows[3 + i - 1][2] as double,
              lessThanOrEqualTo(r.rows[3 + i][2] as double));
        }
      } finally {
        await db.close();
      }
    });

    test('matches single-query results one at a time', () async {
      const dim = 4;
      final rng = math.Random(2);
      final db = await _seedDocs(dim, 20, rng);
      try {
        final q1 = _rand(dim, rng);
        final q2 = _rand(dim, rng);
        final batch = '[${q1.toString()},${q2.toString()}]';

        final batchR = await db.execute(
          "SELECT query_idx, rowid, distance FROM vec_search_batch("
          "'docs', 'embedding', '$batch', 3)",
        );
        final singleR1 = await db.execute(
          "SELECT rowid, distance FROM vec_search("
          "'docs', 'embedding', VEC('${q1.toString()}'), 3)",
        );
        final singleR2 = await db.execute(
          "SELECT rowid, distance FROM vec_search("
          "'docs', 'embedding', VEC('${q2.toString()}'), 3)",
        );

        expect(batchR.rows.take(3).map((r) => r[1]).toList(),
            singleR1.rows.map((r) => r[0]).toList());
        expect(batchR.rows.skip(3).map((r) => r[1]).toList(),
            singleR2.rows.map((r) => r[0]).toList());
      } finally {
        await db.close();
      }
    });

    test('empty batch returns empty result', () async {
      final db = await _seedDocs(4, 5, math.Random(3));
      try {
        final r = await db.execute(
          "SELECT query_idx, rowid, distance FROM vec_search_batch("
          "'docs', 'embedding', '[]', 3)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('invalid queries JSON returns empty result', () async {
      final db = await _seedDocs(4, 5, math.Random(4));
      try {
        final r = await db.execute(
          "SELECT rowid FROM vec_search_batch("
          "'docs', 'embedding', 'not json', 3)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('unknown table returns empty result', () async {
      final db = await _seedDocs(4, 5, math.Random(5));
      try {
        final r = await db.execute(
          "SELECT rowid FROM vec_search_batch("
          "'nope', 'embedding', '[[0,0,0,0]]', 3)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('vec_search_batch TVF: registered index', () {
    test('uses registered HNSW; k*N results total', () async {
      const dim = 8;
      final rng = math.Random(6);
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
        final qs = List.generate(4, (_) => _rand(dim, rng));
        final batch = '[${qs.map((v) => v.toString()).join(",")}]';
        final r = await db.execute(
          "SELECT query_idx, rowid, distance FROM vec_search_batch("
          "'docs', 'embedding', '$batch', 5)",
        );
        expect(r.rows.length, 4 * 5);
        // Each query's group has 5 rows with matching query_idx.
        for (var q = 0; q < 4; q++) {
          final slice = r.rows.skip(q * 5).take(5).map((r) => r[0]).toList();
          expect(slice, List.filled(5, q));
        }
      } finally {
        await db.close();
      }
    });
  });

  group('vec_search_batch TVF: composition', () {
    test('JOIN back to source table returns full projection', () async {
      const dim = 4;
      final rng = math.Random(7);
      final db = await _seedDocs(dim, 20, rng);
      try {
        final q1 = _rand(dim, rng);
        final q2 = _rand(dim, rng);
        final batch = '[${q1.toString()},${q2.toString()}]';
        final r = await db.execute(
          "SELECT v.query_idx, d.id, d.title, v.distance "
          "FROM vec_search_batch('docs', 'embedding', '$batch', 2) v "
          "JOIN docs d ON d.id = v.rowid "
          "ORDER BY v.query_idx, v.distance",
        );
        expect(r.rows.length, 4);
        for (final row in r.rows) {
          expect(row[0], isA<int>());
          expect(row[1], isA<int>());
          expect(row[2], isA<String>());
          expect(row[3], isA<double>());
        }
      } finally {
        await db.close();
      }
    });
  });
}
