import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Out-of-core paging plan, next: multi-statement transactions that
/// span paged tables. `BEGIN ... INSERT/UPDATE/DELETE on a paged
/// table ... COMMIT/ROLLBACK` is now atomic — the paged backing
/// files are only flushed at COMMIT, and on ROLLBACK they are
/// undone via the per-file rollback journal.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_tx_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  Future<Database> seeded() async {
    final db = await Database.open(dbPath());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, name TEXT, qty INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO t VALUES (2, 'b', 20)");
    await db.execute("INSERT INTO t VALUES (3, 'c', 30)");
    return db;
  }

  test('COMMIT flushes paged INSERTs together', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('BEGIN');
    await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
    await db.execute("INSERT INTO t VALUES (5, 'e', 50)");
    // Mid-tx visibility within the same connection.
    final mid = await db.execute('SELECT COUNT(*) FROM t');
    expect(mid.rows, [
      [5],
    ]);
    await db.execute('COMMIT');

    final r = await db.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
      [4],
      [5],
    ]);
  });

  test('ROLLBACK undoes paged INSERTs', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('BEGIN');
    await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
    await db.execute("INSERT INTO t VALUES (5, 'e', 50)");
    final mid = await db.execute('SELECT COUNT(*) FROM t');
    expect(mid.rows, [
      [5],
    ]);
    await db.execute('ROLLBACK');

    final r = await db.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
    ]);
  });

  test('ROLLBACK undoes paged UPDATE + DELETE', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('BEGIN');
    await db.execute("UPDATE t SET name = 'X' WHERE id = 2");
    await db.execute('DELETE FROM t WHERE id = 3');
    final mid = await db.execute('SELECT id, name FROM t ORDER BY id');
    expect(mid.rows, [
      [1, 'a'],
      [2, 'X'],
    ]);
    await db.execute('ROLLBACK');

    final r = await db.execute('SELECT id, name FROM t ORDER BY id');
    expect(r.rows, [
      [1, 'a'],
      [2, 'b'],
      [3, 'c'],
    ]);
  });

  test('rolled-back paged state survives reopen', () async {
    {
      final db = await seeded();
      await db.execute('BEGIN');
      await db.execute("INSERT INTO t VALUES (99, 'zzz', 999)");
      await db.execute('ROLLBACK');
      await db.close();
    }
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    final r = await db.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
    ]);
  });

  test('committed paged state survives reopen', () async {
    {
      final db = await seeded();
      await db.execute('BEGIN');
      await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
      await db.execute('COMMIT');
      await db.close();
    }
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    final r = await db.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
      [4],
    ]);
  });

  test('mixed in-memory + paged: COMMIT and ROLLBACK', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE m (id INTEGER PRIMARY KEY, v TEXT)');
    await db.execute("INSERT INTO m VALUES (1, 'one')");

    // ROLLBACK case: both sides revert.
    await db.execute('BEGIN');
    await db.execute("INSERT INTO m VALUES (2, 'two')");
    await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
    await db.execute('ROLLBACK');

    var rm = await db.execute('SELECT id FROM m ORDER BY id');
    expect(rm.rows, [
      [1],
    ]);
    var rt = await db.execute('SELECT id FROM t ORDER BY id');
    expect(rt.rows, [
      [1],
      [2],
      [3],
    ]);

    // COMMIT case: both sides persist.
    await db.execute('BEGIN');
    await db.execute("INSERT INTO m VALUES (2, 'two')");
    await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
    await db.execute('COMMIT');

    rm = await db.execute('SELECT id FROM m ORDER BY id');
    expect(rm.rows, [
      [1],
      [2],
    ]);
    rt = await db.execute('SELECT id FROM t ORDER BY id');
    expect(rt.rows, [
      [1],
      [2],
      [3],
      [4],
    ]);
  });

  test('secondary index stays consistent across ROLLBACK', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE INDEX t_name ON t(name)');

    // Sanity: index lookup hits before the tx.
    final before = await db.execute("SELECT id FROM t WHERE name = 'b'");
    expect(before.rows, [
      [2],
    ]);

    await db.execute('BEGIN');
    await db.execute("UPDATE t SET name = 'B' WHERE id = 2");
    await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
    final mid = await db.execute("SELECT id FROM t WHERE name = 'B'");
    expect(mid.rows, [
      [2],
    ]);
    await db.execute('ROLLBACK');

    // Old key 'b' is back, 'B' has no hits, id=4 is gone.
    final byB = await db.execute("SELECT id FROM t WHERE name = 'b'");
    expect(byB.rows, [
      [2],
    ]);
    final byBig = await db.execute("SELECT id FROM t WHERE name = 'B'");
    expect(byBig.rows, isEmpty);
    final byD = await db.execute("SELECT id FROM t WHERE name = 'd'");
    expect(byD.rows, isEmpty);
  });

  test('paged DDL is rejected inside a transaction', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('BEGIN');

    await expectLater(
      () => db.execute('CREATE INDEX t_qty ON t(qty)'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      () => db.execute('CREATE TABLE u ('
          'id INTEGER PRIMARY KEY) USING paged'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      () => db.execute('TRUNCATE TABLE t'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      () => db.execute('DROP TABLE t'),
      throwsA(isA<UnsupportedError>()),
    );

    // DML still works.
    await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
    await db.execute('ROLLBACK');
  });

  test('paged writes are rejected while a SAVEPOINT is open', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('BEGIN');
    await db.execute('SAVEPOINT sp1');
    await expectLater(
      () => db.execute("INSERT INTO t VALUES (4, 'd', 40)"),
      throwsA(isA<UnsupportedError>()),
    );
    await db.execute('RELEASE SAVEPOINT sp1');
    // After RELEASE the savepoint stack is empty again, so writes work.
    await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
    await db.execute('ROLLBACK');
    final r = await db.execute('SELECT COUNT(*) FROM t');
    expect(r.rows, [
      [3],
    ]);
  });

  test('autocommit (no BEGIN) still flushes per statement', () async {
    {
      final db = await seeded();
      // No BEGIN — each statement should persist immediately.
      await db.execute("INSERT INTO t VALUES (4, 'd', 40)");
      // Simulate crash: don't call close() / don't COMMIT — but
      // autocommit should already have flushed.
      await db.close();
    }
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    final r = await db.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
      [4],
    ]);
  });
}
