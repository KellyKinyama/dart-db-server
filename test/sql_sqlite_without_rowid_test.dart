/// Tests for reading WITHOUT ROWID tables from real SQLite files.
///
/// WITHOUT ROWID tables are stored as INDEX B-trees (page types 0x02
/// and 0x0a). The cell payload IS the row record, sorted by the
/// PRIMARY KEY columns rather than by an auto-rowid.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_wor_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

void main() {
  group('WITHOUT ROWID', () {
    test('reader: single-column PK at position 0 (no rearrangement)', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('singlepk');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) '
            'WITHOUT ROWID');
        ref.execute("INSERT INTO t VALUES ('alpha', 1), "
            "('beta', 2), ('gamma', 3)");
      } finally {
        ref.dispose();
      }
      final fp = SqliteFile.fromBytes(await f.readAsBytes());
      final rows = fp.readTable('t');
      // PK is column 0 → record column order matches declared order.
      // Sorted by PK value alphabetically.
      expect(rows.map((r) => r.values).toList(), [
        ['alpha', 1],
        ['beta', 2],
        ['gamma', 3],
      ]);
      // rowid is 0 for WITHOUT ROWID.
      expect(rows.every((r) => r.rowid == 0), isTrue);
    });

    test('reader: integer PK WITHOUT ROWID', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('intpk');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT) '
            'WITHOUT ROWID');
        ref.execute("INSERT INTO t VALUES (3, 'c'), (1, 'a'), (2, 'b')");
      } finally {
        ref.dispose();
      }
      final fp = SqliteFile.fromBytes(await f.readAsBytes());
      final rows = fp.readTable('t');
      expect(rows.map((r) => r.values).toList(), [
        [1, 'a'],
        [2, 'b'],
        [3, 'c'],
      ]);
    });

    test('reader: many rows across multiple leaves', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('many');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(k INTEGER PRIMARY KEY, payload TEXT) '
            'WITHOUT ROWID');
        final stmt = ref.prepare('INSERT INTO t VALUES (?, ?)');
        for (var i = 1; i <= 1000; i++) {
          stmt.execute([i, 'row_$i']);
        }
        stmt.dispose();
      } finally {
        ref.dispose();
      }
      final fp = SqliteFile.fromBytes(await f.readAsBytes());
      final rows = fp.readTable('t');
      expect(rows.length, 1000);
      // Spot-check ordering.
      expect(rows.first.values, [1, 'row_1']);
      expect(rows[499].values, [500, 'row_500']);
      expect(rows.last.values, [1000, 'row_1000']);
    });

    test('Database.open reads a WITHOUT ROWID file end-to-end', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('e2e');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE phone(num TEXT PRIMARY KEY, owner TEXT) '
            'WITHOUT ROWID');
        ref.execute("INSERT INTO phone VALUES "
            "('555-1', 'alice'), ('555-2', 'bob'), ('555-3', 'carol')");
      } finally {
        ref.dispose();
      }
      final db = await Database.open(f.path);
      try {
        final r = await db.execute('SELECT num, owner FROM phone ORDER BY num');
        expect(r.rows, [
          ['555-1', 'alice'],
          ['555-2', 'bob'],
          ['555-3', 'carol'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('reader: PK not at position 0 needs column-order remap', () async {
      // SQLite's WITHOUT ROWID encoding moves the PK column(s) to the
      // front of the record, so a table declared as `(name TEXT, k TEXT
      // PRIMARY KEY, v INT)` is stored as `(k, name, v)` on disk. We
      // currently return the on-disk order — assert that and document
      // the limitation.
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('reorder');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(name TEXT, k TEXT PRIMARY KEY, v INT) '
            'WITHOUT ROWID');
        ref.execute("INSERT INTO t VALUES ('Alice', 'a', 100)");
      } finally {
        ref.dispose();
      }
      final fp = SqliteFile.fromBytes(await f.readAsBytes());
      final rows = fp.readTable('t');
      // SQLite stores ('a', 'Alice', 100) — PK first, then the rest in
      // declared order. Prove that's what we see.
      expect(rows.single.values, ['a', 'Alice', 100]);
    });

    test('importSqlite remaps WITHOUT ROWID rows to declared column order',
        () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('remap');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(name TEXT, k TEXT PRIMARY KEY, v INT) '
            'WITHOUT ROWID');
        ref.execute("INSERT INTO t VALUES "
            "('Alice', 'a', 100), ('Bob', 'b', 200)");
      } finally {
        ref.dispose();
      }
      final db = await Database.open(f.path);
      try {
        final r = await db.execute('SELECT name, k, v FROM t ORDER BY k');
        expect(r.rows, [
          ['Alice', 'a', 100],
          ['Bob', 'b', 200],
        ]);
      } finally {
        await db.close();
      }
    });

    test('importSqlite handles composite PK WITHOUT ROWID', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('composite');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        // PK columns are b then a; remaining column c.
        ref.execute('CREATE TABLE t(c TEXT, a INT, b INT, '
            'PRIMARY KEY (b, a)) WITHOUT ROWID');
        ref.execute("INSERT INTO t VALUES ('x', 1, 10), "
            "('y', 2, 20), ('z', 1, 20)");
      } finally {
        ref.dispose();
      }
      final db = await Database.open(f.path);
      try {
        final r = await db.execute('SELECT c, a, b FROM t ORDER BY b, a');
        expect(r.rows, [
          ['x', 1, 10],
          ['z', 1, 20],
          ['y', 2, 20],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
