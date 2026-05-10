import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('Aggregates & GROUP BY', () {
    setUp(() async {
      await db.execute(
          'CREATE TABLE sales (id INTEGER PRIMARY KEY, region TEXT, amount INTEGER)');
      await db.execute(
          "INSERT INTO sales VALUES (1,'east',10),(2,'east',20),(3,'west',5),(4,'west',15),(5,'west',NULL)");
    });

    test('COUNT(*) and total', () async {
      final r = await db.execute('SELECT COUNT(*) AS n FROM sales');
      expect(r.rows.first, [5]);
    });

    test('GROUP BY with SUM/AVG/MIN/MAX', () async {
      final r = await db.execute(
          'SELECT region, SUM(amount) s, AVG(amount) a, MIN(amount) mn, MAX(amount) mx, COUNT(amount) c '
          'FROM sales GROUP BY region ORDER BY region');
      expect(r.rows, [
        ['east', 30, 15.0, 10, 20, 2],
        ['west', 20, 10.0, 5, 15, 2],
      ]);
    });

    test('HAVING filters groups', () async {
      final r = await db.execute(
          'SELECT region, SUM(amount) s FROM sales GROUP BY region HAVING SUM(amount) > 25');
      expect(r.rows, [
        ['east', 30]
      ]);
    });

    test('COUNT(DISTINCT col)', () async {
      final r =
          await db.execute('SELECT COUNT(DISTINCT region) AS n FROM sales');
      expect(r.rows.first, [2]);
    });
  });

  group('Subqueries', () {
    setUp(() async {
      await db.execute('CREATE TABLE u (id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute(
          'CREATE TABLE o (id INTEGER PRIMARY KEY, uid INTEGER, total INTEGER)');
      await db.execute("INSERT INTO u VALUES (1,'A'),(2,'B'),(3,'C')");
      await db.execute('INSERT INTO o VALUES (10,1,100),(11,1,50),(12,2,30)');
    });

    test('IN (subquery)', () async {
      final r = await db.execute(
          'SELECT name FROM u WHERE id IN (SELECT uid FROM o) ORDER BY id');
      expect(r.rows, [
        ['A'],
        ['B']
      ]);
    });

    test('EXISTS (correlated-style)', () async {
      final r = await db.execute(
          'SELECT name FROM u WHERE EXISTS (SELECT 1 FROM o WHERE o.uid = u.id) ORDER BY id');
      expect(r.rows, [
        ['A'],
        ['B']
      ]);
    });

    test('scalar subquery', () async {
      final r = await db.execute('SELECT (SELECT COUNT(*) FROM o) AS n');
      expect(r.rows.first, [3]);
    });
  });

  group('Set operations', () {
    setUp(() async {
      await db.execute('CREATE TABLE a (x INTEGER)');
      await db.execute('CREATE TABLE b (x INTEGER)');
      await db.execute('INSERT INTO a VALUES (1),(2),(3)');
      await db.execute('INSERT INTO b VALUES (2),(3),(4)');
    });

    test('UNION dedupes', () async {
      final r = await db.execute('SELECT x FROM a UNION SELECT x FROM b');
      final xs = r.rows.map((row) => row.first as int).toList()..sort();
      expect(xs, [1, 2, 3, 4]);
    });

    test('UNION ALL preserves duplicates', () async {
      final r = await db.execute('SELECT x FROM a UNION ALL SELECT x FROM b');
      expect(r.rows.length, 6);
    });

    test('INTERSECT', () async {
      final r = await db.execute('SELECT x FROM a INTERSECT SELECT x FROM b');
      final xs = r.rows.map((row) => row.first).toList()..sort();
      expect(xs, [2, 3]);
    });

    test('EXCEPT', () async {
      final r = await db.execute('SELECT x FROM a EXCEPT SELECT x FROM b');
      expect(r.rows, [
        [1]
      ]);
    });
  });

  group('CASE / CAST / || / scalar functions', () {
    test('CASE expression', () async {
      final r = await db
          .execute("SELECT CASE WHEN 1=1 THEN 'yes' ELSE 'no' END AS r");
      expect(r.rows.first, ['yes']);
    });

    test('searched CASE on column', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('INSERT INTO t VALUES (1),(2),(3)');
      final r = await db.execute(
          "SELECT n, CASE WHEN n=1 THEN 'one' WHEN n=2 THEN 'two' ELSE 'other' END label FROM t ORDER BY n");
      expect(r.rows, [
        [1, 'one'],
        [2, 'two'],
        [3, 'other']
      ]);
    });

    test('|| string concat', () async {
      final r = await db.execute("SELECT 'foo' || 'bar' AS s");
      expect(r.rows.first, ['foobar']);
    });

    test('UPPER, LOWER, LENGTH, SUBSTR, TRIM, COALESCE', () async {
      final r = await db.execute(
          "SELECT UPPER('ab'), LOWER('CD'), LENGTH('hello'), SUBSTR('hello',2,3), TRIM('  x  '), COALESCE(NULL, NULL, 'z')");
      expect(r.rows.first, ['AB', 'cd', 5, 'ell', 'x', 'z']);
    });

    test('CAST to INTEGER and TEXT', () async {
      final r = await db.execute(
          "SELECT CAST('42' AS INTEGER) a, CAST(3.7 AS INTEGER) b, CAST(5 AS TEXT) c");
      expect(r.rows.first, [42, 3, '5']);
    });
  });

  group('AUTOINCREMENT / REPLACE / TRUNCATE', () {
    test('AUTOINCREMENT assigns next id', () async {
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)');
      await db.execute("INSERT INTO t (name) VALUES ('a'),('b')");
      await db.execute("INSERT INTO t (id, name) VALUES (10, 'c')");
      await db.execute("INSERT INTO t (name) VALUES ('d')");
      final r = await db.execute('SELECT id, name FROM t ORDER BY id');
      expect(r.rows, [
        [1, 'a'],
        [2, 'b'],
        [10, 'c'],
        [11, 'd']
      ]);
    });

    test('INSERT OR REPLACE upserts on PK conflict', () async {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1,'a')");
      await db.execute("INSERT OR REPLACE INTO t VALUES (1,'b')");
      final r = await db.execute('SELECT name FROM t WHERE id=1');
      expect(r.rows.first, ['b']);
    });

    test('INSERT OR IGNORE skips conflict', () async {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1,'a')");
      await db.execute("INSERT OR IGNORE INTO t VALUES (1,'b')");
      final r = await db.execute('SELECT name FROM t WHERE id=1');
      expect(r.rows.first, ['a']);
    });

    test('REPLACE INTO is alias for INSERT OR REPLACE', () async {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1,'a')");
      await db.execute("REPLACE INTO t VALUES (1,'b')");
      expect((await db.execute('SELECT name FROM t')).rows.first, ['b']);
    });

    test('TRUNCATE TABLE empties + resets autoinc', () async {
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, n TEXT)');
      await db.execute("INSERT INTO t (n) VALUES ('a'),('b')");
      await db.execute('TRUNCATE TABLE t');
      expect((await db.execute('SELECT COUNT(*) FROM t')).rows.first, [0]);
      await db.execute("INSERT INTO t (n) VALUES ('c')");
      expect((await db.execute('SELECT id FROM t')).rows.first, [1]);
    });
  });

  group('CHECK constraints', () {
    test('column-level CHECK rejects bad row', () async {
      await db.execute('CREATE TABLE t(n INTEGER CHECK (n > 0))');
      await db.execute('INSERT INTO t VALUES (5)');
      expect(() => db.execute('INSERT INTO t VALUES (-1)'),
          throwsA(isA<StateError>()));
    });

    test('table-level CHECK', () async {
      await db.execute('CREATE TABLE t(a INTEGER, b INTEGER, CHECK (a < b))');
      await db.execute('INSERT INTO t VALUES (1,2)');
      expect(() => db.execute('INSERT INTO t VALUES (5,3)'),
          throwsA(isA<StateError>()));
    });
  });

  group('Foreign keys', () {
    setUp(() async {
      await db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute(
          'CREATE TABLE c(id INTEGER PRIMARY KEY, pid INTEGER REFERENCES p(id) ON DELETE CASCADE)');
      await db.execute("INSERT INTO p VALUES (1,'A'),(2,'B')");
      await db.execute('INSERT INTO c VALUES (10,1),(11,1),(12,2)');
    });

    test('insert with missing parent fails', () async {
      expect(() => db.execute('INSERT INTO c VALUES (20,99)'),
          throwsA(isA<StateError>()));
    });

    test('ON DELETE CASCADE removes children', () async {
      await db.execute('DELETE FROM p WHERE id = 1');
      final r = await db.execute('SELECT id FROM c ORDER BY id');
      expect(r.rows, [
        [12]
      ]);
    });
  });

  group('Joins (CROSS, RIGHT)', () {
    setUp(() async {
      await db.execute('CREATE TABLE a(x INTEGER)');
      await db.execute('CREATE TABLE b(y INTEGER)');
      await db.execute('INSERT INTO a VALUES (1),(2)');
      await db.execute('INSERT INTO b VALUES (10),(20)');
    });

    test('CROSS JOIN cardinality', () async {
      final r =
          await db.execute('SELECT x, y FROM a CROSS JOIN b ORDER BY x, y');
      expect(r.rows.length, 4);
    });

    test('RIGHT JOIN keeps unmatched right side', () async {
      await db.execute('CREATE TABLE p(id INTEGER, name TEXT)');
      await db.execute('CREATE TABLE q(pid INTEGER, val TEXT)');
      await db.execute("INSERT INTO p VALUES (1,'A')");
      await db.execute("INSERT INTO q VALUES (1,'X'),(2,'Y')");
      final r = await db.execute(
          'SELECT p.name, q.val FROM p RIGHT JOIN q ON p.id = q.pid ORDER BY q.val');
      expect(r.rows, [
        ['A', 'X'],
        [null, 'Y']
      ]);
    });
  });

  group('VIEW / EXPLAIN / PRAGMA', () {
    test('CREATE VIEW + SELECT FROM view', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('INSERT INTO t VALUES (1),(2),(3)');
      await db.execute('CREATE VIEW big AS SELECT n FROM t WHERE n >= 2');
      final r = await db.execute('SELECT n FROM big ORDER BY n');
      expect(r.rows, [
        [2],
        [3]
      ]);
      await db.execute('DROP VIEW big');
    });

    test('EXPLAIN returns plan rows', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      final r = await db.execute('EXPLAIN SELECT * FROM t WHERE n > 0');
      expect(r.columns, ['plan']);
      expect(r.rows.length, greaterThan(0));
    });

    test('PRAGMA is no-op message', () async {
      final r = await db.execute('PRAGMA foreign_keys = ON');
      expect(r.message, contains('PRAGMA'));
    });
  });

  group('NULLS FIRST/LAST', () {
    test('ORDER BY n NULLS LAST', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('INSERT INTO t VALUES (3),(NULL),(1)');
      final r = await db.execute('SELECT n FROM t ORDER BY n NULLS LAST');
      expect(r.rows, [
        [1],
        [3],
        [null]
      ]);
    });

    test('ORDER BY n DESC NULLS FIRST', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('INSERT INTO t VALUES (3),(NULL),(1)');
      final r = await db.execute('SELECT n FROM t ORDER BY n DESC NULLS FIRST');
      expect(r.rows, [
        [null],
        [3],
        [1]
      ]);
    });
  });
}
