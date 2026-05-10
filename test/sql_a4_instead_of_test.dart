import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open();
  });

  group('A4 INSTEAD OF triggers', () {
    test('INSTEAD OF INSERT on view writes to underlying table', () async {
      await db.execute('CREATE TABLE t(a INTEGER, b INTEGER)');
      await db.execute('CREATE VIEW v AS SELECT a, b FROM t');
      await db.execute('CREATE TABLE log(msg TEXT)');
      await db.execute('CREATE TRIGGER vi INSTEAD OF INSERT ON v BEGIN '
          'INSERT INTO t(a, b) VALUES (NEW.a * 10, NEW.b * 10); '
          'END');
      await db.execute('INSERT INTO v(a, b) VALUES (1, 2), (3, 4)');
      final r = await db.execute('SELECT a, b FROM t ORDER BY a');
      expect(r.rows, [
        [10, 20],
        [30, 40]
      ]);
    });

    test('INSTEAD OF UPDATE on view fires per-matching-row', () async {
      await db.execute('CREATE TABLE t(id INTEGER, v INTEGER)');
      await db.execute('INSERT INTO t VALUES (1,10),(2,20),(3,30)');
      await db.execute('CREATE VIEW vw AS SELECT id, v FROM t');
      await db.execute('CREATE TRIGGER vu INSTEAD OF UPDATE ON vw BEGIN '
          'UPDATE t SET v = NEW.v WHERE id = OLD.id; '
          'END');
      await db.execute('UPDATE vw SET v = v + 100 WHERE id >= 2');
      final r = await db.execute('SELECT id, v FROM t ORDER BY id');
      expect(r.rows, [
        [1, 10],
        [2, 120],
        [3, 130]
      ]);
    });

    test('INSTEAD OF DELETE on view', () async {
      await db.execute('CREATE TABLE t(id INTEGER)');
      await db.execute('INSERT INTO t VALUES (1),(2),(3)');
      await db.execute('CREATE VIEW vw AS SELECT id FROM t');
      await db.execute('CREATE TRIGGER vd INSTEAD OF DELETE ON vw BEGIN '
          'DELETE FROM t WHERE id = OLD.id; END');
      await db.execute('DELETE FROM vw WHERE id = 2');
      final r = await db.execute('SELECT id FROM t ORDER BY id');
      expect(r.rows, [
        [1],
        [3]
      ]);
    });

    test('RAISE(ABORT, msg) inside trigger blocks operation', () async {
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('CREATE TRIGGER guard BEFORE INSERT ON t '
          "WHEN NEW.a < 0 BEGIN "
          "SELECT RAISE(ABORT, 'negatives not allowed'); END");
      await db.execute('INSERT INTO t VALUES (5)');
      expect(
        () => db.execute('INSERT INTO t VALUES (-1)'),
        throwsA(isA<StateError>()),
      );
      final r = await db.execute('SELECT a FROM t ORDER BY a');
      expect(r.rows, [
        [5]
      ]);
    });

    test('RAISE(IGNORE) silently skips rest of trigger body', () async {
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('CREATE TABLE log(msg TEXT)');
      await db.execute('CREATE TRIGGER skipper AFTER INSERT ON t BEGIN '
          "SELECT RAISE(IGNORE); "
          "INSERT INTO log VALUES ('should not run'); END");
      await db.execute('INSERT INTO t VALUES (1)');
      final r = await db.execute('SELECT COUNT(*) FROM log');
      expect(r.rows.first.first, 0);
    });
  });
}
