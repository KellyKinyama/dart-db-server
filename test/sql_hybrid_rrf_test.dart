/// Hybrid retrieval scalar functions: `RRF_SCORE`, `RRF`, and
/// `HYBRID_SCORE`. Verified on synthetic data and via an end-to-end
/// FTS5 + vector fusion query.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('RRF_SCORE', () {
    test('scores single-rank contribution with default k=60', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          'SELECT RRF_SCORE(0) AS a, RRF_SCORE(1) AS b, RRF_SCORE(9) AS c',
        );
        final row = r.rows.single;
        expect(row[0], closeTo(1.0 / 60.0, 1e-12));
        expect(row[1], closeTo(1.0 / 61.0, 1e-12));
        expect(row[2], closeTo(1.0 / 69.0, 1e-12));
      } finally {
        await db.close();
      }
    });

    test('NULL rank returns 0 (row absent from that ranker)', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT RRF_SCORE(NULL) AS s');
        expect(r.rows.single[0], 0.0);
      } finally {
        await db.close();
      }
    });

    test('custom k parameter is respected', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT RRF_SCORE(1, 10) AS s');
        expect(r.rows.single[0], closeTo(1.0 / 11.0, 1e-12));
      } finally {
        await db.close();
      }
    });
  });

  group('RRF (variadic)', () {
    test('two-way fusion is the sum of two RRF_SCOREs', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          'SELECT RRF(1, 3) AS s, RRF_SCORE(1) + RRF_SCORE(3) AS ref',
        );
        expect(r.rows.single[0], closeTo(r.rows.single[1] as double, 1e-12));
      } finally {
        await db.close();
      }
    });

    test('NULL args are ignored', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          'SELECT RRF(NULL, 5, NULL) AS s, RRF_SCORE(5) AS ref',
        );
        expect(r.rows.single[0], closeTo(r.rows.single[1] as double, 1e-12));
      } finally {
        await db.close();
      }
    });

    test('all-NULL yields 0', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          'SELECT RRF(NULL, NULL, NULL) AS s',
        );
        expect(r.rows.single[0], 0.0);
      } finally {
        await db.close();
      }
    });
  });

  group('HYBRID_SCORE', () {
    test('alpha=1 returns pure vector similarity', () async {
      final db = await Database.open();
      try {
        // vec_dist=1 → similarity = 1/(1+1) = 0.5
        final r = await db.execute(
          'SELECT HYBRID_SCORE(1.0, 0.9, 1.0) AS s',
        );
        expect(r.rows.single[0], closeTo(0.5, 1e-12));
      } finally {
        await db.close();
      }
    });

    test('alpha=0 returns pure FTS score', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          'SELECT HYBRID_SCORE(1.0, 0.9, 0.0) AS s',
        );
        expect(r.rows.single[0], closeTo(0.9, 1e-12));
      } finally {
        await db.close();
      }
    });

    test('alpha=0.5 balances both terms', () async {
      final db = await Database.open();
      try {
        // 0.5 * (1/(1+3)) + 0.5 * 0.6 = 0.125 + 0.3 = 0.425
        final r = await db.execute(
          'SELECT HYBRID_SCORE(3.0, 0.6, 0.5) AS s',
        );
        expect(r.rows.single[0], closeTo(0.425, 1e-12));
      } finally {
        await db.close();
      }
    });

    test('NULLs on either side contribute 0 for that term', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          'SELECT HYBRID_SCORE(NULL, 0.5, 0.5) AS v_only_null, '
          '       HYBRID_SCORE(2.0, NULL, 0.5) AS f_only_null',
        );
        final row = r.rows.single;
        // v null → 0.5*0 + 0.5*0.5 = 0.25
        expect(row[0], closeTo(0.25, 1e-12));
        // f null → 0.5 * 1/(1+2) + 0 = 1/6
        expect(row[1], closeTo(1.0 / 6.0, 1e-12));
      } finally {
        await db.close();
      }
    });
  });

  group('End-to-end hybrid FTS + vector via RRF', () {
    test('fusion beats either ranker alone on a synthetic case', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'title TEXT, embedding BLOB)');
        // Two conceptual clusters:
        // - 1..3 are about "quantum" (keyword match)
        // - 4..6 have embeddings close to the query (vector match)
        // - 7 is BOTH quantum AND near the query — the true best answer.
        // - 8..10 are noise.
        await db.execute(
          "INSERT INTO docs VALUES "
          "(1, 'quantum mechanics primer',     VEC('[9, 0, 0, 0]')), "
          "(2, 'introduction to quantum',      VEC('[8, 0, 0, 0]')), "
          "(3, 'quantum entanglement basics',  VEC('[7, 0, 0, 0]')), "
          "(4, 'photon travel notes',          VEC('[0, 1, 0, 0]')), "
          "(5, 'nearby measurement journal',   VEC('[0, 1, 0.1, 0]')), "
          "(6, 'proximate signal telemetry',   VEC('[0, 1, 0.2, 0]')), "
          "(7, 'quantum measurement notes',    VEC('[0, 1, 0.05, 0]')), "
          "(8, 'unrelated cooking recipe',     VEC('[10, 10, 10, 10]')), "
          "(9, 'gardening tips 2024',          VEC('[10, 10, 10, 10]')), "
          "(10,'weather forecast',              VEC('[10, 10, 10, 10]'))",
        );

        // Query vector points at [0, 1, 0, 0]; keyword query is "quantum".
        // FTS top-K by title-contains: {1, 2, 3, 7}
        // Vector top-K by L2 to [0,1,0,0]: {4, 5, 7, 6}
        // Fusion: 7 appears in BOTH lists → should be top-ranked.
        // Compute per-row scores via scalar subqueries; RRF handles
        // NULL naturally so rows absent from either ranker score lower.
        final r = await db.execute(
          "WITH fts AS ("
          "  SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rk "
          "  FROM docs WHERE title LIKE '%quantum%' "
          "  ORDER BY id LIMIT 100"
          "), vec AS ("
          "  SELECT id, ROW_NUMBER() OVER "
          "    (ORDER BY VEC_L2(embedding, VEC('[0,1,0,0]')) ASC) AS rk "
          "  FROM docs "
          "  ORDER BY VEC_L2(embedding, VEC('[0,1,0,0]')) ASC LIMIT 4"
          ") "
          "SELECT d.id, "
          "       RRF("
          "         (SELECT rk FROM fts WHERE fts.id = d.id), "
          "         (SELECT rk FROM vec WHERE vec.id = d.id) "
          "       ) AS score "
          "FROM docs d "
          "ORDER BY score DESC LIMIT 3",
        );
        final ids = r.rows.map((row) => row[0] as int).toList();
        expect(ids.first, 7,
            reason: 'row 7 is in BOTH rankings and should win RRF');
        expect(ids, contains(7));
      } finally {
        await db.close();
      }
    });
  });
}
