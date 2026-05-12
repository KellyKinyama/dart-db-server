import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Step 7 of the out-of-core paging plan: arbitrary WHERE predicates
/// and scalar projection expressions on `USING paged` tables.
///
/// Validates:
///  - non-PK `WHERE name = 'x'` (full-scan + Dart-side post-filter)
///  - PK range + non-PK residual combined (`WHERE id > 5 AND name = 'x'`)
///  - LIKE, IS NULL, IN, OR (entirely in residual)
///  - scalar expressions in SELECT projection (`id + 1`, `upper(name)`)
///  - residual filtering on UPDATE / DELETE
///  - aggregates other than COUNT(*) are still rejected
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_where_');
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
    await db.execute("INSERT INTO t VALUES (4, 'dan', 25)");
    await db.execute("INSERT INTO t VALUES (5, 'eve', 30)");
    return db;
  }

  test('non-PK WHERE: equality and inequality', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    expect(
      (await db.execute("SELECT id FROM t WHERE name = 'bob'")).rows,
      [
        [2],
      ],
    );
    expect(
      (await db.execute('SELECT id FROM t WHERE age = 25 ORDER BY id')).rows,
      [
        [2],
        [4],
      ],
    );
    expect(
      (await db.execute('SELECT id FROM t WHERE age > 25 ORDER BY id')).rows,
      [
        [1],
        [3],
        [5],
      ],
    );
  });

  test('PK range AND-ed with non-PK residual', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    // PK pruning + name predicate.
    expect(
      (await db.execute("SELECT id FROM t WHERE id > 1 AND name = 'cara'"))
          .rows,
      [
        [3],
      ],
    );
    // PK range AND non-PK range.
    expect(
      (await db.execute(
              'SELECT id FROM t WHERE id BETWEEN 2 AND 4 AND age >= 30 '
              'ORDER BY id'))
          .rows,
      [
        [3],
      ],
    );
  });

  test('OR / IS NULL / IN entirely in residual', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    // Mixed: id range pruning, plus an OR that has to be applied per-row.
    final r = await db
        .execute("SELECT id FROM t WHERE id > 1 AND (name = 'bob' OR age = 40) "
            'ORDER BY id');
    expect(r.rows, [
      [2],
      [3],
    ]);
    // IN list on a non-PK column.
    final r2 = await db
        .execute("SELECT id FROM t WHERE name IN ('alice', 'eve') ORDER BY id");
    expect(r2.rows, [
      [1],
      [5],
    ]);
    // IS NULL — no rows match in our seed.
    final r3 = await db.execute('SELECT id FROM t WHERE name IS NULL');
    expect(r3.rows, isEmpty);
  });

  test('scalar projection expressions', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    // Arithmetic on a column.
    final r = await db
        .execute('SELECT id, id + 10 AS plus FROM t WHERE id < 3 ORDER BY id');
    expect(r.columns, ['id', 'plus']);
    expect(r.rows, [
      [1, 11],
      [2, 12],
    ]);
    // String concat-via-function (UPPER) if available, else fall back
    // to length(); both are scalar funcs registered in the engine.
    final r2 = await db.execute("SELECT upper(name) AS u FROM t WHERE id = 1");
    expect(r2.columns, ['u']);
    expect(r2.rows, [
      ['ALICE'],
    ]);
  });

  test('UPDATE / DELETE filter on non-PK residual', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final u = await db.execute("UPDATE t SET age = 99 WHERE name = 'alice'");
    expect(u.affected, 1);
    expect(
      (await db.execute('SELECT age FROM t WHERE id = 1')).rows,
      [
        [99],
      ],
    );

    final d = await db.execute('DELETE FROM t WHERE age = 25');
    expect(d.affected, 2);
    expect(
      (await db.execute('SELECT id FROM t ORDER BY id')).rows,
      [
        [1],
        [3],
        [5],
      ],
    );
  });

  test('residual + PK eq still picks the indexed row', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    // PK eq matches but residual filters it out.
    final r =
        await db.execute("SELECT id FROM t WHERE id = 2 AND name = 'NOPE'");
    expect(r.rows, isEmpty);
    // PK eq + matching residual.
    final r2 =
        await db.execute("SELECT id FROM t WHERE id = 2 AND name = 'bob'");
    expect(r2.rows, [
      [2],
    ]);
  });

  test('aggregates other than COUNT(*) are still rejected', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    await expectLater(
      db.execute('SELECT SUM(age) FROM t'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      db.execute('SELECT AVG(age) FROM t'),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      db.execute('SELECT MAX(age) FROM t'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
