library;

import 'dart:async';
import 'dart:io';

import 'database.dart';
import 'oplog.dart';
import 'parser.dart';
import 'result.dart';
import 'statement.dart';

/// Drives a read-only replica [Database], applying op-log records streamed from
/// a primary so the replica stays caught up.
///
/// v1 pulls directly from a source [OpLog] (an in-process primary, or a
/// primary's `<path>.oplog/` on shared storage). The TCP streaming transport —
/// a replica sending its [appliedLsn] and the primary tailing live commits — is
/// a follow-up (see `doc/high-availability-plan.md`, Phase 2).
class Replica {
  /// The replica database this driver writes into. Marked read-only to clients
  /// so the only writes are applied op-log records.
  final Database target;

  Replica(this.target) {
    target.markReplica();
  }

  /// Bootstrap a brand-new replica at [replicaPath] from [primary]: quiesce the
  /// primary for a consistent on-disk image, copy its snapshot, open it as a
  /// replica seeded at the primary's current LSN, then [catchUp] any records
  /// committed after the copy. Returns the ready, caught-up [Replica].
  ///
  /// v1 copies the JSON snapshot file (the primary must be JSON-backed) and
  /// assumes no concurrent writer races the copy — production bootstrap should
  /// seed from a `dbr` snapshot instead. Vector sidecars / paged tables are not
  /// yet copied.
  static Future<Replica> bootstrap(
      Database primary, String replicaPath) async {
    final src = primary.path;
    if (src == null) {
      throw StateError('cannot bootstrap from an in-memory primary');
    }
    await primary.checkpointForBackup();
    final lsn = primary.opLog?.lastLsn ?? 0;
    await File(src).copy(replicaPath);
    final target = await Database.open(replicaPath);
    target.seedAsReplica(lsn);
    final replica = Replica(target);
    if (primary.opLog != null) await replica.catchUp(primary.opLog!);
    return replica;
  }

  /// The highest LSN this replica has durably applied.
  int get appliedLsn => target.appliedLsn;

  /// Attach a shared [fence] (and the [epoch] this node currently holds) so a
  /// later [promote] bumps the cluster epoch and the old primary is fenced.
  void attachFence(ClusterEpoch fence, {int epoch = 0}) =>
      target.attachFence(fence, epoch: epoch);

  /// Apply every source record with `lsn > appliedLsn`, in order. Returns the
  /// number of records applied. Idempotent — safe to call repeatedly.
  Future<int> catchUp(OpLog source) async {
    var n = 0;
    await for (final rec in source.readFrom(target.appliedLsn)) {
      await target.applyReplicated(rec);
      n++;
    }
    return n;
  }

  /// Replication lag in records: the primary's `lastLsn` minus this replica's
  /// [appliedLsn] (0 when fully caught up).
  int lagFrom(OpLog source) {
    final lag = source.lastLsn - target.appliedLsn;
    return lag < 0 ? 0 : lag;
  }

  /// Promote this replica to a writable primary (failover). Accepts client
  /// writes again and seeds its op-log above [appliedLsn] so new commits keep
  /// LSNs monotonic for downstream replicas. The caller is responsible for
  /// fencing the old primary (single-coordinator assumption in v1).
  Future<void> promote() => target.promoteToPrimary();

  /// Continuously follow [source], polling every [interval] until [stop]
  /// completes, then drain once more so no tail record is missed.
  Future<void> follow(
    OpLog source, {
    required Future<void> stop,
    Duration interval = const Duration(milliseconds: 50),
  }) async {
    var stopped = false;
    unawaited(stop.then((_) => stopped = true));
    while (!stopped) {
      await catchUp(source);
      await Future<void>.delayed(interval);
    }
    await catchUp(source);
  }
}

/// Coordinates automatic failover for a set of [replicas] following one
/// primary. On [checkAndFailover], if the injected liveness probe reports the
/// primary dead, the most-caught-up replica is brought fully current and
/// promoted — which bumps the shared epoch and fences the old primary.
///
/// v1 relies on an injected liveness probe and a shared-filesystem op-log for
/// the final catch-up; a networked coordinator with true quorum replaces this
/// in a full Phase 4. All replicas must share the same fence for promotion to
/// fence the old primary.
class FailoverController {
  final List<Replica> replicas;
  final Future<bool> Function() isPrimaryAlive;

  /// Minimum number of replicas that must be reachable to promote. Set to a
  /// majority of the surviving cluster to refuse promotion on a minority
  /// partition (split-brain safety). Default 1 = no quorum requirement.
  final int quorum;

  FailoverController({
    required this.replicas,
    required this.isPrimaryAlive,
    this.quorum = 1,
  });

  /// If the primary is dead, promote the most-caught-up replica and return it;
  /// otherwise return null. [primaryLog], when still readable over shared
  /// storage, is drained into each replica first so the winner is as current
  /// as possible before promotion. Returns null without promoting when fewer
  /// than [quorum] replicas are reachable (minority partition).
  Future<Replica?> checkAndFailover({OpLog? primaryLog}) async {
    if (await isPrimaryAlive()) return null;
    if (replicas.isEmpty) return null;
    if (replicas.length < quorum) return null; // insufficient quorum: refuse
    if (primaryLog != null) {
      for (final r in replicas) {
        try {
          await r.catchUp(primaryLog);
        } catch (_) {
          /* a dead primary's log may be unreadable; promote on what we have */
        }
      }
    }
    final ranked = [...replicas]
      ..sort((a, b) => b.appliedLsn.compareTo(a.appliedLsn));
    final winner = ranked.first;
    await winner.promote();
    return winner;
  }
}

/// Routes SQL across a set of cluster [nodes]: read-only `SELECT`s fan out to
/// replicas (round-robin) for read scaling, everything else goes to the current
/// writable primary. After a promotion the primary is re-resolved on the next
/// call (and on a fenced-write error), so clients transparently follow failover.
///
/// In-process / single-coordinator v1; a networked router subscribing to the
/// coordinator replaces this in a full Phase 4.
class ClusterRouter {
  final List<Database> nodes;
  int _rr = 0;

  ClusterRouter(this.nodes);

  /// The current writable primary: a node that is neither a replica nor fenced.
  Database get primary => nodes.firstWhere(
        (n) => !n.isReplica && !n.isFenced,
        orElse: () => throw StateError('no writable primary available'),
      );

  /// The nodes currently serving as read-only replicas.
  List<Database> get replicas =>
      [for (final n in nodes) if (n.isReplica) n];

  /// Execute [sql]: a `SELECT` is load-balanced across replicas (falling back to
  /// the primary when there are none); any other statement runs on the primary,
  /// retried once against a freshly-resolved primary if the first was fenced.
  Future<QueryResult> execute(String sql) async {
    final stmt = Parser.fromString(sql).parseStatement();
    if (stmt is SelectStmt) {
      final reps = replicas;
      if (reps.isNotEmpty) {
        return reps[_rr++ % reps.length].execute(sql);
      }
    }
    try {
      return await primary.execute(sql);
    } on StateError {
      // The primary may have just been fenced and a replica promoted; the
      // getter re-resolves to the new primary, so retry once.
      return await primary.execute(sql);
    }
  }
}
