library;

import 'dart:math';

import 'package:dart_db_server/server/raft/config.dart';
import 'package:dart_db_server/server/raft/raft_node.dart';
import 'package:dart_db_server/server/raft/transport.dart';
import 'package:test/test.dart';

List<RaftNode> _cluster(SimulatedNetwork net, List<String> ids) {
  final nodes = <RaftNode>[];
  for (final id in ids) {
    final peers = {for (final o in ids) if (o != id) o: 'sim'};
    final node = RaftNode(RaftConfig(id, peers), net.transportFor(id));
    net.register(id, node);
    nodes.add(node);
  }
  return nodes;
}

/// Election safety: at most one leader per term.
void _checkElectionSafety(List<RaftNode> nodes) {
  final leadersByTerm = <int, int>{};
  for (final n in nodes) {
    if (n.isLeader) {
      leadersByTerm[n.currentTerm] = (leadersByTerm[n.currentTerm] ?? 0) + 1;
    }
  }
  for (final e in leadersByTerm.entries) {
    expect(e.value, lessThanOrEqualTo(1),
        reason: 'two leaders at term ${e.key}');
  }
}

/// Log-matching: if two logs hold an entry at the same index with the same
/// term, every preceding entry is identical.
void _checkLogMatching(List<RaftNode> nodes) {
  for (var a = 0; a < nodes.length; a++) {
    for (var b = a + 1; b < nodes.length; b++) {
      final la = nodes[a].log;
      final lb = nodes[b].log;
      final m = min(la.lastIndex, lb.lastIndex);
      for (var i = 1; i <= m; i++) {
        if (la.termAt(i) == lb.termAt(i)) {
          for (var j = 1; j <= i; j++) {
            final ea = la.at(j)!;
            final eb = lb.at(j)!;
            expect(ea.term, eb.term, reason: 'term mismatch at $j');
            expect(ea.ops.join('\u0001'), eb.ops.join('\u0001'),
                reason: 'ops mismatch at $j');
          }
        }
      }
    }
  }
}

/// State-machine safety: once an index is committed anywhere, its entry never
/// changes on any node (tracked across the whole run).
void _checkCommittedStable(
    List<RaftNode> nodes, Map<int, String> committed) {
  for (final n in nodes) {
    for (var i = 1; i <= n.commitIndex; i++) {
      final e = n.log.at(i);
      if (e == null) continue;
      final sig = '${e.term}:${e.ops.join('\u0001')}';
      final prior = committed[i];
      if (prior == null) {
        committed[i] = sig;
      } else {
        expect(sig, prior, reason: 'committed entry at $i changed');
      }
    }
  }
}

void main() {
  group('Raft safety invariants (randomized simulation)', () {
    for (final seed in [1, 7, 42, 99, 2024]) {
      test('invariants hold under random events (seed $seed)', () async {
        final rng = Random(seed);
        final net = SimulatedNetwork();
        final ids = ['n1', 'n2', 'n3'];
        final nodes = _cluster(net, ids);
        final committed = <int, String>{};
        var cmd = 0;

        for (var step = 0; step < 200; step++) {
          final roll = rng.nextInt(100);
          if (roll < 40) {
            // Random node times out and (maybe) starts an election.
            await nodes[rng.nextInt(nodes.length)].onElectionTimeout();
          } else if (roll < 70) {
            // A leader sends heartbeats / replicates.
            final leaders = nodes.where((n) => n.isLeader).toList();
            if (leaders.isNotEmpty) {
              await leaders[rng.nextInt(leaders.length)].sendHeartbeats();
            }
          } else if (roll < 85) {
            // A leader accepts a client command.
            final leaders = nodes.where((n) => n.isLeader).toList();
            if (leaders.isNotEmpty) {
              leaders[rng.nextInt(leaders.length)]
                  .clientAppend(['INSERT INTO t VALUES (${cmd++})']);
            }
          } else if (roll < 95) {
            // Toggle a random partition.
            final a = ids[rng.nextInt(ids.length)];
            var b = ids[rng.nextInt(ids.length)];
            while (b == a) {
              b = ids[rng.nextInt(ids.length)];
            }
            rng.nextBool() ? net.partition(a, b) : net.heal(a, b);
          } else {
            net.healAll();
          }

          _checkElectionSafety(nodes);
          _checkLogMatching(nodes);
          _checkCommittedStable(nodes, committed);
        }

        // Heal and let the cluster converge; a committed entry must persist.
        net.healAll();
        for (var i = 0; i < 20; i++) {
          for (final n in nodes.where((n) => n.isLeader)) {
            await n.sendHeartbeats();
          }
          if (nodes.where((n) => n.isLeader).isEmpty) {
            await nodes[0].onElectionTimeout();
          }
          _checkElectionSafety(nodes);
          _checkLogMatching(nodes);
          _checkCommittedStable(nodes, committed);
        }
      });
    }
  });
}
