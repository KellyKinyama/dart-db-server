/// Direct unit tests for the FTS5 query parser/evaluator and the
/// `MATCH` operator wired through the SQL engine.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('tokenizeFts', () {
    test('splits on punctuation and lowercases', () {
      expect(tokenizeFts("Hello, World!"), ['hello', 'world']);
      expect(tokenizeFts("foo-bar_baz 42"), ['foo', 'bar_baz', '42']);
      expect(tokenizeFts(''), const <String>[]);
    });
  });

  group('fts5Match query language', () {
    test('single term, case-insensitive', () {
      expect(fts5Match('Hello World', 'world'), isTrue);
      expect(fts5Match('Hello World', 'WORLD'), isTrue);
      expect(fts5Match('Hello World', 'galaxy'), isFalse);
    });

    test('implicit AND', () {
      expect(fts5Match('the quick brown fox', 'quick brown'), isTrue);
      expect(fts5Match('the quick fox', 'quick brown'), isFalse);
    });

    test('explicit AND keyword behaves like space', () {
      expect(fts5Match('alpha beta gamma', 'alpha AND gamma'), isTrue);
      expect(fts5Match('alpha gamma', 'alpha AND beta'), isFalse);
    });

    test('OR keyword', () {
      expect(fts5Match('alpha gamma', 'beta OR gamma'), isTrue);
      expect(fts5Match('alpha delta', 'beta OR gamma'), isFalse);
    });

    test('NOT keyword and dash form', () {
      expect(fts5Match('alpha beta', 'alpha NOT gamma'), isTrue);
      expect(fts5Match('alpha gamma', 'alpha NOT gamma'), isFalse);
      expect(fts5Match('alpha beta', 'alpha -gamma'), isTrue);
      expect(fts5Match('alpha gamma', 'alpha -gamma'), isFalse);
    });

    test('phrase requires adjacent tokens in order', () {
      expect(fts5Match('the quick brown fox', '"quick brown"'), isTrue);
      // Same tokens but not adjacent in order.
      expect(fts5Match('quick fast brown fox', '"quick brown"'), isFalse);
      expect(fts5Match('brown quick fox', '"quick brown"'), isFalse);
    });

    test('prefix matches any token starting with given letters', () {
      expect(fts5Match('database administrator', 'data*'), isTrue);
      expect(fts5Match('database administrator', 'admin*'), isTrue);
      expect(fts5Match('database administrator', 'foo*'), isFalse);
    });

    test('parentheses group OR before AND', () {
      // Without parens: alpha AND (beta OR gamma) by precedence anyway,
      // but verify explicit grouping.
      expect(
          fts5Match('alpha gamma delta', '(beta OR gamma) AND alpha'), isTrue);
      expect(fts5Match('alpha delta', '(beta OR gamma) AND alpha'), isFalse);
    });

    test('empty query matches anything', () {
      expect(fts5Match('whatever', ''), isTrue);
      expect(fts5Match('whatever', '   '), isTrue);
    });
  });

  group('MATCH operator end-to-end on fts5 virtual table', () {
    test('phrase MATCH on fts5 virtual table', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES "
            "('the quick brown fox'),"
            "('quick fast brown fox'),"
            "('brown quick fox')");
        final r = await db
            .execute('SELECT body FROM docs WHERE body MATCH \'"quick brown"\' '
                'ORDER BY body');
        expect(r.rows, [
          ['the quick brown fox'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('prefix MATCH on fts5 virtual table', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES "
            "('hello world'),"
            "('helping hands'),"
            "('goodbye')");
        final r = await db.execute(
            "SELECT body FROM docs WHERE body MATCH 'hel*' ORDER BY body");
        expect(r.rows.length, 2);
        expect(r.rows.map((e) => e.first).toSet(),
            {'hello world', 'helping hands'});
      } finally {
        await db.close();
      }
    });

    test('OR MATCH on fts5 virtual table', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES "
            "('apple'),"
            "('banana'),"
            "('cherry')");
        final r = await db
            .execute("SELECT body FROM docs WHERE body MATCH 'apple OR cherry' "
                'ORDER BY body');
        expect(r.rows, [
          ['apple'],
          ['cherry'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('NOT MATCH on fts5 virtual table', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
        await db.execute("INSERT INTO docs VALUES "
            "('alpha gamma'),"
            "('alpha beta'),"
            "('only gamma')");
        final r = await db
            .execute("SELECT body FROM docs WHERE body MATCH 'alpha NOT gamma' "
                'ORDER BY body');
        expect(r.rows, [
          ['alpha beta'],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
