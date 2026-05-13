/// UPDATE ... FROM other (SQLite >= 3.33).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('UPDATE ... FROM', () {
    test('joins target with other table to update values', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INT, x INT)');
        await db
            .execute('INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)');
        await db.execute('CREATE TABLE patch(id INT, val INT)');
        await db
            .execute('INSERT INTO patch VALUES (1, 100), (3, 300)');
        await db.execute(
            'UPDATE t SET x = patch.val FROM patch WHERE t.id = patch.id');
        final r = await db.execute('SELECT id, x FROM t ORDER BY id');
        expect(r.rows, [
          [1, 100],
          [2, 20],
          [3, 300],
        ]);
      } finally {
        await db.close();
      }
    });

    test('FROM with alias', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INT, x INT)');
        await db.execute('INSERT INTO t VALUES (1, 0)');
        await db.execute('CREATE TABLE p(id INT, v INT)');
        await db.execute('INSERT INTO p VALUES (1, 7)');
        await db.execute(
            'UPDATE t SET x = pp.v FROM p AS pp WHERE t.id = pp.id');
        final r = await db.execute('SELECT x FROM t');
        expect(r.rows.first.first, 7);
      } finally {
        await db.close();
      }
    });

    test('rows without a join match are left untouched', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INT, x INT)');
        await db.execute('INSERT INTO t VALUES (1, 1), (2, 2)');
        await db.execute('CREATE TABLE p(id INT, v INT)');
        await db.execute('INSERT INTO p VALUES (1, 99)');
        await db.execute(
            'UPDATE t SET x = p.v FROM p WHERE t.id = p.id');
        final r = await db.execute('SELECT id, x FROM t ORDER BY id');
        expect(r.rows, [
          [1, 99],
          [2, 2],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
