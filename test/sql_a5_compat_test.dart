import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('A5 SQLite syntax acceptance', () {
    test('CREATE TABLE ... WITHOUT ROWID is accepted', () async {
      await db.execute(
          'CREATE TABLE k(id INTEGER PRIMARY KEY, v TEXT) WITHOUT ROWID');
      await db.execute("INSERT INTO k VALUES (1, 'x')");
      final r = await db.execute('SELECT v FROM k WHERE id = 1');
      expect(r.rows.first.first, 'x');
    });

    test('SELECT ... FROM t INDEXED BY name is accepted', () async {
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('CREATE INDEX ix ON t(a)');
      await db.execute('INSERT INTO t VALUES (1),(2),(3)');
      final r = await db.execute('SELECT a FROM t INDEXED BY ix WHERE a >= 2');
      expect(r.rows.length, 2);
    });

    test('UPDATE / DELETE NOT INDEXED is accepted', () async {
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('INSERT INTO t VALUES (1),(2)');
      await db.execute('UPDATE t NOT INDEXED SET a = a + 10');
      await db.execute('DELETE FROM t NOT INDEXED WHERE a = 11');
      final r = await db.execute('SELECT a FROM t');
      expect(r.rows.first.first, 12);
    });

    test('WITH cte AS MATERIALIZED (...) accepted', () async {
      final r = await db
          .execute('WITH x AS MATERIALIZED (SELECT 1 AS v UNION ALL SELECT 2) '
              'SELECT SUM(v) FROM x');
      expect(r.rows.first.first, 3);
    });

    test('VACUUM runs without error', () async {
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('INSERT INTO t VALUES (1)');
      final r = await db.execute('VACUUM');
      expect(r.message, contains('VACUUM'));
    });

    test('ANALYZE writes sqlite_stat1 row counts', () async {
      await db.execute('CREATE TABLE a(x INTEGER)');
      await db.execute('CREATE TABLE b(y INTEGER)');
      await db.execute('INSERT INTO a VALUES (1),(2),(3)');
      await db.execute('INSERT INTO b VALUES (1),(2)');
      await db.execute('ANALYZE');
      final r =
          await db.execute('SELECT tbl, stat FROM sqlite_stat1 ORDER BY tbl');
      expect(r.rows, [
        ['a', '3'],
        ['b', '2']
      ]);
    });
  });
}
