# High-availability plan

A living, prioritized plan to take `dart_db_server` from a **single-process,
single-node** engine to a deployment that survives process and host failures:
durable backups and disaster recovery, streaming replication with hot
read-replicas, and promotion/failover.

Today (baseline) the engine has solid **single-node correctness** — ACID
snapshot-isolation transactions, statement atomicity, crash-atomic persistence
(temp-file → fsync → atomic rename), an in-process `AsyncRwLock`, and a
best-effort cross-process advisory `.lock` — but **zero HA features**: no
replication, failover, clustering, standby, or backup/restore. This plan closes
that gap in layers, cheapest-wins-first.

## How to use this file
- Work top-down: each phase unlocks the next. **Phase 0 (backup/DR) ships
  value immediately** and de-risks everything else.
- The keystone is **Phase 1 (the commit/op-log)** — streaming replication and
  point-in-time recovery both depend on it. Do not start Phase 2 before it.
- For each item: implement behind a flag, add tests (unit + a kill-9 /
  promote-under-load acceptance test), and update **Status** as you go.

## Status legend
`TODO` · `WIP` · `LANDED (<commit>)` · `WON'T` (with reason).

## Design principles
- **Backend-agnostic logical log.** Replication and PITR ride a logical
  change log (committed DDL+DML as ordered records), not the physical file
  format, so it works for the JSON, paged, and SQLite-format backends alike.
- **Single-writer per database.** Keep the existing one-writer model; HA adds
  read-replicas and *failover*, not multi-master. Multi-master / distributed
  transactions are explicitly out of scope (see "Non-goals").
- **Safety over liveness.** Prefer "refuse to serve" (fence) over split-brain.
  No automated promotion lands before fencing exists.
- **Reuse, don't rebuild.** Use the sibling **`dbr`** engine
  (`../../back_up_restore/dart-backup-restore`) for backup/restore/retention
  and 3-2-1 off-site replication instead of writing our own.

---

## Phase 0 — Backup, restore & disaster recovery (via `dbr`)  ·  Status: WIP

**Goal:** scheduled, verified, deduplicated backups with retention and off-site
(3-2-1) replication, plus point-in-time *restore of the data files*. No engine
code changes required — this is an operational integration.

`dbr` (pure-Dart, no FFI) already provides content-defined chunking + global
dedup, SHA-256/Merkle integrity, incremental backups, local + S3 backends,
verified/selective restore, GFS retention, integrity scrub, rate-limited 3-2-1
replication, and a REST API with durable job history. See its
[README](../../back_up_restore/dart-backup-restore/README.md).

Tasks:
- [x] **Quiesce-and-snapshot hook.** `Database.checkpointForBackup()` holds the
  write lock, flushes pending state (`_persist`), folds the WAL into the main
  file on the SQLite backend (`checkpointSqlite` + vector sidecar), and returns
  the backup file set (main file, `.vec.json`, `.paged/`). LANDED.
- [ ] **Backup job.** `dbr backup --source <dbdir> --store <repo> --jobs N`
  on a cron (`dbr schedule`), covering the main file, the vector-index
  sidecars, and the `*.paged/` directory as one snapshot.
- [ ] **Off-site replication.** `dbr replicate --source <repo> --target
  s3://bucket/prefix --rate-limit <cap>` for the DR copy (3-2-1).
- [ ] **Retention + scrub.** GFS retention (`--keep-hourly/daily/...`) and a
  weekly `dbr scrub` for deep integrity verification.
- [ ] **Restore runbook.** Document `dbr restore --snapshot <id> --target
  <dir>` → point `dart_db_server --file` at the restored directory. Add an
  acceptance test that backs up a live DB, kills it, restores, and asserts
  row-for-row equality.
- [ ] **Operator docs.** A `doc/operations.md` section: schedule, verify,
  restore, RPO/RTO expectations.

**Delivers:** disaster recovery, snapshot-level point-in-time restore
(RPO = backup interval), and off-site copies — without touching the engine.

> Limitation: snapshot-interval RPO only. Sub-second / transaction-level RPO
> needs the Phase 1 op-log. Phase 0 and Phase 1 PITR are complementary: `dbr`
> gives the base image + off-site copies; the op-log gives the fine-grained
> replay on top.

---

## Phase 1 — Durable commit/op-log (the keystone)  ·  Status: WIP

**Goal:** an append-only, crash-safe **logical change log**. Every committed
transaction appends one framed record — a monotonic `LSN`, a timestamp, and the
ordered list of applied DDL/DML operations — fsync'd before `COMMIT` returns.
This single artifact enables both streaming replication (Phase 2) and
transaction-level point-in-time recovery.

Tasks:
- [x] **Log format & writer.** `lib/server/oplog.dart`: length-prefixed,
  CRC32-checksummed frames (`[u32 len][u32 crc][payload]`, payload = JSON of
  `{lsn, ts, ops}`); append + fsync (`flush`); segment rotation
  (`<db>.oplog/NNNNNN.log`); `readFrom(afterLsn)` replay iterator;
  `truncateBelow(minLsn)` segment GC; and crash-safe **torn-tail recovery** on
  `open()` (scans every segment, trims a partial final frame, recomputes
  `lastLsn`). Fully unit-tested (`test/oplog_test.dart`). LANDED.
- [ ] **Capture point.** Emit records at the commit boundary in
  `database.dart` (the `COMMIT` path and every auto-commit statement), after
  constraints pass but before releasing the write lock, so log order == apply
  order. Capture the *logical* op (normalized SQL or a structured op), not the
  physical page diff.

  *Partially LANDED:* opt-in `Database.enableOpLog()` opens `<path>.oplog/` and
  the executor appends each committed mutation — auto-commit statements as one
  record, an explicit `BEGIN…COMMIT` as a single multi-op record (`ROLLBACK`
  discards the buffer). Capture currently keys off the `execute(sql)` source
  text; **prepared/bind statements are not yet captured** (tracked below).
  Tests: `test/oplog_capture_test.dart`.
- [ ] **Bind-aware capture.** Capture prepared/parameterized statements (expand
  binds to literals, or log a structured op) so the log is complete.
- [ ] **Recovery/replay.** On `Database.open`, if the log is ahead of the last
  persisted snapshot's LSN, replay the tail to recover committed-but-not-yet-
  snapshotted transactions. Reconciles the "no redo log" gap called out in the
  [reliability plan](reliability-gap-closure-plan.md) (F15 family).

  *LANDED (JSON backend):* the snapshot is stamped with `oplog_lsn`;
  `enableOpLog()` replays every record above it under a `_replaying` guard
  (no re-capture, single converging persist), recovering a commit that was
  fsync'd to the log but lost before the snapshot was rewritten.
  Test: `test/oplog_capture_test.dart` → "replay-on-open recovers a
  committed-but-unpersisted transaction". SQLite backend recovers via its own
  WAL, so replay is skipped there.
- [ ] **Checkpoint/truncation.** Persist a full snapshot periodically, stamp it
  with its LSN, and GC log segments fully below the min(snapshot LSN, slowest
  replica LSN).
- [ ] **PITR.** `restore to <timestamp|LSN>` = restore a `dbr` base image, then
  replay the op-log up to the target LSN.
- [ ] **Tunable durability.** `PRAGMA synchronous = OFF|NORMAL|FULL` to trade
  fsync-per-commit for group-commit batching.

**Delivers:** transaction-level recovery, a replication source of truth, and a
durability contract. Idempotent replay (LSN-guarded) is a hard requirement.

---

## Phase 2 — Streaming replication & read replicas  ·  Status: WIP

**Goal:** one primary streams the op-log to N replicas; replicas apply it and
serve **read-only** traffic (hot standby + read scaling).

Tasks:
- [x] **Replica apply loop.** `lib/server/replication.dart` → `Replica`:
  `catchUp(source)` applies every source record with `lsn > appliedLsn` via
  `Database.applyReplicated` (no re-capture), `lagFrom(source)` reports record
  lag, and `follow(...)` polls continuously. The target is marked read-only
  (`Database.markReplica` — client mutations throw), and `appliedLsn` is
  persisted (`applied_lsn` in the snapshot) so a restarted replica resumes.
  Tests: `test/replication_test.dart` (catch-up, read parity, write rejection,
  incremental/idempotent apply, restart resume). v1 pulls from a source `OpLog`
  (in-process or shared-FS). LANDED.
- [ ] **Replication protocol.** A stream endpoint on the server: replica sends
  its last applied `LSN`, primary streams subsequent frames and tails live
  commits. Reuse the existing TCP/line transport with a new message type.
- [ ] **Bootstrap.** New replica seeds from a `dbr` snapshot (or a primary
  base-image stream), records the snapshot LSN, then catches up via the stream.

  *LANDED (v1):* `Replica.bootstrap(primary, replicaPath)` quiesces the primary
  (`checkpointForBackup`), copies its JSON snapshot, opens it as a replica
  seeded at the primary's LSN (`seedAsReplica`), and catches up. Enables a
  replica that joins *after* data exists, and a downstream replica of a
  **promoted** node. Tests: `test/replication_test.dart` (bootstrap seed,
  bootstrapped-follows-promoted). Production bootstrap should seed from `dbr`;
  vector sidecars / paged tables aren't copied yet.
- [ ] **Lag & backpressure.** Expose `replicationLag` (LSN gap + wall-clock);
  bounded buffers; resumable from last LSN after a disconnect.
- [ ] **Semi-sync (optional).** `PRAGMA replication = async|semisync(k)` —
  withhold `COMMIT` ack until `k` replicas confirm, trading latency for a
  stronger RPO.
- [ ] **Protocol surface.** Decide whether replicas are visible to Oracle/MySQL
  wire clients as read-only endpoints (likely yes — reuse existing front-ends).

**Delivers:** hot standby ready for promotion, and read-replica scale-out.

---

## Phase 3 — Health, promotion & manual failover  ·  Status: WIP

**Goal:** detect primary failure and **promote** a replica with operator action
(no auto-magic yet), without split-brain.

Tasks:
- [x] **Manual promote (mechanics).** `Replica.promote()` →
  `Database.promoteToPrimary()`: clears read-only, opens the node's own op-log
  seeded at `appliedLsn` (`OpLog.open(seedLsn:)`) so post-promotion commits keep
  LSNs monotonic. Test: `test/replication_test.dart` → "promote makes a replica
  writable with monotonic LSNs". *v1 assumes a single coordinator;* cross-node
  fencing is still required before this is safe to automate (below).
- [ ] **Heartbeat & health.** Primary↔replica heartbeats; `GET /health`
  exposing role, `appliedLsn`, lag, and uptime.
- [ ] **Fencing.** An epoch/term token bumped on every promotion; the old
  primary refuses writes once it sees a higher epoch (STONITH-lite). This gate
  **must** land before any automation.
- [ ] **Pick-most-caught-up.** On promote, select the replica with the highest
  `appliedLsn`.
- [ ] **Connection redirect.** A thin front-door (VIP or `dbr`-style router)
  that routes writes→primary, reads→replicas, and surfaces the current primary
  so clients/ORMs reconnect after promotion.

**Delivers:** operator-driven failover with a bounded, documented RTO and no
split-brain.

---

## Phase 4 — Automated failover & coordination  ·  Status: TODO

**Goal:** automatic promotion on primary loss with quorum safety.

Tasks:
- [ ] **Coordinator.** Either integrate an external arbiter (etcd/Consul/ZK) or
  implement a minimal **Raft-lite** for leader election over the small cluster
  (3 or 5 nodes). Start with the external arbiter to avoid building consensus.
- [ ] **Quorum-gated promotion.** Promote only with majority agreement +
  successful fence of the old primary; refuse on a minority partition.
- [ ] **Automatic client re-routing.** Router subscribes to coordinator state
  and fails reads/writes over within the heartbeat window.
- [ ] **Chaos/UAT.** Kill-primary-under-load, network-partition, and
  rolling-restart acceptance tests asserting no lost acked writes and bounded
  RTO.

**Delivers:** unattended HA with a quorum-safe failover path.

---

## Non-goals (explicit scope cuts)
- **Multi-master / active-active writes** and **distributed/2-phase-commit
  transactions.** The model stays single-writer-per-database.
- **Synchronous geo-replication** with zero RPO across regions (semi-sync is
  the strongest guarantee offered).
- **Per-page encryption** of the log/backups (tracked separately; `dbr`
  deprioritizes encryption today).

## Engine code map (where this lands)
- Commit boundary / write lock: `lib/server/database.dart` → `COMMIT` path and
  auto-commit statement dispatch; `AsyncRwLock` in `lib/server/concurrency.dart`.
- Persistence / recovery: `database.dart` → `_persist*` and `Database.open`.
- New: `lib/server/oplog.dart` (log format, writer, replay), replica apply loop,
  replication stream message type in the TCP server
  (`lib/server/server.dart`).
- Backup/DR: external `dbr` CLI + REST (`../../back_up_restore/dart-backup-restore`).

## Risks & mitigations
- **Split-brain** → fencing/epoch gate lands *before* any automated promotion
  (Phase 3 before Phase 4).
- **Log/replica divergence** → LSN-guarded idempotent apply; CRC per frame;
  `dbr scrub`-style deep verify of base images; a replica consistency check
  against the primary.
- **fsync cost per commit** → group commit + `PRAGMA synchronous` tuning.
- **Unbounded log growth** → checkpoint + segment GC below the slowest replica.
- **Backend coverage** → logical log is backend-agnostic; validate replay on
  JSON, paged, and SQLite-format backends in CI.

## Milestones / definition of done
1. **M0 (Phase 0):** nightly `dbr` backup + S3 DR copy + restore acceptance
   test green. *Disaster recovery exists.*
2. **M1 (Phase 1):** op-log + crash replay; transaction-level PITR restore test
   green. *No acked commit is lost on process crash.*
3. **M2 (Phase 2):** a read-replica stays within a bounded lag under load and
   serves reads. *Hot standby exists.*
4. **M3 (Phase 3):** manual `PROMOTE` with fencing; documented RTO; no
   split-brain under a kill-primary test. *Operator failover exists.*
5. **M4 (Phase 4):** automated quorum failover; chaos suite green. *Unattended
   HA exists.*
