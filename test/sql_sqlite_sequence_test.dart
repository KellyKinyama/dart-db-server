/// AUTOINCREMENT counter round-trip via sqlite_sequence.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_seq_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_seq_src_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('sqlite_sequence round-trip', () {
    test('AUTOINCREMENT counter survives export to SQLite', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('export');
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'name TEXT)');
      await db.execute("INSERT INTO t(name) VALUES ('a'),('b'),('c')");
      // Delete the last row so that next id should still be 4 (not reuse 3).
      await db.execute('DELETE FROM t WHERE id=3');
      final out = _tmp('export');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final seq = r
            .select("SELECT seq FROM sqlite_sequence WHERE name='t'")
            .first['seq'];
        expect(seq, 3);
        // SQLite must use 4 for the next AUTOINCREMENT id.
        r.execute("INSERT INTO t(name) VALUES ('d')");
        final newId = r.select("SELECT id FROM t WHERE name='d'").first['id'];
        expect(newId, 4);
      } finally {
        r.dispose();
      }
    });

    test('AUTOINCREMENT counter survives importSqlite from real SQLite',
        () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('import');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'v TEXT)');
        ref.execute("INSERT INTO t(v) VALUES ('x'),('y'),('z')");
        ref.execute('DELETE FROM t WHERE id=3');
      } finally {
        ref.dispose();
      }
      final db = await _newDb('importseq');
      await db.importSqlite(f.path);
      // Insert a new row; should pick id=4.
      await db.execute("INSERT INTO t(v) VALUES ('w')");
      final res = await db.execute("SELECT id FROM t WHERE v='w'");
      expect(res.rows.first[0], 4);
    });

    test('full round-trip: SQLite -> ours -> SQLite preserves seq', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f1 = _tmp('rt1');
      addTearDown(() async => _cleanup(f1));
      final ref = sq.sqlite3.open(f1.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'v TEXT)');
        for (var i = 0; i < 7; i++) {
          ref.execute("INSERT INTO t(v) VALUES ('r$i')");
        }
      } finally {
        ref.dispose();
      }
      final db = await _newDb('rt2');
      await db.importSqlite(f1.path);
      final f2 = _tmp('rt3');
      addTearDown(() async => _cleanup(f2));
      await db.exportSqlite(f2.path);

      final r = sq.sqlite3.open(f2.path);
      try {
        final seq = r
            .select("SELECT seq FROM sqlite_sequence WHERE name='t'")
            .first['seq'];
        expect(seq, 7);
      } finally {
        r.dispose();
      }
    });
  });
}
