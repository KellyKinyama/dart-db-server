/// FTS5 subset: CREATE VIRTUAL TABLE + MATCH operator on a single column.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('fts5 virtual table', () {
    test('column MATCH "term" filters by case-insensitive substring', () async {
      final db = await Database.open();
      await db.execute('CREATE VIRTUAL TABLE docs USING fts5(title, body)');
      await db.execute("INSERT INTO docs VALUES "
          "('Intro',  'hello world'),"
          "('Setup',  'install dart sdk'),"
          "('Note',   'WORLD wide web')");
      final r = await db.execute(
          "SELECT title FROM docs WHERE body MATCH 'world' ORDER BY title");
      expect(r.rows, [
        ['Intro'],
        ['Note']
      ]);
    });

    test('column MATCH "a b" is AND-of-terms', () async {
      final db = await Database.open();
      await db.execute('CREATE VIRTUAL TABLE docs USING fts5(body)');
      await db.execute("INSERT INTO docs VALUES "
          "('the quick brown fox'),"
          "('quick! Now go'),"
          "('brown chair')");
      final r = await db.execute(
          "SELECT body FROM docs WHERE body MATCH 'quick brown' ORDER BY body");
      expect(r.rows, [
        ['the quick brown fox']
      ]);
    });

    test('fts5 tokenize=... arg is parsed and ignored', () async {
      final db = await Database.open();
      // Both an option arg and a regular column arg.
      await db.execute('CREATE VIRTUAL TABLE n '
          'USING fts5(content, tokenize="unicode61")');
      await db.execute("INSERT INTO n VALUES ('hello')");
      final r = await db.execute('SELECT content FROM n');
      expect(r.rows, [
        ['hello']
      ]);
    });
  });
}
