/// More syntactic SQLite parity: EXPLAIN QUERY PLAN; DROP INDEX IF EXISTS.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('EXPLAIN QUERY PLAN', () {
    test('parses and runs like EXPLAIN', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        await db.execute('INSERT INTO t VALUES (1),(2),(3)');
        final r = await db.execute('EXPLAIN QUERY PLAN SELECT * FROM t');
        // Whatever EXPLAIN returns today, EXPLAIN QUERY PLAN must
        // produce the same shape (this just checks it didn't throw and
        // returned at least one row OR a message).
        expect(r.rows.length + (r.message == null ? 0 : 1), greaterThan(0));
      } finally {
        await db.close();
      }
    });
  });

  group('DROP INDEX IF EXISTS', () {
    test('no-op on missing index', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        // Without IF EXISTS this would throw.
        final r = await db.execute('DROP INDEX IF EXISTS no_such_index');
        expect(r.message, contains('did not exist'));
      } finally {
        await db.close();
      }
    });

    test('drops a real index', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        await db.execute('CREATE INDEX ix ON t(x)');
        final r = await db.execute('DROP INDEX IF EXISTS ix');
        expect(r.message, contains('dropped'));
      } finally {
        await db.close();
      }
    });

    test('without IF EXISTS still throws on missing', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        expect(() => db.execute('DROP INDEX no_such_index'),
            throwsA(isA<StateError>()));
      } finally {
        await db.close();
      }
    });
  });
}
