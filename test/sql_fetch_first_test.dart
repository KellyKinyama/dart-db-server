/// Tests the SQL-standard / Oracle row-limiting clause
/// `OFFSET n ROWS FETCH { FIRST | NEXT } m ROWS ONLY`, mapped onto the
/// engine's existing LIMIT/OFFSET.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
    for (var i = 1; i <= 5; i++) {
      await db.execute('INSERT INTO t VALUES ($i, ${i * 10})');
    }
  });

  Future<List<Object?>> ids(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r[0]).toList();

  test('FETCH FIRST n ROWS ONLY limits the result', () async {
    expect(await ids('SELECT id FROM t ORDER BY id FETCH FIRST 2 ROWS ONLY'),
        [1, 2]);
  });

  test('FETCH NEXT n ROWS ONLY is accepted', () async {
    expect(await ids('SELECT id FROM t ORDER BY id FETCH NEXT 3 ROWS ONLY'),
        [1, 2, 3]);
  });

  test('FETCH FIRST ROW ONLY (no count) returns one row', () async {
    expect(
        await ids('SELECT id FROM t ORDER BY id FETCH FIRST ROW ONLY'), [1]);
  });

  test('OFFSET n ROWS FETCH NEXT m ROWS ONLY paginates', () async {
    expect(
        await ids(
            'SELECT id FROM t ORDER BY id OFFSET 2 ROWS FETCH NEXT 2 ROWS ONLY'),
        [3, 4]);
  });

  test('OFFSET n ROWS alone skips rows', () async {
    expect(await ids('SELECT id FROM t ORDER BY id OFFSET 3 ROWS'), [4, 5]);
  });

  test('FETCH FIRST n ROWS WITH TIES is accepted (behaves like ONLY)',
      () async {
    expect(
        await ids('SELECT id FROM t ORDER BY id FETCH FIRST 2 ROWS WITH TIES'),
        [1, 2]);
  });

  test('plain LIMIT still works', () async {
    expect(await ids('SELECT id FROM t ORDER BY id LIMIT 2'), [1, 2]);
  });

  test('FETCH / NEXT / ONLY remain usable as identifiers', () async {
    await db.execute('CREATE TABLE kw (fetch INTEGER, next INTEGER, only INTEGER)');
    await db.execute('INSERT INTO kw VALUES (1, 2, 3)');
    final r = await db.execute('SELECT fetch, next, only FROM kw');
    expect(r.rows, [
      [1, 2, 3]
    ]);
  });
}
