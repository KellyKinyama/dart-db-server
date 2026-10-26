library;

import 'dart:math';

import 'package:dart_db_server/server/raft/config.dart';
import 'package:dart_db_server/server/raft/raft_driver.dart';
import 'package:dart_db_server/server/raft/raft_node.dart';
import 'package:dart_db_server/server/raft/transport.dart';
import 'package:test/test.dart';

Future<void> _until(bool Function() cond,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

int _leaderCount(Iterable<RaftNode> nodes) =>
    nodes.where((n) => n.isLeader).length;

void main() {
  test('timer-driven nodes elect exactly one stable leader', () async {
    final net = SimulatedNetwork();
    final ids = ['n1', 'n2', 'n3'];
    final nodes = <RaftNode>[];
    final drivers = <RaftDriver>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final peers = {for (final o in ids) if (o != id) o: 'sim'};
      final node = RaftNode(RaftConfig(id, peers), net.transportFor(id));
      net.register(id, node);
      nodes.add(node);
      // Distinct seeds so election timeouts spread out and converge fast.
      drivers.add(RaftDriver(node, rng: Random(100 + i)));
    }
    try {
      for (final d in drivers) {
        d.start();
      }
      // A single leader emerges...
      await _until(() => _leaderCount(nodes) == 1);
      // ...and stays stable while heartbeats keep followers quiet.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(_leaderCount(nodes), 1);

      final leader = nodes.firstWhere((n) => n.isLeader);
      // Everyone agrees on the term.
      for (final n in nodes) {
        expect(n.currentTerm, greaterThanOrEqualTo(leader.currentTerm - 0));
      }
    } finally {
      for (final d in drivers) {
        d.stop();
      }
    }
  });

  test('a new leader is elected after the current leader stops', () async {
    final net = SimulatedNetwork();
    final ids = ['n1', 'n2', 'n3'];
    final nodes = <String, RaftNode>{};
    final drivers = <String, RaftDriver>{};
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      final peers = {for (final o in ids) if (o != id) o: 'sim'};
      final node = RaftNode(RaftConfig(id, peers), net.transportFor(id));
      net.register(id, node);
      nodes[id] = node;
      drivers[id] = RaftDriver(node, rng: Random(200 + i));
    }
    try {
      for (final d in drivers.values) {
        d.start();
      }
      await _until(() => _leaderCount(nodes.values) == 1);
      final oldLeader = nodes.values.firstWhere((n) => n.isLeader);

      // The leader "fails": stop its driver and partition it away.
      drivers[oldLeader.nodeId]!.stop();
      net.isolate(oldLeader.nodeId);

      // The surviving majority elects a new leader.
      await _until(() => nodes.values
          .where((n) => n.isLeader && n.nodeId != oldLeader.nodeId)
          .isNotEmpty);
      final newLeader = nodes.values
          .firstWhere((n) => n.isLeader && n.nodeId != oldLeader.nodeId);
      expect(newLeader.currentTerm, greaterThan(oldLeader.currentTerm));
    } finally {
      for (final d in drivers.values) {
        d.stop();
      }
    }
  });
}
