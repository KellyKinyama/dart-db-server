/// End-to-end tests for `Database.exportSqlite` / `Database.importSqlite`,
/// which round-trip the in-memory engine state through real SQLite-format
/// `.sqlite` files.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag, [String ext = 'sqlite']) =>
    File('${Directory.systemTemp.path}/'
        'ddb_export_${tag}_${DateTime.now().microsecondsSinceEpoch}.$ext');

void main() {
  group('exportSqlite', () {
    test('produces a file SQLite can open and read', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY, '
            'name TEXT NOT NULL, score REAL)');
        await db.execute("INSERT INTO users VALUES (1, 'alice', 9.5), "
            "(2, 'bob', 7.25), (3, 'carol', NULL)");
        final out = _tmp('users');
        addTearDown(
            () async { if (await out.exists()) await out.delete(); });
        await db.exportSqlite(out.path);
        final ref = sq.sqlite3.open(out.path);
        try {
          expect(ref.select('PRAGMA integrity_check').rows.single.first, 'ok');
          final r = ref.select('SELECT id, name, score FROM users ORDER BY id');
          expect(r.rows, [
            [1, 'alice', 9.5],
            [2, 'bob', 7.25],
            [3, 'carol', null],
          ]);
        } finally {
          ref.dispose();
        }
      } finally {
        await db.close();
      }
    });

    test('round-trips multiple tables and indexes', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t1(id INTEGER PRIMARY KEY, k TEXT)');
        await db.execute('CREATE INDEX t1_k ON t1(k)');
        await db.execute('CREATE TABLE t2(id INTEGER PRIMARY KEY, v REAL)');
        await db.execute(
            "INSERT INTO t1 VALUES (1, 'beta'), (2, 'alpha'), (3, 'gamma')");
        await db
            .execute('INSERT INTO t2 VALUES (10, 1.5), (20, 2.5), (30, 3.5)');
        final out = _tmp('multi');
        addTearDown(
            () async { if (await out.exists()) await out.delete(); });
        await db.exportSqlite(out.path);
        final ref = sq.sqlite3.open(out.path);
        try {
          expect(ref.select('PRAGMA integrity_check').rows.single.first, 'ok');
          // Counts.
          expect(ref.select('SELECT count(*) FROM t1').rows.single.first, 3);
          expect(ref.select('SELECT count(*) FROM t2').rows.single.first, 3);
          // The index lookup works.
          expect(
              ref
                  .select("SELECT id FROM t1 WHERE k = 'alpha'")
                  .rows
                  .single
                  .first,
              2);
          // Index appears in sqlite_master.
          final idxNames = ref
              .select("SELECT name FROM sqlite_master WHERE type='index' "
                  "AND name NOT LIKE 'sqlite_autoindex_%'")
              .rows
              .map((r) => r.first)
              .toSet();
          expect(idxNames, contains('t1_k'));
        } finally {
          ref.dispose();
        }
      } finally {
        await db.close();
      }
    });

    test('preserves BLOBs (round-trip with overflow)', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, data BLOB)');
        final big = Uint8List(6000);
        for (var i = 0; i < big.length; i++) {
          big[i] = (i * 11) & 0xff;
        }
        await db
            .executeWith('INSERT INTO t VALUES (?, ?)', positional: [1, big]);
        await db.executeWith('INSERT INTO t VALUES (?, ?)', positional: [
          2,
          Uint8List.fromList([0x99, 0x88])
        ]);
        final out = _tmp('blob');
        addTearDown(
            () async { if (await out.exists()) await out.delete(); });
        await db.exportSqlite(out.path);
        final ref = sq.sqlite3.open(out.path);
        try {
          expect(ref.select('PRAGMA integrity_check').rows.single.first, 'ok');
          final r = ref.select('SELECT id, length(data) FROM t ORDER BY id');
          expect(r.rows, [
            [1, 6000],
            [2, 2],
          ]);
        } finally {
          ref.dispose();
        }
      } finally {
        await db.close();
      }
    });

    test('handles a multi-leaf B-tree (many rows)', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, x INT)');
        const n = 2500;
        final stmt = db.prepare('INSERT INTO t VALUES (?, ?)');
        for (var i = 0; i < n; i++) {
          await stmt.execute(positional: [i + 1, i * 2]);
        }
        final out = _tmp('many');
        addTearDown(
            () async { if (await out.exists()) await out.delete(); });
        await db.exportSqlite(out.path);
        final ref = sq.sqlite3.open(out.path);
        try {
          expect(ref.select('PRAGMA integrity_check').rows.single.first, 'ok');
          expect(ref.select('SELECT count(*) FROM t').rows.single.first, n);
          expect(
              ref.select('SELECT x FROM t WHERE id = 1234').rows.single.first,
              1233 * 2);
        } finally {
          ref.dispose();
        }
      } finally {
        await db.close();
      }
    });
  });

  group('importSqlite', () {
    test('reads back what we exported', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final src = await Database.open();
      try {
        await src.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
        await src.execute("INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c')");
        final out = _tmp('rt');
        addTearDown(
            () async { if (await out.exists()) await out.delete(); });
        await src.exportSqlite(out.path);
        final dst = await Database.open();
        try {
          final msg = await dst.importSqlite(out.path);
          expect(msg, contains('1 table'));
          final res = await dst.execute('SELECT id, name FROM t ORDER BY id');
          expect(res.rows, [
            [1, 'a'],
            [2, 'b'],
            [3, 'c'],
          ]);
        } finally {
          await dst.close();
        }
      } finally {
        await src.close();
      }
    });

    test('reads a database created by package:sqlite3', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('foreign');
      addTearDown(() async { if (await f.exists()) await f.delete(); });
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE foo(id INTEGER PRIMARY KEY, label TEXT)');
        ref.execute("INSERT INTO foo VALUES (1, 'x'), (2, 'y'), (3, 'z')");
      } finally {
        ref.dispose();
      }
      final db = await Database.open();
      try {
        final msg = await db.importSqlite(f.path);
        expect(msg, contains('1 table'));
        expect(msg, contains('3 row'));
        final r = await db.execute('SELECT id, label FROM foo ORDER BY id');
        expect(r.rows, [
          [1, 'x'],
          [2, 'y'],
          [3, 'z'],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
