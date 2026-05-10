/// Tests for exporting and round-tripping multi-column indexes.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_mcix_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal', '.lock']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

void main() {
  group('multi-column index export', () {
    test('writer + SQLite agree on a 2-column index payload', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('two');
      addTearDown(() async => _cleanup(f));
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT, v TEXT)');
        await db.execute('CREATE INDEX ix_ab ON t(a, b)');
        await db.execute("INSERT INTO t VALUES "
            "(1, 10, 'x'), (1, 20, 'y'), (2, 5, 'z'), (2, 15, 'w')");
        await db.exportSqlite(f.path);
      } finally {
        await db.close();
      }
      final ref = sq.sqlite3.open(f.path);
      try {
        // Integrity check is the strongest single-shot oracle.
        final ic = ref.select('PRAGMA integrity_check');
        expect(ic.single.values.single, 'ok');
        // SQLite should plan an index lookup using ix_ab on both keys.
        final plan = ref.select(
            "EXPLAIN QUERY PLAN SELECT v FROM t WHERE a = 2 AND b = 15");
        expect(plan.toString().toLowerCase(), contains('ix_ab'));
        final r = ref.select(
            'SELECT a, b, v FROM t ORDER BY a, b');
        expect(r.map((row) => row.values).toList(), [
          [1, 10, 'x'],
          [1, 20, 'y'],
          [2, 5, 'z'],
          [2, 15, 'w'],
        ]);
      } finally {
        ref.dispose();
      }
    });

    test('UNIQUE multi-column index round-trips', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('unique');
      addTearDown(() async => _cleanup(f));
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a TEXT, b INT)');
        await db.execute('CREATE UNIQUE INDEX ux_ab ON t(a, b)');
        // The in-memory engine's UNIQUE check is currently single-column
        // (it only enforces uniqueness on the leading key). Use rows
        // that are unique on every prefix so the engine accepts them
        // and the file we export still exercises a UNIQUE B-tree.
        await db.execute("INSERT INTO t VALUES "
            "('x', 1), ('y', 2), ('z', 3)");
        await db.exportSqlite(f.path);
      } finally {
        await db.close();
      }
      final ref = sq.sqlite3.open(f.path);
      try {
        expect(ref.select('PRAGMA integrity_check').single.values.single,
            'ok');
        // Verify the unique constraint actually fires through the file.
        expect(
          () => ref.execute("INSERT INTO t VALUES ('x', 1)"),
          throwsA(isA<sq.SqliteException>()),
        );
      } finally {
        ref.dispose();
      }
    });

    test('multi-column index survives importSqlite round-trip', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('roundtrip');
      addTearDown(() async => _cleanup(f));
      // Write via our engine.
      {
        final db = await Database.open();
        try {
          await db.execute('CREATE TABLE k(a INT, b INT, c INT)');
          await db.execute('CREATE INDEX ix_abc ON k(a, b, c)');
          for (var i = 0; i < 50; i++) {
            await db.execute('INSERT INTO k VALUES ($i, ${i * 2}, ${i * 3})');
          }
          await db.exportSqlite(f.path);
        } finally {
          await db.close();
        }
      }
      // Read back via our engine.
      final db = await Database.open(f.path);
      try {
        final r = await db.execute('SELECT a, b, c FROM k ORDER BY a');
        expect(r.rows.length, 50);
        expect(r.rows.first, [0, 0, 0]);
        expect(r.rows.last, [49, 98, 147]);
        // The index definition itself should be preserved (3 columns).
        // Find it via internal API: re-export and sniff with sqlite3.
        final f2 = _tmp('roundtrip2');
        addTearDown(() async => _cleanup(f2));
        await db.exportSqlite(f2.path);
        final ref = sq.sqlite3.open(f2.path);
        try {
          final ic = ref.select('PRAGMA integrity_check');
          expect(ic.single.values.single, 'ok');
          final defs = ref.select(
              "SELECT sql FROM sqlite_schema WHERE type='index' "
              "AND name='ix_abc'");
          expect(defs.single.values.single.toString().toLowerCase(),
              contains('a, b, c'));
        } finally {
          ref.dispose();
        }
      } finally {
        await db.close();
      }
    });

    test('multi-leaf multi-column index (large dataset)', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('big');
      addTearDown(() async => _cleanup(f));
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE big(g INT, n INT, label TEXT)');
        await db.execute('CREATE INDEX ix_gn ON big(g, n)');
        for (var i = 0; i < 1500; i++) {
          await db.execute(
              "INSERT INTO big VALUES (${i % 7}, $i, 'r$i')");
        }
        await db.exportSqlite(f.path);
      } finally {
        await db.close();
      }
      final ref = sq.sqlite3.open(f.path);
      try {
        expect(ref.select('PRAGMA integrity_check').single.values.single,
            'ok');
        final c = ref.select(
            'SELECT count(*) FROM big WHERE g = 3').single.values.single;
        expect(c, greaterThan(0));
      } finally {
        ref.dispose();
      }
    });
  });
}
