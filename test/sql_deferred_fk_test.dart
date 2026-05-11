/// PRAGMA defer_foreign_keys: FK checks postponed to COMMIT.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Deferred FK', () {
    test('insert child before parent inside transaction succeeds at commit',
        () async {
      final db = await Database.open();
      await db
          .execute('CREATE TABLE parent(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute('CREATE TABLE child(id INTEGER PRIMARY KEY, '
          'parent_id INTEGER REFERENCES parent(id))');
      await db.execute('PRAGMA defer_foreign_keys = 1');
      await db.execute('BEGIN');
      // Out-of-order insert: child references a parent row that does
      // not yet exist. Without deferred FK this would throw.
      await db.execute('INSERT INTO child VALUES (10, 1)');
      await db.execute("INSERT INTO parent VALUES (1, 'p')");
      await db.execute('COMMIT');
      final r =
          await db.execute('SELECT c.id, p.name FROM child c JOIN parent p '
              'ON p.id = c.parent_id');
      expect(r.rows, [
        [10, 'p']
      ]);
    });

    test('unresolved deferred FK at commit rolls back', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE parent(id INTEGER PRIMARY KEY)');
      await db.execute('CREATE TABLE child(id INTEGER PRIMARY KEY, '
          'parent_id INTEGER REFERENCES parent(id))');
      await db.execute('PRAGMA defer_foreign_keys = 1');
      await db.execute('BEGIN');
      await db.execute('INSERT INTO child VALUES (1, 99)');
      Object? err;
      try {
        await db.execute('COMMIT');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      // The bad row must not be visible after rollback.
      final r = await db.execute('SELECT COUNT(*) FROM child');
      expect(r.rows.first[0], 0);
    });

    test('with deferred OFF, child insert still throws immediately', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE parent(id INTEGER PRIMARY KEY)');
      await db.execute('CREATE TABLE child(id INTEGER PRIMARY KEY, '
          'parent_id INTEGER REFERENCES parent(id))');
      await db.execute('BEGIN');
      Object? err;
      try {
        await db.execute('INSERT INTO child VALUES (1, 1)');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      await db.execute('ROLLBACK');
    });
  });
}
