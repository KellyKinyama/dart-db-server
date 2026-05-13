/// LIMIT/OFFSET on UPDATE and DELETE (SQLITE_ENABLE_UPDATE_DELETE_LIMIT).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('DELETE ... LIMIT k removes only k rows', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n INT)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t(id,n) VALUES($i,$i)');
      }
      final r = await db.execute('DELETE FROM t LIMIT 2');
      expect(r.affected, 2);
      final c = await db.execute('SELECT count(*) FROM t');
      expect(c.rows.first[0], 3);
    } finally {
      await db.close();
    }
  });

  test('DELETE ... LIMIT with OFFSET skips first', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t(id) VALUES($i)');
      }
      final r = await db.execute('DELETE FROM t LIMIT 2 OFFSET 1');
      expect(r.affected, 2);
      final ids = await db.execute('SELECT id FROM t ORDER BY id');
      expect(ids.rows.map((r) => r[0]).toList(), [1, 4, 5]);
    } finally {
      await db.close();
    }
  });

  test('UPDATE ... LIMIT updates only k rows', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n INT)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t(id,n) VALUES($i,0)');
      }
      final r = await db.execute('UPDATE t SET n=99 LIMIT 2');
      expect(r.affected, 2);
      final c = await db.execute('SELECT count(*) FROM t WHERE n=99');
      expect(c.rows.first[0], 2);
    } finally {
      await db.close();
    }
  });
}
