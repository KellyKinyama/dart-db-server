/// sqlite_master / sqlite_schema introspection.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('sqlite_master', () {
    test('lists tables, views, indexes', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INT, n TEXT)');
        await db.execute('CREATE INDEX ix_n ON t(n)');
        await db.execute('CREATE VIEW v AS SELECT id FROM t');
        final r =
            await db.execute("SELECT type, name, tbl_name FROM sqlite_master "
                'ORDER BY type, name');
        expect(r.rows, [
          ['index', 'ix_n', 't'],
          ['table', 't', 't'],
          ['view', 'v', 'v'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('sqlite_schema is the same view', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        final r = await db
            .execute("SELECT count(*) FROM sqlite_schema WHERE type='table'");
        expect((r.rows.first.first as num).toInt(), 1);
      } finally {
        await db.close();
      }
    });

    test('sql column has CREATE TABLE-shaped string', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        final r = await db.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='t'");
        final sql = r.rows.first.first as String;
        expect(sql.toUpperCase(), startsWith('CREATE TABLE'));
        expect(sql, contains('t'));
      } finally {
        await db.close();
      }
    });

    test('rootpage is 0', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        final r = await db
            .execute("SELECT rootpage FROM sqlite_master WHERE name='t'");
        expect(r.rows.first.first, 0);
      } finally {
        await db.close();
      }
    });
  });
}
