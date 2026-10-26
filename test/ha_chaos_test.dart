library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oplog.dart';
import 'package:dart_db_server/server/replication.dart';
import 'package:dart_db_server/server/replication_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_chaos_');
  return '${dir.path}${Platform.pathSeparator}$tag';
}

Future<void> _until(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // End-to-end HA acceptance: a replicated cluster survives a primary crash via
  // probe-driven, epoch-fenced automatic failover with no loss of replicated
  // writes, and the promoted node keeps serving writes.
  test('cluster survives primary crash with no replicated data loss', () async {
    final base = _tmp('cluster');
    final fence = ClusterEpoch('$base.epoch');
    fence.write(1);

    final primary = await Database.open('$base-primary.json');
    await primary.enableOpLog();
    primary.attachFence(fence, epoch: 1);
    final server = ReplicationServer(primary.opLog!);
    final port = await server.start();

    final r1 = Replica(await Database.open('$base-r1.json'))..attachFence(fence);
    final r2 = Replica(await Database.open('$base-r2.json'))..attachFence(fence);
    final c1 = ReplicationClient(r1.target);
    final c2 = ReplicationClient(r2.target);
    await c1.connect('127.0.0.1', port);
    await c2.connect('127.0.0.1', port);

    final router = ClusterRouter([primary, r1.target, r2.target]);
    final probe = PrimaryProbe('127.0.0.1', port,
        timeout: const Duration(milliseconds: 500));
    final controller = FailoverController(
      replicas: [r1, r2],
      isPrimaryAlive: probe.alive,
      quorum: 2, // both replicas must be reachable to promote
    );

    try {
      // Workload through the router (writes land on the primary).
      await router.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
      for (var i = 1; i <= 25; i++) {
        await router.execute('INSERT INTO t VALUES ($i)');
      }
      final committed = primary.opLog!.lastLsn;

      // Replicas stream to full catch-up before the crash.
      await _until(() =>
          r1.appliedLsn == committed && r2.appliedLsn == committed);

      // --- CRASH: the primary becomes unreachable. ---
      await c1.close();
      await c2.close();
      await server.stop();

      expect(await probe.alive(), isFalse);

      // Automatic failover: promote the most-caught-up replica.
      final winner =
          await controller.checkAndFailover(primaryLog: primary.opLog!);
      expect(winner, isNotNull);
      expect(fence.read(), 2); // epoch bumped

      // No replicated write was lost: the new primary has all 25 rows + schema.
      final cnt = await winner!.target.execute('SELECT COUNT(*) FROM t');
      expect(cnt.rows, [
        [25],
      ]);

      // Split-brain safety: the old primary is fenced.
      expect(
        () => primary.execute('INSERT INTO t VALUES (999)'),
        throwsA(isA<StateError>()),
      );

      // The cluster keeps serving writes through the router after failover.
      await router.execute('INSERT INTO t VALUES (26)');
      final cnt2 = await winner.target.execute('SELECT COUNT(*) FROM t');
      expect(cnt2.rows, [
        [26],
      ]);
      expect(router.primary, same(winner.target));
    } finally {
      await c1.close();
      await c2.close();
      await server.stop();
      await primary.close();
      await r1.target.close();
      await r2.target.close();
    }
  });

  test('a partitioned replica catches up after the partition heals', () async {
    final base = _tmp('partition');
    final primary = await Database.open('$base-primary.json');
    await primary.enableOpLog();
    final server = ReplicationServer(primary.opLog!);
    final port = await server.start();

    final r1 = await Database.open('$base-r1.json');
    final r2path = '$base-r2.json';
    var r2 = await Database.open(r2path);
    var c1 = ReplicationClient(r1);
    var c2 = ReplicationClient(r2);
    await c1.connect('127.0.0.1', port);
    await c2.connect('127.0.0.1', port);
    try {
      await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
      for (var i = 1; i <= 10; i++) {
        await primary.execute('INSERT INTO t VALUES ($i)');
      }
      final head = primary.opLog!.lastLsn;
      await _until(() => r1.appliedLsn == head && r2.appliedLsn == head);

      // --- PARTITION r2 away; the primary keeps committing. ---
      await c2.close();
      for (var i = 11; i <= 15; i++) {
        await primary.execute('INSERT INTO t VALUES ($i)');
      }
      final head2 = primary.opLog!.lastLsn;
      await _until(() => r1.appliedLsn == head2); // the connected replica keeps up
      expect(r2.appliedLsn, head); // the partitioned one is stuck

      // --- HEAL: r2 reconnects and resumes from its appliedLsn. ---
      c2 = ReplicationClient(r2);
      await c2.connect('127.0.0.1', port);
      await _until(() => r2.appliedLsn == head2);
      final rr = await r2.execute('SELECT COUNT(*) FROM t');
      expect(rr.rows, [
        [15],
      ]);
    } finally {
      await c1.close();
      await c2.close();
      await server.stop();
      await primary.close();
      await r1.close();
      await r2.close();
    }
  });

  test('a replica survives a rolling restart with no data loss', () async {
    final base = _tmp('rolling');
    final primary = await Database.open('$base-primary.json');
    await primary.enableOpLog();
    final server = ReplicationServer(primary.opLog!);
    final port = await server.start();

    final rpath = '$base-r.json';
    var replica = await Database.open(rpath);
    var client = ReplicationClient(replica);
    await client.connect('127.0.0.1', port);
    try {
      await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
      for (var i = 1; i <= 8; i++) {
        await primary.execute('INSERT INTO t VALUES ($i)');
      }
      await _until(() => replica.appliedLsn == primary.opLog!.lastLsn);

      // --- RESTART the replica (close + reopen from disk). ---
      await client.close();
      await replica.close();

      // The primary keeps committing while the replica is down.
      for (var i = 9; i <= 12; i++) {
        await primary.execute('INSERT INTO t VALUES ($i)');
      }

      replica = await Database.open(rpath); // resumes appliedLsn from its snapshot
      expect(replica.appliedLsn, 9); // CREATE + 8 inserts persisted before restart
      client = ReplicationClient(replica);
      await client.connect('127.0.0.1', port);
      await _until(() => replica.appliedLsn == primary.opLog!.lastLsn);
      final rr = await replica.execute('SELECT COUNT(*) FROM t');
      expect(rr.rows, [
        [12],
      ]);
    } finally {
      await client.close();
      await server.stop();
      await primary.close();
      await replica.close();
    }
  });
}
