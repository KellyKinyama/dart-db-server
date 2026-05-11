/// Planner: `col LIKE 'prefix%'` on a BINARY-indexed text column should
/// be served by a range scan over the index, not a full scan. LIKE in
/// this engine is case-sensitive, so a BINARY index is the safe target.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('LIKE prefix range optimization', () {
    test('BINARY index serves LIKE prefix as a range scan', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        for (var i = 0; i < 200; i++) {
          await db.execute("INSERT INTO t VALUES ($i, 'Name$i')");
        }
        await db.execute('CREATE INDEX t_name ON t(name)');
        final r = await db
            .execute("SELECT id FROM t WHERE name LIKE 'Name1%' ORDER BY id");
        // Name1, Name10..Name19, Name100..Name199 -> 1, 10..19, 100..199.
        final ids = r.rows.map((r) => r.first as int).toList();
        expect(ids.contains(1), isTrue);
        expect(ids.contains(15), isTrue);
        expect(ids.contains(199), isTrue);
        expect(ids.contains(200), isFalse);
        expect(ids.contains(0), isFalse);
        expect(db.lastPlanTrace.join(' '), contains('t_name'),
            reason: 'expected planner to use t_name index for LIKE prefix, '
                'got: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('LIKE without a fixed prefix falls back to a scan', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        for (var i = 0; i < 50; i++) {
          await db.execute("INSERT INTO t VALUES ($i, 'Name$i')");
        }
        await db.execute('CREATE INDEX t_name ON t(name)');
        // Leading % - cannot be served by index.
        final r = await db.execute("SELECT id FROM t WHERE name LIKE '%9'");
        expect(r.rows.isNotEmpty, isTrue);
        expect(db.lastPlanTrace.join(' '), isNot(contains('t_name')),
            reason: 'planner should not use index for non-prefix LIKE, '
                'got: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('NOCASE index is not used for case-sensitive LIKE prefix', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        for (var i = 0; i < 30; i++) {
          await db.execute("INSERT INTO t VALUES ($i, 'Name$i')");
        }
        await db.execute('CREATE INDEX t_name ON t(name COLLATE NOCASE)');
        // LIKE here is case-sensitive: 'Name%' matches all 30 rows.
        // A NOCASE index's lowercased keys would yield 0 rows on a
        // BINARY range scan of 'Name'..'Namf', so the planner must
        // refuse to use it.
        final r = await db
            .execute("SELECT id FROM t WHERE name LIKE 'Name%' ORDER BY id");
        expect(r.rows.length, 30);
        expect(db.lastPlanTrace.join(' '), isNot(contains('t_name')),
            reason: 'NOCASE index must not be used for case-sensitive LIKE, '
                'got: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('underscore wildcard before % disables the optimisation', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
        await db
            .execute("INSERT INTO t VALUES (1, 'abc'), (2, 'axc'), (3, 'azc')");
        await db.execute('CREATE INDEX t_name ON t(name)');
        final r = await db
            .execute("SELECT id FROM t WHERE name LIKE 'a_c%' ORDER BY id");
        expect(r.rows.map((r) => r.first).toList(), [1, 2, 3]);
        expect(db.lastPlanTrace.join(' '), isNot(contains('t_name')));
      } finally {
        await db.close();
      }
    });
  });
}
