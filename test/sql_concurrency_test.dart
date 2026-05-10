/// Concurrency primitive + Database integration tests.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('AsyncRwLock', () {
    test('multiple readers run concurrently', () async {
      final lock = AsyncRwLock();
      var concurrent = 0;
      var maxConcurrent = 0;
      Future<void> reader() => lock.read(() async {
            concurrent++;
            if (concurrent > maxConcurrent) maxConcurrent = concurrent;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            concurrent--;
          });
      await Future.wait([reader(), reader(), reader(), reader()]);
      expect(maxConcurrent, greaterThanOrEqualTo(2),
          reason: 'reads should overlap');
    });

    test('writers are exclusive against other writers', () async {
      final lock = AsyncRwLock();
      var concurrent = 0;
      var maxConcurrent = 0;
      Future<void> writer() => lock.write(() async {
            concurrent++;
            if (concurrent > maxConcurrent) maxConcurrent = concurrent;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            concurrent--;
          });
      await Future.wait([writer(), writer(), writer()]);
      expect(maxConcurrent, 1, reason: 'writers must serialize');
    });

    test('writer waits for in-flight readers', () async {
      final lock = AsyncRwLock();
      final order = <String>[];
      final readDone = Completer<void>();
      final readerFuture = lock.read(() async {
        order.add('read-start');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add('read-end');
        readDone.complete();
      });
      // Give the reader a chance to start.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final writerFuture = lock.write(() async {
        order.add('write');
      });
      await Future.wait([readerFuture, writerFuture]);
      expect(order, ['read-start', 'read-end', 'write']);
    });

    test('reader queued behind writer waits (no starvation)', () async {
      final lock = AsyncRwLock();
      final order = <String>[];
      // First reader holds the lock briefly.
      final r1 = lock.read(() async {
        order.add('r1-start');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add('r1-end');
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // Writer queues.
      final w = lock.write(() async {
        order.add('w');
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // Second reader queues *behind* the writer.
      final r2 = lock.read(() async {
        order.add('r2');
      });
      await Future.wait([r1, w, r2]);
      expect(order, ['r1-start', 'r1-end', 'w', 'r2']);
    });
  });

  group('DbFileLock', () {
    test('release after acquire is idempotent', () async {
      final tmp = File('${Directory.systemTemp.path}/'
          'ddb_filelock_${DateTime.now().microsecondsSinceEpoch}.json');
      addTearDown(() async {
        for (final p in [tmp.path, '${tmp.path}.lock']) {
          final f = File(p);
          if (await f.exists()) await f.delete();
        }
      });
      final lock = DbFileLock(tmp.path);
      await lock.acquire();
      await lock.release();
      await lock.release(); // second release is a no-op.
    });

    test('same-process double-acquire is rejected fast', () async {
      final tmp = File('${Directory.systemTemp.path}/'
          'ddb_filelock2_${DateTime.now().microsecondsSinceEpoch}.json');
      addTearDown(() async {
        for (final p in [tmp.path, '${tmp.path}.lock']) {
          final f = File(p);
          if (await f.exists()) await f.delete();
        }
      });
      final a = DbFileLock(tmp.path);
      final b = DbFileLock(tmp.path);
      await a.acquire();
      try {
        expect(() => b.acquire(), throwsA(isA<StateError>()));
      } finally {
        await a.release();
      }
    });
  });

  group('Database concurrency integration', () {
    test('Database.open + close releases the file lock', () async {
      final tmp = File('${Directory.systemTemp.path}/'
          'ddb_open_${DateTime.now().microsecondsSinceEpoch}.json');
      addTearDown(() async {
        for (final p in [tmp.path, '${tmp.path}.lock']) {
          final f = File(p);
          if (await f.exists()) await f.delete();
        }
      });
      final db1 = await Database.open(tmp.path);
      await db1.execute('CREATE TABLE t(a INTEGER)');
      await db1.execute('INSERT INTO t VALUES (1)');
      await db1.close();

      // After close, a fresh open should not deadlock.
      final db2 = await Database.open(tmp.path);
      final r = await db2.execute('SELECT a FROM t');
      expect(r.rows.single.single, 1);
      await db2.close();
    });

    test('two opens in the same process are rejected', () async {
      final tmp = File('${Directory.systemTemp.path}/'
          'ddb_dbl_${DateTime.now().microsecondsSinceEpoch}.json');
      addTearDown(() async {
        for (final p in [tmp.path, '${tmp.path}.lock']) {
          final f = File(p);
          if (await f.exists()) await f.delete();
        }
      });
      final db1 = await Database.open(tmp.path);
      try {
        await expectLater(Database.open(tmp.path), throwsA(isA<StateError>()));
      } finally {
        await db1.close();
      }
    });

    test('parallel SELECTs progress through executeStmt', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('INSERT INTO t VALUES (1), (2), (3)');
      // Issue many SELECTs concurrently and ensure they all finish
      // with the right answer (regression for the lock wiring).
      final futures =
          List.generate(20, (_) => db.execute('SELECT COUNT(*) FROM t'));
      final results = await Future.wait(futures);
      for (final r in results) {
        expect(r.rows.single.single, 3);
      }
    });

    test('snapshotRead sees data captured at clone time, not later writes',
        () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('INSERT INTO t VALUES (1), (2)');

      // Take a snapshot, then mutate, then read from the snapshot.
      final snapResult = await db.snapshotRead<int>((snap) async {
        // While "inside" the snapshot we can also mutate the live db
        // — the snapshot must not see those writes.
        await db.execute('INSERT INTO t VALUES (3)');
        final r = await snap.execute('SELECT COUNT(*) FROM t');
        return r.rows.single.single as int;
      });
      expect(snapResult, 2);

      // Live db reflects the new row.
      final live = await db.execute('SELECT COUNT(*) FROM t');
      expect(live.rows.single.single, 3);
    });

    test('beginSnapshot / commit returns a stable view, blocks writers',
        () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('INSERT INTO t VALUES (1), (2)');

      await db.beginSnapshot();
      // Inside the snapshot, mutations are rejected.
      await expectLater(
        db.execute('INSERT INTO t VALUES (99)'),
        throwsA(isA<StateError>()),
      );
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.single.single, 2);
      await db.execute('COMMIT');

      // After commit, writes are allowed again and the count is unchanged
      // (the snapshot didn't mutate live state).
      await db.execute('INSERT INTO t VALUES (3)');
      final r2 = await db.execute('SELECT COUNT(*) FROM t');
      expect(r2.rows.single.single, 3);
    });

    test('beginSnapshot rollback also restores live state', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE t(a INTEGER)');
      await db.execute('INSERT INTO t VALUES (1)');
      await db.beginSnapshot();
      await db.execute('ROLLBACK');
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.single.single, 1);
    });
  });
}
