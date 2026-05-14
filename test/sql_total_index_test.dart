/// Phase-2.3 regression: bare `TOTAL(col)` (SQLite extension — never
/// returns NULL) is served entirely from the index — same math as
/// SUM but always REAL and 0.0 on empty.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('TOTAL(col) on indexed col returns REAL', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT TOTAL(v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(15.0, 1e-9));
      expect(r.columns, ['total(v)']);
    } finally {
      await db.close();
    }
  });

  test('TOTAL on empty table returns 0.0 (NOT NULL)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      final r = await db.execute('SELECT TOTAL(v) FROM t');
      expect(r.rows.first.first, isNotNull);
      expect((r.rows.first.first as num).toDouble(), closeTo(0.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('TOTAL ignores NULLs', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [4, null, 6, null, 10]) {
        await db.execute(
            'INSERT INTO t VALUES (${id++}, ${v ?? 'NULL'})');
      }
      final r = await db.execute('SELECT TOTAL(v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(20.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('TOTAL composes with SUM/AVG/MIN/MAX/COUNT in one bare SELECT',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute(
          'SELECT MIN(v), MAX(v), SUM(v), TOTAL(v), AVG(v), COUNT(*) FROM t');
      final row = r.rows.first;
      expect(row[0], 1);
      expect(row[1], 4);
      expect(row[2], 10);
      expect((row[3] as num).toDouble(), closeTo(10.0, 1e-9));
      expect((row[4] as num).toDouble(), closeTo(2.5, 1e-9));
      expect(row[5], 4);
    } finally {
      await db.close();
    }
  });

  test('TOTAL on non-indexed col falls through to generic aggregate',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT TOTAL(v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(10.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('TOTAL on empty non-indexed col still returns 0.0 (generic path)',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      final r = await db.execute('SELECT TOTAL(v) FROM t');
      expect((r.rows.first.first as num).toDouble(), closeTo(0.0, 1e-9));
    } finally {
      await db.close();
    }
  });
}
