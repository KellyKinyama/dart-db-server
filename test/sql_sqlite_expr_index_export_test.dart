/// Tests for expression-index export.
///
/// `CREATE INDEX i ON t(<expr>)` stores the evaluated expression as the
/// key. SQLite will use this index for queries whose predicate matches
/// the same expression (and confirms our entries are correct via
/// `PRAGMA integrity_check`).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_expridx_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_expridx_src_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('expression index export', () {
    test('LOWER(name) on rowid table', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('lower');
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute('CREATE INDEX i_lname ON t(LOWER(name))');
      await db.execute("INSERT INTO t VALUES "
          "(1,'Alice'), (2,'BOB'), (3,'carol'), (4,'DaVe')");
      final out = _tmp('lower');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        // Force the planner to use the expression index.
        final rows = r.select("SELECT id, name FROM t INDEXED BY i_lname "
            "WHERE LOWER(name) = 'bob'");
        expect(rows.length, 1);
        expect(rows.first['id'], 2);
        // Verify the SQL round-tripped with the expression intact.
        final sql = (r
                .select("SELECT sql FROM sqlite_schema WHERE name='i_lname'")
                .first['sql'] as String)
            .toLowerCase()
            .replaceAll(' ', '');
        expect(sql, contains('lower(name)'));
      } finally {
        r.dispose();
      }
    });

    test('arithmetic expression with WHERE filter', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('arith');
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)');
      await db.execute(
          'CREATE INDEX i_sum ON t(a + b) WHERE a IS NOT NULL AND b IS NOT NULL');
      await db.execute("INSERT INTO t VALUES "
          "(1, 10, 20), (2, NULL, 5), (3, 7, 8), (4, 100, 200), (5, 1, NULL)");
      final out = _tmp('arith');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        // Surviving rows after the partial WHERE: id=1 (a+b=30),
        // id=3 (15), id=4 (300). Range 20..100 matches only id=1.
        final rows = r.select("SELECT id FROM t INDEXED BY i_sum "
            "WHERE a IS NOT NULL AND b IS NOT NULL AND (a+b) BETWEEN 20 AND 100 "
            "ORDER BY (a+b)");
        expect(rows.map((m) => m['id']).toList(), [1]);
      } finally {
        r.dispose();
      }
    });

    test('expression index on WITHOUT ROWID table appends PK', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('worexpr');
      await db.execute(
          'CREATE TABLE t(k TEXT PRIMARY KEY, name TEXT) WITHOUT ROWID');
      await db.execute('CREATE INDEX i_lname ON t(LOWER(name))');
      await db.execute("INSERT INTO t VALUES "
          "('u1','Alice'), ('u2','BOB'), ('u3','carol')");
      final out = _tmp('worexpr');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final rows = r.select(
            "SELECT k FROM t INDEXED BY i_lname WHERE LOWER(name) = 'alice'");
        expect(rows.length, 1);
        expect(rows.first['k'], 'u1');
      } finally {
        r.dispose();
      }
    });
  });
}
