/// Oracle date-trunc / quantified subquery / CO-schema gaps closed in the
/// round-33..34 sweeps: TRUNC(date, fmt), quantified comparisons (>= ALL/ANY),
/// LISTAGG ON OVERFLOW, UTL_RAW, and JSON_VALUE/JSON_QUERY.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('TRUNC(date, fmt) truncates to the unit', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TRUNC(TO_DATE('2021-06-15','YYYY-MM-DD'),'MM'),"
              "'YYYY-MM-DD')"),
          '2021-06-01');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TRUNC(TO_DATE('2021-06-15','YYYY-MM-DD'),'YYYY'),"
              "'YYYY-MM-DD')"),
          '2021-01-01');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TRUNC(TO_DATE('2021-06-15','YYYY-MM-DD'),'Q'),"
              "'YYYY-MM-DD')"),
          '2021-04-01');
    } finally {
      await db.close();
    }
  });

  test('quantified comparison >= ALL / <= ANY (subquery)', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (x NUMBER)');
      await db.execute('INSERT INTO t VALUES (1), (2), (3)');
      // x >= ALL -> just the max (3).
      expect(
          await scalar(
              db, 'SELECT COUNT(*) FROM t WHERE x >= ALL (SELECT x FROM t)'),
          1);
      // x <= ANY -> every row (all are <= the max).
      expect(
          await scalar(
              db, 'SELECT COUNT(*) FROM t WHERE x <= ANY (SELECT x FROM t)'),
          3);
    } finally {
      await db.close();
    }
  });

  test('LISTAGG ON OVERFLOW clause parses', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (n NUMBER)');
      await db.execute('INSERT INTO t VALUES (1), (2)');
      final r = await db.execute(
          "SELECT LISTAGG(n, ',' ON OVERFLOW TRUNCATE '...' WITH COUNT) "
          'WITHIN GROUP (ORDER BY n) FROM t');
      expect(r.rows.first.first, '1,2');
    } finally {
      await db.close();
    }
  });

  test('UTL_RAW.CAST_TO_RAW round-trips through RAWTOHEX', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT RAWTOHEX(UTL_RAW.CAST_TO_RAW('AB'))"),
          '4142');
    } finally {
      await db.close();
    }
  });

  test('JSON_VALUE / JSON_QUERY extract from JSON', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT JSON_VALUE('{\"a\":42}', '\$.a')"), 42);
      expect(await scalar(db, "SELECT JSON_QUERY('{\"a\":[1,2]}', '\$.a')"),
          '[1,2]');
    } finally {
      await db.close();
    }
  });
}
