import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// INSERT … ON CONFLICT (cols) DO NOTHING / DO UPDATE on USING paged
/// tables.
///
/// Validates:
///  - ON CONFLICT (pk) DO NOTHING leaves the existing row alone and
///    doesn't count toward `affected`.
///  - ON CONFLICT (pk) DO UPDATE updates the matched row; `excluded.col`
///    references the proposed-insert values; `affected` increments.
///  - ON CONFLICT (unique_col) DO UPDATE targets a UNIQUE secondary
///    index — the matched row may have a different PK than the
///    proposed insert.
///  - ON CONFLICT with empty target acts as "any unique conflict"
///    (PK or any UNIQUE index, first hit wins).
///  - ON CONFLICT (cols) where the column set is neither the PK nor
///    a UNIQUE index raises UnsupportedError.
///  - DO UPDATE WHERE filters out rows that don't satisfy the
///    predicate (leaves the existing row unchanged, no count).
///  - DO UPDATE cannot reassign the primary key.
///  - RETURNING with DO UPDATE emits the *new* row values.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_upsert_');
  });
  tearDown(() async {
    if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  Future<Database> seeded() async {
    final db = await Database.open(dbPath());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, email TEXT, hits INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a@x', 1)");
    await db.execute("INSERT INTO t VALUES (2, 'b@x', 2)");
    return db;
  }

  test('ON CONFLICT (pk) DO NOTHING', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute(
        "INSERT INTO t VALUES (1, 'dup@x', 99) ON CONFLICT(id) DO NOTHING");
    expect(r.affected, 0);
    final row = await db.execute('SELECT email, hits FROM t WHERE id = 1');
    expect(row.rows, [
      ['a@x', 1],
    ]);
  });

  test('ON CONFLICT (pk) DO UPDATE with excluded.col', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute("INSERT INTO t VALUES (1, 'a2@x', 10) "
        'ON CONFLICT(id) DO UPDATE SET email = excluded.email, '
        'hits = hits + excluded.hits');
    expect(r.affected, 1);
    final row = await db.execute('SELECT email, hits FROM t WHERE id = 1');
    expect(row.rows, [
      ['a2@x', 11],
    ]);
  });

  test('ON CONFLICT (unique_col) targets UNIQUE secondary index', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');

    // id=99 is new; email 'b@x' collides with id=2.
    final r = await db.execute("INSERT INTO t VALUES (99, 'b@x', 100) "
        'ON CONFLICT(email) DO UPDATE SET hits = hits + 100');
    expect(r.affected, 1);

    final all = await db.execute('SELECT id, email, hits FROM t ORDER BY id');
    // id=2 is mutated in place; id=99 is NOT inserted.
    expect(all.rows, [
      [1, 'a@x', 1],
      [2, 'b@x', 102],
    ]);
  });

  test('ON CONFLICT with empty target = any unique conflict', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');

    // PK conflict path.
    await db.execute("INSERT INTO t VALUES (1, 'a@x', 0) "
        'ON CONFLICT DO UPDATE SET hits = hits + 10');
    // UNIQUE-index conflict path (new PK, colliding email).
    await db.execute("INSERT INTO t VALUES (50, 'a@x', 0) "
        'ON CONFLICT DO UPDATE SET hits = hits + 100');
    final r = await db.execute('SELECT hits FROM t WHERE id = 1');
    expect(r.rows, [
      [111],
    ]);
  });

  test('ON CONFLICT (cols) without matching constraint is rejected', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await expectLater(
      db.execute(
          "INSERT INTO t VALUES (1, 'x', 1) ON CONFLICT(hits) DO NOTHING"),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('DO UPDATE WHERE filters the update', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    // Existing hits=1 -> WHERE hits > 5 is false -> no update, no count.
    final r = await db.execute("INSERT INTO t VALUES (1, 'x', 0) "
        'ON CONFLICT(id) DO UPDATE SET email = excluded.email '
        'WHERE hits > 5');
    expect(r.affected, 0);
    final row = await db.execute('SELECT email FROM t WHERE id = 1');
    expect(row.rows, [
      ['a@x'],
    ]);
  });

  test('DO UPDATE cannot reassign the primary key', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await expectLater(
      db.execute("INSERT INTO t VALUES (1, 'x', 0) "
          'ON CONFLICT(id) DO UPDATE SET id = 999'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('RETURNING with DO UPDATE emits new row', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute("INSERT INTO t VALUES (1, 'a2@x', 5) "
        'ON CONFLICT(id) DO UPDATE SET hits = hits + excluded.hits '
        'RETURNING id, hits');
    expect(r.rows, [
      [1, 6],
    ]);
  });

  test('upsert survives close + reopen', () async {
    final db1 = await seeded();
    await db1.execute("INSERT INTO t VALUES (1, 'a@x', 0) "
        'ON CONFLICT(id) DO UPDATE SET hits = hits + 41');
    await db1.close();

    final db2 = await Database.open(dbPath());
    addTearDown(() async => db2.close());
    final r = await db2.execute('SELECT hits FROM t WHERE id = 1');
    expect(r.rows, [
      [42],
    ]);
  });
}
