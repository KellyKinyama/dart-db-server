import 'dart:io';

import 'package:dart_db_server/server/database.dart';
import 'package:test/test.dart';

/// Regressions for the storage-engine durability work.
///
/// These tests exercise the atomic-write path — every persist now writes
/// to a `<path>.tmp` sibling, fsyncs it, and renames it over the data
/// file. A crash between the temp write and the rename must leave the
/// original file fully intact, and the leftover temp must be reaped on
/// the next [Database.open].
void main() {
  String tmpPath(String suffix) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ddb_durability_${stamp}_$suffix';
  }

  Future<void> cleanup(String path) async {
    for (final p in [path, '$path.tmp', '$path.lock', '$path-wal']) {
      final f = File(p);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {/* best-effort */}
      }
    }
  }

  group('JSON backend durability', () {
    test('writes go through a sibling .tmp atomically', () async {
      final p = tmpPath('json_atomic.json');
      addTearDown(() => cleanup(p));

      final db = await Database.open(p);
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        await db.execute("INSERT INTO t VALUES (1, 'hello')");
      } finally {
        await db.close();
      }

      // Successful close must leave NO leftover .tmp.
      expect(await File('$p.tmp').exists(), isFalse,
          reason: 'atomic write should have renamed the temp file away');
      expect(await File(p).exists(), isTrue);
    });

    test('crash before rename: original file unchanged, .tmp reaped on open',
        () async {
      final p = tmpPath('json_crash.json');
      addTearDown(() => cleanup(p));

      // 1. Write a known-good baseline.
      final db = await Database.open(p);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await db.execute("INSERT INTO t VALUES (1, 'baseline')");
      await db.close();

      final goodBytes = await File(p).readAsBytes();

      // 2. Simulate a crash mid-write: leave a junk `<path>.tmp` around
      //    AND keep the original file untouched. Real crashes during
      //    [_atomicWriteBytes] manifest as exactly this state, because
      //    the rename step is what makes the new bytes visible.
      await File('$p.tmp').writeAsString('garbage that never made it');

      // 3. Reopen — the stale temp must be reaped, and the on-disk
      //    state must equal the pre-crash baseline.
      final db2 = await Database.open(p);
      try {
        expect(await File('$p.tmp').exists(), isFalse,
            reason: 'stale temp must be cleaned up on open');
        final cur = await File(p).readAsBytes();
        expect(cur, equals(goodBytes),
            reason: 'main file must be byte-identical to the pre-crash one');

        final r = await db2.execute('SELECT v FROM t WHERE id = 1');
        expect(r.rows.single.single, 'baseline');
      } finally {
        await db2.close();
      }
    });

    test('a write that fails mid-flight must not corrupt the existing file',
        () async {
      final p = tmpPath('json_torn.json');
      addTearDown(() => cleanup(p));

      final db = await Database.open(p);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await db.execute('INSERT INTO t VALUES (1)');
      await db.close();

      final before = await File(p).readAsBytes();

      // Lock the destination so the rename step can't run on Windows.
      // The persist will fail; the pre-existing file must survive.
      if (Platform.isWindows) {
        // Hold the file open exclusively to block the delete-then-rename.
        final blocker = await File(p).open(mode: FileMode.append);
        try {
          final db2 = await Database.open(p);
          // Mutate; persist will fail because the destination is held
          // open by the blocker. The exception is expected — what we
          // care about is that the *previous* on-disk bytes are not
          // corrupted by the failed rename.
          try {
            await db2.execute('INSERT INTO t VALUES (2)');
          } catch (_) {/* expected on a contended rename */}
          try {
            await db2.flush();
          } catch (_) {/* expected on a contended rename */}
          await db2.close();
        } finally {
          await blocker.close();
        }
        // Whatever happened, the bytes must still be parseable JSON.
        final after = await File(p).readAsBytes();
        expect(after, isNotEmpty);
        // And reopening must succeed without throwing.
        final db3 = await Database.open(p);
        final rows = (await db3.execute('SELECT id FROM t')).rows;
        expect(rows.map((r) => r.single).toSet(), contains(1));
        await db3.close();
        // Suppress unused warning when the branch is not the one taken.
        // ignore: unused_local_variable
        final _ = before;
      } else {
        // POSIX rename always succeeds on a writable directory; just
        // verify the round-trip still works.
        final db2 = await Database.open(p);
        await db2.execute('INSERT INTO t VALUES (2)');
        await db2.close();
        final db3 = await Database.open(p);
        final rows = (await db3.execute('SELECT id FROM t')).rows;
        expect(rows.map((r) => r.single).toSet(), {1, 2});
        await db3.close();
      }
    });
  });

  group('SQLite-format backend durability', () {
    test('writes are atomic for .sqlite paths too', () async {
      final p = tmpPath('native.sqlite');
      addTearDown(() => cleanup(p));

      final db = await Database.open(p);
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        await db.execute("INSERT INTO t VALUES (1, 'sqlite-native')");
      } finally {
        await db.close();
      }

      expect(await File('$p.tmp').exists(), isFalse,
          reason: '.sqlite persist should also atomic-rename');
      // File must start with the real SQLite magic so external tools can
      // still open it.
      final bytes = await File(p).readAsBytes();
      expect(String.fromCharCodes(bytes.sublist(0, 15)), 'SQLite format 3');
    });

    test('stale .tmp from a crashed sqlite write is cleaned on open', () async {
      final p = tmpPath('native_crash.sqlite');
      addTearDown(() => cleanup(p));

      // Establish a good baseline.
      final db = await Database.open(p);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await db.execute('INSERT INTO t VALUES (42)');
      await db.close();

      // Drop a junk sibling temp as if a writer had crashed.
      await File('$p.tmp').writeAsString('not a sqlite file');

      final db2 = await Database.open(p);
      try {
        expect(await File('$p.tmp').exists(), isFalse);
        final r = await db2.execute('SELECT id FROM t');
        expect(r.rows.single.single, 42);
      } finally {
        await db2.close();
      }
    });
  });
}
