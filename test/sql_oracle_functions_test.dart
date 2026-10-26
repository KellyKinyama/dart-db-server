/// Oracle function + SQL-semantics gaps closed in the round-19..22 sweeps:
/// INSTR/TRUNC args, TRANSLATE/ADD_MONTHS/MONTHS_BETWEEN/NEXT_DAY, MOD sign,
/// GREATEST/LEAST NULL propagation, 2-arg REPLACE, ANSI TRIM, LISTAGG WITHIN
/// GROUP, MERGE qualified SET, and ORDER BY a non-projected ROLLUP key.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('INSTR honors start-position and occurrence args', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT INSTR('abcabc', 'a', 2)"), 4);
      expect(await scalar(db, "SELECT INSTR('abcabc', 'c', 1, 2)"), 6);
      expect(await scalar(db, "SELECT INSTR('abcabc', 'a', -1)"), 4);
    } finally {
      await db.close();
    }
  });

  test('TRUNC honors places and truncates dates', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT TRUNC(3.14159, 2)'), 3.14);
      expect(await scalar(db, 'SELECT TRUNC(3.14159)'), 3);
      expect(await scalar(db, "SELECT TRUNC(DATE '2020-06-17')"), '2020-06-17');
    } finally {
      await db.close();
    }
  });

  test('TRANSLATE / ADD_MONTHS / MONTHS_BETWEEN / NEXT_DAY', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TRANSLATE('abc', 'ab', 'xy')"), 'xyc');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(ADD_MONTHS(DATE '2020-01-31', 1), 'YYYY-MM-DD')"),
          '2020-02-29');
      expect(
          await scalar(db,
              "SELECT MONTHS_BETWEEN(DATE '2020-03-01', DATE '2020-01-01')"),
          2);
      expect(
          await scalar(db,
              "SELECT TO_CHAR(NEXT_DAY(DATE '2020-01-01', 'MONDAY'), 'YYYY-MM-DD')"),
          '2020-01-06');
    } finally {
      await db.close();
    }
  });

  test('MOD follows the dividend sign', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT MOD(-10, 3)'), -1);
      expect(await scalar(db, 'SELECT MOD(10, -3)'), 1);
    } finally {
      await db.close();
    }
  });

  test('GREATEST / LEAST propagate NULL', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT GREATEST(1, NULL, 3)'), null);
      expect(await scalar(db, 'SELECT LEAST(1, NULL, 3)'), null);
      expect(await scalar(db, 'SELECT GREATEST(1, 2, 3)'), 3);
    } finally {
      await db.close();
    }
  });

  test('2-argument REPLACE removes the substring', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT REPLACE('abcabc', 'b')"), 'acac');
    } finally {
      await db.close();
    }
  });

  test('ANSI TRIM(chars FROM string)', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TRIM('_' FROM '_ab_')"), 'ab');
      expect(await scalar(db, "SELECT TRIM(LEADING '_' FROM '_ab_')"), 'ab_');
      expect(await scalar(db, "SELECT TRIM(TRAILING '_' FROM '_ab_')"), '_ab');
    } finally {
      await db.close();
    }
  });

  test('LISTAGG ... WITHIN GROUP (ORDER BY ...)', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE s (v NUMBER)');
      await db.execute('INSERT INTO s VALUES (30), (10), (20)');
      expect(
          await scalar(
              db, "SELECT LISTAGG(v, ',') WITHIN GROUP (ORDER BY v) FROM s"),
          '10,20,30');
    } finally {
      await db.close();
    }
  });

  test('ORDER BY a non-projected grouping column under ROLLUP', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE e (dept NUMBER, sal NUMBER)');
      await db.execute('INSERT INTO e VALUES (10, 100), (20, 70)');
      final r = await db.execute(
          'SELECT SUM(sal) FROM e GROUP BY ROLLUP(dept) ORDER BY dept');
      // Three rows (dept 10, dept 20, grand total); ordering must not error.
      expect(r.rows.length, 3);
    } finally {
      await db.close();
    }
  });

  test('MERGE UPDATE SET accepts an alias-qualified target column', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE tgt (id NUMBER, v NUMBER)');
      await db.execute('INSERT INTO tgt VALUES (1, 10)');
      await db.execute('CREATE TABLE src (id NUMBER, v NUMBER)');
      await db.execute('INSERT INTO src VALUES (1, 99)');
      await db.execute('MERGE INTO tgt t USING src s ON (t.id = s.id) '
          'WHEN MATCHED THEN UPDATE SET t.v = s.v');
      expect(await scalar(db, 'SELECT v FROM tgt WHERE id = 1'), 99);
    } finally {
      await db.close();
    }
  });

  group('F94 advanced SQL', () {
    Future<Database> emp() async {
      final db = await Database.open(null);
      await db.execute('CREATE TABLE emp (id NUMBER, mgr NUMBER, '
          'name VARCHAR2(10), dept NUMBER, sal NUMBER)');
      await db.execute("INSERT INTO emp VALUES (1, NULL, 'A', 10, 100)");
      await db.execute("INSERT INTO emp VALUES (2, 1, 'B', 20, 70)");
      return db;
    }

    test('SYS_CONNECT_BY_PATH builds the hierarchy path', () async {
      final db = await emp();
      try {
        final r = await db.execute(
            "SELECT SYS_CONNECT_BY_PATH(name, '/') AS p FROM emp "
            'START WITH mgr IS NULL CONNECT BY PRIOR id = mgr');
        expect(r.rows, [
          ['/A'],
          ['/A/B'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('PIVOT transposes rows to columns', () async {
      final db = await emp();
      try {
        final r = await db.execute('SELECT * FROM (SELECT dept, sal FROM emp) '
            'PIVOT (SUM(sal) FOR dept IN (10, 20))');
        expect(r.columns, ['10', '20']);
        expect(r.rows, [
          [100, 70]
        ]);
      } finally {
        await db.close();
      }
    });

    test('KEEP (DENSE_RANK FIRST/LAST) ordered-set aggregate', () async {
      final db = await emp();
      try {
        expect(
            await scalar(db,
                'SELECT MAX(sal) KEEP (DENSE_RANK FIRST ORDER BY id) FROM emp'),
            100);
        expect(
            await scalar(db,
                'SELECT MAX(sal) KEEP (DENSE_RANK LAST ORDER BY id) FROM emp'),
            70);
      } finally {
        await db.close();
      }
    });
  });
}
