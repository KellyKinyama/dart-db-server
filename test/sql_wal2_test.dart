/// WAL2 dual-log persistence: alternating `-wal` / `-wal2` companions
/// give a torn-write fallback for the previous commit. PRAGMA
/// wal2_checkpoint folds both WALs into the main file.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dartdb_wal2_');
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  String dbPath() => '${tmp.path}${Platform.pathSeparator}data.sqlite';

  test('journal_mode = wal2 alternates between -wal and -wal2', () async {
    final p = dbPath();
    final db = await Database.open(p);
    try {
      await db.execute('PRAGMA journal_mode = wal2');
      await db.execute('CREATE TABLE t(a INT)');
      await db.execute('INSERT INTO t VALUES(1)');
      // Force a baseline snapshot so subsequent commits write incremental
      // WAL frames rather than full rewrites.
      await db.checkpointSqlite();

      await db.execute('INSERT INTO t VALUES(2)');
      await db.execute('INSERT INTO t VALUES(3)');

      final wal = File('$p-wal');
      final wal2 = File('$p-wal2');
      // After two post-baseline commits, both alternation slots should
      // hold a snapshot.
      expect(wal.existsSync() || wal2.existsSync(), isTrue,
          reason: 'expected at least one WAL slot to hold pending overrides');
      expect(wal.existsSync() && wal2.existsSync(), isTrue,
          reason: 'expected both WAL slots to be populated after >= 2 commits');
    } finally {
      await db.close();
    }
  });

  test('wal2_checkpoint folds both WALs into the main file', () async {
    final p = dbPath();
    final db = await Database.open(p);
    try {
      await db.execute('PRAGMA journal_mode = wal2');
      await db.execute('CREATE TABLE t(a INT)');
      await db.execute('INSERT INTO t VALUES(1)');
      await db.checkpointSqlite();
      await db.execute('INSERT INTO t VALUES(2)');
      await db.execute('INSERT INTO t VALUES(3)');

      await db.execute('PRAGMA wal2_checkpoint');
      // Give the unawaited checkpointSqlite a beat to flush.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(File('$p-wal').existsSync(), isFalse);
      expect(File('$p-wal2').existsSync(), isFalse);
    } finally {
      await db.close();
    }
  });

  test('reopen after wal2 commits sees the latest state', () async {
    final p = dbPath();
    final db1 = await Database.open(p);
    try {
      await db1.execute('PRAGMA journal_mode = wal2');
      await db1.execute('CREATE TABLE t(a INT)');
      await db1.execute('INSERT INTO t VALUES(1)');
      await db1.checkpointSqlite();
      await db1.execute('INSERT INTO t VALUES(2)');
      await db1.execute('INSERT INTO t VALUES(3)');
    } finally {
      await db1.close();
    }
    final db2 = await Database.open(p);
    try {
      final r = await db2.execute('SELECT a FROM t ORDER BY a');
      expect(r.rows.map((row) => row[0]).toList(), [1, 2, 3]);
    } finally {
      await db2.close();
    }
  });
}
