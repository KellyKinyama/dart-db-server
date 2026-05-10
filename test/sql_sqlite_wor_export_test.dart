/// Tests for *writing* WITHOUT ROWID tables to real SQLite files.
///
/// Round-trip via real SQLite: we build a table in our engine, call
/// `exportSqlite`, then open the file with `package:sqlite3` and verify
/// the rows + integrity_check.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_worx_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_worx_src_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('WITHOUT ROWID export', () {
    test('single-column PK at position 0', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('singlepk');
      await db.execute(
          'CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) WITHOUT ROWID');
      await db.execute(
          "INSERT INTO t VALUES ('beta', 2), ('alpha', 1), ('gamma', 3)");
      final out = _tmp('singlepk');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        final rows = r.select('SELECT k, v FROM t ORDER BY k');
        expect(rows.length, 3);
        expect(rows[0]['k'], 'alpha');
        expect(rows[0]['v'], 1);
        expect(rows[1]['k'], 'beta');
        expect(rows[2]['k'], 'gamma');
        final ic = r.select('PRAGMA integrity_check');
        expect(ic.first.values.first, 'ok');
      } finally {
        r.dispose();
      }
    });

    test('PK not at position 0 (column-order remap)', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('pkmid');
      await db.execute(
          'CREATE TABLE t(v INTEGER, k TEXT PRIMARY KEY, w TEXT) WITHOUT ROWID');
      await db.execute(
          "INSERT INTO t(v,k,w) VALUES (10,'b','x'), (20,'a','y'), (30,'c','z')");
      final out = _tmp('pkmid');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        final rows = r.select('SELECT v, k, w FROM t ORDER BY k');
        expect(rows.length, 3);
        expect(rows.map((m) => m['k']).toList(), ['a', 'b', 'c']);
        expect(rows.map((m) => m['v']).toList(), [20, 10, 30]);
        expect(rows.map((m) => m['w']).toList(), ['y', 'x', 'z']);
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
      } finally {
        r.dispose();
      }
    });

    test('composite PK', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('comppk');
      await db.execute(
          'CREATE TABLE t(a INTEGER, b TEXT, v INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID');
      await db.execute(
          "INSERT INTO t VALUES (2,'x',20), (1,'b',12), (1,'a',11), (2,'a',21)");
      final out = _tmp('comppk');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        final rows = r.select('SELECT a,b,v FROM t ORDER BY a,b');
        expect(rows.length, 4);
        expect(rows.map((m) => '${m['a']}/${m['b']}=${m['v']}').toList(),
            ['1/a=11', '1/b=12', '2/a=21', '2/x=20']);
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
      } finally {
        r.dispose();
      }
    });

    test('many rows (multi-leaf)', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('many');
      await db.execute(
          'CREATE TABLE t(k INTEGER PRIMARY KEY, s TEXT) WITHOUT ROWID');
      for (var i = 0; i < 500; i++) {
        await db.execute("INSERT INTO t VALUES ($i, 'row-$i')");
      }
      final out = _tmp('many');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        final n = r.select('SELECT COUNT(*) AS c FROM t').first['c'];
        expect(n, 500);
        final mid = r.select('SELECT s FROM t WHERE k=250').first['s'];
        expect(mid, 'row-250');
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
      } finally {
        r.dispose();
      }
    });

    test('round-trip: export then importSqlite reads back', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('rt');
      await db.execute(
          'CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) WITHOUT ROWID');
      await db
          .execute("INSERT INTO t VALUES ('zeta',26), ('alpha',1), ('mu',13)");
      final out = _tmp('rt');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final db2 = await _newDb('rt2');
      await db2.importSqlite(out.path);
      final res = await db2.execute('SELECT k, v FROM t ORDER BY k');
      expect(res.rows.length, 3);
      expect(res.rows.map((r) => r[0]).toList(), ['alpha', 'mu', 'zeta']);
      expect(res.rows.map((r) => r[1]).toList(), [1, 13, 26]);
    });
  });
}
