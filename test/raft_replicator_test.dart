library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/raft/config.dart';
import 'package:dart_db_server/server/raft/raft_node.dart';
import 'package:dart_db_server/server/raft/raft_replicator.dart';
import 'package:dart_db_server/server/raft/transport.dart';
import 'package:test/test.dart';

class _Node {
  final RaftNode raft;
  final Database db;
  final RaftReplicator repl;
  _Node(this.raft, this.db, this.repl);
}

Future<Map<String, _Node>> _cluster(
    SimulatedNetwork net, List<String> ids) async {
  final nodes = <String, _Node>{};
  for (final id in ids) {
    final peers = {for (final o in ids) if (o != id) o: 'sim'};
    final raft = RaftNode(RaftConfig(id, peers), net.transportFor(id));
    net.register(id, raft);
    final db = await Database.open(); // in-memory state machine
    nodes[id] = _Node(raft, db, RaftReplicator(raft, db));
  }
  return nodes;
}

/// Replicate + commit + apply until every node's DB caught up to the leader's
/// commit index (drives heartbeats, since timeouts are explicit in tests).
Future<void> _settle(Map<String, _Node> nodes, String leader) async {
  for (var i = 0; i < 6; i++) {
    await nodes[leader]!.raft.sendHeartbeats();
    for (final n in nodes.values) {
      await n.repl.drained();
    }
  }
}

void main() {
  test('writes proposed through Raft commit and apply on every node', () async {
    final net = SimulatedNetwork();
    final ids = ['n1', 'n2', 'n3'];
    final nodes = await _cluster(net, ids);
    try {
      await nodes['n1']!.raft.onElectionTimeout(); // n1 leader
      expect(nodes['n1']!.repl.isLeader, isTrue);

      // Direct client writes are refused — writes must go through Raft.
      expect(
        () => nodes['n1']!.db.execute('CREATE TABLE x(id INTEGER)'),
        throwsA(isA<StateError>()),
      );

      // Propose schema + rows on the leader.
      expect(nodes['n1']!.repl.propose('CREATE TABLE t(id INTEGER PRIMARY KEY)'),
          1);
      nodes['n1']!.repl.propose('INSERT INTO t VALUES (1)');
      nodes['n1']!.repl.propose('INSERT INTO t VALUES (2)');
      await _settle(nodes, 'n1');

      // Every node's state machine reflects the committed log.
      for (final id in ids) {
        final r = await nodes[id]!.db.execute('SELECT COUNT(*) FROM t');
        expect(r.rows, [
          [2],
        ], reason: '$id did not apply the committed writes');
      }
    } finally {
      for (final n in nodes.values) {
        await n.db.close();
      }
    }
  });

  test('a follower that was partitioned catches up after rejoin', () async {
    final net = SimulatedNetwork();
    final ids = ['n1', 'n2', 'n3'];
    final nodes = await _cluster(net, ids);
    try {
      await nodes['n1']!.raft.onElectionTimeout();
      nodes['n1']!.repl.propose('CREATE TABLE t(id INTEGER PRIMARY KEY)');

      // Partition n3 away; the leader + n2 still form a majority and commit.
      net.partition('n1', 'n3');
      nodes['n1']!.repl.propose('INSERT INTO t VALUES (1)');
      nodes['n1']!.repl.propose('INSERT INTO t VALUES (2)');
      await _settle(nodes, 'n1');

      // n3 never received the log while partitioned — it is behind.
      expect(nodes['n3']!.repl.appliedLsn,
          lessThan(nodes['n1']!.raft.commitIndex));

      // Heal → n3 catches up to the full committed log.
      net.heal('n1', 'n3');
      await _settle(nodes, 'n1');
      final caught = await nodes['n3']!.db.execute('SELECT COUNT(*) FROM t');
      expect(caught.rows, [
        [2],
      ]);
    } finally {
      for (final n in nodes.values) {
        await n.db.close();
      }
    }
  });
}
