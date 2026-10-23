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

  test('TO_CHAR(date) week / Julian / day-of-year elements', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','WW')"), '29');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','J')"),
          '2460512');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-01-01','DDD')"), '001');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','DDD')"), '202');
    } finally {
      await db.close();
    }
  });

  test('JSON_EXISTS predicate', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db, "SELECT CASE WHEN JSON_EXISTS('{\"a\":1}', '\$.a') "
              'THEN 1 ELSE 0 END'),
          1);
      expect(
          await scalar(db, "SELECT CASE WHEN JSON_EXISTS('{\"a\":1}', '\$.b') "
              'THEN 1 ELSE 0 END'),
          0);
    } finally {
      await db.close();
    }
  });

  test('JSON_VALUE with a RETURNING clause', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db, "SELECT JSON_VALUE('{\"n\":12.5}', '\$.n' RETURNING NUMBER)"),
          12.5);
    } finally {
      await db.close();
    }
  });

  test('VSIZE reports the internal storage size', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT VSIZE(123)'), 3);
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR number Roman numeral + date CC/quoted text', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(2024,'FMRN')"), 'MMXXIV');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','CC')"), '21');
      expect(
          await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','YYYY\"x\"MM')"),
          '2024x07');
    } finally {
      await db.close();
    }
  });

  test('REGEXP_SUBSTR subexpression argument', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT REGEXP_SUBSTR('abc123def','([a-z]+)([0-9]+)',1,1,NULL,2)"),
          '123');
    } finally {
      await db.close();
    }
  });

  test('LISTAGG default separator is empty', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (s VARCHAR2(10))');
      await db.execute("INSERT INTO t VALUES ('a'), ('b'), ('c')");
      expect(
          await scalar(db, 'SELECT LISTAGG(s) WITHIN GROUP (ORDER BY s) FROM t'),
          'abc');
    } finally {
      await db.close();
    }
  });

  test('LEAD IGNORE NULLS skips NULL rows', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER, v NUMBER)');
      await db.execute('INSERT INTO t VALUES (1, 10), (2, NULL), (3, 30)');
      final r = await db.execute(
          'SELECT LEAD(v) IGNORE NULLS OVER (ORDER BY id) FROM t '
          'FETCH FIRST 1 ROW ONLY');
      expect(r.rows.first.first, 30);
    } finally {
      await db.close();
    }
  });

  test('CAST enforces NUMBER scale and VARCHAR2 length', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT CAST(123.456 AS NUMBER(5,1))'), 123.5);
      expect(await scalar(db, "SELECT CAST('abc' AS VARCHAR2(2))"), 'ab');
    } finally {
      await db.close();
    }
  });

  test('APPROX_COUNT_DISTINCT counts distinct values', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (d NUMBER)');
      await db.execute('INSERT INTO t VALUES (10), (10), (20), (30)');
      expect(await scalar(db, 'SELECT APPROX_COUNT_DISTINCT(d) FROM t'), 3);
    } finally {
      await db.close();
    }
  });
}
