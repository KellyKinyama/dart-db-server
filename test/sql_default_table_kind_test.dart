/// Phase-0.2 regression: `PRAGMA default_table_kind = paged` auto-routes
/// bare `CREATE TABLE` statements to the paged backend on path-backed
/// databases, with safe fallback for shapes the paged backend can't
/// host (no PK, composite PK, STRICT, WITHOUT ROWID, in-memory DBs).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_default_kind_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('default is memory; bare CREATE TABLE stays in-memory', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT)');
      final tb = db.lookupBackend('t')!;
      expect(tb.kind, TableBackendKind.memory);
    } finally {
      await db.close();
    }
  });

  test('PRAGMA default_table_kind = paged routes new tables to paged',
      () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('PRAGMA default_table_kind = paged');
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT)');
      final tb = db.lookupBackend('t')!;
      expect(tb.kind, TableBackendKind.paged);

      await db.execute("INSERT INTO t VALUES (1, 'hello')");
      final r = await db.execute('SELECT id, x FROM t WHERE id = 1');
      expect(r.rows, [
        [1, 'hello']
      ]);
    } finally {
      await db.close();
    }
  });

  test('flipping the pragma back to memory restores in-memory routing',
      () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('PRAGMA default_table_kind = paged');
      await db.execute('CREATE TABLE p (id INTEGER PRIMARY KEY)');
      await db.execute('PRAGMA default_table_kind = memory');
      await db.execute('CREATE TABLE m (id INTEGER PRIMARY KEY)');
      expect(db.lookupBackend('p')!.kind, TableBackendKind.paged);
      expect(db.lookupBackend('m')!.kind, TableBackendKind.memory);
    } finally {
      await db.close();
    }
  });

  test('paged-incompatible shapes fall back to in-memory', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('PRAGMA default_table_kind = paged');

      // No primary key -> not paged-eligible.
      await db.execute('CREATE TABLE nopk (x INTEGER, y TEXT)');
      expect(db.lookupBackend('nopk')!.kind, TableBackendKind.memory);

      // Composite primary key -> not paged-eligible.
      await db.execute(
          'CREATE TABLE comp (a INTEGER, b INTEGER, PRIMARY KEY (a, b))');
      expect(db.lookupBackend('comp')!.kind, TableBackendKind.memory);

      // STRICT -> not paged-eligible.
      await db.execute(
          'CREATE TABLE s (id INTEGER PRIMARY KEY, x TEXT) STRICT');
      expect(db.lookupBackend('s')!.kind, TableBackendKind.memory);
    } finally {
      await db.close();
    }
  });

  test('in-memory database ignores PRAGMA default_table_kind = paged',
      () async {
    // No path -> _pagedDir is null -> auto-pageing must NOT engage.
    final db = await Database.open();
    try {
      await db.execute('PRAGMA default_table_kind = paged');
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT)');
      final tb = db.lookupBackend('t')!;
      expect(tb.kind, TableBackendKind.memory);
    } finally {
      await db.close();
    }
  });

  test('explicit USING paged still wins regardless of pragma', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('PRAGMA default_table_kind = memory');
      await db.execute(
          'CREATE TABLE p (id INTEGER PRIMARY KEY, x TEXT) USING paged');
      expect(db.lookupBackend('p')!.kind, TableBackendKind.paged);
    } finally {
      await db.close();
    }
  });

  test('auto-paged tables survive close/reopen', () async {
    final path = dbPath();
    {
      final db = await Database.open(path);
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT)');
        await db.execute("INSERT INTO t VALUES (1, 'persisted')");
      } finally {
        await db.close();
      }
    }
    final db2 = await Database.open(path);
    try {
      final tb = db2.lookupBackend('t')!;
      expect(tb.kind, TableBackendKind.paged);
      final r = await db2.execute('SELECT x FROM t WHERE id = 1');
      expect(r.rows, [
        ['persisted']
      ]);
    } finally {
      await db2.close();
    }
  });
}
