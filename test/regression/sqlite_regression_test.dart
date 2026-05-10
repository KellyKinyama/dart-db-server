/// Regression suite that runs the same SQL against dart-db-server and
/// against `package:sqlite3` (the reference implementation) and asserts
/// that they produce identical results.
///
/// These tests exist to (a) lock in current parity and (b) catch behavioural
/// regressions as we evolve the storage engine, planner and type system
/// toward closer SQLite parity.
///
/// Each test is `skip:`-guarded on the availability of the native sqlite3
/// shared library so this suite is safe to run on hosts without it.
library;

import 'package:test/test.dart';

import 'sqlite_oracle.dart';

void main() {
  final skip = sqliteSkipReason();

  group('SQLite parity (baseline)', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
    });
    tearDown(() => o.close());

    test('CREATE TABLE / INSERT / SELECT *', () async {
      await o.exec(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)');
      await o.exec(
          "INSERT INTO users VALUES (1, 'Alice', 30), (2, 'Bob', 25), (3, 'Carol', 41)");
      await o.expectSameResult('SELECT id, name, age FROM users ORDER BY id');
    });

    test('WHERE: AND / OR / comparisons', () async {
      await o.exec('CREATE TABLE t (id INTEGER, x INTEGER)');
      for (final v in [1, 2, 3, 4, 5]) {
        await o.exec('INSERT INTO t VALUES ($v, ${v * 10})');
      }
      await o.expectSameRows(
          'SELECT id FROM t WHERE x > 20 AND x < 50 ORDER BY id');
      await o.expectSameRows(
          'SELECT id FROM t WHERE x = 10 OR x = 50 ORDER BY id');
    });

    test('IS NULL / IN / BETWEEN / LIKE', () async {
      await o.exec('CREATE TABLE t (name TEXT, score INTEGER)');
      await o.exec(
          "INSERT INTO t VALUES ('alice', 90), ('bob', 75), ('carol', NULL)");
      await o.expectSameRows(
          'SELECT name FROM t WHERE score IS NULL ORDER BY name');
      await o.expectSameRows(
          'SELECT name FROM t WHERE score IN (90, 75) ORDER BY name');
      await o.expectSameRows(
          'SELECT name FROM t WHERE score BETWEEN 80 AND 100 ORDER BY name');
      await o.expectSameRows(
          "SELECT name FROM t WHERE name LIKE 'a%' ORDER BY name");
    });

    test('UPDATE / DELETE affected counts (post-state)', () async {
      await o.exec('CREATE TABLE t (id INTEGER, name TEXT)');
      await o.exec("INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c')");
      await o.exec("UPDATE t SET name = 'X' WHERE id >= 2");
      await o.exec('DELETE FROM t WHERE id = 1');
      await o.expectSameRows('SELECT id, name FROM t ORDER BY id');
    });

    test('Aggregates: COUNT / SUM / AVG / MIN / MAX with GROUP BY', () async {
      await o.exec('CREATE TABLE s (g TEXT, v INTEGER)');
      await o.exec(
          "INSERT INTO s VALUES ('a',1),('a',2),('a',3),('b',10),('b',20)");
      await o.expectSameRows(
        'SELECT g, COUNT(*), SUM(v), MIN(v), MAX(v) '
        'FROM s GROUP BY g ORDER BY g',
      );
      await o.expectSameRows(
        'SELECT g, AVG(v) FROM s GROUP BY g HAVING SUM(v) > 5 ORDER BY g',
      );
    });

    test('JOIN: INNER and LEFT', () async {
      await o.exec('CREATE TABLE a (id INTEGER, name TEXT)');
      await o.exec('CREATE TABLE b (a_id INTEGER, tag TEXT)');
      await o.exec("INSERT INTO a VALUES (1,'one'),(2,'two'),(3,'three')");
      await o.exec("INSERT INTO b VALUES (1,'x'),(1,'y'),(2,'z')");
      await o.expectSameRows(
        'SELECT a.id, a.name, b.tag FROM a INNER JOIN b ON a.id = b.a_id '
        'ORDER BY a.id, b.tag',
      );
      await o.expectSameRows(
        'SELECT a.id, a.name, b.tag FROM a LEFT JOIN b ON a.id = b.a_id '
        'ORDER BY a.id, b.tag',
      );
    });

    test('Subquery: scalar, IN, EXISTS', () async {
      await o.exec('CREATE TABLE p (id INTEGER, v INTEGER)');
      await o.exec('CREATE TABLE q (pid INTEGER)');
      await o.exec('INSERT INTO p VALUES (1,10),(2,20),(3,30)');
      await o.exec('INSERT INTO q VALUES (1),(3)');
      await o.expectSameRows(
        'SELECT id FROM p WHERE id IN (SELECT pid FROM q) ORDER BY id',
      );
      await o.expectSameRows(
        'SELECT id FROM p WHERE EXISTS (SELECT 1 FROM q WHERE q.pid = p.id) '
        'ORDER BY id',
      );
      await o.expectSameRows(
        'SELECT id, (SELECT COUNT(*) FROM q WHERE q.pid = p.id) AS c '
        'FROM p ORDER BY id',
      );
    });

    test('ORDER BY / LIMIT / OFFSET', () async {
      await o.exec('CREATE TABLE n (k INTEGER)');
      for (var i = 0; i < 10; i++) {
        await o.exec('INSERT INTO n VALUES ($i)');
      }
      await o
          .expectSameRows('SELECT k FROM n ORDER BY k DESC LIMIT 3 OFFSET 2');
    });

    test('Set ops: UNION / UNION ALL / INTERSECT / EXCEPT', () async {
      await o.exec('CREATE TABLE u1 (x INTEGER)');
      await o.exec('CREATE TABLE u2 (x INTEGER)');
      await o.exec('INSERT INTO u1 VALUES (1),(2),(2),(3)');
      await o.exec('INSERT INTO u2 VALUES (2),(3),(4)');
      await o
          .expectSameRows('SELECT x FROM u1 UNION SELECT x FROM u2 ORDER BY x');
      await o.expectSameRows(
          'SELECT x FROM u1 UNION ALL SELECT x FROM u2 ORDER BY x');
      await o.expectSameRows(
          'SELECT x FROM u1 INTERSECT SELECT x FROM u2 ORDER BY x');
      await o.expectSameRows(
          'SELECT x FROM u1 EXCEPT SELECT x FROM u2 ORDER BY x');
    });

    test('Scalar funcs: UPPER/LOWER/LENGTH/SUBSTR/COALESCE/IFNULL', () async {
      await o.exec('CREATE TABLE t (s TEXT)');
      await o.exec("INSERT INTO t VALUES ('Hello'),(NULL),('world')");
      await o.expectSameRows(
        "SELECT UPPER(s), LOWER(s), LENGTH(s), SUBSTR(s,1,3), "
        "COALESCE(s,'-'), IFNULL(s,'-') FROM t ORDER BY s IS NULL, s",
      );
    });

    test('CASE: simple and searched', () async {
      await o.exec('CREATE TABLE c (x INTEGER)');
      await o.exec('INSERT INTO c VALUES (1),(2),(3),(4)');
      await o.expectSameRows(
        "SELECT x, CASE x WHEN 1 THEN 'one' WHEN 2 THEN 'two' "
        "ELSE 'many' END FROM c ORDER BY x",
      );
      await o.expectSameRows(
        "SELECT x, CASE WHEN x < 3 THEN 'lo' ELSE 'hi' END FROM c ORDER BY x",
      );
    });
  }, skip: skip);
}
