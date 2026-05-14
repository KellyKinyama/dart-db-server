/// Phase-0.3 regression: `PRAGMA page_size` and `PRAGMA cache_size`
/// flow through to PagedTable.create / .open so user-tuned cache + page
/// sizes actually take effect on the out-of-core backend. Mirrors the
/// SQLite semantics: page_size is recorded on first table create and is
/// authoritative on reopen; cache_size accepts negative KiB or positive
/// page counts.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/paged_table.dart' show PagedTable;
import 'package:test/test.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_pragmas_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('default page_size = 4096 when no pragma is set', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT) USING paged');
      final tb = db.lookupBackend('t');
      expect(tb, isA<PagedTable>());
      expect((tb as PagedTable).pageSize, 4096);
    } finally {
      await db.close();
    }
  });

  test('PRAGMA page_size = 8192 flows to PagedTable.create', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('PRAGMA page_size = 8192');
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT) USING paged');
      final tb = db.lookupBackend('t') as PagedTable;
      expect(tb.pageSize, 8192);
    } finally {
      await db.close();
    }
  });

  test('invalid page_size falls back to 4096', () async {
    final db = await Database.open(dbPath());
    try {
      // Not a power of two.
      await db.execute('PRAGMA page_size = 6000');
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT) USING paged');
      expect((db.lookupBackend('t') as PagedTable).pageSize, 4096);
    } finally {
      await db.close();
    }
  });

  test('on-disk page_size is authoritative on reopen', () async {
    final path = dbPath();
    {
      final db = await Database.open(path);
      try {
        await db.execute('PRAGMA page_size = 8192');
        await db.execute(
            'CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT) USING paged');
        // Insert enough to actually exercise multi-page storage.
        for (var i = 0; i < 50; i++) {
          await db.execute("INSERT INTO t VALUES ($i, 'row-$i')");
        }
      } finally {
        await db.close();
      }
    }
    // Reopen WITHOUT setting page_size — meta.json should win, not the
    // 4096 default.
    final db2 = await Database.open(path);
    try {
      final tb = db2.lookupBackend('t') as PagedTable;
      expect(tb.pageSize, 8192);
      final r = await db2.execute('SELECT x FROM t WHERE id = 42');
      expect(r.rows, [
        ['row-42']
      ]);
    } finally {
      await db2.close();
    }
  });

  test('PRAGMA cache_size = -512 (KiB) does not break inserts', () async {
    final db = await Database.open(dbPath());
    try {
      // 512 KiB / 4096 B = 128-page cache.
      await db.execute('PRAGMA cache_size = -512');
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT) USING paged');
      for (var i = 0; i < 200; i++) {
        await db.execute("INSERT INTO t VALUES ($i, 'row-$i')");
      }
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows[0][0], 200);
    } finally {
      await db.close();
    }
  });

  test('PRAGMA cache_size = 4 (very small) still functions', () async {
    final db = await Database.open(dbPath());
    try {
      // Tiny cache forces frequent evictions — proves the LRU path is
      // exercised, not just default cap.
      await db.execute('PRAGMA cache_size = 4');
      await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT) USING paged');
      for (var i = 0; i < 100; i++) {
        await db.execute("INSERT INTO t VALUES ($i, 'row-$i')");
      }
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows[0][0], 100);
      final r2 = await db.execute('SELECT x FROM t WHERE id = 73');
      expect(r2.rows, [
        ['row-73']
      ]);
    } finally {
      await db.close();
    }
  });
}
