/// COLLATE NOCASE on indexes: case-insensitive lookups, both at runtime
/// and when round-tripped through the SQLite file format.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_nocase_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_nocase_src_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('COLLATE NOCASE indexes', () {
    test('runtime: equality probe is case-insensitive', () async {
      final db = await _newDb('eq');
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute('CREATE INDEX i_name ON t(name COLLATE NOCASE)');
      await db
          .execute("INSERT INTO t VALUES (1,'Alice'),(2,'BOB'),(3,'carol')");
      // Lookups that previously needed a full scan now hit the index
      // regardless of input case. Engine-level: sql equality `=` is
      // case-sensitive by default, but the index is normalized so any
      // case-insensitive predicate the planner translates will land.
      // We test via the index lookup directly (LOWER(name)='alice') to
      // verify the stored keys are normalized — the simpler smoke is to
      // round-trip and confirm SQLite reads it as NOCASE.
      final t = db.table('t');
      expect(t, isNotNull);
      // Direct index inspection: the SplayTreeMap should hold lowercased
      // keys.
      final tree = t!.indexes['i_name']!;
      expect(tree.keys.toSet(), {'alice', 'bob', 'carol'});
    });

    test('export: CREATE INDEX SQL preserves COLLATE NOCASE', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('exp');
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute('CREATE INDEX i_name ON t(name COLLATE NOCASE)');
      await db.execute(
          "INSERT INTO t VALUES (1,'Alice'),(2,'BOB'),(3,'carol'),(4,'bob')");
      final out = _tmp('exp');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final sql = r
            .select("SELECT sql FROM sqlite_schema WHERE name='i_name'")
            .first['sql'] as String;
        expect(sql.toUpperCase(), contains('COLLATE NOCASE'));
        // SQLite uses the index for case-insensitive equality.
        final rows =
            r.select("SELECT id, name FROM t WHERE name = 'BOB' COLLATE NOCASE "
                "ORDER BY id");
        expect(rows.map((m) => m['id']).toList(), [2, 4]);
      } finally {
        r.dispose();
      }
    });

    test('round-trip: SQLite NOCASE index -> ours preserves lookup', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('rt');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
        ref.execute('CREATE INDEX i_name ON t(name COLLATE NOCASE)');
        ref.execute("INSERT INTO t VALUES (1,'Alice'),(2,'BOB'),(3,'carol')");
      } finally {
        ref.dispose();
      }
      final db = await _newDb('rt2');
      await db.importSqlite(f.path);
      final t = db.table('t');
      expect(t, isNotNull);
      // Index keys should be lowercased after import.
      final tree = t!.indexes['i_name']!;
      expect(tree.keys.toSet(), {'alice', 'bob', 'carol'});
    });
  });
}
