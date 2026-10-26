/// Oracle straggler gaps closed in the round-29..31 sweeps: q-quote literals,
/// RETURNING INTO, UNPIVOT, PL/SQL collection types / BULK COLLECT, ROWNUM in
/// UPDATE, the MODEL clause, nested aggregates, exact-decimal NUMBER rounding,
/// and fixed-length CHAR blank-padding.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('q-quote string literals', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT q'[it's a test]'"), "it's a test");
      expect(await scalar(db, "SELECT q'{a{b}'"), 'a{b');
      expect(await scalar(db, "SELECT q'!plain!'"), 'plain');
    } finally {
      await db.close();
    }
  });

  test('DML RETURNING ... INTO in a PL/SQL block', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER, v NUMBER)');
      await db.execute('DECLARE x NUMBER; BEGIN INSERT INTO t VALUES (1, 99) '
          'RETURNING v INTO x; END;');
      expect(await scalar(db, 'SELECT v FROM t'), 99);
    } finally {
      await db.close();
    }
  });

  test('UNPIVOT turns columns into rows', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE s (id NUMBER, a NUMBER, b NUMBER)');
      await db.execute('INSERT INTO s VALUES (1, 10, 20)');
      final r = await db.execute(
          'SELECT col, val FROM s UNPIVOT (val FOR col IN (a, b))');
      final rows = {for (final row in r.rows) row[0]: row[1]};
      expect(rows['a'], 10);
      expect(rows['b'], 20);
    } finally {
      await db.close();
    }
  });

  test('PL/SQL TYPE … IS TABLE OF + BULK COLLECT', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE src (n NUMBER)');
      await db.execute('INSERT INTO src VALUES (5), (7)');
      await db.execute('DECLARE TYPE nt IS TABLE OF NUMBER; a nt; '
          'BEGIN SELECT n BULK COLLECT INTO a FROM src; END;');
    } finally {
      await db.close();
    }
  });

  test('ROWNUM in UPDATE ... SET numbers the rows', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER, v NUMBER)');
      await db.execute('INSERT INTO t VALUES (1, 0), (2, 0)');
      await db.execute('UPDATE t SET v = ROWNUM');
      final r = await db.execute('SELECT v FROM t ORDER BY id');
      expect(r.rows.map((e) => e.first).toList(), [1, 2]);
    } finally {
      await db.close();
    }
  });

  test('MODEL clause is tolerated (parse-and-discard)', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE s (y NUMBER, v NUMBER)');
      await db.execute('INSERT INTO s VALUES (2020, 100)');
      final r = await db.execute('SELECT y, v FROM s MODEL DIMENSION BY (y) '
          'MEASURES (v) RULES (v[2021] = v[2020] * 2)');
      expect(r.rows, isNotEmpty);
    } finally {
      await db.close();
    }
  });

  test('nested aggregate MAX(MIN(x)) over GROUP BY', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (d NUMBER, s NUMBER)');
      await db.execute('INSERT INTO t VALUES (1,10),(1,30),(2,20),(2,40)');
      expect(await scalar(db, 'SELECT MAX(MIN(s)) FROM t GROUP BY d'), 20);
      expect(await scalar(db, 'SELECT MIN(MAX(s)) FROM t GROUP BY d'), 30);
    } finally {
      await db.close();
    }
  });

  test('NUMBER(p,s) uses exact-decimal half-up rounding', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (v NUMBER(10,2))');
      await db.execute('INSERT INTO t VALUES (1.005)');
      expect(await scalar(db, 'SELECT v FROM t'), 1.01);
    } finally {
      await db.close();
    }
  });

  test('CHAR(n) blank-pads to the declared length', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (v CHAR(5))');
      await db.execute("INSERT INTO t VALUES ('ab')");
      expect(await scalar(db, 'SELECT LENGTH(v) FROM t'), 5);
    } finally {
      await db.close();
    }
  });

  test('HEXTORAW / RAWTOHEX round-trip', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT RAWTOHEX(HEXTORAW('DEADBEEF'))"),
          'DEADBEEF');
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR fractional-seconds format FF[n]', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (ts TIMESTAMP(3))');
      await db.execute(
          "INSERT INTO t VALUES (TIMESTAMP '2021-06-15 13:45:30.123')");
      expect(await scalar(db, "SELECT TO_CHAR(ts, 'FF3') FROM t"), '123');
    } finally {
      await db.close();
    }
  });

  test('INTERVAL column types parse', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (v INTERVAL DAY TO SECOND)');
      await db.execute('CREATE TABLE u (w INTERVAL YEAR TO MONTH)');
    } finally {
      await db.close();
    }
  });

  test('NUMBER(p, -s) negative scale rounds left of the point', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (v NUMBER(5,-2))');
      await db.execute('INSERT INTO t VALUES (12345)');
      expect(await scalar(db, 'SELECT v FROM t'), 12300);
    } finally {
      await db.close();
    }
  });
}
