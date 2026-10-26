library;

import 'package:dart_db_server/server/raft/config.dart';
import 'package:dart_db_server/server/raft/raft_node.dart';
import 'package:dart_db_server/server/raft/raft_rpc_server.dart';
import 'package:test/test.dart';

void main() {
  test('a 3-node cluster elects and replicates over real TCP', () async {
    final ids = ['n1', 'n2', 'n3'];
    final nodes = <String, RaftNode>{};
    final servers = <String, RaftRpcServer>{};
    final peerMaps = <String, Map<String, String>>{};
    final ports = <String, int>{};

    // Build each node with a TCP transport over a (soon-filled) peer map, and
    // bind its RPC server to an ephemeral port.
    for (final id in ids) {
      final peers = <String, String>{};
      peerMaps[id] = peers;
      final node = RaftNode(
        RaftConfig(id, {for (final o in ids) if (o != id) o: '?'}),
        TcpRaftTransport(peers),
      );
      nodes[id] = node;
      final server = RaftRpcServer(node);
      ports[id] = await server.start();
      servers[id] = server;
    }
    // Now that ports are known, fill every node's peer address map.
    for (final id in ids) {
      for (final o in ids) {
        if (o != id) peerMaps[id]!['$o'] = '127.0.0.1:${ports[o]}';
      }
    }

    try {
      await nodes['n1']!.onElectionTimeout(); // RequestVote over TCP
      expect(nodes['n1']!.isLeader, isTrue);
      expect(nodes['n1']!.currentTerm, 1);

      // Replicate a couple of entries over TCP.
      nodes['n1']!.clientAppend(['INSERT INTO t VALUES (1)']);
      nodes['n1']!.clientAppend(['INSERT INTO t VALUES (2)']);
      await nodes['n1']!.sendHeartbeats(); // replicate + commit
      expect(nodes['n1']!.commitIndex, 2);
      await nodes['n1']!.sendHeartbeats(); // carry commit to followers

      for (final id in ids) {
        expect(nodes[id]!.log.lastIndex, 2, reason: '$id missing entries');
      }
      expect(nodes['n2']!.commitIndex, 2);
      expect(nodes['n3']!.commitIndex, 2);
    } finally {
      for (final s in servers.values) {
        await s.stop();
      }
    }
  });
}
