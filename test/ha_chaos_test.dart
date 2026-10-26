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
}
