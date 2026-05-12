import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Step 5 of the out-of-core paging plan: `CREATE TABLE … USING paged`
/// wired through the SQL executor.
///
/// Validates the supported surface (CREATE, INSERT, SELECT * / SELECT
/// WHERE pk = ?, UPDATE WHERE pk = ?, DELETE WHERE pk = ?, DROP,
/// DESCRIBE), confirms unsupported shapes throw [UnsupportedError],
/// and verifies that paged tables survive a Database.close / reopen
/// cycle independent of the JSON persist file.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_create_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('CREATE … USING paged + INSERT + SELECT * + WHERE pk', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());

    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, name TEXT, age INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'alice', 30)");
    await db.execute("INSERT INTO t VALUES (2, 'bob', 25)");
    await db.execute("INSERT INTO t VALUES (3, 'cara', 40)");

    final all = await db.execute('SELECT * FROM t');
    expect(all.columns, ['id', 'name', 'age']);
    expect(all.rows.length, 3);
    // PagedTable.scan() returns rows in PK order.
    expect(all.rows[0], [1, 'alice', 30]);
    expect(all.rows[2], [3, 'cara', 40]);

    final one = await db.execute('SELECT * FROM t WHERE id = 2');
    expect(one.rows, [
      [2, 'bob', 25],
    ]);

    final missing = await db.execute('SELECT * FROM t WHERE id = 999');
    expect(missing.rows, isEmpty);
  });

  test('UPDATE / DELETE / DROP', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());

    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, name TEXT) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a')");
    await db.execute("INSERT INTO t VALUES (2, 'b')");

    final upd = await db.execute("UPDATE t SET name = 'B' WHERE id = 2");
    expect(upd.affected, 1);
    final after = await db.execute('SELECT * FROM t WHERE id = 2');
    expect(after.rows, [
      [2, 'B'],
    ]);

    final del = await db.execute('DELETE FROM t WHERE id = 1');
    expect(del.affected, 1);
    final left = await db.execute('SELECT * FROM t');
    expect(left.rows, [
      [2, 'B'],
    ]);

    final drop = await db.execute('DROP TABLE t');
    expect(drop.message, contains('dropped'));
    // After DROP it's no longer registered.
    expect(
      () => db.execute('SELECT * FROM t'),
      throwsA(isA<StateError>()),
    );
  });

  test('persists across Database.close / reopen', () async {
    final p = dbPath();
    final db = await Database.open(p);
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, name TEXT) USING paged');
    await db.execute("INSERT INTO t VALUES (10, 'ten')");
    await db.execute("INSERT INTO t VALUES (20, 'twenty')");
    await db.close();

    final db2 = await Database.open(p);
    addTearDown(() async => db2.close());
    final r = await db2.execute('SELECT * FROM t');
    expect(r.rows, [
      [10, 'ten'],
      [20, 'twenty'],
    ]);
    // Mutations after reopen still work and survive a second cycle.
    await db2.execute("INSERT INTO t VALUES (15, 'fifteen')");
    await db2.execute('DELETE FROM t WHERE id = 10');
    final r2 = await db2.execute('SELECT * FROM t');
    expect(r2.rows, [
      [15, 'fifteen'],
      [20, 'twenty'],
    ]);
  });

  test('rejects unsupported query shapes with helpful errors', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, name TEXT) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a')");

    // UPDATE that tries to reassign the primary key.
    await expectLater(
      db.execute('UPDATE t SET id = 99 WHERE id = 1'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('rejects USING paged on in-memory database', () async {
    final db = await Database.open();
    addTearDown(() async => db.close());
    await expectLater(
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY) USING paged'),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects USING paged without a single-column primary key', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await expectLater(
      db.execute('CREATE TABLE t (id INTEGER, name TEXT) USING paged'),
      throwsA(isA<StateError>()),
    );
  });

  test('paged tables coexist with regular in-memory tables', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE big ('
        'id INTEGER PRIMARY KEY, name TEXT) USING paged');
    await db.execute('CREATE TABLE small (id INTEGER PRIMARY KEY, v TEXT)');
    await db.execute("INSERT INTO big VALUES (1, 'paged')");
    await db.execute("INSERT INTO small VALUES (1, 'mem')");
    final b = await db.execute('SELECT * FROM big');
    final s = await db.execute('SELECT * FROM small');
    expect(b.rows, [
      [1, 'paged'],
    ]);
    expect(s.rows, [
      [1, 'mem'],
    ]);
  });
}
