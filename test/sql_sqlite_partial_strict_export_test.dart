/// Tests for partial-index export (CREATE INDEX ... WHERE ...) and
/// for the STRICT trailer being preserved through exportSqlite.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_partidx_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_partidx_src_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('partial index export', () {
    test('rowid table: WHERE filters out non-matching rows', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('rowid');
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY, status TEXT, v INTEGER)');
      await db.execute("CREATE INDEX i_active ON t(v) WHERE status = 'active'");
      await db.execute("INSERT INTO t VALUES "
          "(1,'active',10), (2,'archived',20), (3,'active',30), "
          "(4,'archived',40), (5,'active',50)");
      final out = _tmp('rowid');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        // SQLite reports the partial-index WHERE clause via index_xinfo's
        // "partial" flag; cleaner: just re-read the SQL.
        final sql = r
            .select("SELECT sql FROM sqlite_schema WHERE name='i_active'")
            .first['sql'] as String;
        expect(sql.toLowerCase(), contains("where status = 'active'"));
        // Force the planner to use the partial index; only matching rows
        // should be visible through it.
        final rows = r.select("SELECT id, v FROM t INDEXED BY i_active "
            "WHERE status = 'active' ORDER BY v");
        expect(rows.map((m) => m['id']).toList(), [1, 3, 5]);
        expect(rows.map((m) => m['v']).toList(), [10, 30, 50]);
      } finally {
        r.dispose();
      }
    });

    test('WITHOUT ROWID table: partial index appends PK', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('wor');
      await db
          .execute('CREATE TABLE t(k TEXT PRIMARY KEY, status TEXT, v INTEGER) '
              'WITHOUT ROWID');
      await db.execute('CREATE INDEX i_v ON t(v) WHERE v > 100');
      await db.execute("INSERT INTO t VALUES "
          "('a','x',50), ('b','x',150), ('c','x',75), "
          "('d','x',300), ('e','x',101)");
      final out = _tmp('wor');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final rows = r.select(
            "SELECT k, v FROM t INDEXED BY i_v WHERE v > 100 ORDER BY v");
        expect(rows.map((m) => m['k']).toList(), ['e', 'b', 'd']);
      } finally {
        r.dispose();
      }
    });

    test('UNIQUE partial index: SQLite enforces uniqueness on read-back',
        () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('uniq');
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY, status TEXT, slot INTEGER)');
      await db.execute(
          "CREATE UNIQUE INDEX i_slot ON t(slot) WHERE status = 'live'");
      await db.execute("INSERT INTO t VALUES "
          "(1,'live',1), (2,'live',2), (3,'archived',1), (4,'archived',2)");
      final out = _tmp('uniq');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        // archived row with slot=1 doesn't conflict (filtered out).
        r.execute("INSERT INTO t VALUES (5,'archived',1)");
        // live row with slot=1 DOES conflict.
        expect(() => r.execute("INSERT INTO t VALUES (6,'live',1)"),
            throwsA(anything));
      } finally {
        r.dispose();
      }
    });
  });

  group('STRICT trailer export', () {
    test('STRICT table is exported with trailer and rejects bad inserts',
        () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('strict');
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, n INTEGER) '
          'STRICT');
      await db.execute("INSERT INTO t VALUES (1,'alice',42)");
      final out = _tmp('strict');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final sql = r
            .select("SELECT sql FROM sqlite_schema WHERE name='t'")
            .first['sql'] as String;
        expect(sql.toUpperCase(), contains('STRICT'));
        final row = r.select('SELECT id, name, n FROM t').first;
        expect(row['id'], 1);
        expect(row['name'], 'alice');
        expect(row['n'], 42);
        // STRICT enforced by SQLite on read-back: TEXT into INTEGER fails.
        expect(() => r.execute("INSERT INTO t VALUES (2,'bob','not-a-number')"),
            throwsA(anything));
      } finally {
        r.dispose();
      }
    });

    test('STRICT + WITHOUT ROWID combined trailer', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('both');
      await db.execute(
          'CREATE TABLE t(k TEXT PRIMARY KEY, n INTEGER) STRICT, WITHOUT ROWID');
      await db.execute("INSERT INTO t VALUES ('a',1),('b',2)");
      final out = _tmp('both');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final sql = r
            .select("SELECT sql FROM sqlite_schema WHERE name='t'")
            .first['sql'] as String;
        final upper = sql.toUpperCase();
        expect(upper, contains('STRICT'));
        expect(upper, contains('WITHOUT ROWID'));
      } finally {
        r.dispose();
      }
    });
  });
}
