library;

import 'dart:async';
import 'dart:math';

import 'config.dart';
import 'raft_log.dart';
import 'raft_store.dart';
import 'rpc.dart';
import 'transport.dart';

enum RaftRole { follower, candidate, leader }

/// A single Raft node implementing leader election and log replication per the
/// Raft paper (Figure 2). Timeouts are driven explicitly ([onElectionTimeout],
/// [sendHeartbeats]) so the module is deterministically testable on a
/// [SimulatedNetwork]; a production driver wraps them in real timers.
class RaftNode implements RaftHandlers {
  final RaftConfig config;
  final RaftTransport transport;
  final RaftLog log;

  /// Durable `currentTerm` / `votedFor` (persisted before RPC replies).
  final RaftStore _store;

  // --- Volatile state. ---
  RaftRole role = RaftRole.follower;
  String? leaderId;
  int commitIndex = 0;

  /// Highest log index handed to [onCommit] (the state machine).
  int lastApplied = 0;

  /// Invoked once per committed entry, in strictly increasing index order —
  /// the hook the engine wires to `Database.applyReplicated`.
  void Function(RaftEntry entry)? onCommit;

  // --- Leader state (reinitialized on election). ---
  final Map<String, int> _nextIndex = {};
  final Map<String, int> _matchIndex = {};

  /// Set true whenever we hear from a current leader / grant a vote, so a
  /// driver can decide whether to start an election on the next tick.
  bool heardFromLeader = false;

  RaftNode(this.config, this.transport, {RaftLog? log, RaftStore? store})
      : log = log ?? RaftLog(),
        _store = store ?? InMemoryRaftStore();

  String get nodeId => config.nodeId;
  bool get isLeader => role == RaftRole.leader;

  /// Persistent term (durable across restarts).
  int get currentTerm => _store.currentTerm;
  set currentTerm(int t) => _store.save(t, _store.votedFor);

  /// Persistent vote for the current term (durable across restarts).
  String? get votedFor => _store.votedFor;
  set votedFor(String? v) => _store.save(_store.currentTerm, v);

  void _becomeFollower(int term) {
    if (term > currentTerm) {
      _store.save(term, null); // new term ⇒ fresh vote, persisted atomically
    }
    role = RaftRole.follower;
  }

  void _becomeLeader() {
    role = RaftRole.leader;
    leaderId = nodeId;
    for (final p in config.peers.keys) {
      _nextIndex[p] = log.lastIndex + 1;
      _matchIndex[p] = 0;
    }
  }

  // --- Election ------------------------------------------------------------

  /// Called when the election timer fires: start a new election unless we are
  /// already leader. Collects votes from peers and becomes leader on a majority.
  Future<void> onElectionTimeout() async {
    if (role == RaftRole.leader) return;
    role = RaftRole.candidate;
    _store.save(currentTerm + 1, nodeId); // new term + self-vote, atomically
    leaderId = null;
    final electionTerm = currentTerm;
    var votes = 1; // self
    final args = RequestVoteArgs(
      term: electionTerm,
      candidateId: nodeId,
      lastLogIndex: log.lastIndex,
      lastLogTerm: log.lastTerm,
    );
    await Future.wait(config.peers.keys.map((peer) async {
      final reply = await transport.sendRequestVote(peer, args);
      if (reply == null) return;
      if (reply.term > currentTerm) {
        _becomeFollower(reply.term);
        return;
      }
      // Ignore stale replies (we moved on to a new term or role).
      if (role != RaftRole.candidate || currentTerm != electionTerm) return;
      if (reply.voteGranted) {
        votes++;
        if (config.hasMajority(votes)) _becomeLeader();
      }
    }));
  }

  @override
  Future<RequestVoteReply> handleRequestVote(RequestVoteArgs args) async {
    if (args.term > currentTerm) _becomeFollower(args.term);
    if (args.term < currentTerm) {
      return RequestVoteReply(term: currentTerm, voteGranted: false);
    }
    // Grant iff we haven't voted for someone else this term and the candidate's
    // log is at least as up-to-date as ours (Raft §5.4.1).
    final upToDate = args.lastLogTerm > log.lastTerm ||
        (args.lastLogTerm == log.lastTerm && args.lastLogIndex >= log.lastIndex);
    final canVote = votedFor == null || votedFor == args.candidateId;
    if (canVote && upToDate) {
      votedFor = args.candidateId;
      heardFromLeader = true; // a valid candidate resets our election timer
      return RequestVoteReply(term: currentTerm, voteGranted: true);
    }
    return RequestVoteReply(term: currentTerm, voteGranted: false);
  }

  // --- Replication ---------------------------------------------------------

  /// Leader: send AppendEntries (heartbeat when there is nothing new) to every
  /// peer, advancing commitIndex when a majority has replicated the term's log.
  Future<void> sendHeartbeats() async {
    if (role != RaftRole.leader) return;
    final term = currentTerm;
    await Future.wait(config.peers.keys.map((peer) async {
      final next = _nextIndex[peer] ?? (log.lastIndex + 1);
      final prevIndex = next - 1;
      final args = AppendEntriesArgs(
        term: term,
        leaderId: nodeId,
        prevLogIndex: prevIndex,
        prevLogTerm: log.termAt(prevIndex),
        entries: log.entriesAfter(prevIndex),
        leaderCommit: commitIndex,
      );
      final reply = await transport.sendAppendEntries(peer, args);
      if (reply == null) return;
      if (reply.term > currentTerm) {
        _becomeFollower(reply.term);
        return;
      }
      if (role != RaftRole.leader || currentTerm != term) return;
      if (reply.success) {
        _matchIndex[peer] = reply.matchIndex;
        _nextIndex[peer] = reply.matchIndex + 1;
        _advanceCommit(term);
      } else {
        // Log inconsistency: back off and retry on the next heartbeat.
        _nextIndex[peer] = max(1, (next) - 1);
      }
    }));
  }

  /// Advance commitIndex to the highest index replicated on a majority — but
  /// only for an entry from the current [term] (Raft §5.4.2).
  void _advanceCommit(int term) {
    for (var n = log.lastIndex; n > commitIndex; n--) {
      if (log.termAt(n) != term) continue;
      var count = 1; // leader has it
      for (final m in _matchIndex.values) {
        if (m >= n) count++;
      }
      if (config.hasMajority(count)) {
        commitIndex = n;
        break;
      }
    }
    _applyCommitted();
  }

  /// Deliver newly-committed entries to [onCommit] in order, exactly once.
  void _applyCommitted() {
    while (lastApplied < commitIndex) {
      lastApplied++;
      final e = log.at(lastApplied);
      if (e != null) onCommit?.call(e);
    }
  }

  @override
  Future<AppendEntriesReply> handleAppendEntries(AppendEntriesArgs args) async {
    if (args.term < currentTerm) {
      return AppendEntriesReply(
          term: currentTerm, success: false, matchIndex: 0);
    }
    if (args.term > currentTerm) _becomeFollower(args.term);
    // Same-term AppendEntries ⇒ a legitimate leader exists; become/stay follower.
    role = RaftRole.follower;
    leaderId = args.leaderId;
    heardFromLeader = true;

    // Log-matching check: our log must contain prevLogIndex with prevLogTerm.
    if (args.prevLogIndex > 0 &&
        (log.lastIndex < args.prevLogIndex ||
            log.termAt(args.prevLogIndex) != args.prevLogTerm)) {
      return AppendEntriesReply(
          term: currentTerm, success: false, matchIndex: 0);
    }

    // Append new entries, truncating any conflicting suffix.
    for (final e in args.entries) {
      if (log.lastIndex >= e.index && log.termAt(e.index) != e.term) {
        log.truncateAfter(e.index - 1);
      }
      if (log.lastIndex < e.index) log.append(e);
    }

    if (args.leaderCommit > commitIndex) {
      commitIndex = min(args.leaderCommit, log.lastIndex);
      _applyCommitted();
    }
    return AppendEntriesReply(
        term: currentTerm, success: true, matchIndex: log.lastIndex);
  }

  /// Leader entry point: append a client command to the local log so the next
  /// [sendHeartbeats] replicates it. Returns the new entry's index, or null
  /// when this node is not the leader.
  int? clientAppend(List<String> ops) {
    if (role != RaftRole.leader) return null;
    final index = log.lastIndex + 1;
    log.append(RaftEntry(currentTerm, index, ops));
    _matchIndex[nodeId] = index;
    return index;
  }
}
