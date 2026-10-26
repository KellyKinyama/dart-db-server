library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
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
}
