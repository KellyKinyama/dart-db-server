/// Phase-2.6 regression: covering-scan now also handles
/// `SELECT col FROM t WHERE col <pred>` for the same predicate
/// shapes the aggregate fast path supports (= lit, BETWEEN,
/// range AND-chain, IN(lits), IS [NOT] NULL).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE INDEX i_v ON t(v)');
    var id = 1;
    for (final v in [1, null, 2, 3, null, 4, 5, 6, 7, 8, 9, 10]) {
      await db.execute(
          'INSERT INTO t VALUES (${id++}, ${v ?? 'NULL'})');
    }
    return db;
  }

  test('covering scan with WHERE col BETWEEN', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT v FROM t WHERE v BETWEEN 3 AND 7 ORDER BY v');
      expect(r.rows, [
        [3], [4], [5], [6], [7],
      ]);
    } finally {
      await db.close();
    }
  });

  test('covering scan with WHERE col >= a AND col <= b DESC', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT v FROM t WHERE v >= 4 AND v <= 8 ORDER BY v DESC');
      expect(r.rows, [
        [8], [7], [6], [5], [4],
      ]);
    } finally {
      await db.close();
    }
  });

  test('covering scan with WHERE col = lit', () async {
    final db = await seed();
    try {
      // Insert a duplicate to verify posting list is enumerated.
      await db.execute('INSERT INTO t VALUES (99, 5)');
      final r = await db.execute('SELECT v FROM t WHERE v = 5');
      expect(r.rows, [
        [5], [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('covering scan with WHERE col IN (lits) sorted ASC', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT v FROM t WHERE v IN (7, 3, 5)');
      expect(r.rows, [
        [3], [5], [7],
      ]);
    } finally {
      await db.close();
    }
  });

  test('covering scan with DISTINCT + WHERE BETWEEN', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3, 4]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db
          .execute('SELECT DISTINCT v FROM t WHERE v BETWEEN 2 AND 3');
      expect(r.rows, [
        [2], [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('covering scan with WHERE col IS NULL → empty', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT v FROM t WHERE v IS NULL');
      expect(r.rows, isEmpty);
    } finally {
      await db.close();
    }
  });

  test('covering scan with WHERE col IS NOT NULL', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v FROM t WHERE v IS NOT NULL ORDER BY v');
      expect(r.rows.map((r) => r.first).toList(),
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    } finally {
      await db.close();
    }
  });

  test('covering scan + WHERE + LIMIT/OFFSET', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v FROM t WHERE v BETWEEN 3 AND 9 ORDER BY v LIMIT 3 OFFSET 2');
      expect(r.rows, [
        [5], [6], [7],
      ]);
    } finally {
      await db.close();
    }
  });

  test('covering scan WHERE on different col bails to generic scan',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER, w INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final pair in [
        [1, 100],
        [2, 200],
        [3, 100],
      ]) {
        await db.execute(
            'INSERT INTO t VALUES (${id++}, ${pair[0]}, ${pair[1]})');
      }
      final r = await db.execute('SELECT v FROM t WHERE w = 100 ORDER BY v');
      expect(r.rows, [
        [1], [3],
      ]);
    } finally {
      await db.close();
    }
  });
}
