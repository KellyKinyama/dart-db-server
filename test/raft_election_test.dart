library;

import 'package:dart_db_server/server/raft/config.dart';
import 'package:dart_db_server/server/raft/raft_node.dart';
import 'package:dart_db_server/server/raft/transport.dart';
import 'package:test/test.dart';

class _Cluster {
  final SimulatedNetwork net;
  final Map<String, RaftNode> nodes;
  _Cluster(this.net, this.nodes);
  RaftNode operator [](String id) => nodes[id]!;
}

_Cluster _cluster(List<String> ids) {
  final net = SimulatedNetwork();
  final nodes = <String, RaftNode>{};
  for (final id in ids) {
    final peers = {for (final o in ids) if (o != id) o: 'sim'};
    final node = RaftNode(RaftConfig(id, peers), net.transportFor(id));
    nodes[id] = node;
    net.register(id, node);
  }
  return _Cluster(net, nodes);
}

void main() {
  group('Raft leader election', () {
    test('a candidate with a majority becomes leader', () async {
      final c = _cluster(['n1', 'n2', 'n3']);
      await c['n1'].onElectionTimeout();
      expect(c['n1'].isLeader, isTrue);
      expect(c['n1'].currentTerm, 1);
      expect(c['n2'].role, RaftRole.follower);
      expect(c['n2'].currentTerm, 1);
      expect(c['n3'].role, RaftRole.follower);
    });

    test('a later election steps the old leader down (one leader per term)',
        () async {
      final c = _cluster(['n1', 'n2', 'n3']);
      await c['n1'].onElectionTimeout(); // n1 leader @ term 1
      expect(c['n1'].isLeader, isTrue);

      await c['n2'].onElectionTimeout(); // n2 campaigns @ term 2
      expect(c['n2'].isLeader, isTrue);
      expect(c['n2'].currentTerm, 2);
      // The old leader has stepped down and adopted the new term.
      expect(c['n1'].isLeader, isFalse);
      expect(c['n1'].role, RaftRole.follower);
      expect(c['n1'].currentTerm, 2);

      // Never two leaders at the same term.
      final leadersAtTerm2 = c.nodes.values
          .where((n) => n.isLeader && n.currentTerm == 2)
          .length;
      expect(leadersAtTerm2, 1);
    });

    test('a minority candidate cannot win; the majority side elects a leader',
        () async {
      final c = _cluster(['n1', 'n2', 'n3']);
      c.net.isolate('n1'); // n1 is partitioned away

      await c['n1'].onElectionTimeout();
      expect(c['n1'].isLeader, isFalse); // no votes reachable
      expect(c['n1'].role, RaftRole.candidate);

      await c['n2'].onElectionTimeout(); // n2 + n3 form a majority
      expect(c['n2'].isLeader, isTrue);
    });

    test('a stale candidate steps down when it sees a higher term', () async {
      final c = _cluster(['n1', 'n2', 'n3']);
      await c['n1'].onElectionTimeout(); // term 1 leader
      // Force n3 to a higher term by campaigning; n1 should yield on contact.
      await c['n3'].onElectionTimeout(); // term 2 leader, n1 steps down
      expect(c['n3'].currentTerm, 2);
      expect(c['n1'].currentTerm, 2);
      expect(c['n1'].isLeader, isFalse);
    });
  });

  group('Raft log replication', () {
    test('a committed entry replicates to a majority and applies', () async {
      final c = _cluster(['n1', 'n2', 'n3']);
      await c['n1'].onElectionTimeout(); // leader @ term 1

      final idx = c['n1'].clientAppend(['INSERT INTO t VALUES (1)']);
      expect(idx, 1);
      expect(c['n1'].commitIndex, 0); // not yet committed

      await c['n1'].sendHeartbeats(); // replicate to followers
      expect(c['n1'].commitIndex, 1); // majority matched → committed
      expect(c['n2'].log.lastIndex, 1);
      expect(c['n3'].log.lastIndex, 1);

      await c['n1'].sendHeartbeats(); // carry leaderCommit to followers
      expect(c['n2'].commitIndex, 1);
      expect(c['n3'].commitIndex, 1);
    });

    test('entries do not commit without a majority', () async {
      final c = _cluster(['n1', 'n2', 'n3']);
      await c['n1'].onElectionTimeout();
      // Partition both followers away from the leader.
      c.net.partition('n1', 'n2');
      c.net.partition('n1', 'n3');

      c['n1'].clientAppend(['INSERT INTO t VALUES (1)']);
      await c['n1'].sendHeartbeats();
      expect(c['n1'].commitIndex, 0); // only the leader has it
      expect(c['n2'].log.lastIndex, 0);

      // Heal one follower → now a majority (leader + n2) → commits.
      c.net.heal('n1', 'n2');
      await c['n1'].sendHeartbeats();
      expect(c['n1'].commitIndex, 1);
      expect(c['n2'].log.lastIndex, 1);
    });

    test('committed entries are delivered to onCommit once, in order',
        () async {
      final c = _cluster(['n1', 'n2', 'n3']);
      final leaderApplied = <String>[];
      final followerApplied = <String>[];
      c['n1'].onCommit = (e) => leaderApplied.add(e.ops.single);
      c['n2'].onCommit = (e) => followerApplied.add(e.ops.single);

      await c['n1'].onElectionTimeout();
      c['n1'].clientAppend(['A']);
      c['n1'].clientAppend(['B']);
      await c['n1'].sendHeartbeats(); // replicate + leader commits
      await c['n1'].sendHeartbeats(); // carry commit to followers

      expect(leaderApplied, ['A', 'B']);
      expect(followerApplied, ['A', 'B']);

      // Idempotent: another heartbeat does not re-deliver committed entries.
      await c['n1'].sendHeartbeats();
      expect(leaderApplied, ['A', 'B']);
      expect(followerApplied, ['A', 'B']);
    });
  });
}
