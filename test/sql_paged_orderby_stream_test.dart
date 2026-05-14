/// Phase-1.0 regression: paged-table SELECT with `ORDER BY pk ASC`
/// now stream-skips the buffer-and-sort. The result must still be
/// correct (PK-ordered, OFFSET / LIMIT honored) and the path must
/// terminate after `offset + limit` rows even when the matched range
/// is much larger.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_orderby_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('ASC + LIMIT streams in PK order and terminates early', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      // Insert in scrambled order to prove we're returning by PK, not
      // by insertion order.
      final ids = [for (var i = 1; i <= 200; i++) i]..shuffle();
      for (final id in ids) {
        await db.execute('INSERT INTO t VALUES ($id, ${id * 10})');
      }
      final r = await db.execute('SELECT id, v FROM t ORDER BY id LIMIT 5');
      expect(r.rows, [
        [1, 10],
        [2, 20],
        [3, 30],
        [4, 40],
        [5, 50],
      ]);
    } finally {
      await db.close();
    }
  });

  test('ASC + OFFSET + LIMIT slices correctly mid-range', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 50; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 100})');
      }
      final r = await db.execute(
          'SELECT id FROM t ORDER BY id LIMIT 4 OFFSET 10');
      expect(r.rows, [
        [11],
        [12],
        [13],
        [14],
      ]);
    } finally {
      await db.close();
    }
  });

  test('DESC + LIMIT still buffers but produces correct result', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 20; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute(
          'SELECT id FROM t ORDER BY id DESC LIMIT 3');
      expect(r.rows, [
        [20],
        [19],
        [18],
      ]);
    } finally {
      await db.close();
    }
  });

  test('ASC ORDER BY composes with WHERE on PK range', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, v INTEGER) USING paged');
      for (var i = 1; i <= 30; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      final r = await db.execute(
          'SELECT id FROM t WHERE id >= 10 AND id < 20 ORDER BY id LIMIT 4');
      expect(r.rows, [
        [10],
        [11],
        [12],
        [13],
      ]);
    } finally {
      await db.close();
    }
  });
}
