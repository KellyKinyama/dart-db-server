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

## Phase R1 — Persistent Raft state & term-aware log  ·  Status: TODO

**Goal:** the durable state Raft safety depends on.

Tasks:
- [ ] **Per-entry term.** Add an optional `term` to `OpLogRecord`
  (backward-compatible; absent ⇒ term 0). Log identity becomes `(term, lsn)`.
- [ ] **Suffix truncation.** `OpLog.truncateAbove(lsn)` to delete conflicting
  tail entries a new leader overwrites (complements the existing prefix
  `truncateBelow`). Must be crash-safe (rewrite/trim the active segment).
- [ ] **Durable Raft vars.** Persist `currentTerm` and `votedFor` (fsync before
  responding to any RPC that depends on them) in `<db>.raft/state.json`.
- [ ] **Generalize the fence.** `currentTerm` subsumes `ClusterEpoch`; keep
  `ClusterEpoch` as the single-node fallback but have Raft own the term.

---

## Phase R2 — Leader election  ·  Status: TODO

**Goal:** exactly one leader per term, chosen only if its log is up to date.

Tasks:
- [ ] **Roles & timers.** Follower / Candidate / Leader state; a **randomized**
  election timeout and a leader heartbeat interval (from an injectable clock).
- [ ] **RequestVote.** On timeout: increment `currentTerm`, vote for self,
  send `RequestVote` to peers. Grant a vote iff the candidate's term ≥ ours,
  we haven't voted this term, and the candidate's log is **at least as
  up-to-date** (compare `(lastTerm, lastLsn)` — the existing `lastLsn` plus the
  new per-entry term). Become leader on a **majority**.
- [ ] **Heartbeats.** The leader sends empty `AppendEntries` each interval to
  suppress elections; a follower that hears from the current-term leader resets
  its timer.
- [ ] **Step-down.** Any RPC/response carrying a higher term ⇒ revert to
  follower and adopt that term (prevents two leaders).

**Delivers:** automatic, split-brain-free leader election — the quorum-safe
replacement for `FailoverController` + `ClusterEpoch` fencing.

---

## Phase R3 — Log replication & commit advancement  ·  Status: TODO

**Goal:** entries committed once a majority has them, then applied in order.

Tasks:
- [ ] **AppendEntries (replication).** Leader tracks `nextIndex[peer]` /
  `matchIndex[peer]`; sends op-log entries from `nextIndex`; on the consistency
  check failing (prev `(term, lsn)` mismatch), decrement `nextIndex` and retry;
  the follower truncates conflicts (`truncateAbove`) and appends.
- [ ] **commitIndex.** Advance to the highest LSN replicated on a **majority**
  of `matchIndex` **and** belonging to `currentTerm` (the Raft "don't commit
  prior-term entries by count" rule). This generalizes semi-sync `awaitAcks`
  from "k acks" to "majority".
- [ ] **Apply loop.** Apply committed-but-unapplied entries via
  `applyReplicated` up to `commitIndex`; `appliedLsn ≤ commitIndex` always.
- [ ] **Leader write path.** A client write on the leader appends to its op-log
  at `currentTerm`, replicates, and the `COMMIT` ack is withheld until the
  entry is **committed** (majority) — reusing the `configureSemiSync` hook,
  now backed by the Raft commitIndex instead of a fixed k.

**Delivers:** linearizable, majority-durable writes with automatic failover.

---

## Phase R4 — Safety hardening  ·  Status: TODO

**Goal:** the properties that make Raft correct, explicitly tested.

Tasks:
- [ ] **Election safety** — at most one leader per term (tested under
  concurrent elections + partitions).
- [ ] **Leader completeness** — a committed entry is present in every future
  leader's log (the up-to-date vote check guarantees this; test it).
- [ ] **Log matching** — identical `(term, lsn)` prefixes across nodes.
- [ ] **State-machine safety** — no node applies a different op at a given LSN.
- [ ] **Fenced reads/writes** — a deposed leader (lower term) rejects client
  writes immediately (reuse the existing write-path fence check, keyed on
  `currentTerm`/leadership rather than `ClusterEpoch`).

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
