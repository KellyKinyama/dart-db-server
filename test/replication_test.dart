library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/replication.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_repl_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('Replica', () {
    test('catches up from a primary op-log and serves matching reads',
        () async {
      final primary = await Database.open(_tmp('primary'));
      await primary.enableOpLog();
      final replica = await Database.open(_tmp('replica'));
      final r = Replica(replica);
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT)');
        await primary.execute("INSERT INTO t VALUES (1,'a'),(2,'b')");
        await primary.execute("UPDATE t SET n='B' WHERE id=2");

        expect(r.lagFrom(primary.opLog!), 3);
        final applied = await r.catchUp(primary.opLog!);
        expect(applied, 3);
        expect(r.appliedLsn, 3);
        expect(r.lagFrom(primary.opLog!), 0);

        final pr = await primary.execute('SELECT id, n FROM t ORDER BY id');
        final rr = await replica.execute('SELECT id, n FROM t ORDER BY id');
        expect(rr.rows, pr.rows);
        expect(rr.rows, [
          [1, 'a'],
          [2, 'B'],
        ]);
      } finally {
        await primary.close();
        await replica.close();
      }
    });

    test('replica rejects client writes', () async {
      final replica = await Database.open(_tmp('ro'));
      Replica(replica);
      try {
        // DDL/DML from a client must be refused on a replica.
        expect(
          () => replica.execute('CREATE TABLE t(id INTEGER)'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await replica.close();
      }
    });

    test('incremental catch-up applies only new records', () async {
      final primary = await Database.open(_tmp('primary2'));
      await primary.enableOpLog();
      final replica = await Database.open(_tmp('replica2'));
      final r = Replica(replica);
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');
        expect(await r.catchUp(primary.opLog!), 2);

        await primary.execute('INSERT INTO t VALUES (2)');
        await primary.execute('INSERT INTO t VALUES (3)');
        // Only the two new records apply the second time.
        expect(await r.catchUp(primary.opLog!), 2);
        expect(await r.catchUp(primary.opLog!), 0); // idempotent

        final rr = await replica.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [3],
        ]);
      } finally {
        await primary.close();
        await replica.close();
      }
    });

    test('replica resumes appliedLsn after restart', () async {
      final primary = await Database.open(_tmp('primary3'));
      await primary.enableOpLog();
      final replicaPath = _tmp('replica3');
      var replica = await Database.open(replicaPath);
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');
        await Replica(replica).catchUp(primary.opLog!);
        expect(replica.appliedLsn, 2);
      } finally {
        await replica.close();
      }
      // Reopen the replica: appliedLsn must survive the restart.
      replica = await Database.open(replicaPath);
      final r = Replica(replica);
      try {
        expect(replica.appliedLsn, 2);
        await primary.execute('INSERT INTO t VALUES (2)');
        expect(await r.catchUp(primary.opLog!), 1); // only the new record
        final rr = await replica.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [2],
        ]);
      } finally {
        await primary.close();
        await replica.close();
      }
    });

    test('promote makes a replica writable with monotonic LSNs', () async {
      final primary = await Database.open(_tmp('p_fail'));
      await primary.enableOpLog();
      final replica = await Database.open(_tmp('r_fail'));
      final r = Replica(replica);
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1),(2)');
        await r.catchUp(primary.opLog!);
        expect(replica.appliedLsn, 2);

        // Primary "fails"; promote the replica.
        await primary.close();
        await r.promote();

        // Now accepts writes, and its op-log continues above the applied LSN.
        await replica.execute('INSERT INTO t VALUES (3)');
        expect(replica.opLog!.lastLsn, 3);
        final rr = await replica.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [3],
        ]);
      } finally {
        await replica.close();
      }
    });
  });
}
