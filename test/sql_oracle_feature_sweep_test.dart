/// Oracle feature-sweep gaps closed in the round-40 sweep: ROUND(date, fmt),
/// TO_CHAR hex format, JSON_OBJECT KEY/VALUE syntax, REMAINDER, STATS_MODE.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('ROUND(date, fmt) applies the date rounding model', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(ROUND(DATE '2024-07-20','MONTH'),'YYYY-MM-DD')"),
          '2024-08-01');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(ROUND(DATE '2024-07-10','MONTH'),'YYYY-MM-DD')"),
          '2024-07-01');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(ROUND(DATE '2024-09-15','YYYY'),'YYYY-MM-DD')"),
          '2025-01-01');
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR(number, hex fmt) emits uppercase hex', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(255,'FMXXX')"), 'FF');
    } finally {
      await db.close();
    }
  });

  test('JSON_OBJECT with KEY ... VALUE syntax', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT JSON_OBJECT('k' VALUE 1)"), '{"k":1}');
      expect(await scalar(db, "SELECT JSON_OBJECT(KEY 'a' VALUE 1, 'b' VALUE 2)"),
          '{"a":1,"b":2}');
    } finally {
      await db.close();
    }
  });

  test('REMAINDER rounds the quotient (unlike MOD)', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT REMAINDER(17, 6)'), -1);
      expect(await scalar(db, 'SELECT MOD(17, 6)'), 5);
    } finally {
      await db.close();
    }
  });

  test('STATS_MODE returns the most frequent value', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (d NUMBER)');
      await db.execute('INSERT INTO t VALUES (50), (50), (60), (90)');
      expect(await scalar(db, 'SELECT STATS_MODE(d) FROM t'), 50);
    } finally {
      await db.close();
    }
  });
}
