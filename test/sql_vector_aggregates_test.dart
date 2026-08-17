/// Vector aggregates VEC_SUM / VEC_AVG. Element-wise batch centroid
/// and sum operations over `GROUP BY` — the SQL-native way to compute
/// category prototypes, cluster centroids, and user-preference vectors.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('VEC_SUM', () {
    test('sums vectors element-wise', () async {
      final db = await Database.open();
      try {
        await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)',
        );
        await db.execute("INSERT INTO t VALUES (1, VEC('[1, 2, 3]'))");
        await db.execute("INSERT INTO t VALUES (2, VEC('[4, 5, 6]'))");
        await db.execute("INSERT INTO t VALUES (3, VEC('[10, 20, 30]'))");
        final r = await db.execute('SELECT VEC_SUM(v) FROM t');
        final blob = r.rows.single[0] as List<int>;
        final sum = decodeVectorBlob(blob);
        expect(sum.values, [15.0, 27.0, 39.0]);
      } finally {
        await db.close();
      }
    });

    test('returns NULL on empty group', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)');
        final r = await db.execute('SELECT VEC_SUM(v) FROM t');
        expect(r.rows.single[0], isNull);
      } finally {
        await db.close();
      }
    });

    test('NULL rows are ignored', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)');
        await db.execute("INSERT INTO t VALUES (1, VEC('[1, 2]'))");
        await db.execute('INSERT INTO t VALUES (2, NULL)');
        await db.execute("INSERT INTO t VALUES (3, VEC('[3, 4]'))");
        final r = await db.execute('SELECT VEC_SUM(v) FROM t');
        final sum = decodeVectorBlob(r.rows.single[0] as List<int>);
        expect(sum.values, [4.0, 6.0]);
      } finally {
        await db.close();
      }
    });

    test('dim mismatch throws', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)');
        await db.execute("INSERT INTO t VALUES (1, VEC('[1, 2]'))");
        await db.execute("INSERT INTO t VALUES (2, VEC('[3, 4, 5]'))");
        expect(
          () => db.execute('SELECT VEC_SUM(v) FROM t'),
          throwsStateError,
        );
      } finally {
        await db.close();
      }
    });
  });

  group('VEC_AVG', () {
    test('computes centroid (element-wise mean)', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)');
        await db.execute("INSERT INTO t VALUES (1, VEC('[1, 2, 3]'))");
        await db.execute("INSERT INTO t VALUES (2, VEC('[4, 5, 6]'))");
        await db.execute("INSERT INTO t VALUES (3, VEC('[10, 20, 30]'))");
        final r = await db.execute('SELECT VEC_AVG(v) FROM t');
        final avg = decodeVectorBlob(r.rows.single[0] as List<int>);
        expect(avg.values[0], closeTo(5.0, 1e-5));
        expect(avg.values[1], closeTo(9.0, 1e-5));
        expect(avg.values[2], closeTo(13.0, 1e-5));
      } finally {
        await db.close();
      }
    });

    test('single-vector average = the vector itself', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)');
        await db.execute("INSERT INTO t VALUES (1, VEC('[7, 8, 9]'))");
        final r = await db.execute('SELECT VEC_AVG(v) FROM t');
        final avg = decodeVectorBlob(r.rows.single[0] as List<int>);
        expect(avg.values, [7.0, 8.0, 9.0]);
      } finally {
        await db.close();
      }
    });

    test('NULL rows ignored, divisor = non-null count', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v BLOB)');
        await db.execute("INSERT INTO t VALUES (1, VEC('[2, 4]'))");
        await db.execute('INSERT INTO t VALUES (2, NULL)');
        await db.execute("INSERT INTO t VALUES (3, VEC('[6, 8]'))");
        final r = await db.execute('SELECT VEC_AVG(v) FROM t');
        final avg = decodeVectorBlob(r.rows.single[0] as List<int>);
        // NULL row skipped → mean of [2,4] and [6,8] = [4,6], NOT /3.
        expect(avg.values, [4.0, 6.0]);
      } finally {
        await db.close();
      }
    });
  });

  group('GROUP BY: category centroids', () {
    test('one centroid per group', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'category TEXT, embedding BLOB)');
        // Category "science": two vectors, centroid = [1.5, 0.5]
        await db.execute(
          "INSERT INTO docs VALUES (1, 'science', VEC('[1, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (2, 'science', VEC('[2, 1]'))",
        );
        // Category "sports": three vectors, centroid = [-1, 0]
        await db.execute(
          "INSERT INTO docs VALUES (3, 'sports', VEC('[0, 1]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (4, 'sports', VEC('[-2, -1]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (5, 'sports', VEC('[-1, 0]'))",
        );

        final r = await db.execute(
          'SELECT category, VEC_AVG(embedding) AS centroid '
          'FROM docs GROUP BY category ORDER BY category',
        );
        expect(r.rows.length, 2);
        final sciCentroid = decodeVectorBlob(r.rows[0][1] as List<int>);
        expect(sciCentroid.values[0], closeTo(1.5, 1e-5));
        expect(sciCentroid.values[1], closeTo(0.5, 1e-5));
        final sptCentroid = decodeVectorBlob(r.rows[1][1] as List<int>);
        expect(sptCentroid.values[0], closeTo(-1.0, 1e-5));
        expect(sptCentroid.values[1], closeTo(0.0, 1e-5));
      } finally {
        await db.close();
      }
    });

    test('nearest-centroid classification pattern works end-to-end', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'category TEXT, embedding BLOB)');
        // Compact clusters at (1,0) and (-1,0).
        await db.execute(
          "INSERT INTO docs VALUES (1, 'A', VEC('[1, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (2, 'A', VEC('[1.1, 0.1]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (3, 'B', VEC('[-1, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (4, 'B', VEC('[-1.1, -0.1]'))",
        );

        // Which category centroid is closest to the query [0.9, 0]?
        // Expected: A (centroid near [1.05, 0.05]).
        final r = await db.execute(
          "WITH centroids AS ("
          "  SELECT category, VEC_AVG(embedding) AS c FROM docs GROUP BY category"
          ") "
          "SELECT category FROM centroids "
          "ORDER BY VEC_L2(c, VEC('[0.9, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 'A');
      } finally {
        await db.close();
      }
    });

    test('mixed dim across groups is fine (dim mismatch only per group)',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, '
            'g TEXT, v BLOB)');
        await db.execute("INSERT INTO t VALUES (1, 'a', VEC('[1, 2]'))");
        await db.execute("INSERT INTO t VALUES (2, 'a', VEC('[3, 4]'))");
        await db.execute("INSERT INTO t VALUES (3, 'b', VEC('[1, 2, 3]'))");
        await db.execute("INSERT INTO t VALUES (4, 'b', VEC('[4, 5, 6]'))");
        final r = await db.execute(
          'SELECT g, VEC_DIM(VEC_AVG(v)) AS d '
          'FROM t GROUP BY g ORDER BY g',
        );
        expect(r.rows.map((r) => [r[0], r[1]]).toList(), [
          ['a', 2],
          ['b', 3],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
