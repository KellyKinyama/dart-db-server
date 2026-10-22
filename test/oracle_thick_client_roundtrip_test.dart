/// End-to-end round-trip of the pure-Dart native (thick) client in
/// `lib/oracle_thick_client.dart` against a real [OracleServer]: native
/// O5LOGON auth, DML affected-row counts, a single- and multi-column SELECT,
/// a bound query, NULL handling, and FETCH pagination past one prefetch batch.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/oracle_thick_client.dart';
import 'package:test/test.dart';

void main() {
  group('native thick-client query round-trip', () {
    late Database db;
    late OracleServer server;
    late OracleThickClient client;

    setUp(() async {
      db = await Database.open(null);
      server = OracleServer(db, port: 0, users: {'app': 'secret'});
      await server.start();
      server.userStore.addPbkdf2User('native', 'Secret123');
      client = await OracleThickClient.connect(server.boundPort);
      final login =
          await client.login(username: 'native', password: 'Secret123');
      expect(login.authenticated, isTrue, reason: 'native login should succeed');
    });

    tearDown(() async {
      await client.close();
      await server.stop();
    });

    test('DDL + DML report affected rows, SELECT decodes columns and rows',
        () async {
      expect(
          await client.execute(
              'CREATE TABLE t (id INTEGER PRIMARY KEY, name VARCHAR2(40))'),
          0);
      expect(
          await client
              .execute("INSERT INTO t (id, name) VALUES (1, 'alice')"),
          1);
      expect(
          await client.execute("INSERT INTO t (id, name) VALUES (2, 'bob')"),
          1);

      final result = await client.query('SELECT id, name FROM t ORDER BY id');
      expect(result.isQuery, isTrue);
      expect(result.columns, ['id', 'name']);
      expect(result.rows, [
        [1, 'alice'],
        [2, 'bob'],
      ]);
    });

    test('a bound query filters on the supplied value', () async {
      await client.execute('CREATE TABLE p (id INTEGER PRIMARY KEY, v INTEGER)');
      await client.execute('INSERT INTO p (id, v) VALUES (1, 10)');
      await client.execute('INSERT INTO p (id, v) VALUES (2, 20)');
      await client.execute('INSERT INTO p (id, v) VALUES (3, 30)');

      final result = await client
          .query('SELECT id FROM p WHERE v > :min ORDER BY id', binds: [15]);
      expect(result.rows, [
        [2],
        [3],
      ]);
    });

    test('NULL column values decode to null', () async {
      await client
          .execute('CREATE TABLE n (id INTEGER PRIMARY KEY, label VARCHAR2(20))');
      await client.execute('INSERT INTO n (id, label) VALUES (1, NULL)');

      final result = await client.query('SELECT id, label FROM n');
      expect(result.rows, [
        [1, null],
      ]);
    });

    test('a scalar expression round-trips as a NUMBER', () async {
      final result = await client.query('SELECT 6 * 7 AS answer FROM dual');
      expect(result.columns, ['answer']);
      expect(result.rows, [
        [42],
      ]);
    });

    test('a result larger than one prefetch batch paginates via FETCH',
        () async {
      await client.execute('CREATE TABLE big (id INTEGER PRIMARY KEY)');
      const total = 250; // > nativeBatchSize (100): forces FETCH pagination
      for (var i = 1; i <= total; i++) {
        await client.execute('INSERT INTO big (id) VALUES ($i)');
      }

      final result = await client.query('SELECT id FROM big ORDER BY id');
      expect(result.rows.length, total);
      expect(result.rows.first, [1]);
      expect(result.rows.last, [total]);
      // Every id present exactly once and in order.
      for (var i = 0; i < total; i++) {
        expect(result.rows[i], [i + 1]);
      }
    });

    test('a bad statement surfaces as an OracleThickException', () async {
      await expectLater(
        client.query('SELECT * FROM does_not_exist'),
        throwsA(isA<OracleThickException>()),
      );
    });
  });
}
