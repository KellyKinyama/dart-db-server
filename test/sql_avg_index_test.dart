/// Phase-2.2 regression: bare `AVG(col)` is served entirely from the
/// index — `Σ(key * postingLen) / Σ(postingLen)`. SQLite returns AVG
/// as REAL whenever there are any rows, NULL on an empty table.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('AVG(col) on indexed col is index-only and returns REAL', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT AVG(v) FROM t');
      expect(r.rows.first.first, closeTo(5.5, 1e-9));
      expect(r.columns, ['avg(v)']);
    } finally {
      await db.close();
    }
  });

  test('AVG handles duplicates correctly', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      // 4x 10 + 1x 5 = 45 / 5 = 9
      for (final v in [10, 10, 5, 10, 10]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT AVG(v) FROM t');
      expect(r.rows.first.first, closeTo(9.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('AVG ignores NULLs', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [4, null, 6, null]) {
        await db.execute(
            'INSERT INTO t VALUES (${id++}, ${v ?? 'NULL'})');
      }
      final r = await db.execute('SELECT AVG(v) FROM t');
      expect(r.rows.first.first, closeTo(5.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('AVG on empty table returns NULL', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT AVG(v) FROM t');
      expect(r.rows, [
        [null],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM, AVG, MIN, MAX, COUNT(*) all in one bare SELECT', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute(
          'SELECT MIN(v), MAX(v), SUM(v), AVG(v), COUNT(*) FROM t');
      final row = r.rows.first;
      expect(row[0], 1);
      expect(row[1], 4);
      expect(row[2], 10);
      expect((row[3] as num).toDouble(), closeTo(2.5, 1e-9));
      expect(row[4], 4);
    } finally {
      await db.close();
    }
  });

  test('AVG on non-indexed col falls through to generic aggregate',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT AVG(v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(2.5, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('AVG(DISTINCT) is not rewritten', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      // DISTINCT values: 1, 2, 3 -> avg 2.0
      for (final v in [1, 1, 2, 2, 3, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT AVG(DISTINCT v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(2.0, 1e-9));
    } finally {
      await db.close();
    }
  });
}
