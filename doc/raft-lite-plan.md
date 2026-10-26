# Raft-lite plan (embedded, no external dependencies)

A living, prioritized plan to replace the HA stack's **single-file epoch +
injected liveness probe + `FailoverController`** (see
[`high-availability-plan.md`](high-availability-plan.md), Phase 4) with a real,
**embedded Raft** consensus module — leader election and majority-committed log
replication — with **no external coordinator** (no etcd/Consul/ZK) and **no new
package dependencies** (pure `dart:io` / `dart:async`).

## Why this is tractable here
The engine already has most of Raft's substrate; Raft-lite is mostly adding the
**consensus/voting** layer on top:

| Raft concept | Already in the engine | Gap to close |
|---|---|---|
| Replicated log | `OpLog` (LSN-ordered, CRC32, crash-safe, streaming) | add a per-entry **term**; add **suffix truncation** for conflict resolution |
| Log apply / state machine | `Database.applyReplicated` + `appliedLsn` | drive it from a **commitIndex** instead of "apply on receipt" |
| Term / fencing | `ClusterEpoch` + `attachFence` (epoch gate) | generalize epoch → **term**; step down on higher term |
| Majority ack | semi-sync `ReplicationServer.awaitAcks(lsn, k, t)` | advance **commitIndex** on **majority matchIndex** |
| Failure detection | `PrimaryProbe` (TCP connect) | replace with **AppendEntries heartbeats** + election timeout |
| Leader = writable | `promoteToPrimary` / `markReplica` | gate writes on **"I am leader of currentTerm"** |
| Client routing | `ClusterRouter` | resolve the primary from the **Raft leader**, not a node scan |

So the op-log becomes Raft's log, `commitIndex` is an LSN, and "promotion" is a
won election. The work is the election + commit-advancement + safety rules.

## How to use this file
- Build strictly in phase order; each phase is independently testable against a
  **simulated network + controllable clock** (see Testing). Do **not** wire the
  real tick loop into live writes until R4 (safety) is green.
- Mirror **Raft paper Figure 2 exactly** — every field, every rule. Deviations
  are where Raft implementations get their consistency bugs.
- Update **Status** per item; move finished items to "Landed".

## Status legend
`TODO` · `WIP` · `LANDED (<commit>)` · `WON'T` (with reason).

## Non-goals
- **Dynamic membership** (add/remove nodes at runtime) — fixed cluster config in
  v1; joint-consensus reconfiguration is a later phase.
- **Multi-Raft / sharding** — one Raft group per database.
- **Log compaction via snapshots transport** — reuse the existing `dbr` /
  `Replica.bootstrap` snapshot seeding; Raft InstallSnapshot RPC is deferred.
- **Byzantine fault tolerance** — crash-stop model only (standard Raft).

---

## Phase R0 — Node identity, cluster config & RPC transport  ·  Status: WIP

**Goal:** a peer-to-peer message layer every later phase rides on.

Tasks:
- [x] **Cluster config.** `RaftConfig(nodeId, peers)` with `members`,
  `clusterSize`, and `majority`/`hasMajority` quorum math
  (`lib/server/raft/config.dart`). LANDED.
- [x] **RPC envelope.** `lib/server/raft/rpc.dart`: `RaftEntry` and the
  `RequestVote` / `AppendEntries` args+replies (Figure 2), all JSON
  round-trippable. LANDED.
- [x] **Simulated transport.** `lib/server/raft/transport.dart`:
  `RaftTransport` / `RaftHandlers` interfaces plus `SimulatedNetwork` — an
  in-memory, one-isolate network with injectable `partition` / `isolate` /
  `heal` and `latency`, so the module is developed and invariant-tested
  deterministically. Tests: `test/raft_transport_test.dart`. LANDED.
- [ ] **TCP transport.** A real `dart:io` implementation of `RaftTransport`
  (reusing the `replication_server.dart` line framing) for cross-host clusters.

---

## Phase R1 — Persistent Raft state & term-aware log  ·  Status: WIP

**Goal:** the durable state Raft safety depends on.

Tasks:
- [x] **Term-aware log.** `RaftLog` (`raft_log.dart`): 1-indexed `(term, index,
  ops)` with `lastIndex`/`lastTerm`/`termAt`/`at`/`entriesAfter`/`append`/
  `truncateAfter`. In-memory in v1; R5 backs it with the on-disk `OpLog`.
- [x] **On-disk term + suffix truncation.** `OpLogRecord.term` (optional,
  backward-compatible) and `OpLog.truncateAbove(maxLsn)` (byte-trims the
  straddling segment, deletes segments above, survives reopen).
  Tests in `test/oplog_test.dart`.
- [x] **Persist `currentTerm`/`votedFor`.** `RaftStore` (`raft_store.dart`)
  with `FileRaftStore` (atomic temp+fsync+rename) and `InMemoryRaftStore`;
  `RaftNode` routes term/vote mutations through it so a restart reloads them
  (no double vote in a term). Tests: `test/raft_store_test.dart`. LANDED.
- [ ] **Generalize the fence.** `currentTerm` subsumes `ClusterEpoch`; keep
  `ClusterEpoch` as the single-node fallback but have Raft own the term.

---

## Phase R2 — Leader election  ·  Status: LANDED

**Goal:** exactly one leader per term, chosen only if its log is up to date.

Tasks:
- [x] **Roles & election.** `RaftNode` follower/candidate/leader;
  `onElectionTimeout` increments the term, self-votes, gathers `RequestVote`
  grants, becomes leader on a majority. Timeouts driven explicitly for
  deterministic tests (a real timer driver is R5).
- [x] **RequestVote.** Grants iff term ≥ ours, not already voted this term, and
  the candidate's `(lastTerm, lastIndex)` is at least as up-to-date (§5.4.1).
- [x] **Heartbeats + step-down.** `sendHeartbeats` suppresses elections; any
  higher term seen ⇒ revert to follower and adopt it (no two leaders).
- Tests: `test/raft_election_test.dart` + the R4 randomized simulation.

**Delivers:** automatic, split-brain-free leader election — the quorum-safe
replacement for `FailoverController` + `ClusterEpoch` fencing.

---

## Phase R3 — Log replication & commit advancement  ·  Status: WIP

**Goal:** entries committed once a majority has them, then applied in order.

Tasks:
- [x] **AppendEntries (replication).** Leader tracks `nextIndex`/`matchIndex`,
  ships `entriesAfter(prev)`, backs off `nextIndex` on a consistency-check
  failure; the follower runs the log-matching check and truncates conflicts
  (`truncateAfter`) before appending.
- [x] **commitIndex.** Advances to the highest index on a **majority** of
  `matchIndex` belonging to the **current term** (§5.4.2); followers adopt
  `leaderCommit`. Tests: `test/raft_election_test.dart` (commit on majority,
  no commit without majority).
- [ ] **Apply loop.** Apply committed-but-unapplied entries via
  `Database.applyReplicated` up to `commitIndex` (R5 wiring).
- [ ] **Leader write path.** Withhold the `COMMIT` ack until the entry is
  committed (majority), reusing `configureSemiSync` backed by commitIndex (R5).

---

## Phase R4 — Safety hardening  ·  Status: WIP

**Goal:** the properties that make Raft correct, explicitly tested.

Tasks:
- [x] **Randomized invariant simulation.** `test/raft_safety_test.dart` runs
  many seeded scenarios (200 random events each: elections, heartbeats, client
  appends, partitions/heals) over a 3-node cluster and asserts after **every
  step**: **election safety** (≤1 leader/term), **log matching** (equal
  `(term, index)` ⇒ identical prefix), and **state-machine safety** (a
  committed index never changes). Converges after `healAll`. LANDED.
- [ ] **Leader completeness (explicit).** A dedicated test that a committed
  entry survives leader changes (currently covered transitively by the
  up-to-date vote check + committed-stability invariant).
- [ ] **Linearizability checker.** A Jepsen-style history check of concurrent
  client ops under faults.
- [ ] **Fenced reads/writes.** A deposed leader rejects client writes
  immediately (R5 wiring, keyed on leadership of `currentTerm`).
- [ ] **Pre-vote (optional).** Avoid term inflation from a partitioned node
  disrupting a healthy leader on rejoin.

---

## Phase R5 — Integration & cutover  ·  Status: TODO

**Goal:** replace the Phase-4 HA glue with the Raft module, behind a flag.

Tasks:
- [ ] **Leadership → writability.** `Database` accepts client writes only while
  the Raft module reports it leader of `currentTerm`; otherwise it is a
  read-only follower (reuse `markReplica` / the write-path gate).
- [ ] **Router.** `ClusterRouter` resolves the primary from the Raft leader and
  redirects on leader change (replace the node-scan heuristic).
- [ ] **Bootstrap/catch-up.** A far-behind follower seeds via
  `Replica.bootstrap` (snapshot) then resumes AppendEntries — no InstallSnapshot
  RPC needed in v1.
- [ ] **Deprecate.** `FailoverController` + `PrimaryProbe` become thin shims or
  are removed; `ClusterEpoch` stays only for the non-Raft single-coordinator
  mode.

---

## Testing strategy (first-class — Raft lives or dies here)
- **Deterministic simulation:** one isolate, an in-memory transport with
  injectable partitions / drops / reordering, and a virtual clock driving all
  timeouts. Every phase has unit tests here before any real sockets.
- **Property/invariant checks:** after every simulated step assert the five
  safety properties (R4) hold across all nodes.
- **Linearizability:** a Jepsen-style history checker — concurrent client ops
  against the cluster under induced faults must linearize.
- **Chaos reuse:** extend `test/ha_chaos_test.dart` (crash / partition /
  rolling-restart) to run against the Raft-backed cluster and assert **no lost
  committed writes** and bounded election time.

## Code map (where this lands)
- `lib/server/raft/` — new: `config.dart`, `transport.dart` (+ simulated),
  `raft_node.dart` (roles, timers, RequestVote/AppendEntries handlers),
  `rpc.dart` (message types).
- `lib/server/oplog.dart` — `OpLogRecord.term`; `OpLog.truncateAbove`.
- `lib/server/database.dart` — leadership-gated write path; commitIndex-backed
  semi-sync; apply from `commitIndex`.
- `lib/server/replication.dart` — `ClusterRouter` leader resolution; retire
  `FailoverController` once R5 lands.

## Risks & mitigations
- **Raft subtlety** (the usual source of consensus bugs) → implement Figure 2
  verbatim; gate correctness on the invariant + linearizability suites, not
  example tests.
- **Logical-log determinism** — AppendEntries replicates **SQL ops**; replay
  must be deterministic across nodes. Audit non-deterministic functions
  (`SYSDATE`, `RANDOM`, sequences) — the **leader must materialize them to
  literals before logging** (the bind-aware capture path already inlines
  values; extend it to volatile scalars).
- **Split-brain during reconnect** → step-down-on-higher-term + durable
  `votedFor` (fsync before replying) are mandatory, not optional.
- **Performance** (fsync per commit + majority round-trip) → batch AppendEntries
  and group-commit; expose `PRAGMA synchronous` as today.

## Milestones / definition of done
1. **MR0:** simulated transport + election in the deterministic harness; one
   leader per term under partitions.
2. **MR1:** majority-committed replication; committed entries apply in order on
   all nodes.
3. **MR2:** the five safety invariants + a linearizability check pass under
   induced faults.
4. **MR3:** Raft-backed cluster passes the chaos suite (crash/partition/rolling
   restart) with **no lost committed writes**; `ClusterRouter` follows leader
   changes; `FailoverController`/`PrimaryProbe` retired.
