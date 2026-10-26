library;

import 'dart:async';

import '../database.dart';
import '../oplog.dart';
import 'raft_node.dart';
import 'rpc.dart';

/// Binds a [RaftNode] to a [Database] so a cluster's committed log drives the
/// state machine: the database is a read-only replica (direct client writes are
/// rejected), and every entry Raft **commits** is applied to it in order via
/// `applyReplicated`. Writes enter through [propose] on the leader.
///
/// This keeps the engine's commit path untouched — Raft decides *what* commits;
/// the existing replica-apply path decides *how* it lands — which is the
/// low-risk route to R5 integration (see `doc/raft-lite-plan.md`).
class RaftReplicator {
  final RaftNode node;
  final Database db;

  final List<RaftEntry> _pending = [];
  bool _applying = false;

  RaftReplicator(this.node, this.db) {
    db.markReplica(); // writes flow through Raft, not direct client execute
    node.onCommit = (entry) {
      _pending.add(entry);
      unawaited(_drain());
    };
  }

  bool get isLeader => node.isLeader;

  /// Highest LSN applied to the database.
  int get appliedLsn => db.appliedLsn;

  /// Propose a write through consensus. Returns the assigned log index on the
  /// leader, or null when this node is not the leader (the caller should route
  /// to the current leader). The entry applies once a majority has committed it.
  int? propose(String sql) => node.clientAppend([sql]);

  /// Completes once every committed entry handed over so far has been applied.
  Future<void> drained() async {
    while (_applying || _pending.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> _drain() async {
    if (_applying) return;
    _applying = true;
    try {
      while (_pending.isNotEmpty) {
        final e = _pending.removeAt(0);
        await db.applyReplicated(OpLogRecord(
          e.index,
          DateTime.now().millisecondsSinceEpoch,
          e.ops,
          term: e.term,
        ));
      }
    } finally {
      _applying = false;
    }
  }
}
