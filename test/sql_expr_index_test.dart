/// Tests for expression-index planner narrowing.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('expression index narrowing', () {
    test('planner uses an expression index when the query has the same expr',
        () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        for (var i = 0; i < 200; i++) {
          await db.execute("INSERT INTO t VALUES ($i, 'Name$i')");
        }
        await db.execute('CREATE INDEX t_lower ON t(LOWER(name))');

        final r = await db
            .execute("SELECT id FROM t WHERE LOWER(name) = 'name42'");
        expect(r.rows, [
          [42]
        ]);
        expect(db.lastPlanTrace.join(' '), contains('t_lower'),
            reason: 'expected planner to choose t_lower expression index, '
                'got: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('planner ignores the expression index when the query uses the raw column',
        () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        for (var i = 0; i < 200; i++) {
          await db.execute("INSERT INTO t VALUES ($i, 'Name$i')");
        }
        await db.execute('CREATE INDEX t_lower ON t(LOWER(name))');

        final r = await db
            .execute("SELECT id FROM t WHERE name = 'Name42'");
        expect(r.rows, [
          [42]
        ]);
        expect(db.lastPlanTrace.join(' '), isNot(contains('t_lower')),
            reason: 'expression index incorrectly chosen for raw-column '
                'predicate: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('expression index reflects rows inserted after CREATE INDEX',
        () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        await db.execute('CREATE INDEX t_lower ON t(LOWER(name))');
        await db.execute("INSERT INTO t VALUES (1, 'Alpha')");
        await db.execute("INSERT INTO t VALUES (2, 'Beta')");
        final r = await db
            .execute("SELECT id FROM t WHERE LOWER(name) = 'beta'");
        expect(r.rows, [
          [2]
        ]);
      } finally {
        await db.close();
      }
    });

    test('expression index drops rows on DELETE', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        await db.execute('CREATE INDEX t_lower ON t(LOWER(name))');
        await db.execute("INSERT INTO t VALUES (1, 'Foo')");
        await db.execute("INSERT INTO t VALUES (2, 'Foo')");
        await db.execute('DELETE FROM t WHERE id = 1');
        final r = await db
            .execute("SELECT id FROM t WHERE LOWER(name) = 'foo'");
        expect(r.rows, [
          [2]
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
