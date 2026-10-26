library;

import 'dart:io';

import 'package:dart_db_server/server/raft/config.dart';
import 'package:dart_db_server/server/raft/raft_node.dart';
import 'package:dart_db_server/server/raft/raft_store.dart';
import 'package:dart_db_server/server/raft/rpc.dart';
import 'package:dart_db_server/server/raft/transport.dart';
import 'package:test/test.dart';

String _tmp(String tag) =>
    '${Directory.systemTemp.createTempSync('ddbs_raftstate_').path}'
    '${Platform.pathSeparator}$tag.json';

void main() {
  group('FileRaftStore', () {
    test('persists and reloads currentTerm / votedFor', () {
      final path = _tmp('s1');
      FileRaftStore(path).save(5, 'n2');
      final reopened = FileRaftStore(path);
      expect(reopened.currentTerm, 5);
      expect(reopened.votedFor, 'n2');
    });

    test('missing file reads as term 0 / no vote', () {
      final store = FileRaftStore(_tmp('missing'));
      expect(store.currentTerm, 0);
      expect(store.votedFor, isNull);
    });
  });

  group('RaftNode durable state', () {
    test('term and vote survive a restart (no double vote in a term)',
        () async {
      final statePath = _tmp('node');
      final net = SimulatedNetwork();
      final cfg = RaftConfig('n1', {'n2': 'sim', 'n3': 'sim'});

      // A node grants a vote to n2 at term 3, then "crashes".
      var node = RaftNode(cfg, net.transportFor('n1'),
          store: FileRaftStore(statePath));
      final reply = await node.handleRequestVote(RequestVoteArgs(
          term: 3, candidateId: 'n2', lastLogIndex: 0, lastLogTerm: 0));
      expect(reply.voteGranted, isTrue);
      expect(node.currentTerm, 3);
      expect(node.votedFor, 'n2');

      // Restart: a fresh node reloads the persisted term + vote.
      node = RaftNode(cfg, net.transportFor('n1'),
          store: FileRaftStore(statePath));
      expect(node.currentTerm, 3);
      expect(node.votedFor, 'n2');

      // It must NOT grant a second vote to a different candidate in term 3.
      final reply2 = await node.handleRequestVote(RequestVoteArgs(
          term: 3, candidateId: 'n3', lastLogIndex: 0, lastLogTerm: 0));
      expect(reply2.voteGranted, isFalse);
    });
  });
}
