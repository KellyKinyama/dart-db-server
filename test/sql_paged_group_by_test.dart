import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Step 11 of the out-of-core paging plan: GROUP BY and non-COUNT
/// aggregates on `USING paged` tables.
void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_agg_');
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
        'id INTEGER PRIMARY KEY, dept TEXT, salary INTEGER) USING paged');
    await db.execute("INSERT INTO t VALUES (1, 'eng', 100)");
    await db.execute("INSERT INTO t VALUES (2, 'eng', 120)");
    await db.execute("INSERT INTO t VALUES (3, 'eng', 110)");
    await db.execute("INSERT INTO t VALUES (4, 'sales', 80)");
    await db.execute("INSERT INTO t VALUES (5, 'sales', 90)");
    await db.execute("INSERT INTO t VALUES (6, 'hr', 70)");
    return db;
  }

  test('scalar aggregates with no GROUP BY', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute(
        'SELECT COUNT(*), SUM(salary), AVG(salary), MIN(salary), MAX(salary) FROM t');
    expect(r.rows, [
      [6, 570, 95.0, 70, 120],
    ]);
  });

  test('GROUP BY single column with COUNT and SUM', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute(
        'SELECT dept, COUNT(*), SUM(salary) FROM t GROUP BY dept ORDER BY dept');
    expect(r.rows, [
      ['eng', 3, 330],
      ['hr', 1, 70],
      ['sales', 2, 170],
    ]);
  });

  test('GROUP BY + HAVING filters groups', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute(
        'SELECT dept, AVG(salary) FROM t GROUP BY dept HAVING AVG(salary) > 80 ORDER BY dept');
    expect(r.rows, [
      ['eng', 110.0],
      ['sales', 85.0],
    ]);
  });

  test('ORDER BY aggregate expression DESC', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT dept, SUM(salary) AS total '
        'FROM t GROUP BY dept ORDER BY total DESC');
    expect(r.rows, [
      ['eng', 330],
      ['sales', 170],
      ['hr', 70],
    ]);
  });

  test('GROUP BY combined with WHERE filtering', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute(
        'SELECT dept, COUNT(*) FROM t WHERE salary >= 90 GROUP BY dept ORDER BY dept');
    expect(r.rows, [
      ['eng', 3],
      ['sales', 1],
    ]);
  });

  test('COUNT(DISTINCT col)', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT COUNT(DISTINCT dept) FROM t');
    expect(r.rows, [
      [3],
    ]);
  });

  test('aggregate + LIMIT after sort', () async {
    final db = await seeded();
    addTearDown(() async => db.close());

    final r = await db.execute('SELECT dept, SUM(salary) AS total '
        'FROM t GROUP BY dept ORDER BY total DESC LIMIT 2');
    expect(r.rows, [
      ['eng', 330],
      ['sales', 170],
    ]);
  });
}
