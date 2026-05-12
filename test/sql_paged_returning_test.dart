import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// INSERT … SELECT and RETURNING on paged tables.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_ret_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  Future<Database> opened() async {
    final db = await Database.open(dbPath());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, name TEXT, qty INTEGER) USING paged');
    return db;
  }

  // ---------------------------------------------------------------------------
  // INSERT … SELECT
  // ---------------------------------------------------------------------------

  test('INSERT … SELECT from an in-memory source', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE src '
        '(id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)');
    await db.execute("INSERT INTO src VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO src VALUES (2, 'b', 20)");
    await db.execute("INSERT INTO src VALUES (3, 'c', 30)");

    final r = await db.execute('INSERT INTO t SELECT * FROM src');
    expect(r.affected, 3);

    final read = await db.execute('SELECT id, name, qty FROM t ORDER BY id');
    expect(read.rows, [
      [1, 'a', 10],
      [2, 'b', 20],
      [3, 'c', 30],
    ]);
  });

  test('INSERT … SELECT with WHERE filter', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE src '
        '(id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)');
    for (var i = 1; i <= 5; i++) {
      await db.execute("INSERT INTO src VALUES ($i, 'x$i', ${i * 10})");
    }
    final r = await db
        .execute('INSERT INTO t SELECT id, name, qty FROM src WHERE qty >= 30');
    expect(r.affected, 3);
    final read = await db.execute('SELECT id FROM t ORDER BY id');
    expect(read.rows, [
      [3],
      [4],
      [5],
    ]);
  });

  test('INSERT … SELECT from the paged table itself (copy-with-offset)',
      () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute("INSERT INTO t VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO t VALUES (2, 'b', 20)");
    final r =
        await db.execute('INSERT INTO t SELECT id + 10, name, qty FROM t');
    expect(r.affected, 2);
    final read = await db.execute('SELECT id FROM t ORDER BY id');
    expect(read.rows, [
      [1],
      [2],
      [11],
      [12],
    ]);
  });

  // ---------------------------------------------------------------------------
  // RETURNING — INSERT
  // ---------------------------------------------------------------------------

  test('INSERT … VALUES … RETURNING *', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    final r = await db
        .execute("INSERT INTO t VALUES (1, 'a', 10), (2, 'b', 20) RETURNING *");
    expect(r.columns, ['id', 'name', 'qty']);
    expect(r.rows, [
      [1, 'a', 10],
      [2, 'b', 20],
    ]);
    expect(r.affected, 2);
  });

  test('INSERT … RETURNING projection list with aliases and expressions',
      () async {
    final db = await opened();
    addTearDown(() async => db.close());
    final r = await db.execute(
        "INSERT INTO t VALUES (5, 'e', 50) RETURNING id, qty * 2 AS doubled");
    expect(r.columns, ['id', 'doubled']);
    expect(r.rows, [
      [5, 100],
    ]);
  });

  test('INSERT … SELECT … RETURNING returns the inserted rows', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE src '
        '(id INTEGER PRIMARY KEY, name TEXT, qty INTEGER)');
    await db.execute("INSERT INTO src VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO src VALUES (2, 'b', 20)");
    final r =
        await db.execute('INSERT INTO t SELECT * FROM src RETURNING id, name');
    expect(r.columns, ['id', 'name']);
    expect(r.rows, [
      [1, 'a'],
      [2, 'b'],
    ]);
    expect(r.affected, 2);
  });

  // ---------------------------------------------------------------------------
  // RETURNING — UPDATE
  // ---------------------------------------------------------------------------

  test('UPDATE … RETURNING returns the post-update values', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute("INSERT INTO t VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO t VALUES (2, 'b', 20)");
    final r = await db
        .execute("UPDATE t SET qty = qty + 1 WHERE id = 2 RETURNING id, qty");
    expect(r.columns, ['id', 'qty']);
    expect(r.rows, [
      [2, 21],
    ]);
    expect(r.affected, 1);
  });

  test('UPDATE … RETURNING with no rows matched yields empty rows', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    final r =
        await db.execute("UPDATE t SET qty = 99 WHERE id = 42 RETURNING id");
    expect(r.columns, ['id']);
    expect(r.rows, isEmpty);
    expect(r.affected, 0);
  });

  // ---------------------------------------------------------------------------
  // RETURNING — DELETE
  // ---------------------------------------------------------------------------

  test('DELETE … RETURNING * returns the pre-deletion rows', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute("INSERT INTO t VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO t VALUES (2, 'b', 20)");
    await db.execute("INSERT INTO t VALUES (3, 'c', 30)");
    final r = await db.execute('DELETE FROM t WHERE id >= 2 RETURNING *');
    expect(r.columns, ['id', 'name', 'qty']);
    expect(r.rows, [
      [2, 'b', 20],
      [3, 'c', 30],
    ]);
    expect(r.affected, 2);
    final left = await db.execute('SELECT id FROM t');
    expect(left.rows, [
      [1],
    ]);
  });

  test('DELETE … RETURNING projection', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute("INSERT INTO t VALUES (7, 'g', 70)");
    final r =
        await db.execute('DELETE FROM t WHERE id = 7 RETURNING name, qty');
    expect(r.columns, ['name', 'qty']);
    expect(r.rows, [
      ['g', 70],
    ]);
  });

  // ---------------------------------------------------------------------------
  // Transaction integration
  // ---------------------------------------------------------------------------

  test('INSERT … SELECT inside a transaction respects ROLLBACK', () async {
    final db = await opened();
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE src (id INTEGER PRIMARY KEY, '
        'name TEXT, qty INTEGER)');
    await db.execute("INSERT INTO src VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO src VALUES (2, 'b', 20)");

    await db.execute('BEGIN');
    await db.execute('INSERT INTO t SELECT * FROM src');
    final mid = await db.execute('SELECT COUNT(*) FROM t');
    expect(mid.rows, [
      [2],
    ]);
    await db.execute('ROLLBACK');
    final after = await db.execute('SELECT COUNT(*) FROM t');
    expect(after.rows, [
      [0],
    ]);
  });
}
