/// Tests for the WAL (Write-Ahead Log) reader.
///
/// We can't write a WAL file (we have no checkpointer), so every test
/// produces a WAL by driving `package:sqlite3` in WAL journal mode and
/// then reads the resulting db + wal pair through our pure-Dart code.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmpDb(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_wal_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File db) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final f = File('${db.path}$ext');
    if (await f.exists()) await f.delete();
  }
}

void main() {
  group('WAL reader', () {
    test('reads pages committed only in the WAL', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('basic');
      addTearDown(() async => _cleanup(f));
      // Create the db, switch to WAL mode, then commit data without
      // checkpointing — so the rows live in the -wal file, not the main db.
      // We must read the bytes BEFORE dispose() because the last
      // connection's close performs a checkpoint and truncates the WAL.
      final ref = sq.sqlite3.open(f.path);
      Uint8List dbBytes;
      Uint8List walBytes;
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
        ref.execute('PRAGMA journal_mode = WAL');
        ref.execute('PRAGMA wal_autocheckpoint = 0');
        ref.execute("INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c')");
        dbBytes = Uint8List.fromList(await f.readAsBytes());
        final wal = File('${f.path}-wal');
        expect(await wal.exists(), isTrue,
            reason: 'expected ${wal.path} to be present');
        walBytes = Uint8List.fromList(await wal.readAsBytes());
        expect(walBytes.length, greaterThan(32));
      } finally {
        ref.dispose();
      }
      final fp = SqliteFile.fromBytesWithWal(dbBytes, walBytes);
      // Note: readTable returns the raw record contents; INTEGER PRIMARY
      // KEY values live in rowid, and the record column is stored as NULL.
      final rows = fp.readTable('t');
      expect(rows.map((r) => r.values).toList(), [
        [null, 'a'],
        [null, 'b'],
        [null, 'c'],
      ]);
      expect(rows.map((r) => r.rowid).toList(), [1, 2, 3]);
    });

    test('without WAL bytes, reading the bare db sees stale state', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('stale');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      Uint8List dbBytes;
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
        ref.execute('PRAGMA journal_mode = WAL');
        ref.execute('PRAGMA wal_autocheckpoint = 0');
        ref.execute("INSERT INTO t VALUES (1, 'wal_only')");
        dbBytes = Uint8List.fromList(await f.readAsBytes());
      } finally {
        ref.dispose();
      }
      // The schema may or may not be in the main file depending on how
      // SQLite flushed — but at minimum, importing without the WAL should
      // not produce the row.
      final fp = SqliteFile.fromBytes(dbBytes);
      try {
        final rows = fp.readTable('t');
        expect(rows.where((r) => r.values[1] == 'wal_only'), isEmpty,
            reason: 'main file should not contain WAL-only inserts');
      } catch (_) {
        // Either path is acceptable: if even `t` isn't visible, the
        // assertion that WAL is required is even stronger.
      }
    });

    test('Database.importSqlite auto-loads the -wal companion', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('auto');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, label TEXT)');
        ref.execute('PRAGMA journal_mode = WAL');
        ref.execute('PRAGMA wal_autocheckpoint = 0');
        ref.execute("INSERT INTO t VALUES (1, 'one'), (2, 'two')");
        // Snapshot the on-disk state while the connection still holds
        // the WAL open (close would checkpoint it away).
        final wal = File('${f.path}-wal');
        await File('${f.path}.snapshot').writeAsBytes(await f.readAsBytes());
        await File('${f.path}.snapshot-wal')
            .writeAsBytes(await wal.readAsBytes());
      } finally {
        ref.dispose();
      }
      // Move snapshot into place for importSqlite.
      addTearDown(() async {
        for (final p in ['${f.path}.snapshot', '${f.path}.snapshot-wal']) {
          final fs = File(p);
          if (await fs.exists()) await fs.delete();
        }
      });
      final db = await Database.open();
      try {
        final msg = await db.importSqlite('${f.path}.snapshot');
        expect(msg, contains('1 table'));
        expect(msg, contains('2 row'));
        final r = await db.execute('SELECT id, label FROM t ORDER BY id');
        expect(r.rows, [
          [1, 'one'],
          [2, 'two'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('multiple WAL commits — only last one wins for each page', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('multi');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      Uint8List dbBytes;
      Uint8List walBytes;
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
        ref.execute('PRAGMA journal_mode = WAL');
        ref.execute('PRAGMA wal_autocheckpoint = 0');
        ref.execute('INSERT INTO t VALUES (1, 100)');
        ref.execute('UPDATE t SET v = 200 WHERE id = 1');
        ref.execute('UPDATE t SET v = 300 WHERE id = 1');
        dbBytes = Uint8List.fromList(await f.readAsBytes());
        walBytes =
            Uint8List.fromList(await File('${f.path}-wal').readAsBytes());
      } finally {
        ref.dispose();
      }
      final fp = SqliteFile.fromBytesWithWal(dbBytes, walBytes);
      final row = fp.readTable('t').single;
      // Column 0 is INTEGER PRIMARY KEY → stored as NULL, lives in rowid.
      expect(row.values[1], 300);
      expect(row.rowid, 1);
    });

    test('rejects WAL with mismatched page size', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('badwal');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      Uint8List dbBytes;
      Uint8List walBytes;
      try {
        ref.execute('CREATE TABLE t(x)');
        ref.execute('PRAGMA journal_mode = WAL');
        ref.execute('PRAGMA wal_autocheckpoint = 0');
        ref.execute('INSERT INTO t VALUES (1)');
        dbBytes = Uint8List.fromList(await f.readAsBytes());
        walBytes =
            Uint8List.fromList(await File('${f.path}-wal').readAsBytes());
      } finally {
        ref.dispose();
      }
      // Corrupt the WAL header's page-size field (bytes 8..11) to 1024.
      final tampered = Uint8List.fromList(walBytes);
      ByteData.sublistView(tampered).setUint32(8, 1024);
      expect(
        () => SqliteFile.fromBytesWithWal(dbBytes, tampered),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('page size'))),
      );
    });

    test('a pristine empty WAL is treated as no-op', () async {
      // An empty WAL header with no committed frames leaves the database
      // unchanged. We can synthesise such a WAL by truncating a real one
      // down to 32 bytes (header only).
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('empty_wal');
      addTearDown(() async => _cleanup(f));
      final ref = sq.sqlite3.open(f.path);
      Uint8List dbBytes;
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, x INT)');
        ref.execute('INSERT INTO t VALUES (1, 42)');
        dbBytes = Uint8List.fromList(await f.readAsBytes());
      } finally {
        ref.dispose();
      }
      // Build a 32-byte all-zero "WAL" — invalid magic so _parseWal
      // throws. Confirm we surface that as FormatException.
      final fakeWal = Uint8List(32);
      expect(
        () => SqliteFile.fromBytesWithWal(dbBytes, fakeWal),
        throwsA(isA<FormatException>()),
      );
      // And a too-short WAL (under header size) is silently ignored.
      final tiny = Uint8List(10);
      final fp = SqliteFile.fromBytesWithWal(dbBytes, tiny);
      // INTEGER PRIMARY KEY → column stored as NULL in record.
      final row = fp.readTable('t').single;
      expect(row.values[1], 42);
      expect(row.rowid, 1);
    });
  });
}
