# Plan: reverse-engineering the Oracle Database server wire protocol

> **Status:** design plan / roadmap. This document describes how to add an
> **Oracle-compatible server front-end** so unmodified Oracle clients
> (node-oracledb thin mode, python-oracledb thin, JDBC thin, and the
> sibling pure-Dart `oracledb` driver) can connect to `dart_db_server` and
> run SQL — the same way `mysql_wire.dart` already lets MySQL clients
> connect. It mirrors the proven `mysql_wire.dart` approach: a protocol
> front-end that translates the wire format to/from the existing
> `Database.execute()` core.

## Why this is tractable (we are not starting from zero)

The hardest part of reverse-engineering a closed protocol — figuring out
the byte layout — is **already solved** in the sibling workspace
`../dart-oracledb`, a mature pure-Dart Oracle *client* that speaks the
thin-mode **TNS/TTC** protocol. A client is a complete, executable
specification of the protocol: every packet it **encodes** is a request
the server must **decode**, and every packet it **decodes** is a response
the server must **encode**. Reverse-engineering the server therefore
reduces to **inverting** the client's existing encode/decode logic.

Primary reference artifacts (all in `../dart-oracledb/lib/src/`):

| Layer | Client file(s) to invert | What the server must do |
| ----- | ------------------------ | ----------------------- |
| TNS transport framing | `transport/packet.dart` | Parse CONNECT, reply ACCEPT/REDIRECT/REFUSE, frame DATA packets, handle MARKER/RESEND |
| TTC packet envelope | `protocol/ttc_packet.dart` | Decode inbound function codes; encode replies |
| Capability negotiation | `protocol/capabilities.dart`, `protocol/protocol.dart` | Decode client caps, send compatible server caps |
| Data-type negotiation | `protocol/messages/` (DataTypes) | Accept the client's type table, reply with the server's |
| Authentication | `crypto/auth.dart`, `crypto/session_key.dart`, `crypto/verifier.dart`, `protocol/messages/auth_message.dart`, `protocol/messages/fast_auth_message.dart` | Act as the **verifier side** of O5LOGON/O8LOGON and FAST_AUTH |
| Execute / fetch | `protocol/messages/execute_message.dart`, `protocol/bind_parser.dart`, `protocol/result_set_cursor.dart` | Decode OALL8 execute, bind values; encode describe + row data |
| Value codecs | `protocol/data_types.dart`, `oracle_*.dart`, `protocol/oson.dart` | Encode NUMBER, DATE/TS, INTERVAL, ROWID, LOB locators, JSON (OSON), VECTOR |
| Error reporting | `errors.dart` | Emit `ORA-NNNNN` errors in TTC error (OER) format |

A second independent reference is Oracle's official
[`node-oracledb`](https://github.com/oracle/node-oracledb) thin driver
(`lib/thin/protocol/`), which `dart-oracledb` itself was ported from and
which the code comments cite by constant name (e.g. `TNS_LOB_OP_*`,
`TNS_UDS_FLAGS_*`). Cross-checking both keeps the server honest.

## Legality / scope note

This is a **clean-room, interoperability** effort against a documented,
already-open-source *client* implementation — not decompilation of the
Oracle server. The goal is protocol *compatibility* for a
from-scratch engine, exactly like the existing MySQL front-end. We
implement only what real clients send; we do not redistribute any Oracle
binaries, and this project is not affiliated with Oracle.

## Target architecture

Add `lib/server/oracle_wire.dart` as a sibling of `mysql_wire.dart`,
wired into `server.dart` by port or by sniffing the first inbound bytes
(a TNS CONNECT packet starts with a 2-byte big-endian length followed by
packet type `0x01`, which is unambiguous against the MySQL handshake and
the JSON line protocol).

```
Oracle client ──TCP──▶ oracle_wire.dart
                         │  TNS framing  (invert transport/packet.dart)
                         │  TTC envelope (invert ttc_packet.dart)
                         │  cap + type negotiation
                         │  auth (verifier side)
                         ▼
                       translate TTC execute/fetch  ──▶  Database.execute()
                         ▲                                     │
                         │  encode describe + rows + ORA errors│
                         └─────────────────────────────────────┘
```

Reuse the existing low-level `ReadBuffer`/`WriteBuffer` byte helpers from
`../dart-oracledb/lib/src/protocol/buffer.dart` (vendor a copy, or extract
a shared `oracle_codec` mini-package) so encode/decode stay bit-identical
to the client.

## Methodology — capture, invert, verify

1. **Capture ground truth.** Run the existing `dart-oracledb` integration
   suite against real Oracle 23ai (Docker Desktop, `localhost:1521`) and
   21c (Colima, `localhost:1522`) per `../dart-oracledb/AGENTS.md`, with
   the driver's packet logging enabled, to record real client↔server byte
   exchanges for every message type. These become golden transcripts.
2. **Invert per layer.** For each layer in the table above, write the
   server-side decoder by reading the client's encoder, and the
   server-side encoder by reading the client's decoder. Keep the same
   constant names so the two files diff cleanly.
3. **Verify by loopback.** The ultimate test: point the real
   `dart-oracledb` client (and node-oracledb) at `dart_db_server` and
   assert the same `QueryResult` round-trips as the JSON protocol. A
   byte-level conformance test replays each golden transcript and asserts
   the server produces identical response bytes.

## Phased roadmap

**Phase 0 — Spike & transcripts. ✅ (initial)** Stand up a raw TCP listener
that accepts a TNS CONNECT and replies with an ACCEPT; confirm a client
progresses past connect. Record golden transcripts for every subsequent
phase. *Exit:* client reaches cap negotiation.

> **Landed:** `lib/server/oracle_codec.dart` (TNS/TTC byte buffers),
> `lib/server/oracle_tns.dart` (TNS framing: CONNECT parse, version
> negotiation, ACCEPT/DATA build), and `lib/server/oracle_wire.dart`
> (`OracleServer` + per-connection state machine that answers CONNECT with
> ACCEPT and frames DATA/MARKER). Enable with
> `dart run bin/dart_db_server.dart --oracle-port 1521`. Covered by
> `test/oracle_wire_test.dart`. **Next:** record golden transcripts from a
> real client and implement the TTC PROTOCOL + DATA-TYPES exchange.

**Phase 1 — TNS transport + negotiation.** Full CONNECT/ACCEPT (incl.
large-SDU/`tnsVersionMinLargeSdu`, data-flags, end-of-request flags),
MARKER/RESEND/ABORT handling, DATA packet framing, and the TTC
PROTOCOL + DATA-TYPES negotiation handshake. *Exit:* client and server
agree on version, charset (AL32UTF8 / 873), and the type table.

**Phase 2 — Authentication (verifier side).** This is the crypto core.
Implement the server half of:
- **AUTH_PHASE_ONE** — return `AUTH_VFR_DATA` (salt), verifier type
  (`0x939` O5LOGON / `0xB92` O8LOGON PBKDF2), iteration count, and the
  server nonce.
- **AUTH_PHASE_TWO** — derive the session key the same way
  `crypto/session_key.dart` does, validate the client's password proof,
  and return the server proof.
- **FAST_AUTH** (23ai single-round-trip) per `fast_auth_message.dart`.

  Store users as Oracle-style verifiers (not plaintext) so the proof math
  matches. Start with one hard-coded test user, then a `CREATE USER`
  surface. *Exit:* `oracledb` client authenticates end-to-end.

**Phase 3 — Execute & fetch (the money path).** Decode the OALL8
`ttcFuncExecute` message (SQL text, bind metadata, bind values, fetch
array size, options) via the inverse of `execute_message.dart` +
`bind_parser.dart`. Hand the SQL + binds to `Database.execute()`. Encode
the describe (column metadata) and row data stream, honoring the
prefetch/fetch-array protocol and `ttcFuncFetch` continuations from
`result_set_cursor.dart`. Map engine errors to `ORA-NNNNN` OER packets via
`errors.dart`. *Exit:* `SELECT`/`INSERT`/`UPDATE`/`DELETE` with binds work
from a stock client.

**Phase 4 — Transactions & statement lifecycle.** `ttcFuncCommit` /
`ttcFuncRollback`, cursor close (`ttcFuncCloseCursors`), re-execute of
cached cursors (`ttcFuncReExecute` / `ttcFuncReExecuteAndFetch`),
`ttcPing`, and graceful `ttcClose`. Map to the engine's existing
`BEGIN/COMMIT/ROLLBACK` and prepared-statement cache.

**Phase 5 — Rich type codecs.** Incrementally add server-side encoders by
inverting the client decoders, each behind a conformance test:
- NUMBER (Oracle's base-100 mantissa) and the integer/float fast paths.
- DATE / TIMESTAMP / TIMESTAMP WITH (LOCAL) TIME ZONE
  (`oracle_timestamp_tz.dart`, incl. region-name decode).
- INTERVAL DAY→SECOND / YEAR→MONTH (`oracle_interval.dart`).
- ROWID / UROWID.
- LOB locators + the `ttcLobOp` streaming ops (`lob_op_message.dart`,
  `lob_locator.dart`): length, read, write, trim, chunk-size, temp-LOB
  create/free.
- Native JSON / OSON (`oson.dart`) and VECTOR (`oracle_vector.dart`,
  dense + sparse) for 23ai parity.

**Phase 6 — TLS & robustness.** Native-network-encryption / TLS front
(mirror `transport/tls.dart`), SDU renegotiation, attention/break
handling, and fuzz/malformed-packet hardening (reuse the
`oraMalformedPacket` fail-loud posture from the client).

## Deliverables & tests

- `lib/server/oracle_wire.dart` — the front-end (parallels `mysql_wire.dart`).
- `lib/server/oracle_codec/` — vendored/extracted buffer + constants shared
  with the byte layout in `../dart-oracledb`.
- `test/oracle_wire_test.dart` — **golden-transcript conformance**: replay
  captured client bytes, assert exact server response bytes per phase.
- `test/oracle_interop_test.dart` — **live loopback**: drive
  `dart_db_server` with the real `oracledb` Dart client and assert parity
  with the JSON protocol for each SQL feature.

## Known risks / unknowns to resolve during Phase 0–2

- **Auth crypto exactness** — the proof/session-key derivation must match
  byte-for-byte; `crypto/*.dart` is the reference, but the *verifier*
  (server) side is only implied by it and needs careful inversion plus a
  real-client check.
- **Version drift** — 21c (classical two-phase auth) vs 23ai (FAST_AUTH)
  negotiate differently; both must be supported, matching the client's
  dual-path handling.
- **Describe metadata completeness** — clients validate column metadata
  strictly; the UDS/charset/precision flags in `constants.dart` must be
  emitted correctly or fetch decoding fails loud on the client.
- **Undocumented corners** — any message the capture reveals but the
  client doesn't exercise will need live probing against a real server.
