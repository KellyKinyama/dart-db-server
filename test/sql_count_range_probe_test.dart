/// Phase-1.9 regression: `SELECT COUNT(*) FROM t WHERE col BETWEEN
/// lo AND hi` and `WHERE col >= lo AND col <= hi` (and the < / >
/// flavours) short-circuit by walking the index map's sorted keys
/// in [lo, hi] and summing posting-list lengths.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('COUNT(*) WHERE col BETWEEN a AND b', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 100; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k BETWEEN 30 AND 40');
      expect(r.rows, [
        [11], // 30..40 inclusive
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WHERE col >= a AND col <= b matches BETWEEN', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 100; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k >= 30 AND k <= 40');
      expect(r.rows, [
        [11],
      ]);
    } finally {
      await db.close();
    }
  });

  test('Half-open: col >= a AND col < b', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 20; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k >= 5 AND k < 10');
      expect(r.rows, [
        [5], // 5,6,7,8,9
      ]);
    } finally {
      await db.close();
    }
  });

  test('Range with literal-on-left commuted bound', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 20; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      // 5 <= k AND k < 10
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE 5 <= k AND k < 10');
      expect(r.rows, [
        [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('Empty range returns 0', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 20; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k BETWEEN 50 AND 60');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('TEXT BETWEEN', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, s TEXT)');
      await db.execute('CREATE INDEX i_s ON t(s)');
      var id = 1;
      for (final s in ['alpha', 'bravo', 'charlie', 'delta', 'echo']) {
        await db.execute("INSERT INTO t VALUES (${id++}, '$s')");
      }
      final r = await db
          .execute("SELECT COUNT(*) FROM t WHERE s BETWEEN 'b' AND 'd'");
      expect(r.rows, [
        [2], // 'bravo', 'charlie'
      ]);
    } finally {
      await db.close();
    }
  });

  test('NOT BETWEEN falls through to generic path', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db
          .execute('SELECT COUNT(*) FROM t WHERE k NOT BETWEEN 3 AND 7');
      expect(r.rows, [
        [5], // 1, 2, 8, 9, 10
      ]);
    } finally {
      await db.close();
    }
  });

  test('Range over duplicate keys sums posting lists correctly', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      var id = 1;
      // 3x 1, 5x 2, 2x 3, 4x 4, 1x 5
      for (final p in [
        [1, 3],
        [2, 5],
        [3, 2],
        [4, 4],
        [5, 1],
      ]) {
        for (var j = 0; j < p[1]; j++) {
          await db.execute('INSERT INTO t VALUES (${id++}, ${p[0]})');
        }
      }
      final r =
          await db.execute('SELECT COUNT(*) FROM t WHERE k BETWEEN 2 AND 4');
      expect(r.rows, [
        [11], // 5 + 2 + 4
      ]);
    } finally {
      await db.close();
    }
  });
}
