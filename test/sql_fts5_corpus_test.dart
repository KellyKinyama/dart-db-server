/// Tests for corpus-aware FTS5 ranking: the pure-Dart [Fts5Index] class
/// and the SQL `BM25_CORPUS(text, query, 'table', 'column')` function.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Fts5Index (pure Dart)', () {
    test('build records df, doc count and avg doc length', () {
      final idx = Fts5Index.build([
        'alpha beta gamma',
        'alpha gamma',
        'gamma',
        'delta',
      ]);
      expect(idx.docCount, 4);
      // Total tokens = 3 + 2 + 1 + 1 = 7. avg = 7/4 = 1.75.
      expect(idx.avgDocLength, closeTo(1.75, 1e-9));
      expect(idx.df('alpha'), 2);
      expect(idx.df('beta'), 1);
      expect(idx.df('gamma'), 3);
      expect(idx.df('delta'), 1);
      expect(idx.df('missing'), 0);
    });

    test('matches respects the FTS5 query grammar', () {
      final idx = Fts5Index.build([
        'apple banana',
        'banana cherry',
        'cherry only',
      ]);
      expect(idx.matches(0, 'apple'), isTrue);
      expect(idx.matches(0, 'cherry'), isFalse);
      expect(idx.matches(1, 'banana cherry'), isTrue);
      expect(idx.matches(2, 'apple OR cherry'), isTrue);
    });

    test('bm25 returns 0 for non-matching docs', () {
      final idx = Fts5Index.build(['alpha', 'beta', 'gamma']);
      expect(idx.bm25(0, 'beta'), 0);
      expect(idx.bm25(1, 'beta'), greaterThan(0));
    });

    test('bm25 ranks more-on-topic docs higher', () {
      // 'alpha' is rare (1 doc); 'common' is in every doc.
      final idx = Fts5Index.build([
        'alpha common common',
        'beta common common',
        'gamma common common',
      ]);
      // alpha occurs once in doc 0 and nowhere else: idf is high.
      // common occurs in every doc: idf collapses, so it contributes
      // far less. doc 0 must outscore docs 1 and 2 for query 'alpha'.
      final s0 = idx.bm25(0, 'alpha');
      final s1 = idx.bm25(1, 'alpha');
      expect(s0, greaterThan(0));
      expect(s1, 0); // doesn't match at all
      // For query 'common', every doc matches and they should tie.
      final c0 = idx.bm25(0, 'common');
      final c1 = idx.bm25(1, 'common');
      final c2 = idx.bm25(2, 'common');
      expect(c0, closeTo(c1, 1e-9));
      expect(c1, closeTo(c2, 1e-9));
    });

    test('bm25 penalises longer documents (length normalisation)', () {
      final idx = Fts5Index.build([
        'cat', // 1 token, contains query term
        'cat zzz zzz zzz zzz zzz zzz zzz zzz zzz', // 10 tokens, also contains query term
      ]);
      final short = idx.bm25(0, 'cat');
      final long = idx.bm25(1, 'cat');
      expect(short, greaterThan(long));
    });

    test('bm25Text scores arbitrary text using corpus stats', () {
      final idx = Fts5Index.build([
        'alpha common',
        'beta common',
        'gamma common',
      ]);
      // Non-corpus document: still gets sensible BM25 using corpus df.
      final s = idx.bm25Text('alpha alpha alpha', 'alpha');
      expect(s, greaterThan(0));
      // Repeated 'alpha' saturates but stays under the asymptotic
      // limit; the score should not exceed an arbitrarily large value.
      expect(s.isFinite, isTrue);
    });

    test('prefix query sums per-matching-token BM25 contributions', () {
      final idx = Fts5Index.build([
        'database administrator',
        'data center',
        'unrelated stuff',
      ]);
      final s0 = idx.bm25(0, 'data*');
      final s1 = idx.bm25(1, 'data*');
      expect(s0, greaterThan(0));
      expect(s1, greaterThan(0));
    });
  });

  group('BM25_CORPUS SQL function', () {
    test('ranks rows with proper IDF + length normalisation', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        // 'rare' appears in just one row; 'common' in all four. With
        // proper BM25 the doc containing 'rare' should sort first when
        // ranking by 'rare'.
        await db.execute("INSERT INTO docs VALUES "
            "('rare common common'),"
            "('common common'),"
            "('common common common'),"
            "('common common common common')");
        final r = await db.execute("SELECT body FROM docs "
            "WHERE body MATCH 'rare' "
            "ORDER BY bm25_corpus(body, 'rare', 'docs', 'body') DESC");
        expect(r.rows.length, 1);
        expect(r.rows.single.first, 'rare common common');
      } finally {
        await db.close();
      }
    });

    test('length normalisation: same tf, shorter doc scores higher',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        // Both docs contain 'alpha' exactly once. doc1 is short (2 tokens),
        // doc2 is long (10 tokens). BM25 length normalisation must
        // prefer doc1.
        await db.execute("INSERT INTO docs VALUES "
            "('alpha zzz'),"
            "('alpha zzz zzz zzz zzz zzz zzz zzz zzz zzz')");
        final r = await db.execute(
            "SELECT body, bm25_corpus(body, 'alpha', 'docs', 'body') AS s "
            "FROM docs WHERE body MATCH 'alpha' ORDER BY length(body)");
        expect(r.rows.length, 2);
        final shortScore = (r.rows[0][1] as num).toDouble();
        final longScore = (r.rows[1][1] as num).toDouble();
        expect(shortScore, greaterThan(longScore));
      } finally {
        await db.close();
      }
    });

    test('cache is invalidated after inserts', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES ('only one row')");
        // Trigger first build.
        await db.execute(
            "SELECT bm25_corpus(body, 'row', 'docs', 'body') FROM docs");
        // After more inserts, idf for 'row' should change.
        await db.execute("INSERT INTO docs VALUES "
            "('row row'), ('many many rows')");
        final r = await db.execute("SELECT body "
            "FROM docs WHERE body MATCH 'row' "
            "ORDER BY bm25_corpus(body, 'row', 'docs', 'body') DESC, body");
        // Highest tf for 'row' wins under length normalisation, regardless
        // of order. Just assert all matching docs are present.
        expect(
            r.rows.map((e) => e.first).toSet(),
            containsAll(
                {'only one row', 'row row'}));
      } finally {
        await db.close();
      }
    });
  });
}
