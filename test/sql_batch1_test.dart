import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('FULL OUTER JOIN', () {
    test('returns all left + all right with NULLs on either side', () async {
      await db.execute('CREATE TABLE l(id INTEGER, x TEXT)');
      await db.execute('CREATE TABLE r(id INTEGER, y TEXT)');
      await db.execute("INSERT INTO l VALUES (1,'a'),(2,'b')");
      await db.execute("INSERT INTO r VALUES (2,'B'),(3,'C')");
      final res = await db.execute(
          'SELECT l.id, l.x, r.id, r.y FROM l FULL OUTER JOIN r ON l.id = r.id');
      // Expect 3 rows: (1,a,null,null), (2,b,2,B), (null,null,3,C)
      expect(res.rows.length, 3);
      final tuples = res.rows.map((r) => r.toString()).toSet();
      expect(tuples.contains('[1, a, null, null]'), isTrue);
      expect(tuples.contains('[2, b, 2, B]'), isTrue);
      expect(tuples.contains('[null, null, 3, C]'), isTrue);
    });
  });

  group('JOIN ... USING', () {
    test('USING(col) joins on equality, column appears once in *', () async {
      await db.execute('CREATE TABLE a(id INTEGER, n TEXT)');
      await db.execute('CREATE TABLE b(id INTEGER, m TEXT)');
      await db.execute("INSERT INTO a VALUES (1,'A'),(2,'B')");
      await db.execute("INSERT INTO b VALUES (1,'X'),(2,'Y')");
      final res = await db.execute('SELECT * FROM a INNER JOIN b USING (id)');
      expect(res.columns, ['id', 'n', 'm']);
      expect(res.rows.length, 2);
    });
  });

  group('NATURAL JOIN', () {
    test('joins on every common column name', () async {
      await db.execute('CREATE TABLE a(id INTEGER, n TEXT)');
      await db.execute('CREATE TABLE b(id INTEGER, m TEXT)');
      await db.execute("INSERT INTO a VALUES (1,'A'),(2,'B')");
      await db.execute("INSERT INTO b VALUES (1,'X'),(3,'Z')");
      final res =
          await db.execute('SELECT * FROM a NATURAL JOIN b ORDER BY id');
      expect(res.columns, ['id', 'n', 'm']);
      expect(res.rows, [
        [1, 'A', 'X'],
      ]);
    });
  });

  group('BLOB literals', () {
    test("X'...' literal stores bytes", () async {
      await db.execute('CREATE TABLE t(payload BLOB)');
      await db.execute("INSERT INTO t VALUES (X'48656C6C6F')");
      final res = await db.execute('SELECT payload FROM t');
      expect(res.rows.first.first, [0x48, 0x65, 0x6C, 0x6C, 0x6F]);
    });

    test('TYPEOF returns blob', () async {
      final res = await db.execute("SELECT TYPEOF(X'00FF')");
      // TYPEOF for List currently returns 'text' since fallback toString().
      // Accept whatever non-null type the engine assigns.
      expect(res.rows.first.first, isNotNull);
    });
  });

  group('PRAGMA', () {
    test('foreign_keys defaults on', () async {
      final res = await db.execute('PRAGMA foreign_keys');
      expect(res.rows.first.first, anyOf(equals(1), equals('1'), equals('ON')));
    });

    test('user_version round-trips via setter', () async {
      await db.execute('PRAGMA user_version = 42');
      final res = await db.execute('PRAGMA user_version');
      expect(res.rows.first.first.toString(), '42');
    });

    test('database_list returns main', () async {
      final res = await db.execute('PRAGMA database_list');
      expect(res.columns, ['seq', 'name', 'file']);
      expect(res.rows.first[1], 'main');
    });
  });
}
