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
}
