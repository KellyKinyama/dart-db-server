// End-to-end driver test: spin up MySqlServer in front of an in-memory
// Database, connect with the published `mysql_client` package, and run
// COM_QUERY + COM_STMT_PREPARE/EXECUTE round-trips through it.
import 'dart:async';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:mysql_client/mysql_client.dart';
import 'package:test/test.dart';

void main() {
  group('mysql_client driver compatibility', () {
    late Database db;
    late MySqlServer server;
    late MySQLConnection conn;

    setUp(() async {
      db = await Database.open(null);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1, 'alice'), (2, 'bob')");
      server = MySqlServer(db, port: 0);
      await server.start();
      conn = await MySQLConnection.createConnection(
        host: '127.0.0.1',
        port: server.boundPort,
        userName: 'root',
        password: '',
        secure: false,
      );
      await conn.connect();
    });

    tearDown(() async {
      await conn.close();
      await server.stop();
    });

    test('plain COM_QUERY SELECT returns the expected rows', () async {
      final r = await conn.execute('SELECT id, name FROM t ORDER BY id');
      final rows = r.rows.map((r) => [r.colAt(0), r.colAt(1)]).toList();
      expect(rows, [
        ['1', 'alice'],
        ['2', 'bob'],
      ]);
    });

    test('INFORMATION_SCHEMA introspection works through the driver', () async {
      final tables = await conn.execute(
          'SELECT table_name FROM information_schema.tables '
          'WHERE table_schema = DATABASE() AND table_name = \'t\'');
      expect(tables.rows.first.colAt(0), 't');

      final cols = await conn.execute(
          'SELECT column_name, is_nullable FROM information_schema.columns '
          'WHERE table_name = \'t\' ORDER BY ordinal_position');
      final rows = cols.rows.map((r) => [r.colAt(0), r.colAt(1)]).toList();
      expect(rows, [
        ['id', 'NO'],
        ['name', 'YES'],
      ]);
    });

    test('a stored procedure runs via CALL through the driver', () async {
      await conn.execute('''
        CREATE PROCEDURE bump(IN start_id INT, IN cnt INT)
        BEGIN
          DECLARE i INT DEFAULT 0;
          WHILE i < cnt DO
            INSERT INTO t VALUES (start_id + i, 'gen' || (start_id + i));
            SET i = i + 1;
          END WHILE;
        END
      ''');
      await conn.execute('CALL bump(10, 2)');
      final r =
          await conn.execute('SELECT id, name FROM t WHERE id >= 10 ORDER BY id');
      final rows = r.rows.map((row) => [row.colAt(0), row.colAt(1)]).toList();
      expect(rows, [
        ['10', 'gen10'],
        ['11', 'gen11'],
      ]);
    });

    test('a procedure can return a result set to the driver', () async {
      await conn.execute('''
        CREATE PROCEDURE all_names()
        BEGIN
          SELECT name FROM t ORDER BY id;
        END
      ''');
      final r = await conn.execute('CALL all_names()');
      expect(r.rows.map((row) => row.colAt(0)).toList(), ['alice', 'bob']);
    });

    test('session user-variables persist across statements', () async {
      await conn.execute('SET @greeting = \'hi\'');
      final r = await conn.execute('SELECT @greeting');
      expect(r.rows.first.colAt(0), 'hi');
    });

    test('CALL OUT parameter writes back to a @var', () async {
      await conn.execute('''
        CREATE PROCEDURE row_count(OUT c INT)
        BEGIN
          SELECT COUNT(*) INTO c FROM t;
        END
      ''');
      await conn.execute('CALL row_count(@n)');
      final r = await conn.execute('SELECT @n');
      expect(r.rows.first.colAt(0), '2');
    });

    test('COM_QUERY INSERT reports affectedRows', () async {
      final r = await conn.execute(
        "INSERT INTO t VALUES (3, 'carol'), (4, 'dave')",
      );
      expect(r.affectedRows.toInt(), 2);
    });

    test(
      'prepared statement with positional param returns the matching row',
      () async {
        final stmt = await conn.prepare('SELECT id, name FROM t WHERE id = ?');
        final r = await stmt.execute([2]);
        final rows = r.rows.map((r) => [r.colAt(0), r.colAt(1)]).toList();
        expect(rows, [
          ['2', 'bob'],
        ]);
        await stmt.deallocate();
      },
    );

    test('prepared INSERT with two params adds a row', () async {
      final stmt = await conn.prepare('INSERT INTO t VALUES (?, ?)');
      final r = await stmt.execute([5, 'eve']);
      expect(r.affectedRows.toInt(), 1);
      await stmt.deallocate();
      final back = await conn.execute('SELECT name FROM t WHERE id = 5');
      expect(back.rows.first.colAt(0), 'eve');
    });

    test(
      'multi-statement COM_QUERY returns one result per statement',
      () async {
        // `mysql_client`'s state machine only walks the linked list when
        // result sets carry column data, so this exercise sticks to SELECTs.
        final first = await conn.execute(
          "SELECT id FROM t WHERE id = 1;"
          "SELECT name FROM t WHERE id = 2;"
          "SELECT id, name FROM t WHERE id IN (1, 2) ORDER BY id",
        );
        final all = first.toList();
        expect(all.length, 3);
        expect(all[0].rows.map((r) => r.colAt(0)).toList(), ['1']);
        expect(all[1].rows.map((r) => r.colAt(0)).toList(), ['bob']);
        expect(all[2].rows.map((r) => [r.colAt(0), r.colAt(1)]).toList(), [
          ['1', 'alice'],
          ['2', 'bob'],
        ]);
      },
    );
  });
}
