/// Phase-1.5 regression: `COUNT(col)` is rewritten to `COUNT(*)` for
/// the fast-path purposes when `col` is known non-NULL — i.e. declared
/// NOT NULL or the table's PRIMARY KEY. Falls back to the generic
/// aggregate path when nullability isn't known.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_count_col_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('COUNT(id) on integer PK uses fast path', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      for (var i = 1; i <= 10; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(id) FROM t');
      expect(r.rows, [
        [10],
      ]);
      // Default alias should preserve the column-form spelling.
      expect(r.columns, ['count(id)']);
    } finally {
      await db.close();
    }
  });

  test('COUNT(NOT NULL col) on in-memory table uses fast path', () async {
    final db = await Database.open();
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)');
      for (var i = 1; i <= 4; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 10})');
      }
      final r = await db.execute('SELECT COUNT(v) FROM t');
      expect(r.rows, [
        [4],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(nullable col) does NOT use the rewrite (counts non-NULLs)',
      () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('INSERT INTO t VALUES (1, 10)');
      await db.execute('INSERT INTO t VALUES (2, NULL)');
      await db.execute('INSERT INTO t VALUES (3, 30)');
      await db.execute('INSERT INTO t VALUES (4, NULL)');
      final r = await db.execute('SELECT COUNT(v) FROM t');
      expect(r.rows, [
        [2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(id) on paged-table PK uses fast path', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 25; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(id) FROM t');
      expect(r.rows, [
        [25],
      ]);
      expect(r.columns, ['count(id)']);
    } finally {
      await db.close();
    }
  });

  test('COUNT(non-PK col) on paged table falls through (no nullability info)',
      () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      await db.execute('INSERT INTO t VALUES (1, 10)');
      await db.execute('INSERT INTO t VALUES (2, 20)');
      // Generic path; correctness check only.
      final r = await db.execute('SELECT COUNT(v) FROM t');
      expect(r.rows, [
        [2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(id) AS n preserves explicit alias', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      for (var i = 1; i <= 3; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute('SELECT COUNT(id) AS n FROM t');
      expect(r.columns, ['n']);
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });

  test('COUNT(DISTINCT col) is not rewritten', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      var id = 1;
      for (final v in [1, 2, 2, 3, 3, 3]) {
        await db.execute('INSERT INTO t VALUES (${id++}, $v)');
      }
      final r = await db.execute('SELECT COUNT(DISTINCT v) FROM t');
      expect(r.rows, [
        [3],
      ]);
    } finally {
      await db.close();
    }
  });
}
