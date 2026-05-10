import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('ALTER TABLE drop column', () {
    test('removes the column and its data', () async {
      await db.execute('CREATE TABLE t(a INTEGER, b INTEGER, c INTEGER)');
      await db.execute('INSERT INTO t VALUES (1,2,3),(4,5,6)');
      await db.execute('ALTER TABLE t DROP COLUMN b');
      final r = await db.execute('SELECT * FROM t ORDER BY a');
      expect(r.columns, ['a', 'c']);
      expect(r.rows, [
        [1, 3],
        [4, 6],
      ]);
    });
  });

  group('ALTER TABLE rename column', () {
    test('renames a column, keeps data', () async {
      await db.execute('CREATE TABLE t(a INTEGER, b INTEGER)');
      await db.execute('INSERT INTO t VALUES (1,2)');
      await db.execute('ALTER TABLE t RENAME COLUMN b TO bb');
      final r = await db.execute('SELECT a, bb FROM t');
      expect(r.rows, [
        [1, 2],
      ]);
    });
  });

  group('ALTER TABLE rename to (table rename)', () {
    test('renames the table itself', () async {
      await db.execute('CREATE TABLE old_t(a INTEGER)');
      await db.execute('INSERT INTO old_t VALUES (42)');
      await db.execute('ALTER TABLE old_t RENAME TO new_t');
      final r = await db.execute('SELECT a FROM new_t');
      expect(r.rows, [
        [42],
      ]);
    });
  });

  group('Generated columns', () {
    test('GENERATED ALWAYS AS (...) computes value at INSERT', () async {
      await db.execute(
          'CREATE TABLE t(a INTEGER, b INTEGER, s INTEGER GENERATED ALWAYS AS (a + b))');
      await db.execute('INSERT INTO t (a, b) VALUES (3, 4),(10, 20)');
      final r = await db.execute('SELECT a, b, s FROM t ORDER BY a');
      expect(r.rows, [
        [3, 4, 7],
        [10, 20, 30],
      ]);
    });

    test('GENERATED columns recompute on UPDATE', () async {
      await db.execute(
          'CREATE TABLE t(a INTEGER, b INTEGER, s INTEGER GENERATED ALWAYS AS (a * b))');
      await db.execute('INSERT INTO t (a, b) VALUES (2, 5)');
      await db.execute('UPDATE t SET a = 6');
      final r = await db.execute('SELECT a, b, s FROM t');
      expect(r.rows.first, [6, 5, 30]);
    });

    test('Shorthand: AS (...) STORED', () async {
      await db
          .execute('CREATE TABLE t(x INTEGER, y INTEGER AS (x * x) STORED)');
      await db.execute('INSERT INTO t (x) VALUES (4)');
      final r = await db.execute('SELECT x, y FROM t');
      expect(r.rows.first, [4, 16]);
    });
  });

  group('Partial indexes', () {
    test('CREATE INDEX ... WHERE is accepted', () async {
      await db.execute('CREATE TABLE t(a INTEGER, b INTEGER)');
      await db.execute('INSERT INTO t VALUES (1,1),(2,2),(3,3)');
      await db.execute('CREATE INDEX idx_t_a ON t(a) WHERE b > 1');
      final r = await db.execute('SELECT * FROM t WHERE a = 2');
      expect(r.rows, [
        [2, 2],
      ]);
    });
  });

  group('Expression indexes', () {
    test('CREATE INDEX ... ON t(LOWER(name)) is accepted', () async {
      await db.execute('CREATE TABLE u(name TEXT)');
      await db.execute("INSERT INTO u VALUES ('Alice'),('BOB')");
      await db.execute('CREATE INDEX idx_u_lname ON u(LOWER(name))');
      final r =
          await db.execute("SELECT name FROM u WHERE LOWER(name) = 'alice'");
      expect(r.rows, [
        ['Alice'],
      ]);
    });
  });
}
