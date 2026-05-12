import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Step 12 of the out-of-core paging plan: joins involving paged
/// tables. Paged participants are snapshotted into transient in-memory
/// tables for the duration of the query; correctness over the regular
/// executor's full join surface.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_join_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  Future<Database> seeded() async {
    final db = await Database.open(dbPath());
    // Paged "employees" table.
    await db.execute('CREATE TABLE emp ('
        'id INTEGER PRIMARY KEY, name TEXT, dept_id INTEGER) USING paged');
    await db.execute("INSERT INTO emp VALUES (1, 'alice', 10)");
    await db.execute("INSERT INTO emp VALUES (2, 'bob', 20)");
    await db.execute("INSERT INTO emp VALUES (3, 'cara', 10)");
    await db.execute("INSERT INTO emp VALUES (4, 'dan', 30)");
    // In-memory "departments" table.
    await db.execute('CREATE TABLE dept (id INTEGER PRIMARY KEY, name TEXT)');
    await db.execute("INSERT INTO dept VALUES (10, 'eng')");
    await db.execute("INSERT INTO dept VALUES (20, 'sales')");
    await db.execute("INSERT INTO dept VALUES (40, 'hr')");
    return db;
  }

  test('INNER JOIN: paged FROM + in-memory side', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT emp.name, dept.name FROM emp '
        'INNER JOIN dept ON emp.dept_id = dept.id ORDER BY emp.id');
    expect(r.rows, [
      ['alice', 'eng'],
      ['bob', 'sales'],
      ['cara', 'eng'],
    ]);
  });

  test('LEFT JOIN keeps unmatched paged rows', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT emp.name, dept.name FROM emp '
        'LEFT JOIN dept ON emp.dept_id = dept.id ORDER BY emp.id');
    expect(r.rows, [
      ['alice', 'eng'],
      ['bob', 'sales'],
      ['cara', 'eng'],
      ['dan', null],
    ]);
  });

  test('JOIN of two paged tables', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE a ('
        'id INTEGER PRIMARY KEY, name TEXT) USING paged');
    await db.execute('CREATE TABLE b ('
        'id INTEGER PRIMARY KEY, aid INTEGER, label TEXT) USING paged');
    await db.execute("INSERT INTO a VALUES (1, 'one')");
    await db.execute("INSERT INTO a VALUES (2, 'two')");
    await db.execute("INSERT INTO b VALUES (10, 1, 'x')");
    await db.execute("INSERT INTO b VALUES (11, 1, 'y')");
    await db.execute("INSERT INTO b VALUES (12, 2, 'z')");

    final r = await db.execute('SELECT a.name, b.label FROM a '
        'INNER JOIN b ON a.id = b.aid ORDER BY b.id');
    expect(r.rows, [
      ['one', 'x'],
      ['one', 'y'],
      ['two', 'z'],
    ]);
  });

  test('in-memory FROM joined against paged table', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT dept.name, COUNT(*) FROM dept '
        'INNER JOIN emp ON dept.id = emp.dept_id '
        'GROUP BY dept.name ORDER BY dept.name');
    expect(r.rows, [
      ['eng', 2],
      ['sales', 1],
    ]);
  });

  test('paged participant is not polluted with the snapshot', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    // Run a join.
    await db.execute('SELECT emp.id FROM emp '
        'INNER JOIN dept ON emp.dept_id = dept.id');
    // The paged-table SELECT path still works afterwards (the
    // snapshot must have been torn down).
    final r = await db.execute('SELECT COUNT(*) FROM emp');
    expect(r.rows, [
      [4],
    ]);
    // And a fresh CREATE TABLE under the same name (after dropping)
    // works — the snapshot was not leaked into _tables.
    await db.execute('DROP TABLE emp');
    await db.execute('CREATE TABLE emp (id INTEGER PRIMARY KEY) USING paged');
  });

  // ---------------------------------------------------------------------------
  // Equi-join pre-filter (paged side restricted to in-memory build keys).
  // ---------------------------------------------------------------------------

  test('pre-filter via primary-key lookup on paged side', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute(
        'CREATE TABLE big (id INTEGER PRIMARY KEY, v TEXT) USING paged');
    // 100 paged rows — only 3 will be relevant after the join.
    for (var i = 1; i <= 100; i++) {
      await db.execute("INSERT INTO big VALUES ($i, 'r$i')");
    }
    await db.execute('CREATE TABLE picks (k INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO picks VALUES (7)');
    await db.execute('INSERT INTO picks VALUES (42)');
    await db.execute('INSERT INTO picks VALUES (99)');

    final r = await db.execute('SELECT big.id, big.v FROM big '
        'INNER JOIN picks ON big.id = picks.k ORDER BY big.id');
    expect(r.rows, [
      [7, 'r7'],
      [42, 'r42'],
      [99, 'r99'],
    ]);
  });

  test('pre-filter via secondary-index lookup on paged side', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE big '
        '(id INTEGER PRIMARY KEY, tag TEXT) USING paged');
    for (var i = 1; i <= 50; i++) {
      final tag = (i % 5 == 0)
          ? 'x'
          : (i % 5 == 1)
              ? 'y'
              : 'z';
      await db.execute("INSERT INTO big VALUES ($i, '$tag')");
    }
    await db.execute('CREATE INDEX big_tag ON big(tag)');
    await db.execute('CREATE TABLE picks (k TEXT PRIMARY KEY)');
    await db.execute("INSERT INTO picks VALUES ('x')");

    final r = await db.execute('SELECT big.id FROM big '
        'INNER JOIN picks ON big.tag = picks.k ORDER BY big.id');
    // tag='x' fires for i in {5,10,15,...,50}.
    expect(r.rows, [
      for (var i = 5; i <= 50; i += 5) [i],
    ]);
  });

  test('pre-filter via filtered scan when no index on paged column', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE big '
        '(id INTEGER PRIMARY KEY, label TEXT) USING paged');
    for (var i = 1; i <= 20; i++) {
      await db.execute("INSERT INTO big VALUES ($i, 'L${i % 4}')");
    }
    await db.execute('CREATE TABLE picks (k TEXT PRIMARY KEY)');
    await db.execute("INSERT INTO picks VALUES ('L1')");
    await db.execute("INSERT INTO picks VALUES ('L3')");

    final r = await db.execute('SELECT big.id FROM big '
        'INNER JOIN picks ON big.label = picks.k ORDER BY big.id');
    // i%4==1 → 1,5,9,13,17; i%4==3 → 3,7,11,15,19.
    expect(r.rows, [
      for (final i in [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]) [i],
    ]);
  });

  test('pre-filter handles empty in-memory build side', () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE big (id INTEGER PRIMARY KEY) USING paged');
    for (var i = 1; i <= 10; i++) {
      await db.execute('INSERT INTO big VALUES ($i)');
    }
    await db.execute('CREATE TABLE picks (k INTEGER PRIMARY KEY)');

    final r = await db.execute('SELECT big.id FROM big '
        'INNER JOIN picks ON big.id = picks.k');
    expect(r.rows, isEmpty);
  });

  test('LEFT JOIN bypasses pre-filter and keeps unmatched paged rows',
      () async {
    final db = await Database.open(dbPath());
    addTearDown(() async => db.close());
    await db.execute('CREATE TABLE big (id INTEGER PRIMARY KEY) USING paged');
    for (var i = 1; i <= 5; i++) {
      await db.execute('INSERT INTO big VALUES ($i)');
    }
    await db.execute('CREATE TABLE picks (k INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO picks VALUES (3)');

    final r = await db.execute('SELECT big.id, picks.k FROM big '
        'LEFT JOIN picks ON big.id = picks.k ORDER BY big.id');
    expect(r.rows, [
      [1, null],
      [2, null],
      [3, 3],
      [4, null],
      [5, null],
    ]);
  });
}
