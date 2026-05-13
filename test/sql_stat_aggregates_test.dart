/// ANY_VALUE / MEDIAN / STDDEV / VARIANCE aggregates.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('ANY_VALUE returns first non-null', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(x INT)');
      await db.execute('INSERT INTO t VALUES(NULL),(7),(9)');
      final r = await db.execute('SELECT ANY_VALUE(x) FROM t');
      expect(r.rows.first[0], 7);
    } finally {
      await db.close();
    }
  });

  test('MEDIAN of odd and even counts', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(x REAL)');
      await db.execute('INSERT INTO t VALUES(1),(2),(3),(4),(100)');
      final r = await db.execute('SELECT MEDIAN(x) FROM t');
      expect((r.rows.first[0] as num).toDouble(), 3);

      await db.execute('DELETE FROM t WHERE x=100');
      final r2 = await db.execute('SELECT MEDIAN(x) FROM t');
      expect((r2.rows.first[0] as num).toDouble(), 2.5);
    } finally {
      await db.close();
    }
  });

  test('STDDEV_POP and VAR_POP match definition', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(x REAL)');
      await db.execute('INSERT INTO t VALUES(2),(4),(4),(4),(5),(5),(7),(9)');
      final r = await db.execute('SELECT STDDEV_POP(x), VAR_POP(x) FROM t');
      // mean=5, sumSq=32, var=4, stddev=2.
      expect((r.rows.first[0] as num).toDouble(), closeTo(2.0, 1e-9));
      expect((r.rows.first[1] as num).toDouble(), closeTo(4.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('STDDEV_SAMP uses N-1 denominator', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(x REAL)');
      await db.execute('INSERT INTO t VALUES(1),(2),(3),(4),(5)');
      final r = await db.execute('SELECT STDDEV_SAMP(x) FROM t');
      expect((r.rows.first[0] as num).toDouble(),
          closeTo(math.sqrt(2.5), 1e-9));
    } finally {
      await db.close();
    }
  });
}
