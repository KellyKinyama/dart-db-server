library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oplog.dart';
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

    test('bootstrap seeds a fresh replica from the primary snapshot', () async {
      final primary = await Database.open(_tmp('boot_p'));
      await primary.enableOpLog();
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT)');
        await primary.execute("INSERT INTO t VALUES (1,'a'),(2,'b')");

        // A replica that starts AFTER data already exists must still converge.
        final replica = await Replica.bootstrap(primary, _tmp('boot_r'));
        try {
          expect(replica.appliedLsn, primary.opLog!.lastLsn);
          final rr =
              await replica.target.execute('SELECT id, n FROM t ORDER BY id');
          expect(rr.rows, [
            [1, 'a'],
            [2, 'b'],
          ]);

          // Further primary writes stream through incrementally.
          await primary.execute("INSERT INTO t VALUES (3,'c')");
          await replica.catchUp(primary.opLog!);
          final rr2 = await replica.target.execute('SELECT COUNT(*) FROM t');
          expect(rr2.rows, [
            [3],
          ]);
        } finally {
          await replica.target.close();
        }
      } finally {
        await primary.close();
      }
    });

    test('a bootstrapped replica can follow a promoted primary', () async {
      final primary = await Database.open(_tmp('chain_p'));
      await primary.enableOpLog();
      final mid = await Database.open(_tmp('chain_mid'));
      final midR = Replica(mid);
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');
        await midR.catchUp(primary.opLog!);
        await primary.close();
        await midR.promote(); // mid becomes the new primary
        await mid.execute('INSERT INTO t VALUES (2)');

        // A downstream replica bootstraps from the promoted node, then follows.
        final down = await Replica.bootstrap(mid, _tmp('chain_down'));
        try {
          final rr = await down.target.execute('SELECT COUNT(*) FROM t');
          expect(rr.rows, [
            [2],
          ]);
          await mid.execute('INSERT INTO t VALUES (3)');
          await down.catchUp(mid.opLog!);
          final rr2 = await down.target.execute('SELECT COUNT(*) FROM t');
          expect(rr2.rows, [
            [3],
          ]);
        } finally {
          await down.target.close();
        }
      } finally {
        await mid.close();
      }
    });

    test('fencing: promotion fences the old primary (no split-brain)',
        () async {
      final epochPath = _tmp('epoch').replaceAll('.json', '.epoch');
      final fence = ClusterEpoch(epochPath);
      fence.write(1); // primary holds epoch 1

      final primary = await Database.open(_tmp('fence_p'));
      await primary.enableOpLog();
      primary.attachFence(fence, epoch: 1);
      final replica = await Database.open(_tmp('fence_r'));
      final r = Replica(replica);
      r.attachFence(fence); // replica holds epoch 0 until promoted
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');
        await r.catchUp(primary.opLog!);

        // Failover: promote the replica. This bumps the shared epoch to 2.
        await r.promote();
        expect(fence.read(), 2);
        expect(replica.epoch, 2);

        // The OLD primary (still alive, epoch 1) is now fenced.
        expect(
          () => primary.execute('INSERT INTO t VALUES (99)'),
          throwsA(isA<StateError>()),
        );

        // The NEW primary (epoch 2) accepts writes.
        await replica.execute('INSERT INTO t VALUES (2)');
        final rr = await replica.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [2],
        ]);
      } finally {
        await primary.close();
        await replica.close();
      }
    });

    test('haStatus reports role, epoch, and replication position', () async {
      final primary = await Database.open(_tmp('hs_p'));
      await primary.enableOpLog();
      final replica = await Database.open(_tmp('hs_r'));
      final r = Replica(replica);
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');

        final ps = primary.haStatus();
        expect(ps.role, 'primary');
        expect(ps.logLastLsn, 2);
        expect(ps.fenced, isFalse);

        await r.catchUp(primary.opLog!);
        final rs = replica.haStatus();
        expect(rs.role, 'replica');
        expect(rs.appliedLsn, 2);
      } finally {
        await primary.close();
        await replica.close();
      }
    });

    test('FailoverController promotes the most-caught-up replica', () async {
      final fence = ClusterEpoch(_tmp('fo').replaceAll('.json', '.epoch'));
      fence.write(1);
      final primary = await Database.open(_tmp('fo_p'));
      await primary.enableOpLog();
      primary.attachFence(fence, epoch: 1);

      final r1 = Replica(await Database.open(_tmp('fo_r1')))..attachFence(fence);
      final r2 = Replica(await Database.open(_tmp('fo_r2')))..attachFence(fence);
      var alive = true;
      final ctrl = FailoverController(
        replicas: [r1, r2],
        isPrimaryAlive: () async => alive,
      );
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');
        await r1.catchUp(primary.opLog!); // r1 fully caught up
        await primary.execute('INSERT INTO t VALUES (2)');

        // Primary alive → no failover.
        expect(await ctrl.checkAndFailover(primaryLog: primary.opLog!), isNull);

        // Primary dies.
        alive = false;
        final winner =
            await ctrl.checkAndFailover(primaryLog: primary.opLog!);
        expect(winner, isNotNull);
        expect(fence.read(), 2); // epoch bumped
        expect(winner!.target.epoch, 2);

        // Old primary is fenced; the winner is writable.
        expect(
          () => primary.execute('INSERT INTO t VALUES (99)'),
          throwsA(isA<StateError>()),
        );
        await winner.target.execute('INSERT INTO t VALUES (3)');
        final rr = await winner.target.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [3],
        ]);
      } finally {
        await primary.close();
        await r1.target.close();
        await r2.target.close();
      }
    });

    test('ClusterRouter routes reads to replicas, writes to primary, and '
        'redirects after failover', () async {
      final fence = ClusterEpoch(_tmp('rt').replaceAll('.json', '.epoch'));
      fence.write(1);
      final primary = await Database.open(_tmp('rt_p'));
      await primary.enableOpLog();
      primary.attachFence(fence, epoch: 1);
      final replica = await Database.open(_tmp('rt_r'));
      final rep = Replica(replica)..attachFence(fence);
      final router = ClusterRouter([primary, replica]);
      try {
        // Writes land on the primary.
        await router.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await router.execute('INSERT INTO t VALUES (1)');
        await rep.catchUp(primary.opLog!);

        // A SELECT is served by the replica (round-robin over one replica).
        final rr = await router.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [1],
        ]);

        // Failover: promote the replica (fences the old primary).
        await rep.promote();

        // The router now sends writes to the promoted node automatically.
        await router.execute('INSERT INTO t VALUES (2)');
        final rr2 = await router.execute('SELECT COUNT(*) FROM t');
        expect(rr2.rows, [
          [2],
        ]);
        // The promoted node is the writable primary now.
        expect(router.primary, same(replica));
      } finally {
        await primary.close();
        await replica.close();
      }
    });

    test('FailoverController refuses to promote without quorum', () async {
      final fence = ClusterEpoch(_tmp('q').replaceAll('.json', '.epoch'));
      fence.write(1);
      final primary = await Database.open(_tmp('q_p'));
      await primary.enableOpLog();
      primary.attachFence(fence, epoch: 1);
      final r1 = Replica(await Database.open(_tmp('q_r1')))..attachFence(fence);
      // Cluster of 3 (primary + 2 replicas); only 1 replica is reachable here,
      // so a quorum of 2 cannot be met → promotion must be refused.
      final ctrl = FailoverController(
        replicas: [r1],
        isPrimaryAlive: () async => false,
        quorum: 2,
      );
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await r1.catchUp(primary.opLog!);

        final winner = await ctrl.checkAndFailover(primaryLog: primary.opLog!);
        expect(winner, isNull); // minority partition: no promotion
        expect(fence.read(), 1); // epoch unchanged
        expect(r1.target.isReplica, isTrue); // still a replica
      } finally {
        await primary.close();
        await r1.target.close();
      }
    });
  });
}
