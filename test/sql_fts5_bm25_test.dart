/// Unit tests for the FTS5 ranking functions: `fts5TermFrequency`,
/// `fts5Bm25`, and their SQL bindings `FTS5_TF(text, query)` /
/// `BM25(text, query[, k1[, b]])`.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('fts5TermFrequency (pure Dart)', () {
    test('counts raw occurrences of a single term', () {
      expect(fts5TermFrequency('the cat sat on the mat', 'the'), 2);
      expect(fts5TermFrequency('the cat sat on the mat', 'mat'), 1);
      expect(fts5TermFrequency('the cat sat on the mat', 'dog'), 0);
    });

    test('sums TFs across AND terms', () {
      expect(fts5TermFrequency('alpha alpha beta', 'alpha beta'), 3);
    });

    test('non-match returns 0 even when one term appears', () {
      // AND semantics: missing term short-circuits to 0.
      expect(fts5TermFrequency('alpha alpha', 'alpha beta'), 0);
    });

    test('OR adds contributions from each branch', () {
      expect(fts5TermFrequency('alpha gamma', 'alpha OR beta'), 1);
      expect(fts5TermFrequency('alpha beta', 'alpha OR beta'), 2);
    });

    test('phrase counts non-overlapping matches', () {
      expect(fts5TermFrequency('a b a b a b', '"a b"'), 3);
      // Overlapping should not double-count.
      expect(fts5TermFrequency('a a a', '"a a"'), 1);
    });

    test('prefix counts every matching token', () {
      expect(fts5TermFrequency('data database datum point', 'dat*'), 3);
    });

    test('empty query scores 0', () {
      expect(fts5TermFrequency('anything', ''), 0);
    });
  });

  group('fts5Bm25 (pure Dart)', () {
    test('non-match scores exactly 0', () {
      expect(fts5Bm25('alpha beta', 'gamma'), 0);
    });

    test('match score is positive and saturates with tf', () {
      final s1 = fts5Bm25('alpha', 'alpha');
      final s2 = fts5Bm25('alpha alpha', 'alpha');
      final s10 = fts5Bm25('alpha ' * 10, 'alpha');
      expect(s1, greaterThan(0));
      expect(s2, greaterThan(s1));
      expect(s10, greaterThan(s2));
      // Hard upper bound: tf*(k1+1)/(tf+k1) < k1+1.
      expect(s10, lessThan(1.2 + 1));
    });

    test('k1 parameter controls saturation', () {
      final tight = fts5Bm25('alpha alpha alpha', 'alpha', k1: 0.1);
      final loose = fts5Bm25('alpha alpha alpha', 'alpha', k1: 5);
      // Higher k1 -> less saturation -> larger spread between low and high tf.
      expect(loose, greaterThan(tight));
    });
  });

  group('SQL BM25 / FTS5_TF functions', () {
    test('ORDER BY bm25(body, query) DESC ranks more relevant docs first',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES "
            "('apple'),"
            "('apple apple apple'),"
            "('banana'),"
            "('apple apple')");
        final r = await db.execute('SELECT body FROM docs '
            "WHERE body MATCH 'apple' "
            'ORDER BY bm25(body, \'apple\') DESC');
        expect(r.rows.map((e) => e.first).toList(), [
          'apple apple apple',
          'apple apple',
          'apple',
        ]);
      } finally {
        await db.close();
      }
    });

    test('FTS5_TF returns the raw match count', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES "
            "('alpha beta alpha'),"
            "('gamma delta')");
        final r = await db.execute(
            'SELECT fts5_tf(body, \'alpha\') AS tf FROM docs ORDER BY body');
        // 'alpha beta alpha' sorts before 'gamma delta'.
        expect(r.rows.map((e) => (e.first as num).toInt()).toList(), [2, 0]);
      } finally {
        await db.close();
      }
    });

    test('BM25 accepts custom k1/b arguments', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES ('alpha alpha alpha')");
        final r =
            await db.execute("SELECT bm25(body, 'alpha', 5.0, 0.0) FROM docs");
        // Same value as the pure-Dart call.
        final expected = fts5Bm25('alpha alpha alpha', 'alpha', k1: 5.0, b: 0);
        expect(
            (r.rows.single.first as num).toDouble(), closeTo(expected, 1e-9));
      } finally {
        await db.close();
      }
    });
  });
}
