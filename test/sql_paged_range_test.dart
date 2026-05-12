import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Step 6 of the out-of-core paging plan: broaden the SQL surface
/// supported on `USING paged` tables.
///
/// Validates PK range scans (`<`, `<=`, `>`, `>=`, BETWEEN, AND-chains),
/// `ORDER BY pk [DESC]`, `LIMIT` / `OFFSET`, `COUNT(*)`, bulk UPDATE
/// across a PK range, and bulk DELETE across a PK range / over the
/// whole table.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_range_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  Future<Database> seeded(int n) async {
    final db = await Database.open(dbPath());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, name TEXT) USING paged');
    for (var i = 1; i <= n; i++) {
      await db.execute("INSERT INTO t VALUES ($i, 'r$i')");
    }
    return db;
  }

  test('range scans: <, <=, >, >=, BETWEEN, AND-chain', () async {
    final db = await seeded(10);
    addTearDown(() async => db.close());

    expect((await db.execute('SELECT * FROM t WHERE id < 4')).rows, [
      [1, 'r1'],
      [2, 'r2'],
      [3, 'r3']
    ]);
    expect((await db.execute('SELECT * FROM t WHERE id <= 2')).rows, [
      [1, 'r1'],
      [2, 'r2']
    ]);
    expect((await db.execute('SELECT * FROM t WHERE id > 8')).rows, [
      [9, 'r9'],
      [10, 'r10']
    ]);
    expect((await db.execute('SELECT * FROM t WHERE id >= 9')).rows, [
      [9, 'r9'],
      [10, 'r10']
    ]);
    expect(
        (await db.execute('SELECT * FROM t WHERE id BETWEEN 3 AND 5')).rows, [
      [3, 'r3'],
      [4, 'r4'],
      [5, 'r5']
    ]);
    expect(
        (await db.execute('SELECT * FROM t WHERE id >= 4 AND id < 7')).rows, [
      [4, 'r4'],
      [5, 'r5'],
      [6, 'r6']
    ]);
    // Reversed comparator (`lit < pk`) is also accepted.
    expect((await db.execute('SELECT * FROM t WHERE 7 < id')).rows, [
      [8, 'r8'],
      [9, 'r9'],
      [10, 'r10']
    ]);
    // Contradiction → empty.
    expect((await db.execute('SELECT * FROM t WHERE id = 3 AND id = 4')).rows,
        isEmpty);
  });

  test('ORDER BY pk ASC/DESC + LIMIT/OFFSET', () async {
    final db = await seeded(10);
    addTearDown(() async => db.close());

    expect((await db.execute('SELECT * FROM t ORDER BY id LIMIT 3')).rows, [
      [1, 'r1'],
      [2, 'r2'],
      [3, 'r3']
    ]);
    expect(
        (await db.execute('SELECT * FROM t ORDER BY id LIMIT 3 OFFSET 4')).rows,
        [
          [5, 'r5'],
          [6, 'r6'],
          [7, 'r7']
        ]);
    expect(
        (await db.execute('SELECT * FROM t ORDER BY id DESC LIMIT 2')).rows, [
      [10, 'r10'],
      [9, 'r9']
    ]);
    expect(
        (await db.execute(
                'SELECT * FROM t WHERE id BETWEEN 3 AND 7 ORDER BY id DESC'))
            .rows,
        [
          [7, 'r7'],
          [6, 'r6'],
          [5, 'r5'],
          [4, 'r4'],
          [3, 'r3']
        ]);
    // OFFSET past the end yields empty.
    expect(
        (await db.execute('SELECT * FROM t ORDER BY id LIMIT 5 OFFSET 50'))
            .rows,
        isEmpty);
  });

  test('COUNT(*) full, ranged, and contradicted', () async {
    final db = await seeded(10);
    addTearDown(() async => db.close());

    final all = await db.execute('SELECT COUNT(*) FROM t');
    expect(all.columns.length, 1);
    expect(all.rows, [
      [10]
    ]);

    expect(
        (await db.execute(
                'SELECT COUNT(*) AS n FROM t WHERE id BETWEEN 3 AND 7'))
            .columns,
        ['n']);
    expect(
        (await db.execute(
                'SELECT COUNT(*) AS n FROM t WHERE id BETWEEN 3 AND 7'))
            .rows,
        [
          [5]
        ]);
    expect((await db.execute('SELECT COUNT(*) FROM t WHERE id = 99')).rows, [
      [0]
    ]);
  });

  test('bulk UPDATE across a range and over the whole table', () async {
    final db = await seeded(5);
    addTearDown(() async => db.close());

    final r1 =
        await db.execute("UPDATE t SET name = 'X' WHERE id BETWEEN 2 AND 4");
    expect(r1.affected, 3);
    expect((await db.execute('SELECT * FROM t')).rows, [
      [1, 'r1'],
      [2, 'X'],
      [3, 'X'],
      [4, 'X'],
      [5, 'r5'],
    ]);
    final r2 = await db.execute("UPDATE t SET name = 'Y'");
    expect(r2.affected, 5);
    expect((await db.execute('SELECT name FROM t ORDER BY id')).rows, [
      ['Y'],
      ['Y'],
      ['Y'],
      ['Y'],
      ['Y']
    ]);
  });

  test('bulk DELETE across a range and over the whole table', () async {
    final db = await seeded(6);
    addTearDown(() async => db.close());

    final r1 = await db.execute('DELETE FROM t WHERE id < 3');
    expect(r1.affected, 2);
    expect((await db.execute('SELECT id FROM t')).rows, [
      [3],
      [4],
      [5],
      [6]
    ]);
    final r2 = await db.execute('DELETE FROM t');
    expect(r2.affected, 4);
    expect((await db.execute('SELECT COUNT(*) FROM t')).rows, [
      [0]
    ]);
  });

  test('survives close / reopen with mixed mutations', () async {
    final p = dbPath();
    final db = await Database.open(p);
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, v TEXT) USING paged');
    for (var i = 1; i <= 8; i++) {
      await db.execute("INSERT INTO t VALUES ($i, 'v$i')");
    }
    await db.execute("UPDATE t SET v = 'edited' WHERE id BETWEEN 3 AND 5");
    await db.execute('DELETE FROM t WHERE id >= 7');
    await db.close();

    final db2 = await Database.open(p);
    addTearDown(() async => db2.close());
    expect((await db2.execute('SELECT * FROM t ORDER BY id')).rows, [
      [1, 'v1'],
      [2, 'v2'],
      [3, 'edited'],
      [4, 'edited'],
      [5, 'edited'],
      [6, 'v6'],
    ]);
    expect((await db2.execute('SELECT COUNT(*) FROM t')).rows, [
      [6]
    ]);
  });
}
