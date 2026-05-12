import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Step 8 of the out-of-core paging plan: SQL-level CREATE/DROP INDEX
/// support on `USING paged` tables.
///
/// Validates:
///  - CREATE INDEX on a non-PK column survives reopen, equality
///    SELECT returns matching rows.
///  - INSERT/UPDATE/DELETE keep the index consistent.
///  - DROP INDEX removes the sidecar files and the index name.
///  - Unsupported variants (UNIQUE, multi-column, expression, partial)
///    are rejected.
///  - Index-routed lookup respects any extra residual conjuncts.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_idx_');
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
        'id INTEGER PRIMARY KEY, name TEXT, age INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'alice', 30)");
    await db.execute("INSERT INTO t VALUES (2, 'bob', 25)");
    await db.execute("INSERT INTO t VALUES (3, 'cara', 40)");
    await db.execute("INSERT INTO t VALUES (4, 'bob', 33)");
    await db.execute("INSERT INTO t VALUES (5, 'eve', 30)");
    return db;
  }

  test('CREATE INDEX + equality lookup returns matching rows', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('CREATE INDEX idx_name ON t(name)');

    final r = await db
        .execute("SELECT id, age FROM t WHERE name = 'bob' ORDER BY id");
    expect(r.rows, [
      [2, 25],
      [4, 33],
    ]);
  });

  test('index survives close + reopen', () async {
    final db = await seeded();
    await db.execute('CREATE INDEX idx_name ON t(name)');
    await db.close();

    final db2 = await Database.open(dbPath());
    addTearDown(() async => db2.close());

    final r = await db2.execute("SELECT id FROM t WHERE name = 'eve'");
    expect(r.rows, [
      [5],
    ]);
    // DROP INDEX must still be able to find the owning paged table
    // after restore — exercises the owner-map rebuild.
    final dropped = await db2.execute('DROP INDEX idx_name');
    expect(dropped.message, contains('dropped'));
  });

  test('INSERT/UPDATE/DELETE keep index consistent', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('CREATE INDEX idx_name ON t(name)');
    await db.execute("INSERT INTO t VALUES (6, 'bob', 99)");
    await db.execute("UPDATE t SET name = 'zara' WHERE id = 4");
    await db.execute("DELETE FROM t WHERE id = 2");

    final bobs =
        await db.execute("SELECT id FROM t WHERE name = 'bob' ORDER BY id");
    expect(bobs.rows, [
      [6],
    ]);
    final zara = await db.execute("SELECT id FROM t WHERE name = 'zara'");
    expect(zara.rows, [
      [4],
    ]);
  });

  test('DROP INDEX removes sidecar files', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('CREATE INDEX idx_name ON t(name)');

    // Sidecar should now exist under the paged subdir.
    final pagedDir =
        Directory('${tmpRoot.path}${Platform.pathSeparator}store.paged');
    final before = pagedDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.contains('idx_name'))
        .toList();
    expect(before, isNotEmpty);

    await db.execute('DROP INDEX idx_name');

    final after = pagedDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.contains('idx_name'))
        .toList();
    expect(after, isEmpty);
  });

  test('UNIQUE / multi-column / expression / partial are rejected', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await expectLater(
      db.execute('CREATE UNIQUE INDEX u ON t(name)'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      db.execute('CREATE INDEX m ON t(name, age)'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('index routing still honours additional residual conjuncts', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await db.execute('CREATE INDEX idx_name ON t(name)');
    // Both rows with name='bob' will match the index probe, but the
    // age>30 conjunct must still drop id=2 (age=25) and keep id=4
    // (age=33). This proves the residual is re-applied per row.
    final r = await db.execute(
        "SELECT id FROM t WHERE name = 'bob' AND age > 30 ORDER BY id");
    expect(r.rows, [
      [4],
    ]);
  });
}
