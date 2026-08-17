/// Table-to-table k-NN TVF: `vec_search_join(target_table, target_col,
/// query_table, query_col, k[, metric])`. Feed queries directly from
/// another table — no JSON encoding needed. Ideal for RAG evaluation
/// pipelines: "for each row in test_queries, find top-k from docs".
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

Future<Database> _seedBoth(
    int dim, int nDocs, int nQueries, math.Random rng) async {
  final db = await Database.open();
  await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
      'title TEXT, embedding BLOB)');
  for (var i = 0; i < nDocs; i++) {
    final v = _rand(dim, rng);
    await db.execute(
      "INSERT INTO docs VALUES ($i, 'doc_$i', VEC('${v.toString()}'))",
    );
  }
  await db.execute('CREATE TABLE queries (id INTEGER PRIMARY KEY, '
      'label TEXT, q_vec BLOB)');
  for (var i = 0; i < nQueries; i++) {
    final v = _rand(dim, rng);
    await db.execute(
      "INSERT INTO queries VALUES ($i, 'q_$i', VEC('${v.toString()}'))",
    );
  }
  return db;
}

void main() {
  group('vec_search_join TVF: no index', () {
    test('each query row produces k rows, ordered by query_rowid then dist',
        () async {
      const dim = 4;
      final rng = math.Random(1);
      final db = await _seedBoth(dim, 20, 3, rng);
      try {
        final r = await db.execute(
          "SELECT query_rowid, rowid, distance FROM vec_search_join("
          "'docs', 'embedding', 'queries', 'q_vec', 4)",
        );
        expect(r.rows.length, 3 * 4);
        // Each group of 4 has same query_rowid.
        for (var q = 0; q < 3; q++) {
          final slice = r.rows.skip(q * 4).take(4).toList();
          for (final row in slice) {
            expect(row[0], q);
          }
          // Non-decreasing distance in each group.
          for (var i = 1; i < 4; i++) {
            expect(slice[i - 1][2] as double,
                lessThanOrEqualTo(slice[i][2] as double));
          }
        }
      } finally {
        await db.close();
      }
    });

    test('matches single-query results row-for-row', () async {
      const dim = 4;
      final rng = math.Random(2);
      final db = await _seedBoth(dim, 20, 3, rng);
      try {
        final joined = await db.execute(
          "SELECT query_rowid, rowid, distance FROM vec_search_join("
          "'docs', 'embedding', 'queries', 'q_vec', 3)",
        );

        for (var qi = 0; qi < 3; qi++) {
          final qBlob = await db.execute(
            'SELECT q_vec FROM queries WHERE id = $qi',
          );
          final qVec = decodeVectorBlob(qBlob.rows.single[0] as List<int>);
          final qLit = "VEC('${qVec.toString()}')";
          final single = await db.execute(
            "SELECT rowid, distance FROM vec_search("
            "'docs', 'embedding', $qLit, 3)",
          );
          final joinedSlice = joined.rows.skip(qi * 3).take(3).toList();
          expect(joinedSlice.map((r) => r[1]).toList(),
              single.rows.map((r) => r[0]).toList());
        }
      } finally {
        await db.close();
      }
    });

    test('query rows with NULL embedding contribute no output', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[0, 1]'))");
        await db.execute('CREATE TABLE queries (id INTEGER PRIMARY KEY, '
            'q_vec BLOB)');
        await db.execute("INSERT INTO queries VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO queries VALUES (2, NULL)");
        await db.execute("INSERT INTO queries VALUES (3, VEC('[0, 1]'))");
        final r = await db.execute(
          "SELECT query_rowid, rowid FROM vec_search_join("
          "'docs', 'embedding', 'queries', 'q_vec', 1)",
        );
        // Query 2 (NULL) skipped; queries 1 and 3 each contribute 1 row.
        expect(r.rows.length, 2);
        expect(r.rows[0][0], 1);
        expect(r.rows[1][0], 3);
      } finally {
        await db.close();
      }
    });

    test('unknown table / column returns empty', () async {
      final db = await _seedBoth(4, 5, 2, math.Random(3));
      try {
        final r1 = await db.execute(
          "SELECT rowid FROM vec_search_join("
          "'nope', 'embedding', 'queries', 'q_vec', 3)",
        );
        expect(r1.rows, isEmpty);
        final r2 = await db.execute(
          "SELECT rowid FROM vec_search_join("
          "'docs', 'embedding', 'queries', 'nope', 3)",
        );
        expect(r2.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('vec_search_join TVF: registered index', () {
    test('uses registered HNSW; N × k output rows', () async {
      const dim = 8;
      final rng = math.Random(4);
      final db = await _seedBoth(dim, 100, 5, rng);
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
        final r = await db.execute(
          "SELECT query_rowid, rowid, distance FROM vec_search_join("
          "'docs', 'embedding', 'queries', 'q_vec', 4)",
        );
        expect(r.rows.length, 5 * 4);
      } finally {
        await db.close();
      }
    });
  });

  group('vec_search_join TVF: composition', () {
    test('JOINs back to both source tables project full rows', () async {
      const dim = 4;
      final db = await _seedBoth(dim, 20, 3, math.Random(5));
      try {
        final r = await db.execute(
          "SELECT q.label, d.title, v.distance "
          "FROM vec_search_join('docs', 'embedding', 'queries', 'q_vec', 2) v "
          "JOIN queries q ON q.id = v.query_rowid "
          "JOIN docs d ON d.id = v.rowid "
          "ORDER BY q.id, v.distance",
        );
        expect(r.columns, ['q.label', 'd.title', 'v.distance']);
        expect(r.rows.length, 3 * 2);
        for (final row in r.rows) {
          expect(row[0], isA<String>());
          expect(row[1], isA<String>());
          expect(row[2], isA<double>());
        }
      } finally {
        await db.close();
      }
    });
  });
}
