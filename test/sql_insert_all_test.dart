/// Tests Oracle `INSERT ALL` / `INSERT FIRST` multi-table insert.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE a (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE TABLE b (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE TABLE c (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE TABLE src (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('INSERT INTO src VALUES (1, 5)');
    await db.execute('INSERT INTO src VALUES (2, 15)');
    await db.execute('INSERT INTO src VALUES (3, 25)');
  });

  Future<List<List<Object?>>> rowsOf(String t) async =>
      (await db.execute('SELECT id, v FROM $t ORDER BY id'))
          .rows
          .map((r) => r.toList())
          .toList();

  test('unconditional INSERT ALL fans out to every INTO', () async {
    final r = await db.execute('''
      INSERT ALL
        INTO a (id, v) VALUES (id, v)
        INTO b (id, v) VALUES (id, v * 10)
      SELECT id, v FROM src
    ''');
    expect(r.affected, 6);
    expect(await rowsOf('a'), [
      [1, 5],
      [2, 15],
      [3, 25],
    ]);
    expect(await rowsOf('b'), [
      [1, 50],
      [2, 150],
      [3, 250],
    ]);
  });

  test('conditional INSERT ALL applies every matching WHEN, then ELSE', () async {
    await db.execute('''
      INSERT ALL
        WHEN v < 10 THEN INTO a (id, v) VALUES (id, v)
        WHEN v < 20 THEN INTO b (id, v) VALUES (id, v)
        ELSE INTO c (id, v) VALUES (id, v)
      SELECT id, v FROM src
    ''');
    expect(await rowsOf('a'), [
      [1, 5],
    ]);
    expect(await rowsOf('b'), [
      [1, 5],
      [2, 15],
    ]);
    expect(await rowsOf('c'), [
      [3, 25],
    ]);
  });

  test('INSERT FIRST stops at the first matching WHEN per row', () async {
    await db.execute('''
      INSERT FIRST
        WHEN v < 20 THEN INTO a (id, v) VALUES (id, v)
        WHEN v < 30 THEN INTO b (id, v) VALUES (id, v)
        ELSE INTO c (id, v) VALUES (id, v)
      SELECT id, v FROM src
    ''');
    expect(await rowsOf('a'), [
      [1, 5],
      [2, 15],
    ]);
    expect(await rowsOf('b'), [
      [3, 25],
    ]);
    expect(await rowsOf('c'), isEmpty);
  });

  test('ELSE fires only when no WHEN matched', () async {
    await db.execute('''
      INSERT ALL
        WHEN v > 100 THEN INTO a (id, v) VALUES (id, v)
        ELSE INTO c (id, v) VALUES (id, v)
      SELECT id, v FROM src
    ''');
    expect(await rowsOf('a'), isEmpty);
    expect(await rowsOf('c'), [
      [1, 5],
      [2, 15],
      [3, 25],
    ]);
  });

  test('INTO without VALUES uses the driving row positionally', () async {
    final r = await db.execute(
      'INSERT ALL INTO a (id, v) SELECT 9, 99 FROM src WHERE id = 1',
    );
    expect(r.affected, 1);
    expect(await rowsOf('a'), [
      [9, 99],
    ]);
  });

  test('computed VALUES expressions reference driving columns', () async {
    await db.execute('''
      INSERT ALL
        INTO a (id, v) VALUES (id, v + 1)
      SELECT id, v FROM src WHERE id <= 2
    ''');
    expect(await rowsOf('a'), [
      [1, 6],
      [2, 16],
    ]);
  });
}
