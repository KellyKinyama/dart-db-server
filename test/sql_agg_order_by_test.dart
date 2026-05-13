/// Aggregate ORDER BY (SQL standard / SQLite ≥ 3.44) +
/// CHAR_LENGTH / CHARACTER_LENGTH aliases.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('CHAR_LENGTH and CHARACTER_LENGTH alias LENGTH', () async {
    final db = await Database.open();
    try {
      final r = await db.execute(
          "SELECT CHAR_LENGTH('abc'), CHARACTER_LENGTH('hello'),"
          " CHAR_LENGTH(NULL)");
      expect(r.rows.first, [3, 5, null]);
    } finally {
      await db.close();
    }
  });

  test('GROUP_CONCAT with ORDER BY sorts contributions', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(name TEXT, n INT)');
      await db.execute(
          "INSERT INTO t VALUES ('c',3),('a',1),('b',2)");
      final r = await db.execute(
          "SELECT GROUP_CONCAT(name, ',' ORDER BY n) FROM t");
      expect(r.rows.first[0], 'a,b,c');
      final r2 = await db.execute(
          "SELECT GROUP_CONCAT(name, ',' ORDER BY n DESC) FROM t");
      expect(r2.rows.first[0], 'c,b,a');
    } finally {
      await db.close();
    }
  });

  test('JSON_GROUP_ARRAY with ORDER BY', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(n INT)');
      await db.execute('INSERT INTO t VALUES(3),(1),(2)');
      final r = await db.execute(
          'SELECT JSON_GROUP_ARRAY(n ORDER BY n) FROM t');
      expect(r.rows.first[0], '[1,2,3]');
    } finally {
      await db.close();
    }
  });
}
