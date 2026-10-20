/// Tests Oracle sequences: CREATE/DROP SEQUENCE and seq.NEXTVAL / seq.CURRVAL.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async => db = await Database.open(null));

  Future<Object?> one(String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('NEXTVAL starts at START WITH and advances by INCREMENT BY', () async {
    await db.execute('CREATE SEQUENCE s START WITH 10 INCREMENT BY 5');
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 10);
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 15);
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 20);
  });

  test('defaults are START WITH 1 INCREMENT BY 1', () async {
    await db.execute('CREATE SEQUENCE s');
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 1);
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 2);
  });

  test('multiple NEXTVAL refs in one row return the same value', () async {
    await db.execute('CREATE SEQUENCE s START WITH 1');
    expect(
      (await db.execute('SELECT s.NEXTVAL, s.NEXTVAL FROM DUAL')).rows.first,
      [1, 1],
    );
    // A new statement advances once.
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 2);
  });

  test('NEXTVAL advances per row but is stable within a row', () async {
    await db.execute('CREATE TABLE src (n INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO src VALUES (1)');
    await db.execute('INSERT INTO src VALUES (2)');
    await db.execute('INSERT INTO src VALUES (3)');
    await db.execute('CREATE TABLE dst (a INTEGER, b INTEGER)');
    await db.execute('CREATE SEQUENCE q START WITH 10 INCREMENT BY 10');
    await db.execute('INSERT INTO dst SELECT q.NEXTVAL, q.NEXTVAL FROM src');
    final r = await db.execute('SELECT a, b FROM dst ORDER BY a');
    expect(r.rows.map((x) => x.toList()).toList(), [
      [10, 10],
      [20, 20],
      [30, 30],
    ]);
  });

  test('CURRVAL returns the last issued value', () async {
    await db.execute('CREATE SEQUENCE s START WITH 7');
    await db.execute('SELECT s.NEXTVAL FROM DUAL');
    await db.execute('SELECT s.NEXTVAL FROM DUAL');
    expect(await one('SELECT s.CURRVAL FROM DUAL'), 8);
  });

  test('CURRVAL before NEXTVAL is an error', () async {
    await db.execute('CREATE SEQUENCE s');
    expect(
      () => db.execute('SELECT s.CURRVAL FROM DUAL'),
      throwsA(isA<StateError>()),
    );
  });

  test('sequence drives a primary key via INSERT VALUES', () async {
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    await db.execute('CREATE SEQUENCE tseq START WITH 1');
    await db.execute("INSERT INTO t VALUES (tseq.NEXTVAL, 'a')");
    await db.execute("INSERT INTO t VALUES (tseq.NEXTVAL, 'b')");
    final r = await db.execute('SELECT id, name FROM t ORDER BY id');
    expect(r.rows.map((x) => x.toList()).toList(), [
      [1, 'a'],
      [2, 'b'],
    ]);
  });

  test('NEXTVAL advances once per row in INSERT ... SELECT', () async {
    await db.execute('CREATE TABLE src (n INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO src VALUES (1)');
    await db.execute('INSERT INTO src VALUES (2)');
    await db.execute('INSERT INTO src VALUES (3)');
    await db.execute('CREATE TABLE dst (id INTEGER PRIMARY KEY)');
    await db.execute('CREATE SEQUENCE q START WITH 100 INCREMENT BY 10');
    await db.execute('INSERT INTO dst SELECT q.NEXTVAL FROM src');
    final r = await db.execute('SELECT id FROM dst ORDER BY id');
    expect(r.rows.map((x) => x.first).toList(), [100, 110, 120]);
  });

  test('CYCLE wraps at MAXVALUE', () async {
    await db.execute(
      'CREATE SEQUENCE s START WITH 1 INCREMENT BY 1 MAXVALUE 3 CYCLE '
      'MINVALUE 1',
    );
    final got = <Object?>[];
    for (var i = 0; i < 5; i++) {
      got.add(await one('SELECT s.NEXTVAL FROM DUAL'));
    }
    expect(got, [1, 2, 3, 1, 2]);
  });

  test('NOCYCLE past MAXVALUE is an error', () async {
    await db.execute('CREATE SEQUENCE s START WITH 1 MAXVALUE 2 NOCYCLE');
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 1);
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 2);
    expect(
      () => db.execute('SELECT s.NEXTVAL FROM DUAL'),
      throwsA(isA<StateError>()),
    );
  });

  test('CREATE SEQUENCE IF NOT EXISTS / duplicate error', () async {
    await db.execute('CREATE SEQUENCE s');
    expect(() => db.execute('CREATE SEQUENCE s'), throwsA(isA<StateError>()));
    final r = await db.execute('CREATE SEQUENCE IF NOT EXISTS s');
    expect(r.message, contains('already exists'));
  });

  test('DROP SEQUENCE removes it', () async {
    await db.execute('CREATE SEQUENCE s');
    await db.execute('SELECT s.NEXTVAL FROM DUAL');
    await db.execute('DROP SEQUENCE s');
    expect(
      () => db.execute('SELECT s.NEXTVAL FROM DUAL'),
      throwsA(isA<StateError>()),
    );
    final r = await db.execute('DROP SEQUENCE IF EXISTS s');
    expect(r.message, contains('did not exist'));
  });

  test('sequence values are not rolled back with the transaction', () async {
    await db.execute('CREATE SEQUENCE s START WITH 1');
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 1);
    await db.execute('BEGIN');
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 2);
    await db.execute('ROLLBACK');
    // Oracle: NEXTVAL is non-transactional, so the next value keeps climbing.
    expect(await one('SELECT s.NEXTVAL FROM DUAL'), 3);
  });
}
