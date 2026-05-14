/// Phase-0.6 regression: in-memory composite-index plans can now combine
/// an equality prefix with a range predicate on the *next* indexed
/// column, matching what the paged backend already did. Verified
/// through both row correctness and EXPLAIN QUERY PLAN.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('composite index: leading equality + trailing range is correct',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_ab ON t(a, b)');
      for (var i = 0; i < 100; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 4}, $i)');
      }
      // a=2 selects {2, 6, 10, ..., 98}; restricting b in [20, 60] keeps
      // {22, 26, 30, ..., 58}.
      final r = await db.execute(
          'SELECT id FROM t WHERE a = 2 AND b >= 20 AND b <= 60 ORDER BY id');
      final expected = <List<Object?>>[
        for (var i = 0; i < 100; i++)
          if (i % 4 == 2 && i >= 20 && i <= 60) [i],
      ];
      expect(r.rows, expected);
    } finally {
      await db.close();
    }
  });

  test('composite index: half-open range (only upper) still works',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_ab ON t(a, b)');
      for (var i = 0; i < 30; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 3}, $i)');
      }
      final r = await db.execute(
          'SELECT id FROM t WHERE a = 0 AND b < 15 ORDER BY id');
      final expected = <List<Object?>>[
        for (var i = 0; i < 30; i++)
          if (i % 3 == 0 && i < 15) [i],
      ];
      expect(r.rows, expected);
    } finally {
      await db.close();
    }
  });

  test('EXPLAIN QUERY PLAN uses the composite index for prefix+range',
      () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute('CREATE INDEX i_ab ON t(a, b)');
      for (var i = 0; i < 60; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 3}, $i)');
      }
      final r = await db.execute(
          'EXPLAIN QUERY PLAN SELECT id FROM t WHERE a = 1 AND b > 10');
      // The plan trace is surfaced through the result rows; flatten and
      // assert the composite index is used (rather than a full scan).
      final text = r.rows.map((row) => row.join(' ')).join('\n').toUpperCase();
      expect(text, contains('I_AB'));
      expect(text, contains('SEARCH'));
    } finally {
      await db.close();
    }
  });

  test('three-column index, prefix=2 + range on 3rd column', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, c INTEGER)');
      await db.execute('CREATE INDEX i_abc ON t(a, b, c)');
      for (var i = 0; i < 200; i++) {
        await db.execute(
            'INSERT INTO t VALUES ($i, ${i % 5}, ${(i ~/ 5) % 4}, $i)');
      }
      final r = await db.execute('SELECT id FROM t '
          'WHERE a = 2 AND b = 1 AND c >= 50 AND c < 150 ORDER BY id');
      final expected = <List<Object?>>[
        for (var i = 0; i < 200; i++)
          if (i % 5 == 2 && (i ~/ 5) % 4 == 1 && i >= 50 && i < 150) [i],
      ];
      expect(r.rows, expected);
    } finally {
      await db.close();
    }
  });
}
