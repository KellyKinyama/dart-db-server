/// Tests Oracle's `ROWNUM` pseudo-column used as a WHERE-clause row limiter,
/// and the SQL-standard `FETCH FIRST ... ROWS ONLY` without a preceding
/// `ORDER BY`.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    for (var i = 1; i <= 5; i++) {
      await db.execute("INSERT INTO t VALUES ($i, 'n$i')");
    }
  });

  Future<List<Object?>> ids(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.first).toList();

  test('ROWNUM <= n limits the result', () async {
    expect(await ids('SELECT id FROM t WHERE ROWNUM <= 3'), [1, 2, 3]);
    expect(await ids('SELECT id FROM t WHERE ROWNUM <= 0'), isEmpty);
    expect(await ids('SELECT id FROM t WHERE ROWNUM <= 99'), [1, 2, 3, 4, 5]);
  });

  test('ROWNUM < n limits to n-1', () async {
    expect(await ids('SELECT id FROM t WHERE ROWNUM < 3'), [1, 2]);
    expect(await ids('SELECT id FROM t WHERE ROWNUM < 1'), isEmpty);
  });

  test('ROWNUM = 1 returns the first row; = n (n>1) returns nothing', () async {
    expect(await ids('SELECT id FROM t WHERE ROWNUM = 1'), [1]);
    expect(await ids('SELECT id FROM t WHERE ROWNUM = 2'), isEmpty);
  });

  test('ROWNUM > n / >= n (n>1) is unsatisfiable', () async {
    expect(await ids('SELECT id FROM t WHERE ROWNUM > 1'), isEmpty);
    expect(await ids('SELECT id FROM t WHERE ROWNUM >= 2'), isEmpty);
  });

  test('always-true ROWNUM predicates drop out', () async {
    expect(await ids('SELECT id FROM t WHERE ROWNUM >= 1'), [1, 2, 3, 4, 5]);
    expect(await ids('SELECT id FROM t WHERE ROWNUM > 0'), [1, 2, 3, 4, 5]);
  });

  test('reversed form n >= ROWNUM', () async {
    expect(await ids('SELECT id FROM t WHERE 3 >= ROWNUM'), [1, 2, 3]);
    expect(await ids('SELECT id FROM t WHERE 2 > ROWNUM'), [1]);
  });

  test('ROWNUM combines with other predicates via AND', () async {
    expect(
      await ids("SELECT id FROM t WHERE name <> 'n1' AND ROWNUM <= 2"),
      [2, 3],
    );
  });

  test('ROWNUM is case-insensitive', () async {
    expect(await ids('SELECT id FROM t WHERE rownum <= 2'), [1, 2]);
  });

  test('top-N: inner ORDER BY, outer ROWNUM limit', () async {
    // Classic Oracle top-N idiom: order inside a subquery, then cap with ROWNUM.
    final rows = await ids(
      'SELECT id FROM (SELECT id FROM t ORDER BY id DESC) WHERE ROWNUM <= 2',
    );
    expect(rows, [5, 4]);
  });

  test('ROWNUM limit tightens an explicit FETCH FIRST', () async {
    // The smaller of the two bounds wins.
    expect(
      await ids('SELECT id FROM t WHERE ROWNUM <= 2 FETCH FIRST 4 ROWS ONLY'),
      [1, 2],
    );
  });

  test('FETCH FIRST n ROWS ONLY without ORDER BY', () async {
    expect(await ids('SELECT id FROM t FETCH FIRST 2 ROWS ONLY'), [1, 2]);
    expect(await ids('SELECT id FROM t FETCH FIRST 1 ROW ONLY'), [1]);
  });

  test('ROWNUM in the SELECT list numbers output rows', () async {
    final r = await db.execute('SELECT ROWNUM, name FROM t');
    expect(r.rows.map((x) => x.toList()).toList(), [
      [1, 'n1'],
      [2, 'n2'],
      [3, 'n3'],
      [4, 'n4'],
      [5, 'n5'],
    ]);
  });

  test('ROWNUM in the SELECT list can be aliased and limited', () async {
    final r = await db.execute('SELECT ROWNUM rn, name FROM t WHERE ROWNUM <= 3');
    expect(r.columns.first, 'rn');
    expect(r.rows.map((x) => x.toList()).toList(), [
      [1, 'n1'],
      [2, 'n2'],
      [3, 'n3'],
    ]);
  });

  test('ROWNUM is assigned before the final ORDER BY (Oracle order)', () async {
    // Oracle assigns ROWNUM during the scan, before sorting, so after an
    // ORDER BY the numbers appear in the pre-sort order.
    final r = await db.execute('SELECT ROWNUM, name FROM t ORDER BY name DESC');
    expect(r.rows.map((x) => x.toList()).toList(), [
      [5, 'n5'],
      [4, 'n4'],
      [3, 'n3'],
      [2, 'n2'],
      [1, 'n1'],
    ]);
  });

  test('pagination idiom: ROWNUM in a subquery, filtered in the outer', () async {
    final r = await db.execute(
      'SELECT name FROM (SELECT name, ROWNUM rn FROM t) WHERE rn BETWEEN 2 AND 4',
    );
    expect(r.rows.map((x) => x.first).toList(), ['n2', 'n3', 'n4']);
  });

  test('ROWNUM nested inside a larger scalar expression', () async {
    expect(
      (await db.execute("SELECT 'row ' || ROWNUM FROM t WHERE id <= 3"))
          .rows
          .map((x) => x.first)
          .toList(),
      ['row 1', 'row 2', 'row 3'],
    );
    expect(
      (await db.execute('SELECT ROWNUM * 10 FROM t WHERE id <= 3'))
          .rows
          .map((x) => x.first)
          .toList(),
      [10, 20, 30],
    );
  });

  test('ROWNUM in CASE and alongside a bare ROWNUM', () async {
    final r = await db.execute(
      "SELECT ROWNUM, 'r' || ROWNUM, "
      'CASE WHEN ROWNUM = 1 THEN name END FROM t WHERE id <= 3',
    );
    expect(r.rows.map((x) => x.toList()).toList(), [
      [1, 'r1', 'n1'],
      [2, 'r2', null],
      [3, 'r3', null],
    ]);
  });

  test('explicit window function nested in an expression', () async {
    final r = await db.execute(
      'SELECT name, ROW_NUMBER() OVER (ORDER BY id DESC) + 100 FROM t '
      'WHERE id <= 3',
    );
    expect(r.rows.map((x) => x.toList()).toList(), [
      ['n1', 103],
      ['n2', 102],
      ['n3', 101],
    ]);
  });
}

