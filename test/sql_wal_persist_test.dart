/// Incremental WAL persist: small mutations to a SQLite-format database
/// produce a `<path>-wal` companion rather than rewriting the entire main
/// file. checkpointSqlite() folds the WAL back into the main image.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmpPath(String tag) => '${Directory.systemTemp.path}/ddb_wal_${tag}_'
    '${DateTime.now().microsecondsSinceEpoch}.sqlite';

void main() {
  group('Incremental SQLite persist', () {
    test('small mutation produces a -wal companion (main file untouched)',
        () async {
      final p = _tmpPath('small');
      addTearDown(() async {
        for (final f in [File(p), File('$p-wal')]) {
          if (await f.exists()) await f.delete();
        }
      });
      var db = await Database.open(p);
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
      // Bulk-load enough rows that 1-row mutations will only touch a
      // small fraction of the page count.
      for (var i = 1; i <= 200; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 10})');
      }
      // Fold any incremental WAL accumulated during bulk-load back
      // into the main file so the post-close state is canonical.
      await db.checkpointSqlite();
      await db.close();

      // Snapshot the main file size + bytes after initial full write.
      final mainBefore = await File(p).readAsBytes();
      expect(await File('$p-wal').exists(), isFalse,
          reason: 'no -wal after explicit checkpoint');

      // Reopen and make a tiny mutation. This should trigger an
      // incremental persist: -wal appears, main untouched.
      db = await Database.open(p);
      await db.execute('UPDATE t SET v = 9999 WHERE id = 1');
      await db.close();

      final wal = File('$p-wal');
      expect(await wal.exists(), isTrue, reason: '-wal must be written');
      final walBytes = await wal.readAsBytes();
      final mainAfter = await File(p).readAsBytes();
      expect(mainAfter, mainBefore,
          reason: 'main file bytes must be unchanged by incremental persist');
      expect(walBytes.length, lessThan(mainAfter.length),
          reason: '-wal should be smaller than the main file');

      // Reopen: the mutation must be visible (WAL replay).
      db = await Database.open(p);
      addTearDown(db.close);
      final r = await db.execute('SELECT v FROM t WHERE id = 1');
      expect(r.rows.first[0], 9999);
    });

    test('checkpointSqlite folds the WAL back into the main file', () async {
      final p = _tmpPath('ckpt');
      addTearDown(() async {
        for (final f in [File(p), File('$p-wal')]) {
          if (await f.exists()) await f.delete();
        }
      });
      var db = await Database.open(p);
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
      for (var i = 1; i <= 100; i++) {
        await db.execute('INSERT INTO t VALUES ($i, $i)');
      }
      await db.checkpointSqlite();
      await db.close();

      db = await Database.open(p);
      await db.execute('UPDATE t SET v = 42 WHERE id = 7');
      await db.close();
      expect(await File('$p-wal').exists(), isTrue);

      // Reopen + checkpoint.
      db = await Database.open(p);
      await db.checkpointSqlite();
      await db.close();
      expect(await File('$p-wal').exists(), isFalse,
          reason: 'WAL should be gone after checkpoint');

      // Mutation still visible after the checkpoint.
      db = await Database.open(p);
      addTearDown(db.close);
      final r = await db.execute('SELECT v FROM t WHERE id = 7');
      expect(r.rows.first[0], 42);
    });
  });
}
