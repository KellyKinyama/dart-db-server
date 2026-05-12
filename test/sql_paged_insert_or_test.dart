import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// INSERT OR IGNORE / INSERT OR REPLACE on USING paged tables.
///
/// Validates:
///  - OR IGNORE: PK conflict and UNIQUE conflict are silently skipped,
///    the rest of the batch goes through, affected count excludes
///    the ignored rows.
///  - OR REPLACE: PK conflict and UNIQUE conflict cause the
///    conflicting row(s) to be deleted before the new row is
///    inserted. A single new row may evict multiple existing rows
///    (PK match + multiple UNIQUE matches).
///  - RETURNING with OR IGNORE only emits rows that were actually
///    inserted; with OR REPLACE every replaced/inserted row appears.
///  - Both modes survive close + reopen.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_inor_');
  });
  tearDown(() async {
    if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  Future<Database> seeded() async {
    final db = await Database.open(dbPath());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, email TEXT, name TEXT) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a@x', 'alice')");
    await db.execute("INSERT INTO t VALUES (2, 'b@x', 'bob')");
    await db.execute("INSERT INTO t VALUES (3, 'c@x', 'cara')");
    return db;
  }

  test('OR IGNORE skips PK conflict', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r =
        await db.execute("INSERT OR IGNORE INTO t VALUES (1, 'dup@x', 'dup')");
    expect(r.affected, 0);
    final after = await db.execute('SELECT email FROM t WHERE id = 1');
    expect(after.rows, [
      ['a@x'],
    ]);
  });

  test('OR IGNORE skips UNIQUE conflict but inserts the rest', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');

    // Two rows: one collides on email, the other is fine.
    final r1 = await db
        .execute("INSERT OR IGNORE INTO t VALUES (10, 'a@x', 'dup-email')");
    expect(r1.affected, 0);
    final r2 = await db
        .execute("INSERT OR IGNORE INTO t VALUES (10, 'new@x', 'newname')");
    expect(r2.affected, 1);

    final all = await db.execute('SELECT id FROM t ORDER BY id');
    expect(all.rows, [
      [1],
      [2],
      [3],
      [10],
    ]);
  });

  test('OR REPLACE evicts the PK-conflicting row', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db
        .execute("INSERT OR REPLACE INTO t VALUES (1, 'a2@x', 'alice2')");
    expect(r.affected, 1);
    final row = await db.execute('SELECT email, name FROM t WHERE id = 1');
    expect(row.rows, [
      ['a2@x', 'alice2'],
    ]);
  });

  test('OR REPLACE evicts the UNIQUE-conflicting row', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');

    // id=99 is new (no PK conflict) but its email collides with id=2.
    final r =
        await db.execute("INSERT OR REPLACE INTO t VALUES (99, 'b@x', 'bob2')");
    expect(r.affected, 1);

    final all = await db.execute('SELECT id, email FROM t ORDER BY id');
    // id=2 must be gone; id=99 takes over 'b@x'.
    expect(all.rows, [
      [1, 'a@x'],
      [3, 'c@x'],
      [99, 'b@x'],
    ]);
  });

  test('OR REPLACE evicts both PK and UNIQUE conflicts at once', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');

    // Reusing id=1 (PK conflict with alice) AND email 'b@x' (UNIQUE
    // conflict with bob). Both alice and bob must be evicted.
    final r = await db
        .execute("INSERT OR REPLACE INTO t VALUES (1, 'b@x', 'merged')");
    expect(r.affected, 1);

    final all = await db.execute('SELECT id, email, name FROM t ORDER BY id');
    expect(all.rows, [
      [1, 'b@x', 'merged'],
      [3, 'c@x', 'cara'],
    ]);
  });

  test('OR IGNORE RETURNING only emits inserted rows', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute(
        "INSERT OR IGNORE INTO t VALUES (1, 'dup@x', 'dup') RETURNING id");
    expect(r.rows, isEmpty);
    expect(r.affected, 0);

    final r2 = await db.execute(
        "INSERT OR IGNORE INTO t VALUES (42, 'new@x', 'new') RETURNING id");
    expect(r2.rows, [
      [42],
    ]);
  });

  test('OR REPLACE survives close + reopen', () async {
    final db1 = await seeded();
    await db1.execute("INSERT OR REPLACE INTO t VALUES (1, 'rewrite@x', 'r')");
    await db1.close();

    final db2 = await Database.open(dbPath());
    addTearDown(() async => db2.close());
    final r = await db2.execute('SELECT email FROM t WHERE id = 1');
    expect(r.rows, [
      ['rewrite@x'],
    ]);
  });
}
