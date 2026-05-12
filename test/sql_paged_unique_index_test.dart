import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// UNIQUE secondary indexes on USING paged tables.
///
/// Validates:
///  - CREATE UNIQUE INDEX rejects existing duplicates and cleans up
///    its half-built sidecar files.
///  - After a successful UNIQUE INDEX, INSERT/UPDATE that would
///    violate it are rejected with StateError.
///  - UPDATE that touches the indexed column on a single row, but
///    keeps the value unique, is allowed (no false self-conflict).
///  - UPDATE that doesn't change the indexed column is allowed (and
///    is unaffected by the unique constraint).
///  - Composite UNIQUE indexes work.
///  - NULL components don't participate in the uniqueness check
///    (multiple NULLs allowed, matching SQLite).
///  - The unique constraint survives close + reopen.
///  - A unique-violation inside a transaction rolls back the
///    transaction cleanly.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_uniq_');
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
        'id INTEGER PRIMARY KEY, email TEXT, age INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a@x', 30)");
    await db.execute("INSERT INTO t VALUES (2, 'b@x', 25)");
    await db.execute("INSERT INTO t VALUES (3, 'c@x', 40)");
    return db;
  }

  test('CREATE UNIQUE INDEX then INSERT duplicate is rejected', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');
    await expectLater(
      db.execute("INSERT INTO t VALUES (4, 'a@x', 99)"),
      throwsA(isA<StateError>()),
    );
    // The PK index must not have an orphan row left behind.
    final all = await db.execute('SELECT id FROM t ORDER BY id');
    expect(all.rows, [
      [1],
      [2],
      [3],
    ]);
  });

  test('CREATE UNIQUE INDEX rejects existing duplicates', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, email TEXT) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a@x')");
    await db.execute("INSERT INTO t VALUES (2, 'a@x')");

    await expectLater(
      db.execute('CREATE UNIQUE INDEX u_email ON t(email)'),
      throwsA(isA<StateError>()),
    );
    // Half-built sidecar files must be gone so the index name is reusable.
    final base = dbPath();
    expect(await File('$base.t.idx_u_email').exists(), isFalse);
    expect(await File('$base.t.idx_u_email.journal').exists(), isFalse);
  });

  test('UPDATE that would collide is rejected, self-update is allowed',
      () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');
    // Collide: try to set row 2's email to row 1's email.
    await expectLater(
      db.execute("UPDATE t SET email = 'a@x' WHERE id = 2"),
      throwsA(isA<StateError>()),
    );
    // Self-update on a non-indexed column is fine.
    await db.execute("UPDATE t SET age = 26 WHERE id = 2");
    // Same-value update on indexed column should not false-fail.
    await db.execute("UPDATE t SET email = 'b@x' WHERE id = 2");
    final r = await db.execute('SELECT id, email, age FROM t ORDER BY id');
    expect(r.rows, [
      [1, 'a@x', 30],
      [2, 'b@x', 26],
      [3, 'c@x', 40],
    ]);
  });

  test('NULL values do not constrain uniqueness', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, email TEXT) USING paged');
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');
    await db.execute('INSERT INTO t (id, email) VALUES (1, NULL)');
    await db.execute('INSERT INTO t (id, email) VALUES (2, NULL)');
    await db.execute('INSERT INTO t (id, email) VALUES (3, NULL)');
    await db.execute("INSERT INTO t (id, email) VALUES (4, 'x')");
    await expectLater(
      db.execute("INSERT INTO t (id, email) VALUES (5, 'x')"),
      throwsA(isA<StateError>()),
    );
    final r = await db.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
      [4],
    ]);
  });

  test('composite UNIQUE index', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, a TEXT, b INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'x', 1)");
    await db.execute("INSERT INTO t VALUES (2, 'x', 2)");
    await db.execute("INSERT INTO t VALUES (3, 'y', 1)");
    await db.execute('CREATE UNIQUE INDEX u_ab ON t(a, b)');
    // OK: same a, different b
    await db.execute("INSERT INTO t VALUES (4, 'x', 3)");
    // Collide: (x, 1) already exists
    await expectLater(
      db.execute("INSERT INTO t VALUES (5, 'x', 1)"),
      throwsA(isA<StateError>()),
    );
  });

  test('UNIQUE survives close + reopen', () async {
    final db1 = await seeded();
    await db1.execute('CREATE UNIQUE INDEX u_email ON t(email)');
    await db1.close();

    final db2 = await Database.open(dbPath());
    addTearDown(() async => db2.close());
    await expectLater(
      db2.execute("INSERT INTO t VALUES (4, 'a@x', 99)"),
      throwsA(isA<StateError>()),
    );
    await db2.execute("INSERT INTO t VALUES (4, 'd@x', 99)");
    final r = await db2.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
      [4],
    ]);
  });

  test('unique violation inside a transaction rolls back', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');

    await db.execute('BEGIN');
    await db.execute("INSERT INTO t VALUES (10, 'new@x', 1)");
    await expectLater(
      db.execute("INSERT INTO t VALUES (11, 'a@x', 2)"),
      throwsA(isA<StateError>()),
    );
    await db.execute('ROLLBACK');

    final r = await db.execute('SELECT id FROM t ORDER BY id');
    expect(r.rows, [
      [1],
      [2],
      [3],
    ]);
  });
}
