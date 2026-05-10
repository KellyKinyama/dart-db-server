import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('Triggers', () {
    test('AFTER INSERT trigger logs into another table using NEW.col',
        () async {
      await db.execute('CREATE TABLE t(id INTEGER, n TEXT)');
      await db.execute('CREATE TABLE log(id INTEGER, msg TEXT)');
      await db.execute(
          "CREATE TRIGGER tr_insert AFTER INSERT ON t FOR EACH ROW BEGIN "
          "INSERT INTO log VALUES (NEW.id, NEW.n);"
          "END");
      await db.execute("INSERT INTO t VALUES (1, 'a'),(2, 'b')");
      final r = await db.execute('SELECT id, msg FROM log ORDER BY id');
      expect(r.rows, [
        [1, 'a'],
        [2, 'b'],
      ]);
    });

    test('AFTER UPDATE trigger sees NEW and OLD', () async {
      await db.execute('CREATE TABLE t(id INTEGER, n TEXT)');
      await db
          .execute('CREATE TABLE audit(id INTEGER, before TEXT, after TEXT)');
      await db.execute("INSERT INTO t VALUES (1,'a')");
      await db
          .execute("CREATE TRIGGER tr_upd AFTER UPDATE ON t FOR EACH ROW BEGIN "
              "INSERT INTO audit VALUES (NEW.id, OLD.n, NEW.n);"
              "END");
      await db.execute("UPDATE t SET n = 'z' WHERE id = 1");
      final r = await db.execute('SELECT id, before, after FROM audit');
      expect(r.rows, [
        [1, 'a', 'z'],
      ]);
    });

    test('AFTER DELETE trigger sees OLD', () async {
      await db.execute('CREATE TABLE t(id INTEGER)');
      await db.execute('CREATE TABLE deleted(id INTEGER)');
      await db.execute('INSERT INTO t VALUES (5),(6)');
      await db
          .execute("CREATE TRIGGER tr_del AFTER DELETE ON t FOR EACH ROW BEGIN "
              "INSERT INTO deleted VALUES (OLD.id);"
              "END");
      await db.execute('DELETE FROM t WHERE id = 6');
      final r = await db.execute('SELECT id FROM deleted');
      expect(r.rows, [
        [6],
      ]);
    });

    test('DROP TRIGGER stops further firing', () async {
      await db.execute('CREATE TABLE t(id INTEGER)');
      await db.execute('CREATE TABLE log(id INTEGER)');
      await db.execute("CREATE TRIGGER tr AFTER INSERT ON t FOR EACH ROW BEGIN "
          "INSERT INTO log VALUES (NEW.id);"
          "END");
      await db.execute('INSERT INTO t VALUES (1)');
      await db.execute('DROP TRIGGER tr');
      await db.execute('INSERT INTO t VALUES (2)');
      final r = await db.execute('SELECT id FROM log');
      expect(r.rows, [
        [1],
      ]);
    });
  });

  group('Savepoints', () {
    test('SAVEPOINT + ROLLBACK TO restores state', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('INSERT INTO t VALUES (1)');
      await db.execute('SAVEPOINT sp1');
      await db.execute('INSERT INTO t VALUES (2),(3)');
      var r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.first, [3]);
      await db.execute('ROLLBACK TO sp1');
      r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.first, [1]);
    });

    test('RELEASE SAVEPOINT keeps changes', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('SAVEPOINT sp');
      await db.execute('INSERT INTO t VALUES (10)');
      await db.execute('RELEASE SAVEPOINT sp');
      final r = await db.execute('SELECT n FROM t');
      expect(r.rows, [
        [10],
      ]);
    });

    test('Nested savepoints: rollback to outer discards both', () async {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('SAVEPOINT a');
      await db.execute('INSERT INTO t VALUES (1)');
      await db.execute('SAVEPOINT b');
      await db.execute('INSERT INTO t VALUES (2)');
      await db.execute('ROLLBACK TO a');
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.first, [0]);
    });
  });
}
