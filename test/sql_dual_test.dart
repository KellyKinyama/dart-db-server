/// Tests the Oracle `DUAL` one-row table and common scalar idioms used with it.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async => db = await Database.open(null));

  Future<Object?> one(String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('SELECT constant FROM DUAL', () async {
    expect(await one('SELECT 1 FROM DUAL'), 1);
    expect(await one("SELECT 'x' FROM dual"), 'x');
    expect(await one('SELECT 1 + 1 AS r FROM DUAL'), 2);
  });

  test('DUAL exposes the DUMMY column', () async {
    expect(await one('SELECT DUMMY FROM DUAL'), 'X');
    expect(await one('SELECT dummy FROM dual'), 'X');
  });

  test('NVL / COALESCE / DECODE over DUAL', () async {
    expect(await one("SELECT NVL(NULL, 'd') FROM DUAL"), 'd');
    expect(await one('SELECT COALESCE(NULL, 5) FROM DUAL'), 5);
    expect(await one("SELECT DECODE(1, 1, 'a', 'b') FROM DUAL"), 'a');
  });

  test('SYSDATE / SYSTIMESTAMP as barewords', () async {
    final d = await one('SELECT SYSDATE FROM DUAL') as String;
    expect(d, matches(r'^\d{4}-\d{2}-\d{2} '));
    final ts = await one('SELECT SYSTIMESTAMP FROM DUAL') as String;
    expect(ts, matches(r'^\d{4}-\d{2}-\d{2} '));
  });

  test('TO_CHAR / TO_NUMBER', () async {
    expect(await one('SELECT TO_CHAR(123) FROM DUAL'), '123');
    expect(await one("SELECT TO_CHAR('abc') FROM DUAL"), 'abc');
    expect(await one("SELECT TO_NUMBER('42') FROM DUAL"), 42);
    expect(await one("SELECT TO_NUMBER('3.5') FROM DUAL"), 3.5);
  });

  test('a real table named DUAL still works if created', () async {
    await db.execute('CREATE TABLE dual (x INTEGER)');
    await db.execute('INSERT INTO dual VALUES (7)');
    expect(await one('SELECT x FROM dual'), 7);
  });

  test('DUAL in a scalar subquery', () async {
    await db.execute('CREATE TABLE t (id INTEGER)');
    await db.execute('INSERT INTO t VALUES (1)');
    expect(await one('SELECT (SELECT 9 FROM DUAL) FROM t'), 9);
  });
}
