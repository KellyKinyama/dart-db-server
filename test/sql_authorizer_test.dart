/// Authorizer hook: callback can deny or silently ignore statements.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Authorizer', () {
    test('deny on DROP TABLE blocks the statement', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE t(id INTEGER)');
      await db.execute('INSERT INTO t VALUES (1)');
      db.authorizer = (stmt, table) {
        if (stmt is DropTableStmt) return AuthorizerResult.deny;
        return AuthorizerResult.allow;
      };
      Object? err;
      try {
        await db.execute('DROP TABLE t');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      // Data still intact.
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.first[0], 1);
    });

    test('ignore silently skips the statement', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE t(id INTEGER)');
      db.authorizer = (stmt, table) {
        if (stmt is InsertStmt) return AuthorizerResult.ignore;
        return AuthorizerResult.allow;
      };
      await db.execute('INSERT INTO t VALUES (42)');
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.first[0], 0,
          reason: 'INSERT should have been ignored, not applied');
    });

    test('allowlist by table name', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE pub(id INTEGER, v TEXT)');
      await db.execute('CREATE TABLE secret(id INTEGER, v TEXT)');
      await db.execute("INSERT INTO secret VALUES (1, 'shh')");
      db.authorizer = (stmt, table) {
        if (stmt is SelectStmt && table == 'secret') {
          return AuthorizerResult.deny;
        }
        return AuthorizerResult.allow;
      };
      Object? err;
      try {
        await db.execute('SELECT * FROM secret');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      // Public table still queryable.
      final r = await db.execute('SELECT COUNT(*) FROM pub');
      expect(r.rows.first[0], 0);
    });
  });
}
