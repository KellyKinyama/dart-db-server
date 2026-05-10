/// Tests for *secondary indexes on WITHOUT ROWID tables*.
///
/// In SQLite, an index on a WITHOUT ROWID table appends the table's
/// PRIMARY KEY columns to every entry (skipping any PK columns already
/// present in the index key). The exporter has to reproduce that exact
/// shape or `PRAGMA integrity_check` rejects the file.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_woridx_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_woridx_src_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('WITHOUT ROWID secondary indexes', () {
    test('single-column index, single-column PK', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('single');
      await db.execute(
          'CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) WITHOUT ROWID');
      await db.execute('CREATE INDEX iv ON t(v)');
      await db.execute("INSERT INTO t VALUES "
          "('alpha', 30), ('beta', 10), ('gamma', 20)");
      final out = _tmp('single');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        // Force the index to actually be used.
        final rows = r.select('SELECT k, v FROM t WHERE v BETWEEN 15 AND 25');
        expect(rows.length, 1);
        expect(rows.first['k'], 'gamma');
        // Verify SQLite agrees the index exists and is usable.
        final idxList = r.select("PRAGMA index_list('t')");
        final names = idxList.map((m) => m['name']).toSet();
        expect(names.contains('iv'), isTrue);
      } finally {
        r.dispose();
      }
    });

    test('multi-column index, composite PK, with overlapping column', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('overlap');
      await db.execute('CREATE TABLE t(a INTEGER, b TEXT, v INTEGER, '
          'PRIMARY KEY(a,b)) WITHOUT ROWID');
      // Index on (v, a): "a" already in PK, so only "b" gets appended.
      await db.execute('CREATE INDEX i_va ON t(v, a)');
      await db.execute("INSERT INTO t VALUES "
          "(1,'x',100), (2,'y',200), (1,'z',150), (3,'w',50)");
      final out = _tmp('overlap');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final rows = r.select('SELECT a,b,v FROM t WHERE v >= 100 AND v <= 200 '
            'ORDER BY v');
        expect(rows.map((m) => '${m['a']}/${m['b']}=${m['v']}').toList(),
            ['1/x=100', '1/z=150', '2/y=200']);
        // index_info should report two columns for i_va (the declared key).
        final info = r.select("PRAGMA index_info('i_va')");
        expect(info.length, 2);
        expect(info[0]['name'], 'v');
        expect(info[1]['name'], 'a');
      } finally {
        r.dispose();
      }
    });

    test('UNIQUE secondary index on WITHOUT ROWID', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('uniq');
      await db.execute(
          'CREATE TABLE t(k TEXT PRIMARY KEY, email TEXT) WITHOUT ROWID');
      await db.execute('CREATE UNIQUE INDEX i_email ON t(email)');
      await db.execute("INSERT INTO t VALUES "
          "('u1','a@x'), ('u2','b@x'), ('u3','c@x')");
      final out = _tmp('uniq');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        // SQLite enforces the UNIQUE constraint on read-back inserts.
        expect(() => r.execute("INSERT INTO t VALUES ('u4','a@x')"),
            throwsA(anything));
        final rows = r.select("SELECT k FROM t WHERE email = 'b@x'");
        expect(rows.length, 1);
        expect(rows.first['k'], 'u2');
      } finally {
        r.dispose();
      }
    });

    test('many rows, multi-leaf index', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final db = await _newDb('manyidx');
      await db.execute(
          'CREATE TABLE t(k INTEGER PRIMARY KEY, s TEXT) WITHOUT ROWID');
      await db.execute('CREATE INDEX i_s ON t(s)');
      for (var i = 0; i < 400; i++) {
        await db.execute(
            "INSERT INTO t VALUES ($i, 'v${i.toString().padLeft(4, "0")}')");
      }
      final out = _tmp('manyidx');
      addTearDown(() async => _cleanup(out));
      await db.exportSqlite(out.path);

      final r = sq.sqlite3.open(out.path);
      try {
        expect(r.select('PRAGMA integrity_check').first.values.first, 'ok');
        final hit = r.select("SELECT k FROM t WHERE s = 'v0250'");
        expect(hit.length, 1);
        expect(hit.first['k'], 250);
      } finally {
        r.dispose();
      }
    });
  });
}
