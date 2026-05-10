import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('INSERT ... SELECT', () {
    test('copies rows from another table', () async {
      await db.execute('CREATE TABLE src(id INTEGER, n TEXT)');
      await db.execute('CREATE TABLE dst(id INTEGER, n TEXT)');
      await db.execute("INSERT INTO src VALUES (1,'a'),(2,'b'),(3,'c')");
      final r = await db
          .execute('INSERT INTO dst SELECT id, n FROM src WHERE id > 1');
      expect(r.affected, 2);
      final got = await db.execute('SELECT id, n FROM dst ORDER BY id');
      expect(got.rows, [
        [2, 'b'],
        [3, 'c'],
      ]);
    });

    test('with explicit column list and projection', () async {
      await db.execute('CREATE TABLE dst(id INTEGER, doubled INTEGER)');
      await db.execute('CREATE TABLE src(x INTEGER)');
      await db.execute('INSERT INTO src VALUES (10),(20)');
      await db.execute('INSERT INTO dst (id, doubled) SELECT x, x*2 FROM src');
      final r = await db.execute('SELECT id, doubled FROM dst ORDER BY id');
      expect(r.rows, [
        [10, 20],
        [20, 40],
      ]);
    });
  });

  group('RETURNING', () {
    setUp(() async {
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, n TEXT)');
    });

    test('INSERT ... RETURNING id, n', () async {
      final r = await db
          .execute("INSERT INTO t (n) VALUES ('a'),('b') RETURNING id, n");
      expect(r.columns, ['id', 'n']);
      expect(r.rows, [
        [1, 'a'],
        [2, 'b'],
      ]);
    });

    test('INSERT ... RETURNING *', () async {
      final r = await db.execute("INSERT INTO t (n) VALUES ('z') RETURNING *");
      expect(r.columns, ['id', 'n']);
      expect(r.rows, [
        [1, 'z'],
      ]);
    });

    test('UPDATE ... RETURNING new value', () async {
      await db.execute("INSERT INTO t (n) VALUES ('a'),('b')");
      final r =
          await db.execute("UPDATE t SET n = 'X' WHERE id = 2 RETURNING id, n");
      expect(r.rows, [
        [2, 'X'],
      ]);
    });

    test('DELETE ... RETURNING captures old rows', () async {
      await db.execute("INSERT INTO t (n) VALUES ('a'),('b'),('c')");
      final r = await db.execute('DELETE FROM t WHERE id < 3 RETURNING id, n');
      expect(r.rows, [
        [1, 'a'],
        [2, 'b'],
      ]);
      final remaining = await db.execute('SELECT COUNT(*) FROM t');
      expect(remaining.rows.first, [1]);
    });
  });

  group('Common Table Expressions (WITH)', () {
    setUp(() async {
      await db.execute('CREATE TABLE sales(region TEXT, amount INTEGER)');
      await db.execute(
          "INSERT INTO sales VALUES ('east',10),('east',20),('west',5),('west',15)");
    });

    test('single CTE', () async {
      final r = await db.execute(
          'WITH totals AS (SELECT region, SUM(amount) total FROM sales GROUP BY region) '
          'SELECT region, total FROM totals ORDER BY region');
      expect(r.rows, [
        ['east', 30],
        ['west', 20],
      ]);
    });

    test('CTE referenced in JOIN', () async {
      await db.execute('CREATE TABLE meta(region TEXT, label TEXT)');
      await db.execute("INSERT INTO meta VALUES ('east','E'),('west','W')");
      final r = await db.execute(
          'WITH totals AS (SELECT region, SUM(amount) total FROM sales GROUP BY region) '
          'SELECT m.label, t.total FROM totals t INNER JOIN meta m ON m.region = t.region ORDER BY m.label');
      expect(r.rows, [
        ['E', 30],
        ['W', 20],
      ]);
    });

    test('multiple CTEs, later refers to earlier', () async {
      final r = await db.execute(
          'WITH east AS (SELECT amount FROM sales WHERE region = \'east\'), '
          '     east_sum AS (SELECT SUM(amount) s FROM east) '
          'SELECT s FROM east_sum');
      expect(r.rows, [
        [30],
      ]);
    });

    test('CTE used in INSERT...SELECT', () async {
      await db.execute('CREATE TABLE summary(region TEXT, total INTEGER)');
      await db.execute(
          'WITH totals AS (SELECT region, SUM(amount) total FROM sales GROUP BY region) '
          'INSERT INTO summary SELECT region, total FROM totals');
      final r =
          await db.execute('SELECT region, total FROM summary ORDER BY region');
      expect(r.rows, [
        ['east', 30],
        ['west', 20],
      ]);
    });
  });

  group('Derived tables (subquery in FROM)', () {
    test('SELECT from subquery alias', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('INSERT INTO t VALUES (1),(2),(3),(4)');
      final r = await db.execute(
          'SELECT s.n2 FROM (SELECT n*n AS n2 FROM t WHERE n >= 2) s ORDER BY s.n2');
      expect(r.rows, [
        [4],
        [9],
        [16]
      ]);
    });

    test('JOIN against derived table', () async {
      await db.execute('CREATE TABLE u(id INTEGER, name TEXT)');
      await db.execute('CREATE TABLE o(uid INTEGER, total INTEGER)');
      await db.execute("INSERT INTO u VALUES (1,'A'),(2,'B'),(3,'C')");
      await db.execute('INSERT INTO o VALUES (1,10),(1,20),(2,5)');
      final r = await db.execute('SELECT u.name, t.total FROM u INNER JOIN '
          '(SELECT uid, SUM(total) total FROM o GROUP BY uid) t ON t.uid = u.id '
          'ORDER BY u.name');
      expect(r.rows, [
        ['A', 30],
        ['B', 5],
      ]);
    });
  });

  group('ORDER BY column position', () {
    test('ORDER BY 1 sorts on first projected column', () async {
      await db.execute('CREATE TABLE t(a INTEGER, b INTEGER)');
      await db.execute('INSERT INTO t VALUES (3,1),(1,2),(2,3)');
      final r = await db.execute('SELECT a, b FROM t ORDER BY 1');
      expect(r.rows, [
        [1, 2],
        [2, 3],
        [3, 1]
      ]);
    });

    test('ORDER BY 2 DESC', () async {
      await db.execute('CREATE TABLE t(a INTEGER, b INTEGER)');
      await db.execute('INSERT INTO t VALUES (3,1),(1,2),(2,3)');
      final r = await db.execute('SELECT a, b FROM t ORDER BY 2 DESC');
      expect(r.rows, [
        [2, 3],
        [1, 2],
        [3, 1]
      ]);
    });
  });

  group('GLOB operator', () {
    test('GLOB matches Unix-style wildcards', () async {
      await db.execute('CREATE TABLE t(s TEXT)');
      await db
          .execute("INSERT INTO t VALUES ('foo'),('foobar'),('bar'),('FOOX')");
      final r =
          await db.execute("SELECT s FROM t WHERE s GLOB 'foo*' ORDER BY s");
      expect(r.rows, [
        ['foo'],
        ['foobar']
      ]);
    });

    test('GLOB ? matches a single char', () async {
      await db.execute('CREATE TABLE t(s TEXT)');
      await db.execute("INSERT INTO t VALUES ('a'),('ab'),('abc')");
      final r =
          await db.execute("SELECT s FROM t WHERE s GLOB 'a?' ORDER BY s");
      expect(r.rows, [
        ['ab']
      ]);
    });
  });

  group('Math functions', () {
    test('FLOOR / CEIL / ABS / SIGN', () async {
      final r = await db.execute(
          'SELECT FLOOR(1.7), CEIL(1.2), ABS(-3.5), SIGN(-5), SIGN(0), SIGN(7)');
      expect(r.rows.first, [1, 2, 3.5, -1, 0, 1]);
    });

    test('SQRT and POWER', () async {
      final r = await db.execute('SELECT SQRT(16), POWER(2, 10)');
      final row = r.rows.first;
      expect((row[0] as num).round(), 4);
      expect(row[1], 1024.0);
    });

    test('INSTR finds substrings (1-based, 0 = not found)', () async {
      final r = await db
          .execute("SELECT INSTR('hello world','world'), INSTR('abc','x')");
      expect(r.rows.first, [7, 0]);
    });

    test('LPAD / RPAD', () async {
      final r = await db.execute("SELECT LPAD('5', 3, '0'), RPAD('a', 4, '-')");
      expect(r.rows.first, ['005', 'a---']);
    });

    test('TYPEOF', () async {
      final r = await db
          .execute("SELECT TYPEOF(1), TYPEOF(1.5), TYPEOF('a'), TYPEOF(NULL)");
      expect(r.rows.first, ['integer', 'real', 'text', 'null']);
    });
  });

  group('Datetime functions', () {
    test('DATE / TIME / DATETIME parse ISO strings', () async {
      final r = await db.execute(
          "SELECT DATE('2024-03-15T10:20:30Z'), TIME('2024-03-15T10:20:30Z'), "
          "DATETIME('2024-03-15T10:20:30Z')");
      expect(r.rows.first, ['2024-03-15', '10:20:30', '2024-03-15 10:20:30']);
    });

    test('STRFTIME formatting', () async {
      final r = await db.execute(
          "SELECT STRFTIME('%Y/%m/%d %H-%M-%S', '2024-03-15T10:20:30Z')");
      expect(r.rows.first, ['2024/03/15 10-20-30']);
    });

    test('CURRENT_DATE bareword returns YYYY-MM-DD', () async {
      final r = await db.execute('SELECT CURRENT_DATE');
      final s = r.rows.first.first as String;
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s), isTrue);
    });

    test('CURRENT_TIMESTAMP bareword returns full datetime', () async {
      final r = await db.execute('SELECT CURRENT_TIMESTAMP');
      final s = r.rows.first.first as String;
      expect(
          RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(s), isTrue);
    });
  });
}
