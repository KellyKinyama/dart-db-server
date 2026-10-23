/// Oracle CTE gaps closed in the round-26 sweep: a recursive WITH without the
/// SQLite-style RECURSIVE keyword (Oracle auto-detects recursion), and a WITH
/// clause nested inside a parenthesized subquery / derived table.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('recursive WITH is auto-detected without the RECURSIVE keyword',
      () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE d (x NUMBER)');
      await db.execute('INSERT INTO d VALUES (1)');
      expect(
        await scalar(
            db,
            'WITH r(n) AS (SELECT 1 FROM d UNION ALL '
            'SELECT n + 1 FROM r WHERE n < 5) SELECT COUNT(*) FROM r'),
        5,
      );
    } finally {
      await db.close();
    }
  });

  test('explicit WITH RECURSIVE still works', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE d (x NUMBER)');
      await db.execute('INSERT INTO d VALUES (1)');
      expect(
        await scalar(
            db,
            'WITH RECURSIVE r(n) AS (SELECT 1 FROM d UNION ALL '
            'SELECT n + 1 FROM r WHERE n < 3) SELECT COUNT(*) FROM r'),
        3,
      );
    } finally {
      await db.close();
    }
  });

  test('a WITH clause inside a parenthesized subquery parses and runs',
      () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE d (x NUMBER)');
      await db.execute('INSERT INTO d VALUES (1)');
      expect(
        await scalar(
            db,
            'SELECT COUNT(*) FROM '
            '(WITH x AS (SELECT 1 n FROM d) SELECT n FROM x)'),
        1,
      );
    } finally {
      await db.close();
    }
  });
}
