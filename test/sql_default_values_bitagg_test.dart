/// SQL parity batch: INSERT...DEFAULT VALUES + BIT_AND/BIT_OR/BIT_XOR
/// aggregates.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('INSERT ... DEFAULT VALUES', () {
    test('inserts a single row with column defaults / autoincrement', () async {
      final db = await Database.open();
      try {
        await db.execute("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,"
            " name TEXT DEFAULT 'anon', age INTEGER DEFAULT 0)");
        await db.execute('INSERT INTO t DEFAULT VALUES');
        final r = await db.execute('SELECT id, name, age FROM t ORDER BY id');
        expect(r.rows, [
          [1, 'anon', 0]
        ]);
      } finally {
        await db.close();
      }
    });

    test('respects last_insert_rowid()', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, x INT)');
        await db.execute('INSERT INTO t DEFAULT VALUES');
        await db.execute('INSERT INTO t DEFAULT VALUES');
        final r = await db.execute('SELECT last_insert_rowid()');
        expect((r.rows.first.first as num).toInt(), 2);
      } finally {
        await db.close();
      }
    });
  });

  group('BIT_AND / BIT_OR / BIT_XOR aggregates', () {
    test('basic semantics', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        await db.execute('INSERT INTO t VALUES (12), (10), (6)');
        // 12 & 10 & 6 = 0
        // 12 | 10 | 6 = 14
        // 12 ^ 10 ^ 6 = 0
        final r =
            await db.execute('SELECT bit_and(x), bit_or(x), bit_xor(x) FROM t');
        expect(r.rows.first, [0, 14, 0]);
      } finally {
        await db.close();
      }
    });

    test('skips NULL inputs', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        await db.execute('INSERT INTO t VALUES (5), (NULL), (3)');
        final r =
            await db.execute('SELECT bit_and(x), bit_or(x), bit_xor(x) FROM t');
        expect(r.rows.first, [1, 7, 6]);
      } finally {
        await db.close();
      }
    });

    test('all-NULL group returns NULL', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        await db.execute('INSERT INTO t VALUES (NULL), (NULL)');
        final r =
            await db.execute('SELECT bit_and(x), bit_or(x), bit_xor(x) FROM t');
        expect(r.rows.first, [null, null, null]);
      } finally {
        await db.close();
      }
    });

    test('GROUP BY', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(g INT, x INT)');
        await db.execute('INSERT INTO t VALUES (1, 5), (1, 6), (2, 1), (2, 2)');
        final r = await db
            .execute('SELECT g, bit_or(x) FROM t GROUP BY g ORDER BY g');
        expect(r.rows, [
          [1, 7],
          [2, 3],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
