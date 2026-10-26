library;

/// One Raft log entry. [index] is the op-log LSN; [term] is the leader term
/// under which it was created; [ops] are the SQL statements to apply.
class RaftEntry {
  final int term;
  final int index;
  final List<String> ops;

  RaftEntry(this.term, this.index, this.ops);

  Map<String, Object?> toJson() => {'term': term, 'index': index, 'ops': ops};

  factory RaftEntry.fromJson(Map<String, Object?> j) => RaftEntry(
        (j['term'] as num).toInt(),
        (j['index'] as num).toInt(),
        (j['ops'] as List).cast<String>(),
      );
}

/// `RequestVote` RPC arguments (Raft Figure 2).
class RequestVoteArgs {
  final int term;
  final String candidateId;
  final int lastLogIndex;
  final int lastLogTerm;

  RequestVoteArgs({
    required this.term,
    required this.candidateId,
    required this.lastLogIndex,
    required this.lastLogTerm,
  });

  Map<String, Object?> toJson() => {
        'rpc': 'request_vote',
        'term': term,
        'candidate_id': candidateId,
        'last_log_index': lastLogIndex,
        'last_log_term': lastLogTerm,
      };

  factory RequestVoteArgs.fromJson(Map<String, Object?> j) => RequestVoteArgs(
        term: (j['term'] as num).toInt(),
        candidateId: j['candidate_id'] as String,
        lastLogIndex: (j['last_log_index'] as num).toInt(),
        lastLogTerm: (j['last_log_term'] as num).toInt(),
      );
}

class RequestVoteReply {
  final int term;
  final bool voteGranted;

  RequestVoteReply({required this.term, required this.voteGranted});

  Map<String, Object?> toJson() =>
      {'term': term, 'vote_granted': voteGranted};

  factory RequestVoteReply.fromJson(Map<String, Object?> j) => RequestVoteReply(
        term: (j['term'] as num).toInt(),
        voteGranted: j['vote_granted'] as bool,
      );
}

/// `AppendEntries` RPC arguments (Raft Figure 2). Empty [entries] is a
/// heartbeat.
class AppendEntriesArgs {
  final int term;
  final String leaderId;
  final int prevLogIndex;
  final int prevLogTerm;
  final List<RaftEntry> entries;
  final int leaderCommit;

  AppendEntriesArgs({
    required this.term,
    required this.leaderId,
    required this.prevLogIndex,
    required this.prevLogTerm,
    required this.entries,
    required this.leaderCommit,
  });

  Map<String, Object?> toJson() => {
        'rpc': 'append_entries',
        'term': term,
        'leader_id': leaderId,
        'prev_log_index': prevLogIndex,
        'prev_log_term': prevLogTerm,
        'entries': [for (final e in entries) e.toJson()],
        'leader_commit': leaderCommit,
      };

  factory AppendEntriesArgs.fromJson(Map<String, Object?> j) =>
      AppendEntriesArgs(
        term: (j['term'] as num).toInt(),
        leaderId: j['leader_id'] as String,
        prevLogIndex: (j['prev_log_index'] as num).toInt(),
        prevLogTerm: (j['prev_log_term'] as num).toInt(),
        entries: [
          for (final e in (j['entries'] as List))
            RaftEntry.fromJson((e as Map).cast<String, Object?>()),
        ],
        leaderCommit: (j['leader_commit'] as num).toInt(),
      );
}

class AppendEntriesReply {
  final int term;
  final bool success;

  /// The highest log index the follower now matches with the leader (used to
  /// advance `matchIndex` without a separate probe).
  final int matchIndex;

  AppendEntriesReply({
    required this.term,
    required this.success,
    required this.matchIndex,
  });

  Map<String, Object?> toJson() =>
      {'term': term, 'success': success, 'match_index': matchIndex};

  factory AppendEntriesReply.fromJson(Map<String, Object?> j) =>
      AppendEntriesReply(
        term: (j['term'] as num).toInt(),
        success: j['success'] as bool,
        matchIndex: (j['match_index'] as num).toInt(),
      );
}
