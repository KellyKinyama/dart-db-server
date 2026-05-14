/// Phase-2.1 regression: bare `SUM(col)` (alongside MIN/MAX/COUNT(*))
/// is served entirely from the index — sum of `key * postingLen`.
/// NULLs already excluded (indexes don't store them). Empty table
/// returns NULL.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('SUM(col) on indexed col is index-only', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, 2, 3, 4, 5]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT SUM(v) FROM t');
      expect(r.rows, [
        [15],
      ]);
      expect(r.columns, ['sum(v)']);
    } finally {
      await db.close();
    }
  });

  test('SUM with duplicates across posting lists', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      // 3x 10 + 2x 5 + 1x 7 = 30 + 10 + 7 = 47
      for (final v in [10, 5, 10, 7, 10, 5]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT SUM(v) FROM t');
      expect(r.rows, [
        [47],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM ignores NULLs (indexes never store them)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, null, 2, null, 3]) {
        await db.execute(
            'INSERT INTO t VALUES (${id++}, ${v ?? 'NULL'})');
      }
      final r = await db.execute('SELECT SUM(v) FROM t');
      expect(r.rows, [
        [6],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM on empty table returns NULL', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT SUM(v) FROM t');
      expect(r.rows, [
        [null],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM, MIN, MAX, COUNT(*) all in one bare SELECT', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute(
          'SELECT MIN(v), MAX(v), SUM(v), COUNT(*) FROM t');
      expect(r.rows, [
        [1, 10, 55, 10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM on REAL keys yields double result', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1.5, 2.5, 3.0]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT SUM(v) FROM t');
      expect(r.rows.first.first, closeTo(7.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('SUM on non-indexed col falls through to generic aggregate',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT SUM(v) FROM t');
      expect(r.rows, [
        [10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM(DISTINCT) is not rewritten', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, 1, 2, 2, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT SUM(DISTINCT v) FROM t');
      expect(r.rows, [
        [6], // 1 + 2 + 3
      ]);
    } finally {
      await db.close();
    }
  });
}
