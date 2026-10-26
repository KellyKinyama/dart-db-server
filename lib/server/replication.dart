library;

import 'dart:async';

import 'database.dart';
import 'oplog.dart';

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

  /// The highest LSN this replica has durably applied.
  int get appliedLsn => target.appliedLsn;

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
