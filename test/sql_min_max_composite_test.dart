/// Phase-3.0 regression: bare `MIN(col)` / `MAX(col)` where `col` is
/// the LEADING column of a composite (multi-col) index — answer is
/// `firstKey().parts[0]` / `lastKey().parts[0]` from the SplayTreeMap.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
    await db.execute('CREATE INDEX i_ab ON t(a, b)');
    var id = 1;
    for (final pair in [
      [3, 30],
      [1, 10],
      [4, 40],
      [1, 11],
      [5, 50],
      [9, 90],
      [2, 20],
      [6, 60],
    ]) {
      await db.execute(
          'INSERT INTO t VALUES (${id++}, ${pair[0]}, ${pair[1]})');
    }
    return db;
  }

  test('MIN(a) on composite index leading col', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT MIN(a) FROM t');
      expect(r.rows, [
        [1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MAX(a) on composite index leading col', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT MAX(a) FROM t');
      expect(r.rows, [
        [9],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN(a), MAX(a), COUNT(*) combo on composite index', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT MIN(a), MAX(a), COUNT(*) FROM t');
      expect(r.rows, [
        [1, 9, 8],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN(b) on TRAILING composite col bails (only single-col index '
      'on b would qualify)', () async {
    final db = await seed();
    try {
      // No single-col index on b, no leading-position composite — the
      // generic aggregate path still produces the correct answer.
      final r = await db.execute('SELECT MIN(b) FROM t');
      expect(r.rows, [
        [10],
      ]);
    } finally {
      await db.close();
    }
  });

  test('SUM(a) on composite leading col bails to generic path', () async {
    final db = await seed();
    try {
      // Composite SUM would over-count by the trailing-col fan-out IF
      // we used posting lengths naively; we deliberately bail.
      final r = await db.execute('SELECT SUM(a) FROM t');
      expect(r.rows.first.first, 31); // 3+1+4+1+5+9+2+6
    } finally {
      await db.close();
    }
  });

  test('MIN(a) on single-col index still works (regression)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER)');
      await db.execute('CREATE INDEX i_a ON t(a)');
      var id = 1;
      for (final v in [3, 1, 4, 1, 5, 9, 2, 6]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT MIN(a), MAX(a) FROM t');
      expect(r.rows, [
        [1, 9],
      ]);
    } finally {
      await db.close();
    }
  });

  test('MIN(a) on empty composite-indexed table → NULL', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_ab ON t(a, b)');
      final r = await db.execute('SELECT MIN(a), MAX(a) FROM t');
      expect(r.rows, [
        [null, null],
      ]);
    } finally {
      await db.close();
    }
  });
}
