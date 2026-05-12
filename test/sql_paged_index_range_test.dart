import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Step 9 of the out-of-core paging plan: range queries on indexed
/// non-PK columns. The secondary-index key encoding is now byte-order-
/// preserving, so `WHERE col < x`, `> x`, `BETWEEN`, etc. can be served
/// by an index range-scan instead of a full table scan.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_idxrng_');
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
    await db.execute("INSERT INTO t VALUES (4, 'dan', 33)");
    await db.execute("INSERT INTO t VALUES (5, 'eve', 22)");
    await db.execute("INSERT INTO t VALUES (6, 'frank', 50)");
    await db.execute('CREATE INDEX idx_age ON t(age)');
    await db.execute('CREATE INDEX idx_name ON t(name)');
    return db;
  }

  test('integer range: age > 30', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT id FROM t WHERE age > 30 ORDER BY id');
    expect(r.rows, [
      [3],
      [4],
      [6],
    ]);
  });

  test('integer range: age >= 30', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT id FROM t WHERE age >= 30 ORDER BY id');
    expect(r.rows, [
      [1],
      [3],
      [4],
      [6],
    ]);
  });

  test('integer range: age < 30', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT id FROM t WHERE age < 30 ORDER BY id');
    expect(r.rows, [
      [2],
      [5],
    ]);
  });

  test('integer two-sided range: age > 25 AND age <= 40', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db
        .execute('SELECT id FROM t WHERE age > 25 AND age <= 40 ORDER BY id');
    expect(r.rows, [
      [1],
      [3],
      [4],
    ]);
  });

  test('text range: name > "c"', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute("SELECT id FROM t WHERE name > 'c' ORDER BY id");
    expect(r.rows, [
      [3],
      [4],
      [5],
      [6],
    ]);
  });

  test('text range with different lengths preserves dictionary order',
      () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE w ('
        'id INTEGER PRIMARY KEY, name TEXT) USING paged');
    // Names with varying lengths: "a" must sort before "ab" must sort
    // before "b" must sort before "ba". A naive length-prefixed
    // encoding gets this wrong.
    await db.execute("INSERT INTO w VALUES (1, 'a')");
    await db.execute("INSERT INTO w VALUES (2, 'ab')");
    await db.execute("INSERT INTO w VALUES (3, 'b')");
    await db.execute("INSERT INTO w VALUES (4, 'ba')");
    await db.execute("INSERT INTO w VALUES (5, 'z')");
    await db.execute('CREATE INDEX idx_n ON w(name)');

    // Everything strictly less than 'b' is just 'a' and 'ab'.
    final r1 =
        await db.execute("SELECT id FROM w WHERE name < 'b' ORDER BY id");
    expect(r1.rows, [
      [1],
      [2],
    ]);
    // BETWEEN 'ab' AND 'ba' inclusive: 'ab','b','ba'.
    final r2 = await db.execute(
        "SELECT id FROM w WHERE name >= 'ab' AND name <= 'ba' ORDER BY id");
    expect(r2.rows, [
      [2],
      [3],
      [4],
    ]);
  });

  test('range plan with extra residual still filters correctly', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    // age > 25 chooses the idx_age range, but name LIKE 'a%' is a
    // residual conjunct re-applied per row. Only alice (id=1) matches.
    final r = await db.execute(
        "SELECT id FROM t WHERE age > 25 AND name LIKE 'a%' ORDER BY id");
    expect(r.rows, [
      [1],
    ]);
  });
}
