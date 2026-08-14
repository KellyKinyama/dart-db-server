// Tests for the MySQL connection-management surface added to the parser
// and executor: SET (no-op), USE, SHOW DATABASES / COLUMNS / CREATE TABLE
// / VARIABLES / STATUS, and the @@var system-variable expression.
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('MySQL connection-management surface', () {
    late Database db;

    setUp(() async {
      db = await Database.open(null);
      await db.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
      );
    });

    test('SELECT @@version returns the server version literal', () async {
      final r = await db.execute('SELECT @@version');
      expect(r.rows.single.single, '8.0.0-dart_db_server');
    });

    test('SELECT @@global.character_set_client', () async {
      final r = await db.execute('SELECT @@global.character_set_client');
      expect(r.rows.single.single, 'utf8mb4');
    });

    test('SELECT @@unknown returns NULL', () async {
      final r = await db.execute('SELECT @@no_such_var');
      expect(r.rows.single.single, isNull);
    });

    test('SET autocommit = 0 succeeds as a no-op', () async {
      final r = await db.execute('SET autocommit = 0');
      expect(r.message, 'OK');
    });

    test('SET NAMES utf8mb4 succeeds as a no-op', () async {
      final r = await db.execute('SET NAMES utf8mb4');
      expect(r.message, 'OK');
    });

    test('USE main acknowledged', () async {
      final r = await db.execute('USE main');
      expect(r.message, 'Database changed');
    });

    test('SHOW DATABASES returns the main database', () async {
      final r = await db.execute('SHOW DATABASES');
      expect(r.columns, ['Database']);
      expect(r.rows.map((r) => r.first).toList(), ['main']);
    });

    test('SHOW COLUMNS FROM t works like DESCRIBE', () async {
      final r = await db.execute('SHOW COLUMNS FROM t');
      expect(r.columns.first, 'name');
      expect(r.rows.map((r) => r[0] as String).toList(), ['id', 'name']);
    });

    test('SHOW CREATE TABLE t emits a reconstructed DDL', () async {
      final r = await db.execute('SHOW CREATE TABLE t');
      expect(r.columns, ['Table', 'Create Table']);
      final ddl = r.rows.single[1] as String;
      expect(ddl, contains('CREATE TABLE `t`'));
      expect(ddl, contains('`id`'));
      expect(ddl, contains('PRIMARY KEY'));
      expect(ddl, contains('NOT NULL'));
    });

    test('SHOW VARIABLES LIKE \'character%\' filters', () async {
      final r = await db.execute("SHOW VARIABLES LIKE 'character%'");
      final names = r.rows.map((r) => r[0] as String).toList();
      expect(names, isNotEmpty);
      for (final n in names) {
        expect(n.startsWith('character'), isTrue, reason: n);
      }
    });

    test('SHOW STATUS returns an empty result set', () async {
      final r = await db.execute('SHOW STATUS');
      expect(r.columns, ['Variable_name', 'Value']);
      expect(r.rows, isEmpty);
    });
  });
}
