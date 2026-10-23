/// Oracle numeric/byte functions, TIMESTAMP intervals, PL/SQL depth and
/// TIMESTAMP WITH TIME ZONE gaps closed in the round-27..28 sweeps.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('BITAND / BIN_TO_NUM / byte string functions', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT BITAND(6, 3)'), 2);
      expect(await scalar(db, 'SELECT BIN_TO_NUM(1, 0, 1)'), 5);
      expect(await scalar(db, "SELECT LENGTHB('abc')"), 3);
      expect(await scalar(db, "SELECT SUBSTRB('abcdef', 2, 3)"), 'bcd');
      expect(await scalar(db, "SELECT INSTRB('a1b2c3', '2')"), 4);
      expect(await scalar(db, "SELECT ORA_HASH('x', 0)"), 0);
    } finally {
      await db.close();
    }
  });

  test('POWER with a fractional exponent', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT ROUND(POWER(27, 1.0/3))'), 3);
    } finally {
      await db.close();
    }
  });

  test('TIMESTAMP subtraction yields a day interval for EXTRACT', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT EXTRACT(DAY FROM (TIMESTAMP '2020-01-05 00:00:00' - "
              "TIMESTAMP '2020-01-01 00:00:00'))"),
          4);
    } finally {
      await db.close();
    }
  });

  test('TIMESTAMP WITH TIME ZONE column type parses', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (ts TIMESTAMP WITH TIME ZONE)');
      await db.execute('CREATE TABLE u (ts TIMESTAMP(6) WITH LOCAL TIME ZONE)');
    } finally {
      await db.close();
    }
  });

  test('PL/SQL CASE statement (simple and searched)', () async {
    final db = await Database.open(null);
    try {
      await db.execute('DECLARE x NUMBER := 2; BEGIN CASE x WHEN 1 THEN NULL; '
          'WHEN 2 THEN NULL; ELSE NULL; END CASE; END;');
      await db.execute('BEGIN CASE WHEN 1 = 1 THEN NULL; ELSE NULL; '
          'END CASE; END;');
    } finally {
      await db.close();
    }
  });

  test('%TYPE anchored declaration', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (n NUMBER)');
      await db.execute(
          'DECLARE v t.n%TYPE := 99; BEGIN INSERT INTO t VALUES (v); END;');
      expect(await scalar(db, 'SELECT n FROM t'), 99);
    } finally {
      await db.close();
    }
  });

  test('PL/SQL package function called without parentheses', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE d (x NUMBER)');
      await db.execute('INSERT INTO d VALUES (1)');
      await db.execute('CREATE PACKAGE pk AS FUNCTION f RETURN NUMBER; END;');
      await db.execute('CREATE PACKAGE BODY pk AS FUNCTION f RETURN NUMBER IS '
          'BEGIN RETURN 42; END; END;');
      expect(await scalar(db, 'SELECT pk.f FROM d'), 42);
    } finally {
      await db.close();
    }
  });
}
