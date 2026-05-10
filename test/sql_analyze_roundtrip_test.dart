/// ANALYZE / sqlite_stat1 round-trip through SQLite file format.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_stat_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_stat_src_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('ANALYZE round-trip', () {
    test('export: ANALYZE produces sqlite_stat1 readable by SQLite', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('exp');
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
      await db.execute('CREATE INDEX i_k ON t(k)');
      for (var i = 0; i < 25; i++) {
        await db.execute("INSERT INTO t VALUES ($i, 'v${i % 5}')");
      }
      await db.execute('ANALYZE');
      final out = _tmp('exp');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final rows =
            r.select("SELECT tbl, idx, stat FROM sqlite_stat1 WHERE tbl='t' "
                "ORDER BY idx IS NULL DESC, idx");
        expect(rows.length, 2);
        // Table-level row count.
        expect(rows[0]['idx'], isNull);
        expect(rows[0]['stat'], '25');
        // Per-index stat: '<rowCount> <avgRowsPerKey>'
        expect(rows[1]['idx'], 'i_k');
        expect(rows[1]['stat'], '25 5');
      } finally {
        r.dispose();
      }
    });

    test('import: SQLite ANALYZE stats restore planner cardinality', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('imp');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
        ref.execute('CREATE INDEX i_k ON t(k)');
        for (var i = 0; i < 50; i++) {
          ref.execute("INSERT INTO t VALUES ($i, 'v${i % 10}')");
        }
        ref.execute('ANALYZE');
      } finally {
        ref.dispose();
      }
      final db = await _newDb('imp2');
      await db.importSqlite(f.path);
      // sqlite_stat1 must have made it through as a regular table.
      // SQLite only emits per-index rows; first integer of `stat` is the
      // index (and therefore table) row count.
      final res = await db
          .execute("SELECT stat FROM sqlite_stat1 WHERE tbl='t' AND idx='i_k'");
      expect(res.rows.length, 1);
      final firstNum = (res.rows.first[0] as String).split(' ').first;
      expect(int.parse(firstNum), 50);
    });
  });
}
