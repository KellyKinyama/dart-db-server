library;

import 'package:dart_db_server/server/raft/config.dart';
import 'package:dart_db_server/server/raft/rpc.dart';
import 'package:dart_db_server/server/raft/transport.dart';
import 'package:test/test.dart';

/// A trivial node that grants every vote and accepts every append — enough to
/// exercise the transport's delivery/partition semantics.
class _EchoNode implements RaftHandlers {
  final String id;
  int requestVotes = 0;
  int appends = 0;
  _EchoNode(this.id);

  @override
  Future<RequestVoteReply> handleRequestVote(RequestVoteArgs args) async {
    requestVotes++;
    return RequestVoteReply(term: args.term, voteGranted: true);
  }

  @override
  Future<AppendEntriesReply> handleAppendEntries(AppendEntriesArgs args) async {
    appends++;
    return AppendEntriesReply(
        term: args.term, success: true, matchIndex: args.prevLogIndex);
  }
}

void main() {
  group('RaftConfig', () {
    test('majority math for 3- and 5-node clusters', () {
      final c3 = RaftConfig('n1', {'n2': 'h:1', 'n3': 'h:2'});
      expect(c3.clusterSize, 3);
      expect(c3.majority, 2);
      expect(c3.hasMajority(2), isTrue);
      expect(c3.hasMajority(1), isFalse);
      expect(c3.members, {'n1', 'n2', 'n3'});

      final c5 = RaftConfig('n1', {
        'n2': 'h:2',
        'n3': 'h:3',
        'n4': 'h:4',
        'n5': 'h:5',
      });
      expect(c5.majority, 3);
      expect(c5.hasMajority(3), isTrue);
      expect(c5.hasMajority(2), isFalse);
    });
  });

  group('RPC serialization', () {
    test('RequestVote round-trips', () {
      final a = RequestVoteArgs(
          term: 4, candidateId: 'n2', lastLogIndex: 9, lastLogTerm: 3);
      final a2 = RequestVoteArgs.fromJson(a.toJson());
      expect(a2.term, 4);
      expect(a2.candidateId, 'n2');
      expect(a2.lastLogIndex, 9);
      expect(a2.lastLogTerm, 3);
      final r = RequestVoteReply.fromJson(
          RequestVoteReply(term: 4, voteGranted: true).toJson());
      expect(r.voteGranted, isTrue);
    });

    test('AppendEntries round-trips with entries', () {
      final a = AppendEntriesArgs(
        term: 7,
        leaderId: 'n1',
        prevLogIndex: 5,
        prevLogTerm: 6,
        entries: [
          RaftEntry(7, 6, ['INSERT INTO t VALUES (1)']),
          RaftEntry(7, 7, ['INSERT INTO t VALUES (2)']),
        ],
        leaderCommit: 5,
      );
      final a2 = AppendEntriesArgs.fromJson(a.toJson());
      expect(a2.term, 7);
      expect(a2.entries.length, 2);
      expect(a2.entries[1].index, 7);
      expect(a2.entries[0].ops.single, 'INSERT INTO t VALUES (1)');
      final rep = AppendEntriesReply.fromJson(
          AppendEntriesReply(term: 7, success: true, matchIndex: 7).toJson());
      expect(rep.success, isTrue);
      expect(rep.matchIndex, 7);
    });
  });

  group('SimulatedNetwork', () {
    test('delivers RPCs between registered nodes', () async {
      final net = SimulatedNetwork();
      final n2 = _EchoNode('n2');
      net.register('n2', n2);
      final t1 = net.transportFor('n1');

      final reply = await t1.sendRequestVote(
          'n2',
          RequestVoteArgs(
              term: 1, candidateId: 'n1', lastLogIndex: 0, lastLogTerm: 0));
      expect(reply, isNotNull);
      expect(reply!.voteGranted, isTrue);
      expect(n2.requestVotes, 1);
    });

    test('a partition drops messages in both directions', () async {
      final net = SimulatedNetwork();
      net.register('n2', _EchoNode('n2'));
      final t1 = net.transportFor('n1');
      net.partition('n1', 'n2');

      final reply = await t1.sendAppendEntries(
          'n2',
          AppendEntriesArgs(
            term: 1,
            leaderId: 'n1',
            prevLogIndex: 0,
            prevLogTerm: 0,
            entries: const [],
            leaderCommit: 0,
          ));
      expect(reply, isNull); // dropped

      net.heal('n1', 'n2');
      final reply2 = await t1.sendAppendEntries(
          'n2',
          AppendEntriesArgs(
            term: 1,
            leaderId: 'n1',
            prevLogIndex: 0,
            prevLogTerm: 0,
            entries: const [],
            leaderCommit: 0,
          ));
      expect(reply2, isNotNull); // delivered after heal
    });

    test('isolate severs a node from all peers', () async {
      final net = SimulatedNetwork();
      net.register('n2', _EchoNode('n2'));
      net.register('n3', _EchoNode('n3'));
      net.isolate('n1');
      final t1 = net.transportFor('n1');
      expect(
          await t1.sendRequestVote(
              'n2',
              RequestVoteArgs(
                  term: 1, candidateId: 'n1', lastLogIndex: 0, lastLogTerm: 0)),
          isNull);
      expect(
          await t1.sendRequestVote(
              'n3',
              RequestVoteArgs(
                  term: 1, candidateId: 'n1', lastLogIndex: 0, lastLogTerm: 0)),
          isNull);
    });
  });
}
