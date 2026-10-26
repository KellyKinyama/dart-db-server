library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oplog.dart';
import 'package:dart_db_server/server/replication.dart';
import 'package:dart_db_server/server/replication_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_tcp_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

/// Poll until [cond] holds or [timeout] elapses (streaming apply is async).
Future<void> _until(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('TCP replication', () {
    test('streams backlog then live tail to a replica', () async {
      final primary = await Database.open(_tmp('p'));
      await primary.enableOpLog();
      // Backlog exists before the replica connects.
      await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT)');
      await primary.execute("INSERT INTO t VALUES (1,'a')");

      final server = ReplicationServer(primary.opLog!);
      final port = await server.start();

      final replica = await Database.open(_tmp('r'));
      final client = ReplicationClient(replica);
      try {
        await client.connect('127.0.0.1', port);

        // Backlog applies.
        await _until(() => replica.appliedLsn >= 2);
        final rr = await replica.execute('SELECT id, n FROM t ORDER BY id');
        expect(rr.rows, [
          [1, 'a'],
        ]);

        // A live write on the primary streams through.
        await primary.execute("INSERT INTO t VALUES (2,'b')");
        await _until(() => replica.appliedLsn >= 3);
        final rr2 = await replica.execute('SELECT COUNT(*) FROM t');
        expect(rr2.rows, [
          [2],
        ]);
      } finally {
        await client.close();
        await server.stop();
        await primary.close();
        await replica.close();
      }
    });

    test('replica rejects local writes while following', () async {
      final primary = await Database.open(_tmp('p2'));
      await primary.enableOpLog();
      final server = ReplicationServer(primary.opLog!);
      final port = await server.start();
      final replica = await Database.open(_tmp('r2'));
      final client = ReplicationClient(replica);
      try {
        await client.connect('127.0.0.1', port);
        expect(
          () => replica.execute('CREATE TABLE x(id INTEGER)'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await client.close();
        await server.stop();
        await primary.close();
        await replica.close();
      }
    });

    test('replica resumes from its appliedLsn after reconnect', () async {
      final primary = await Database.open(_tmp('p3'));
      await primary.enableOpLog();
      final replicaPath = _tmp('r3');

      var server = ReplicationServer(primary.opLog!);
      var port = await server.start();
      var replica = await Database.open(replicaPath);
      var client = ReplicationClient(replica);
      try {
        await client.connect('127.0.0.1', port);
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');
        await _until(() => replica.appliedLsn >= 2);
      } finally {
        await client.close();
        await server.stop();
        await replica.close();
      }

      // Primary keeps committing while the replica is offline.
      await primary.execute('INSERT INTO t VALUES (2)');
      await primary.execute('INSERT INTO t VALUES (3)');

      // Reconnect: the replica resumes from appliedLsn (2) and gets 3 & 4 only.
      server = ReplicationServer(primary.opLog!);
      port = await server.start();
      replica = await Database.open(replicaPath);
      expect(replica.appliedLsn, 2);
      client = ReplicationClient(replica);
      try {
        await client.connect('127.0.0.1', port);
        await _until(() => replica.appliedLsn >= 4);
        final rr = await replica.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [3],
        ]);
      } finally {
        await client.close();
        await server.stop();
        await primary.close();
        await replica.close();
      }
    });
  });

  group('liveness probe & wall-clock lag', () {
    test('PrimaryProbe reports reachable vs down', () async {
      final primary = await Database.open(_tmp('probe_p'));
      await primary.enableOpLog();
      final server = ReplicationServer(primary.opLog!);
      final port = await server.start();
      final probe = PrimaryProbe('127.0.0.1', port,
          timeout: const Duration(milliseconds: 500));
      try {
        expect(await probe.alive(), isTrue);
        await server.stop();
        expect(await probe.alive(), isFalse);
      } finally {
        await primary.close();
      }
    });

    test('probe-driven FailoverController promotes when primary is down',
        () async {
      final fence = ClusterEpoch(_tmp('pf').replaceAll('.json', '.epoch'));
      fence.write(1);
      final primary = await Database.open(_tmp('pf_p'));
      await primary.enableOpLog();
      primary.attachFence(fence, epoch: 1);
      final server = ReplicationServer(primary.opLog!);
      final port = await server.start();

      final replica = Replica(await Database.open(_tmp('pf_r')))
        ..attachFence(fence);
      final probe = PrimaryProbe('127.0.0.1', port,
          timeout: const Duration(milliseconds: 500));
      final ctrl = FailoverController(
        replicas: [replica],
        isPrimaryAlive: probe.alive,
      );
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await replica.catchUp(primary.opLog!);

        // Primary reachable → no failover.
        expect(await ctrl.checkAndFailover(), isNull);

        // Primary goes down → probe fails → controller promotes.
        await server.stop();
        final winner = await ctrl.checkAndFailover(primaryLog: primary.opLog!);
        expect(winner, isNotNull);
        expect(fence.read(), 2);
      } finally {
        await primary.close();
        await replica.target.close();
      }
    });

    test('lagMsFrom reports a non-negative time lag', () async {
      final primary = await Database.open(_tmp('lag_p'));
      await primary.enableOpLog();
      final replica = await Database.open(_tmp('lag_r'));
      final r = Replica(replica);
      try {
        await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await primary.execute('INSERT INTO t VALUES (1)');
        // Caught up → zero time lag.
        await r.catchUp(primary.opLog!);
        expect(r.lagMsFrom(primary.opLog!), 0);
        // A new primary commit makes the replica lag (in records at least).
        await primary.execute('INSERT INTO t VALUES (2)');
        expect(r.lagMsFrom(primary.opLog!), greaterThanOrEqualTo(0));
        expect(r.lagFrom(primary.opLog!), 1);
      } finally {
        await primary.close();
        await replica.close();
      }
    });

    test('HealthServer serves /health JSON for a node', () async {
      final primary = await Database.open(_tmp('health_p'));
      await primary.enableOpLog();
      await primary.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
      final health = HealthServer(primary);
      final port = await health.start();
      final httpClient = HttpClient();
      try {
        final req =
            await httpClient.get('127.0.0.1', port, '/health');
        final resp = await req.close();
        expect(resp.statusCode, 200);
        final body = await resp.transform(utf8.decoder).join();
        expect(body, contains('"role":"primary"'));
        expect(body, contains('"log_last_lsn":1'));

        // Unknown path → 404.
        final req2 = await httpClient.get('127.0.0.1', port, '/nope');
        final resp2 = await req2.close();
        expect(resp2.statusCode, 404);
        await resp2.drain<void>();
      } finally {
        httpClient.close(force: true);
        await health.stop();
        await primary.close();
      }
    });
  });
}
