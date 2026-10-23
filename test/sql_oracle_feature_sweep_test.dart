/// Oracle feature-sweep gaps closed in the round-40 sweep: ROUND(date, fmt),
/// TO_CHAR hex format, JSON_OBJECT KEY/VALUE syntax, REMAINDER, STATS_MODE.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('ROUND(date, fmt) applies the date rounding model', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(ROUND(DATE '2024-07-20','MONTH'),'YYYY-MM-DD')"),
          '2024-08-01');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(ROUND(DATE '2024-07-10','MONTH'),'YYYY-MM-DD')"),
          '2024-07-01');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(ROUND(DATE '2024-09-15','YYYY'),'YYYY-MM-DD')"),
          '2025-01-01');
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR(number, hex fmt) emits uppercase hex', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(255,'FMXXX')"), 'FF');
    } finally {
      await db.close();
    }
  });

  test('JSON_OBJECT with KEY ... VALUE syntax', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT JSON_OBJECT('k' VALUE 1)"), '{"k":1}');
      expect(await scalar(db, "SELECT JSON_OBJECT(KEY 'a' VALUE 1, 'b' VALUE 2)"),
          '{"a":1,"b":2}');
    } finally {
      await db.close();
    }
  });

  test('REMAINDER rounds the quotient (unlike MOD)', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT REMAINDER(17, 6)'), -1);
      expect(await scalar(db, 'SELECT MOD(17, 6)'), 5);
    } finally {
      await db.close();
    }
  });

  test('STATS_MODE returns the most frequent value', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (d NUMBER)');
      await db.execute('INSERT INTO t VALUES (50), (50), (60), (90)');
      expect(await scalar(db, 'SELECT STATS_MODE(d) FROM t'), 50);
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR(date) week / Julian / day-of-year elements', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','WW')"), '29');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','J')"),
          '2460512');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-01-01','DDD')"), '001');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','DDD')"), '202');
    } finally {
      await db.close();
    }
  });

  test('JSON_EXISTS predicate', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db, "SELECT CASE WHEN JSON_EXISTS('{\"a\":1}', '\$.a') "
              'THEN 1 ELSE 0 END'),
          1);
      expect(
          await scalar(db, "SELECT CASE WHEN JSON_EXISTS('{\"a\":1}', '\$.b') "
              'THEN 1 ELSE 0 END'),
          0);
    } finally {
      await db.close();
    }
  });

  test('JSON_VALUE with a RETURNING clause', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db, "SELECT JSON_VALUE('{\"n\":12.5}', '\$.n' RETURNING NUMBER)"),
          12.5);
    } finally {
      await db.close();
    }
  });

  test('VSIZE reports the internal storage size', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT VSIZE(123)'), 3);
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR number Roman numeral + date CC/quoted text', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(2024,'FMRN')"), 'MMXXIV');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','CC')"), '21');
      expect(
          await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','YYYY\"x\"MM')"),
          '2024x07');
    } finally {
      await db.close();
    }
  });

  test('REGEXP_SUBSTR subexpression argument', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT REGEXP_SUBSTR('abc123def','([a-z]+)([0-9]+)',1,1,NULL,2)"),
          '123');
    } finally {
      await db.close();
    }
  });

  test('LISTAGG default separator is empty', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (s VARCHAR2(10))');
      await db.execute("INSERT INTO t VALUES ('a'), ('b'), ('c')");
      expect(
          await scalar(db, 'SELECT LISTAGG(s) WITHIN GROUP (ORDER BY s) FROM t'),
          'abc');
    } finally {
      await db.close();
    }
  });

  test('LEAD IGNORE NULLS skips NULL rows', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER, v NUMBER)');
      await db.execute('INSERT INTO t VALUES (1, 10), (2, NULL), (3, 30)');
      final r = await db.execute(
          'SELECT LEAD(v) IGNORE NULLS OVER (ORDER BY id) FROM t '
          'FETCH FIRST 1 ROW ONLY');
      expect(r.rows.first.first, 30);
    } finally {
      await db.close();
    }
  });

  test('CAST enforces NUMBER scale and VARCHAR2 length', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT CAST(123.456 AS NUMBER(5,1))'), 123.5);
      expect(await scalar(db, "SELECT CAST('abc' AS VARCHAR2(2))"), 'ab');
    } finally {
      await db.close();
    }
  });

  test('APPROX_COUNT_DISTINCT counts distinct values', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (d NUMBER)');
      await db.execute('INSERT INTO t VALUES (10), (10), (20), (30)');
      expect(await scalar(db, 'SELECT APPROX_COUNT_DISTINCT(d) FROM t'), 3);
    } finally {
      await db.close();
    }
  });

  test('EXTRACT from an INTERVAL literal', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT EXTRACT(HOUR FROM INTERVAL '2 03:04:05' DAY TO SECOND)"),
          3);
    } finally {
      await db.close();
    }
  });

  test('TRUNC(date, IW) starts the ISO week on Monday', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TRUNC(DATE '2024-07-20','IW'),'YYYY-MM-DD')"),
          '2024-07-15');
    } finally {
      await db.close();
    }
  });

  test('LEVEL and CONNECT_BY_ISCYCLE in a hierarchy', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE emp (id NUMBER, mgr NUMBER)');
      await db.execute('INSERT INTO emp VALUES (1, NULL), (2, 1), (3, 2)');
      expect(
          await scalar(db,
              'SELECT COUNT(*) FROM emp START WITH mgr IS NULL '
              'CONNECT BY PRIOR id = mgr AND LEVEL <= 2'),
          2);
      expect(
          await scalar(db,
              'SELECT MAX(CONNECT_BY_ISCYCLE) FROM emp START WITH mgr IS NULL '
              'CONNECT BY NOCYCLE PRIOR id = mgr'),
          0);
    } finally {
      await db.close();
    }
  });

  test('KEEP (DENSE_RANK FIRST) sorts NULLs last for ASC', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE k (g NUMBER, v NUMBER)');
      await db.execute('INSERT INTO k VALUES (NULL, 99), (1, 10), (1, 30)');
      expect(
          await scalar(
              db, 'SELECT MAX(v) KEEP (DENSE_RANK FIRST ORDER BY g) FROM k'),
          30);
    } finally {
      await db.close();
    }
  });

  test('XMLELEMENT with .getStringVal() and LNNVL', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db, "SELECT XMLELEMENT(\"e\", 'hi').getStringVal()"),
          '<e>hi</e>');
      expect(
          await scalar(
              db, "SELECT CASE WHEN LNNVL(1=2) THEN 'y' ELSE 'n' END"),
          'y');
    } finally {
      await db.close();
    }
  });

  test('TO_NUMBER with a format model strips grouping', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_NUMBER('1,234.56', '9,999.99')"),
          1234.56);
      expect(await scalar(db, "SELECT TO_NUMBER('\$1,234', 'L9,999')"), 1234);
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR lowercase fm modifier trims padding', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(DATE '2024-07-20', 'fmDay, Month DD, YYYY')"),
          'Saturday, July 20, 2024');
    } finally {
      await db.close();
    }
  });

  test('FETCH FIRST n PERCENT ROWS ONLY', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (v NUMBER)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i)');
      }
      expect(
          await scalar(db,
              'SELECT COUNT(*) FROM (SELECT v FROM t ORDER BY v '
              'FETCH FIRST 50 PERCENT ROWS ONLY)'),
          5);
    } finally {
      await db.close();
    }
  });

  test('FROM_TZ + AT TIME ZONE shifts the wall-clock time', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(FROM_TZ(TIMESTAMP '2024-01-01 12:00:00','+00:00') "
              "AT TIME ZONE '+05:00','HH24:MI')"),
          '17:00');
    } finally {
      await db.close();
    }
  });

  test('GROUP BY CUBE/ROLLUP collapse grouping sets', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (a NUMBER, b NUMBER)');
      await db.execute('INSERT INTO t VALUES (1, 10), (1, 20), (2, 10)');
      expect(
          await scalar(db,
              'SELECT COUNT(*) FROM (SELECT a, b FROM t GROUP BY CUBE(a, b))'),
          8);
      expect(
          await scalar(db,
              'SELECT COUNT(*) FROM (SELECT a, b FROM t GROUP BY ROLLUP(a, b))'),
          6);
    } finally {
      await db.close();
    }
  });

  test('row/tuple IN-list', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE u (a NUMBER, b VARCHAR2(5))');
      await db.execute("INSERT INTO u VALUES (90, 'x'), (60, 'y'), (1, 'z')");
      expect(
          await scalar(db,
              "SELECT COUNT(*) FROM u WHERE (a, b) IN ((90, 'x'), (60, 'y'))"),
          2);
    } finally {
      await db.close();
    }
  });

  test('ROUND / NANVL exact-decimal + NaN guard', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT ROUND(1.005, 2)'), 1.01);
      expect(await scalar(db, 'SELECT NANVL(5, -1)'), 5);
    } finally {
      await db.close();
    }
  });

  test('inline WITH FUNCTION', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              'WITH FUNCTION dbl(x NUMBER) RETURN NUMBER IS BEGIN RETURN x*2; '
              'END; SELECT dbl(21) v FROM dual'),
          42);
    } finally {
      await db.close();
    }
  });

  // ---- Round 46 (mega-sweep): F183–F193 ----------------------------------

  test('F183 TO_CHAR(date) IYYY/RM/W/SSSSS tokens', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','IYYY')"),
          '2024');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','RM')"), 'VII');
      expect(await scalar(db, "SELECT TO_CHAR(DATE '2024-07-20','W')"), '3');
    } finally {
      await db.close();
    }
  });

  test('F184 TO_CHAR(number) MI/G/D elements', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(-1234,'FM9999MI')"), '1234-');
      expect(await scalar(db, "SELECT TO_CHAR(1234,'FM9G999')"), '1,234');
      expect(await scalar(db, "SELECT TO_CHAR(12.5,'FM99D9')"), '12.5');
    } finally {
      await db.close();
    }
  });

  test('F186 NTH_VALUE ... FROM LAST', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE m (y NUMBER)');
      await db.execute('INSERT INTO m VALUES (10), (20), (30)');
      expect(
          await scalar(
              db,
              'SELECT MAX(nv) FROM (SELECT NTH_VALUE(y, 1) FROM LAST OVER '
              '(ORDER BY y ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED '
              'FOLLOWING) nv FROM m)'),
          30);
    } finally {
      await db.close();
    }
  });

  test('F188 XMLQUERY / XMLCAST evaluate constant content', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT XMLCAST(XMLQUERY('1+2' RETURNING CONTENT) AS NUMBER) "
              'FROM dual'),
          3);
    } finally {
      await db.close();
    }
  });

  test('F189 ROWID pseudo-column resolves on any rowid table', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (x NUMBER)');
      await db.execute('INSERT INTO t VALUES (1)');
      expect(
          await scalar(db, 'SELECT COUNT(*) FROM t WHERE ROWID IS NOT NULL'),
          1);
    } finally {
      await db.close();
    }
  });

  test('F191 OVERLAPS predicate', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              "SELECT CASE WHEN (DATE '2024-01-01', DATE '2024-06-01') OVERLAPS "
              "(DATE '2024-03-01', DATE '2024-09-01') THEN 1 ELSE 0 END "
              'FROM dual'),
          1);
    } finally {
      await db.close();
    }
  });

  test('F192 = ALL (subquery)', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE s (v NUMBER)');
      await db.execute('INSERT INTO s VALUES (5), (5), (5)');
      expect(
          await scalar(
              db, 'SELECT CASE WHEN 5 = ALL (SELECT v FROM s) THEN 1 ELSE 0 '
              'END FROM dual'),
          1);
    } finally {
      await db.close();
    }
  });

  // ---- Round 47/48 (mega-sweep II/III): F194–F201 -------------------------

  test('F194 INITCAP word-breaks on non-alphanumerics', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT INITCAP('o''brien mcleod')"),
          "O'Brien Mcleod");
    } finally {
      await db.close();
    }
  });

  test('F195 CONNECT BY LEVEL row generator', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db, 'SELECT SUM(LEVEL) FROM dual CONNECT BY LEVEL <= 5'),
          15);
    } finally {
      await db.close();
    }
  });

  test('F196 INTERSECT ALL / MINUS ALL', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              'SELECT COUNT(*) FROM (SELECT 1 FROM dual INTERSECT ALL '
              'SELECT 1 FROM dual)'),
          1);
      expect(
          await scalar(
              db,
              'SELECT COUNT(*) FROM (SELECT 1 FROM dual MINUS ALL '
              'SELECT 2 FROM dual)'),
          1);
    } finally {
      await db.close();
    }
  });

  test('F197 REGEXP case-insensitive match_param', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              "SELECT CASE WHEN REGEXP_LIKE('abc', 'ABC', 'i') THEN 1 ELSE 0 "
              'END FROM dual'),
          1);
    } finally {
      await db.close();
    }
  });

  test('F198 GROUP BY () grand total', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE a (x NUMBER)');
      await db.execute('INSERT INTO a VALUES (1), (2)');
      expect(await scalar(db, 'SELECT COUNT(*) FROM a GROUP BY ()'), 2);
    } finally {
      await db.close();
    }
  });

  test('F199 analytic over aggregate SUM(COUNT(*)) OVER ()', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE a (x NUMBER)');
      await db.execute('INSERT INTO a VALUES (1), (2)');
      expect(
          await scalar(
              db, 'SELECT DISTINCT SUM(COUNT(*)) OVER () FROM a GROUP BY x'),
          2);
    } finally {
      await db.close();
    }
  });

  test('F200 TO_DATE with DDD day-of-year', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TO_DATE('2024-060','YYYY-DDD'),'YYYY-MM-DD') "
              'FROM dual'),
          '2024-02-29');
    } finally {
      await db.close();
    }
  });

  test("F201 TRUNC(date, 'IYYY') ISO year", () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TRUNC(DATE '2024-07-20','IYYY'),'YYYY-MM-DD') "
              'FROM dual'),
          '2024-01-01');
    } finally {
      await db.close();
    }
  });

  // ---- Round 49 (mega-sweep IV): F202–F208 --------------------------------

  test('F202 MOD(n, 0) returns n', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT MOD(5, 0) FROM dual'), 5);
    } finally {
      await db.close();
    }
  });

  test('F203 ROLLUP in a composite GROUP BY', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE g (a NUMBER, b NUMBER)');
      await db.execute('INSERT INTO g VALUES (1, 10), (1, 20), (2, 30)');
      expect(
          await scalar(db,
              'SELECT COUNT(*) FROM (SELECT a FROM g GROUP BY a, ROLLUP(b))'),
          5);
    } finally {
      await db.close();
    }
  });

  test(r'F204 JSON_TABLE array wildcard $[*]', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              'SELECT COUNT(*) FROM (SELECT * FROM JSON_TABLE('
              "'[{\"a\":1},{\"a\":2}]', '\$[*]' COLUMNS (a NUMBER PATH "
              "'\$.a')))"),
          2);
    } finally {
      await db.close();
    }
  });

  test('F205 COUNT(*) with WHERE ROWNUM <= n', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i)');
      }
      expect(await scalar(db, 'SELECT COUNT(*) FROM t WHERE ROWNUM <= 3'), 3);
    } finally {
      await db.close();
    }
  });

  test('F206 TO_BINARY_FLOAT / TO_BINARY_DOUBLE', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              "SELECT CASE WHEN TO_BINARY_FLOAT('3.14') > 3 THEN 1 ELSE 0 END "
              'FROM dual'),
          1);
    } finally {
      await db.close();
    }
  });

  test('F207 EXTRACT(TIMEZONE_MINUTE FROM ts)', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              'SELECT EXTRACT(TIMEZONE_MINUTE FROM '
              "TIMESTAMP '2024-01-01 00:00:00 +05:30') FROM dual"),
          30);
    } finally {
      await db.close();
    }
  });

  test('F208 (expr) DAY TO SECOND interval cast', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              'SELECT EXTRACT(DAY FROM '
              "(DATE '2024-03-01' - DATE '2024-01-01') DAY TO SECOND) "
              'FROM dual'),
          60);
    } finally {
      await db.close();
    }
  });

  // ---- Round 50 (mega-sweep V): F209–F211 ---------------------------------

  test('F209 REGEXP POSIX character classes', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db, "SELECT REGEXP_REPLACE('a1b2','[[:digit:]]','#') FROM dual"),
          'a#b#');
    } finally {
      await db.close();
    }
  });

  test('F210 APPROX_PERCENTILE aggregate', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE m (v NUMBER)');
      await db.execute('INSERT INTO m VALUES (10), (20), (30), (40)');
      expect(
          await scalar(db,
              'SELECT APPROX_PERCENTILE(0.5) WITHIN GROUP (ORDER BY v) FROM m'),
          20);
    } finally {
      await db.close();
    }
  });

  test('F211 INTERVAL YEAR TO MONTH keeps the day', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db,
              "SELECT TO_CHAR(DATE '2024-07-20' + INTERVAL '1-6' YEAR TO "
              "MONTH, 'YYYY-MM-DD') FROM dual"),
          '2026-01-20');
    } finally {
      await db.close();
    }
  });

  // ---- Round 51 (mega-sweep VI): F212–F213 --------------------------------

  test('F212 TO_CLOB', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(TO_CLOB('hello')) FROM dual"),
          'hello');
    } finally {
      await db.close();
    }
  });

  test('F213 NLS_UPPER / NLS_LOWER / NLS_INITCAP', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT NLS_INITCAP('hello world') FROM dual"),
          'Hello World');
      expect(await scalar(db, "SELECT NLS_UPPER('abc') FROM dual"), 'ABC');
      expect(await scalar(db, "SELECT NLS_LOWER('ABC') FROM dual"), 'abc');
    } finally {
      await db.close();
    }
  });

  // ---- Round 52 (DML/DDL effects): F214–F217 ------------------------------

  test('F214 INSERT ALL (multi-table insert)', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE ia (id NUMBER, v NUMBER)');
      await db.execute('INSERT ALL INTO ia (id, v) VALUES (1, 10) '
          'INTO ia (id, v) VALUES (2, 20) SELECT * FROM dual');
      expect(await scalar(db, 'SELECT COUNT(*) FROM ia'), 2);
    } finally {
      await db.close();
    }
  });

  test('F215 BEFORE UPDATE row-level trigger fires', () async {
    final db = await Database.open(null);
    try {
      await db.execute(
          'CREATE TABLE tg (id NUMBER, v NUMBER, upd NUMBER DEFAULT 0)');
      await db.execute('INSERT INTO tg VALUES (1, 10, 0)');
      await db.execute(
          'CREATE OR REPLACE TRIGGER tg_bu BEFORE UPDATE ON tg FOR EACH ROW '
          'BEGIN :NEW.upd := :OLD.upd + 1; END;');
      await db.execute('UPDATE tg SET v = 20 WHERE id = 1');
      expect(await scalar(db, 'SELECT upd FROM tg WHERE id = 1'), 1);
    } finally {
      await db.close();
    }
  });

  test('F216 INSTEAD OF trigger on a view', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE iob (id NUMBER, v NUMBER)');
      await db.execute('CREATE VIEW iov AS SELECT id, v FROM iob');
      await db.execute(
          'CREATE OR REPLACE TRIGGER iov_ii INSTEAD OF INSERT ON iov '
          'FOR EACH ROW BEGIN INSERT INTO iob VALUES (:NEW.id, :NEW.v * 10); '
          'END;');
      await db.execute('INSERT INTO iov VALUES (1, 5)');
      expect(await scalar(db, 'SELECT v FROM iob WHERE id = 1'), 50);
    } finally {
      await db.close();
    }
  });

  test('F217 DEFAULT <sequence>.NEXTVAL column default', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE SEQUENCE ns2 START WITH 1');
      await db.execute(
          'CREATE TABLE nn (id NUMBER DEFAULT ns2.NEXTVAL NOT NULL, v NUMBER)');
      await db.execute('INSERT INTO nn (v) VALUES (10)');
      expect(await scalar(db, 'SELECT id FROM nn'), 1);
    } finally {
      await db.close();
    }
  });

  // ---- Round 53/54 (complex queries, data-type fidelity): F218–F223 -------

  test('F218 LAG/LEAD with a column default argument', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (v NUMBER)');
      await db.execute('INSERT INTO t VALUES (10), (30)');
      expect(
          await scalar(
              db,
              'SELECT LAG(v, 1, v) OVER (ORDER BY v) FROM t '
              'FETCH FIRST 1 ROW ONLY'),
          10);
    } finally {
      await db.close();
    }
  });

  test('F219 GROUPING() marks ROLLUP superaggregate rows', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (g NUMBER)');
      await db.execute('INSERT INTO t VALUES (1), (1), (2)');
      expect(
          await scalar(
              db,
              'SELECT COUNT(*) FROM (SELECT g FROM t GROUP BY ROLLUP(g) '
              'HAVING GROUPING(g) = 0)'),
          2);
    } finally {
      await db.close();
    }
  });

  test('F220 PIVOT row count', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (g NUMBER, v NUMBER)');
      await db.execute('INSERT INTO t VALUES (1, 10), (1, 30), (2, 50)');
      expect(
          await scalar(
              db,
              'SELECT COUNT(*) FROM (SELECT * FROM (SELECT g, v FROM t) '
              'PIVOT (COUNT(*) FOR g IN (1, 2)))'),
          3);
    } finally {
      await db.close();
    }
  });

  test('F222 concatenation treats NULL as empty string', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(
              db, "SELECT 'x' || CAST(NULL AS VARCHAR2(5)) || 'y' FROM dual"),
          'xy');
    } finally {
      await db.close();
    }
  });

  test('F223 EXTRACT field from an INTERVAL column', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE i (v INTERVAL DAY TO SECOND)');
      await db.execute(
          "INSERT INTO i VALUES (INTERVAL '1 02:00:00' DAY TO SECOND)");
      expect(await scalar(db, 'SELECT EXTRACT(HOUR FROM v) FROM i'), 2);
    } finally {
      await db.close();
    }
  });
}
