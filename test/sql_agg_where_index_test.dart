/// Phase-2.4 regression: bare aggregate (`MIN`/`MAX`/`SUM`/`AVG`/
/// `TOTAL`/`COUNT(col)`) on a single-column non-NOCASE non-partial
/// index, with WHERE restricted to the SAME column, is served from
/// the index — only the matching subrange is walked, no row hydration.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE INDEX i_v ON t(v)');
    var id = 1;
    for (final v in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]) {
      await db.execute('INSERT INTO t VALUES (${id++}, $v)');
    }
    return db;
  }

  test('SUM(v) WHERE v BETWEEN lo AND hi (range walk)', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT SUM(v) FROM t WHERE v BETWEEN 3 AND 7');
      expect(r.rows.first.first, 25); // 3+4+5+6+7
      expect(r.columns, ['sum(v)']);
    } finally {
      await db.close();
    }
  });

  test('AVG(v) WHERE v >= a AND v <= b', () async {
    final db = await seed();
    try {
      final r =
          await db.execute('SELECT AVG(v) FROM t WHERE v >= 4 AND v <= 8');
      expect((r.rows.first.first as num).toDouble(), closeTo(6.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('TOTAL(v) WHERE v BETWEEN, no matches → 0.0', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT TOTAL(v) FROM t WHERE v BETWEEN 100 AND 200');
      expect((r.rows.first.first as num).toDouble(), closeTo(0.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('SUM/AVG WHERE no matches → NULL', () async {
    final db = await seed();
    try {
      final r1 =
          await db.execute('SELECT SUM(v) FROM t WHERE v BETWEEN 100 AND 200');
      expect(r1.rows.first.first, isNull);
      final r2 =
          await db.execute('SELECT AVG(v) FROM t WHERE v BETWEEN 100 AND 200');
      expect(r2.rows.first.first, isNull);
    } finally {
      await db.close();
    }
  });

  test('MIN/MAX WHERE BETWEEN restrict to subrange', () async {
    final db = await seed();
    try {
      final r1 =
          await db.execute('SELECT MIN(v) FROM t WHERE v BETWEEN 4 AND 8');
      expect(r1.rows.first.first, 4);
      final r2 =
          await db.execute('SELECT MAX(v) FROM t WHERE v BETWEEN 4 AND 8');
      expect(r2.rows.first.first, 8);
    } finally {
      await db.close();
    }
  });

  test('SUM(v) WHERE v IN (3, 5, 7)', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT SUM(v) FROM t WHERE v IN (3, 5, 7)');
      expect(r.rows.first.first, 15);
    } finally {
      await db.close();
    }
  });

  test('COUNT(v) WHERE v = lit (single key)', () async {
    final db = await seed();
    try {
      // Add a duplicate so the posting list has length > 1.
      await db.execute('INSERT INTO t VALUES (11, 5)');
      final r = await db.execute('SELECT COUNT(v) FROM t WHERE v = 5');
      expect(r.rows.first.first, 2);
    } finally {
      await db.close();
    }
  });

  test('SUM with weighted duplicates in subrange', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX i_v ON t(v)');
      var id = 1;
      // 3x 10, 2x 5, 1x 1 — restrict to v >= 5 → 3x10 + 2x5 = 40
      for (final v in [10, 10, 5, 10, 5, 1]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT SUM(v) FROM t WHERE v >= 5');
      expect(r.rows.first.first, 40);
    } finally {
      await db.close();
    }
  });

  test('Open range: v < hi only — bails (no upper-only support)', () async {
    // Single-sided ranges aren't recognized; falls through to generic
    // path which still returns the right answer.
    final db = await seed();
    try {
      final r = await db.execute('SELECT SUM(v) FROM t WHERE v <= 4');
      expect(r.rows.first.first, 10); // 1+2+3+4
    } finally {
      await db.close();
    }
  });

  test('AVG WHERE col = NULL → empty input → NULL', () async {
    final db = await seed();
    try {
      final r = await db.execute('SELECT AVG(v) FROM t WHERE v = NULL');
      expect(r.rows.first.first, isNull);
    } finally {
      await db.close();
    }
  });

  test('Aggregate on non-indexed col falls through (correctness)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      // No index on v.
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r =
          await db.execute('SELECT SUM(v) FROM t WHERE v BETWEEN 2 AND 4');
      expect(r.rows.first.first, 9);
    } finally {
      await db.close();
    }
  });
}
