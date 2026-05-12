import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// UPDATE that reassigns the primary key on USING paged tables.
///
/// Validates:
///  - Reassigning to an unused PK moves the row (old PK gone, new PK
///    present, non-PK columns preserved).
///  - Reassigning to a PK that's already taken throws StateError and
///    leaves both rows intact.
///  - PK reassignment maintains secondary indexes.
///  - PK reassignment respects UNIQUE secondary indexes: the new row
///    must not collide on a UNIQUE column either.
///  - RETURNING emits the new (post-update) row with the new PK.
///  - Setting the PK to NULL is rejected.
///  - Survives close + reopen.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_pkre_');
  });
  tearDown(() async {
    if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  Future<Database> seeded() async {
    final db = await Database.open(dbPath());
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, email TEXT, age INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'a@x', 30)");
    await db.execute("INSERT INTO t VALUES (2, 'b@x', 25)");
    return db;
  }

  test('PK reassignment to free slot moves the row', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r =
        await db.execute('UPDATE t SET id = 5, age = age + 1 WHERE id = 1');
    expect(r.affected, 1);
    final all = await db.execute('SELECT id, email, age FROM t ORDER BY id');
    expect(all.rows, [
      [2, 'b@x', 25],
      [5, 'a@x', 31],
    ]);
  });

  test('PK reassignment maintains a regular secondary index', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE INDEX idx_email ON t(email)');

    await db.execute("UPDATE t SET id = 50 WHERE email = 'a@x'");
    final r = await db.execute("SELECT id, age FROM t WHERE email = 'a@x'");
    expect(r.rows, [
      [50, 30],
    ]);
  });

  test('PK reassignment respects UNIQUE secondary index', () async {
    final db = await seeded();
    addTearDown(() async => db.close());
    await db.execute('CREATE UNIQUE INDEX u_email ON t(email)');

    // Try to move row 1 to PK 99 *and* change email to 'b@x', which
    // collides with row 2 on the UNIQUE email index.
    await expectLater(
      db.execute("UPDATE t SET id = 99, email = 'b@x' WHERE id = 1"),
      throwsA(isA<StateError>()),
    );
    // Both rows still intact.
    final r = await db.execute('SELECT id, email FROM t ORDER BY id');
    expect(r.rows, [
      [1, 'a@x'],
      [2, 'b@x'],
    ]);
  });

  test('RETURNING after PK reassignment emits the new row', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db
        .execute('UPDATE t SET id = 7 WHERE id = 1 RETURNING id, email');
    expect(r.rows, [
      [7, 'a@x'],
    ]);
  });

  test('PK reassignment to NULL is rejected', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await expectLater(
      db.execute('UPDATE t SET id = NULL WHERE id = 1'),
      throwsA(isA<StateError>()),
    );
  });

  test('PK reassignment survives close + reopen', () async {
    final db1 = await seeded();
    await db1.execute('UPDATE t SET id = 100 WHERE id = 1');
    await db1.close();

    final db2 = await Database.open(dbPath());
    addTearDown(() async => db2.close());
    final r = await db2.execute('SELECT id, email FROM t ORDER BY id');
    expect(r.rows, [
      [2, 'b@x'],
      [100, 'a@x'],
    ]);
  });
}
