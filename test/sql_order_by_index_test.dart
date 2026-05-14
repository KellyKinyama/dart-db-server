/// Phase-0.7 regression: ORDER BY can be satisfied by index order, so
/// the executor skips the post-scan sort entirely. We assert both row
/// correctness and the `lastPlanSortSkipped` introspection flag.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('ORDER BY single indexed column ASC skips sort', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      // Insert out-of-order so a scan would NOT return rows sorted.
      var id = 1;
      for (final v in [50, 10, 30, 5, 90, 20, 40, 60, 70, 80]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db
          .execute('SELECT v FROM t WHERE v >= 10 AND v <= 80 ORDER BY v');
      expect(r.rows.map((row) => row[0]).toList(),
          [10, 20, 30, 40, 50, 60, 70, 80]);
      expect(db.lastPlanSortSkipped, isTrue);
    } finally {
      await db.close();
    }
  });

  test('ORDER BY composite-index columns ASC skips sort', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_ab ON t(a, b)');
      // Insert in scrambled (a, b) order with unique ids.
      final inserts = <List<int>>[
        for (var i = 0; i < 40; i++) [i + 1, i % 4, (i * 13) % 50],
      ];
      inserts.shuffle();
      for (final row in inserts) {
        await db
            .execute('INSERT INTO t VALUES (${row[0]}, ${row[1]}, ${row[2]})');
      }
      // a is equality-bound by the WHERE → b is the only sort key the
      // index provides, and the planner uses (a, b)-prefix scan.
      final r = await db.execute('SELECT a, b FROM t WHERE a = 2 ORDER BY b');
      final bs = r.rows.map((row) => row[1] as int).toList();
      expect(bs, equals(List<int>.from(bs)..sort()));
      expect(bs, isNotEmpty);
      expect(db.lastPlanSortSkipped, isTrue);
    } finally {
      await db.close();
    }
  });

  test('ORDER BY equality column alone trivially skips sort', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k TEXT)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      for (final k in ['x', 'y', 'x', 'z', 'x']) {
        await db.execute("INSERT INTO t VALUES (${id++}, '$k')");
      }
      final r = await db.execute("SELECT id FROM t WHERE k = 'x' ORDER BY k");
      expect(r.rows.length, 3);
      expect(db.lastPlanSortSkipped, isTrue);
    } finally {
      await db.close();
    }
  });

  test('ORDER BY DESC on indexed column reverses (no sort)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [3, 1, 4, 1, 5, 9, 2, 6]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db
          .execute('SELECT v FROM t WHERE v >= 1 AND v <= 9 ORDER BY v DESC');
      expect(r.rows.map((row) => row[0]).toList(), [9, 6, 5, 4, 3, 2, 1, 1]);
      // Phase 0.8: DESC is now satisfied by reversing the index walk.
      expect(db.lastPlanSortSkipped, isTrue);
    } finally {
      await db.close();
    }
  });

  test('ORDER BY mixed ASC + DESC on different cols still sorts', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t '
          '(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_ab ON t(a, b)');
      var id = 1;
      for (var a = 0; a < 3; a++) {
        for (var b = 0; b < 3; b++) {
          await db.execute('INSERT INTO t VALUES (${id++}, $a, $b)');
        }
      }
      // Mixed direction can't be served by a single forward/reverse walk.
      final r = await db.execute(
          'SELECT a, b FROM t WHERE a >= 0 ORDER BY a ASC, b DESC');
      expect(db.lastPlanSortSkipped, isFalse);
      // Spot-check correctness:
      expect(r.rows.first, [0, 2]);
      expect(r.rows.last, [2, 0]);
    } finally {
      await db.close();
    }
  });

  test('ORDER BY on non-index column still sorts', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_a ON t(a)');
      for (var i = 0; i < 10; i++) {
        await db.execute('INSERT INTO t VALUES (${i + 1}, ${i % 3}, ${9 - i})');
      }
      final r = await db.execute('SELECT id, b FROM t WHERE a = 1 ORDER BY b');
      final bs = r.rows.map((row) => row[1] as int).toList();
      expect(bs, equals(List<int>.from(bs)..sort()));
      // Index gives us (a, rowid) order, not b-order → must sort.
      expect(db.lastPlanSortSkipped, isFalse);
    } finally {
      await db.close();
    }
  });

  test('aggregate query never claims sort skipped', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t WHERE v >= 1 GROUP BY v ORDER BY v');
      expect(r.rows, [
        [1, 1],
        [2, 2],
        [3, 3],
      ]);
      expect(db.lastPlanSortSkipped, isFalse);
    } finally {
      await db.close();
    }
  });
}
