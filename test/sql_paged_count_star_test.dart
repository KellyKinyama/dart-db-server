/// Phase-1.4 regression: bare `SELECT COUNT(*) FROM t` short-circuits
/// for paged-backed tables via `PagedTable.length` (O(1)) without
/// hydrating any row. Falls through (returns null from the fast path)
/// when WHERE is present, since paged COUNT-with-WHERE is not yet
/// optimised.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_count_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('COUNT(*) on empty paged table returns 0', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows, [
        [0],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) on paged table returns row count', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 137; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 2})');
      }
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows, [
        [137],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) AS alias preserves alias on paged table', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(*) AS n FROM t');
      expect(r.columns, ['n']);
      expect(r.rows, [
        [5],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) reflects deletes on paged table', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 20; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      await db.execute('DELETE FROM t WHERE id <= 7');
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows, [
        [13],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) WITH WHERE on paged table still produces correct count',
      () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 50; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      // Generic aggregate path handles this; we just check correctness.
      final r = await db.execute('SELECT COUNT(*) FROM t WHERE v > 30');
      expect(r.rows, [
        [20],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(*) honors LIMIT 0 / OFFSET 1 on paged table', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r0 = await db.execute('SELECT COUNT(*) FROM t LIMIT 0');
      expect(r0.rows, isEmpty);
      final r1 = await db.execute('SELECT COUNT(*) FROM t LIMIT 1 OFFSET 1');
      expect(r1.rows, isEmpty);
    } finally {
      await db.close();
    }
  });
}
