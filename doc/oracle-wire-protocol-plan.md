# Plan: reverse-engineering the Oracle Database server wire protocol

> **Status:** design plan / roadmap. This document describes how to add an
> **Oracle-compatible server front-end** so unmodified Oracle clients
> (node-oracledb thin mode, python-oracledb thin, JDBC thin, and the
> sibling pure-Dart `oracledb` driver) can connect to `dart_db_server` and
> run SQL — the same way `mysql_wire.dart` already lets MySQL clients
> connect. It mirrors the proven `mysql_wire.dart` approach: a protocol
> front-end that translates the wire format to/from the existing
> `Database.execute()` core.

## Progress at a glance

| Phase | Status | What works |
| ----- | ------ | ---------- |
| 0 — TNS transport | ✅ | CONNECT parse, version negotiation, ACCEPT, DATA/MARKER framing |
| 1 — TTC negotiation | ✅ | PROTOCOL + DATA-TYPES exchange (charset, caps, field version 24) |
| 2 — Authentication | ✅ (SHA512/O5LOGON) | Verifier side: AUTH_PHASE_ONE/TWO, no plaintext storage; PBKDF2/12c + FAST_AUTH pending |
| 3 — Execute & fetch | ✅ | Decode OALL8, run via the engine, reply DML status / query rows; **positional + named bind variables**; **large results split across packets** |
| 4 — Transactions & lifecycle | ✅ | COMMIT/ROLLBACK drive the engine; PING; statement-cache cursor re-execute; close-cursors piggyback; logoff via socket close; **per-session isolation** (serializable) |
| 5 — Rich type codecs | ◻ (NUMBER, RAW, DATE) | Numeric → NUMBER, byte buffers → RAW, DATE/TIMESTAMP binds → ISO text; INTERVAL/LOB/JSON/VECTOR pending |
| 6 — TLS & robustness | ⬜ | native-net-encryption/TLS, SDU renegotiation, fuzz hardening |

A client can connect from TCP all the way through a real SQL `SELECT`.
Delivered modules live in `lib/server/oracle_*.dart`, enabled with
`dart run bin/dart_db_server.dart --oracle-port 1521 --oracle-user user/pass`,
and covered by the `test/oracle_*_test.dart` suites (31 tests, including live
socket round-trips). See the per-phase **Landed** notes below for detail.

> **✅ Validated against the real `oracledb` client.** The actual pure-Dart
> thin client connects to the server (no Docker / real Oracle needed, since the
> server *is* the database): it negotiates, authenticates via O5LOGON, runs its
> connect-time charset probe, and round-trips `CREATE` / `INSERT` / `SELECT`
> with native `int` / `double` / `String` values; a wrong password is
> rejected. Harness: `validation/` (separate project pulling both the server
> and the `oracledb` client via path) — `validation/test/realclient_test.dart`
> and `validation/bin/validate.dart`. Two real-world fixes fell out of this:
> the server now negotiates TNS version **318** with **large-SDU (4-byte)
> DATA framing** (see "Closing the remaining work" item 1 below — CONNECT and
> ACCEPT stay 2-byte; only post-ACCEPT DATA packets use the 4-byte length),
> and it answers the client's `nls_database_parameters` charset probe with a
> synthetic `AL32UTF8` / `AL16UTF16` result.

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
> `test/oracle_wire_test.dart`.

**Phase 1 — TNS transport + negotiation. ◻ (in progress)** Full
CONNECT/ACCEPT (incl.
large-SDU/`tnsVersionMinLargeSdu`, data-flags, end-of-request flags),
MARKER/RESEND/ABORT handling, DATA packet framing, and the TTC
PROTOCOL + DATA-TYPES negotiation handshake. *Exit:* client and server
agree on version, charset (AL32UTF8 / 873), and the type table.

> **Landed:** `lib/server/oracle_ttc.dart` — the TTC negotiation layer.
> The connection state machine now answers the classical handshake: a
> PROTOCOL request (function 1) gets a `buildProtocolResponse` (server
> version, banner, AL32UTF8/873 charset, AL16UTF16/2000 national charset,
> FDO, and 53-byte compile / 7-byte runtime capability vectors with field
> version 24 at slot 7), and a DATA-TYPES request (function 2) gets a
> `buildDataTypesResponse` (type 2 + `0x0000` terminator). The DATA-packet
> decoder now lifts the 2-byte data-flags field off the TTC body.
> `test/oracle_wire_test.dart` drives the full CONNECT -> PROTOCOL ->
> DATA-TYPES exchange at the byte level and decodes each response with a
> mirror of the client's `ProtocolResponse.decode`. **Next:** AUTH phase
> (function 0x76) lands the connection in Phase 2; record a real-client
> transcript to confirm the negotiation bytes before auth.

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

> **Landed (O5LOGON/SHA512 verifier):** `lib/server/oracle_crypto.dart`
> (SHA-512, PBKDF2-HMAC-SHA512, AES-256-CBC raw/PKCS7 via `pointycastle`)
> and `lib/server/oracle_auth.dart` — the verifier side. The server stores
> only `{salt, SHA512(password‖salt)[0:32]}` per user (never plaintext). In
> AUTH_PHASE_ONE (function `0x76`) it seals a fresh 48-byte nonce into
> `AUTH_SESSKEY` and advertises the salt in `AUTH_VFR_DATA` (flags = verifier
> type `0x939`); in AUTH_PHASE_TWO (`0x73`) it decrypts the client session
> key, derives the combo key (PBKDF2 over `hex(partB‖serverNonce)`, client
> default mixing), decrypts `AUTH_PASSWORD`, and re-derives the hash to
> confirm — constant-time compared. Success returns a STATUS message; failure
> and unknown users return a TTC ORA-01017 error. Users are registered via
> the `OracleServer(users: {...})` constructor or `--oracle-user user/pass`.
> `test/oracle_auth_test.dart` simulates the client proof and covers accept /
> wrong-password / unknown-user, plus a **live end-to-end** socket handshake
> CONNECT → PROTOCOL → DATA-TYPES → AUTH1 → AUTH2 → authenticated. **Next:**
> PBKDF2/12c + FAST_AUTH paths, and confirm against the real `oracledb`
> client; then Phase 3 execute/fetch.

**Phase 3 — Execute & fetch (the money path).** Decode the OALL8
`ttcFuncExecute` message (SQL text, bind metadata, bind values, fetch
array size, options) via the inverse of `execute_message.dart` +
`bind_parser.dart`. Hand the SQL + binds to `Database.execute()`. Encode
the describe (column metadata) and row data stream, honoring the
prefetch/fetch-array protocol and `ttcFuncFetch` continuations from
`result_set_cursor.dart`. Map engine errors to `ORA-NNNNN` OER packets via
`errors.dart`. *Exit:* `SELECT`/`INSERT`/`UPDATE`/`DELETE` with binds work
from a stock client.

> **Landed (no-bind path):** `lib/server/oracle_execute.dart`.
> `decodeExecuteRequest` walks the OALL8 header (field version 24) to recover
> the SQL text, cursor id, and bind count; the connection runs it through
> `Database.execute()`. Responses are encoded as the inverse of the client's
> response decoders: DML/DDL as a success `ERROR(num=0, rowCount)`, queries as
> `DESCRIBE_INFO` + `ROW_HEADER` + per-row `ROW_DATA` + a terminal
> `ORA-01403` (end of fetch). Result columns are described as **VARCHAR2** and
> values sent as UTF-8 strings — a valid shape the client decodes to `String`,
> which sidesteps Oracle's base-100 NUMBER encoding for now. `test/
> oracle_execute_test.dart` round-trips the request decode, validates each
> response encoding with mirrors of the client decoders, and drives a **live**
> login → CREATE → INSERT → SELECT over a socket (`test/oracle_support.dart`
> centralizes the client simulation). **Next:** bind variables (metadata +
> values), native NUMBER/DATE/etc. column encoding, multi-packet/large result
> flow control and `ttcFuncFetch` continuations, then confirm against the real
> `oracledb` client.

> **Update (bind variables):** `decodeExecuteRequest` now decodes the bind
> metadata blocks and the ROW_DATA value block (NUMBER, VARCHAR2/CHAR, RAW,
> NULL) after the OALL8 header — for fresh executes and cached re-executes
> alike (binds travel even when the SQL doesn't). The wire sends values
> positionally; `_executeWithBinds` tokenizes the SQL with the engine's lexer,
> maps each value to the placeholder in first-appearance order, and runs
> `Database.executeWith(positional:, named:)` — so `:1`/`:2` (positional),
> `:name` (named), and repeated placeholders all bind correctly. Proven
> against the **real `oracledb` client** (`validation/test/realclient_test.dart`:
> positional List binds, a named `:dept` filter, and a repeated `:x`) plus a
> self-contained main-suite test.

> **Update (large results / multi-packet):** `_sendTtc` now splits a TTC
> response larger than the negotiated SDU across multiple DATA packets; the
> client reassembles them into one TTC stream (its completion probe reads
> packets until the terminal message decodes), so result sets are no longer
> capped at one packet. The negotiated SDU is captured at CONNECT and used as
> the chunk size. Proven against the **real client** (an 800-row, ~40 KB
> SELECT) and a self-contained main-suite test (400 rows) that reassembles
> frames via a new `readExecuteResponse` helper.

**Phase 4 — Transactions & statement lifecycle.** `ttcFuncCommit` /
`ttcFuncRollback`, cursor close (`ttcFuncCloseCursors`), re-execute of
cached cursors (`ttcFuncReExecute` / `ttcFuncReExecuteAndFetch`),
`ttcPing`, and graceful `ttcClose`. Map to the engine's existing
`BEGIN/COMMIT/ROLLBACK` and prepared-statement cache.

> **Landed (commit/rollback/ping):** `oracle_execute.dart` `buildStatusOk`
> plus dispatch in `oracle_wire.dart` for `ttcFuncCommit` (14),
> `ttcFuncRollback` (15), and `ttcFuncPing` (0x93) — each a bare FUNCTION RPC
> (`[3][func][seq][token]`) acknowledged with a success STATUS the client
> reads as end-of-call. Because the engine applies writes immediately and
> persists on its own schedule, COMMIT/ROLLBACK are acknowledgements rather
> than a true durable boundary / undo (documented limitation).
> `test/oracle_lifecycle_test.dart` drives each call live after login and
> confirms the connection stays usable. **Next:** cursor close
> (`ttcFuncCloseCursors` piggyback), cached-cursor re-execute, graceful
> `ttcClose`, and real per-session transaction semantics.

> **Update (real transactions):** COMMIT and ROLLBACK now drive the engine
> when a transaction is open — `db.inTransaction` gates a real
> `db.execute('COMMIT'/'ROLLBACK')`, so a client that issues `BEGIN` then
> DML has its work actually persisted or undone by the TTC lifecycle call;
> outside a transaction they stay harmless acks (no regression to the
> auto-commit path). `test/oracle_lifecycle_test.dart` proves ROLLBACK
> undoes an insert and COMMIT persists it over a live socket. Per-session
> isolation across concurrent connections is still not modeled (one shared
> engine transaction).

> **Update (cursors & lifecycle):** `oracle_wire.dart` now keeps a
> per-connection cursor cache (cursor id → SQL). A fresh EXECUTE (cursor 0)
> is assigned an id that the response echoes in its ERROR body, so the
> client's transparent statement cache stores it; a cache hit re-executes
> with that id and **no SQL on the wire**, which the server resolves from the
> cache. A leading **close-cursors piggyback** (message type 17, function
> 105) prepended to any call is consumed and frees the listed cursors; an
> unknown cursor id draws an invalid-cursor error. Graceful **logoff** needs
> no RPC — the client's `disconnect()` just closes the socket, which the
> `onDone` handler already cleans up. Covered by `test/oracle_cursor_test.dart`
> (re-execute by id, piggyback free).

> **Update (per-session isolation):** the single shared engine keeps one
> global transaction snapshot (`_tables` is swapped to it), so correct
> isolation is enforced by **serializing** sessions through a FIFO gate in
> `oracle_wire.dart`. A session that opens a transaction (`BEGIN`, or a
> `db.inTransaction` that stays set after a statement) becomes the gate's
> owner and holds it across every statement until it commits or rolls back;
> other sessions' statements — including reads — queue until then, so a
> session's uncommitted work is never visible to another (serializable
> isolation). Statements outside a transaction grab-run-release and never
> block each other beyond their own execution, so the no-transaction fast
> path is unchanged. A session that disconnects mid-transaction is rolled
> back and the gate released, so one stuck client can't wedge the server.
> `test/oracle_isolation_test.dart` proves an uncommitted insert is invisible
> and blocks a second session until rollback, that a commit makes it visible,
> and that a mid-transaction disconnect frees the gate. The remaining
> trade-off is concurrency, not correctness: cross-session reads serialize
> while any transaction is open (no row-level MVCC).

> **Update (performance — concurrent reads):** the gate was upgraded from a
> single FIFO mutex to a fair **reader/writer** gate (`_SessionGate`). Only a
> transaction-opening statement takes the **exclusive** lock and holds it for
> the transaction's lifetime; **every other statement takes a shared lock**,
> so reads (and writes, which the engine's own lock already serializes) from
> different sessions run **concurrently** in the common no-transaction case —
> the previous design serialized them all. Isolation is unchanged: a shared
> acquire blocks while any session holds an open transaction's exclusive lock,
> so uncommitted work stays invisible. Statement classification is
> conservative (only `BEGIN` / `START TRANSACTION` take the exclusive lock);
> a misclassified autocommit write is still correct because the engine's
> internal write lock serializes it and it opens no transaction.
> `test/oracle_isolation_test.dart` adds a many-session concurrent-read check
> alongside the isolation proofs.

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

> **Landed (NUMBER):** `lib/server/oracle_number.dart` — a verbatim port of
> the client's base-100 `encodeNumber`/`decodeNumber`. `buildQueryResponse`
> now infers each column's type from its values: a column whose every
> non-null value is a representable number is described as **NUMBER** (type 2)
> and its cells encoded with `encodeOracleNumber`, so the client returns real
> `int`/`double` values instead of strings; mixed or non-numeric columns stay
> VARCHAR2. `test/oracle_execute_test.dart` round-trips ints, negatives, zero,
> and decimals (decoded with the ported `decodeOracleNumber`, byte-identical
> to the client), and the live SELECT now yields native numbers. **Next:**
> DATE/TIMESTAMP, INTERVAL, ROWID, LOB locators, JSON (OSON), VECTOR — noting
> the engine stores most non-numeric values as text, so those apply where the
> engine surfaces a typed value.

> **Update (RAW):** byte-buffer (`Uint8List`) columns are now described as
> Oracle **RAW** (type 23) and their bytes sent length-prefixed, so a BLOB
> column round-trips as `Uint8List` on the client instead of a stringified
> form. Per-column inference picks NUMBER / RAW / VARCHAR2 by scanning the
> values; an empty byte buffer reads back as NULL (indistinguishable on the
> wire), covered by `test/oracle_execute_test.dart`.

> **Update (DATE / TIMESTAMP binds):** a `DATE` (7-byte), `TIMESTAMP` (11) or
> timestamp-with-zone (13) **bind value** is decoded (`_decodeOracleDateTime`)
> to an ISO-8601 `YYYY-MM-DD HH:MM:SS[.ffffff]` string — the text form the
> engine already stores dates as — so a `DateTime` bound by the real client
> round-trips (proven in `validation/test/realclient_test.dart`). The fetch
> side still returns stored dates as VARCHAR2 text (the engine has no native
> date type), so the round-trip is bind-`DateTime` → fetch-`String`.
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

## Closing the remaining work

Everything below follows the same proven recipe: **invert the client's
encoder/decoder** for the type or message, **integrate with the engine**
(which stores most rich values as text/primitives, so a symmetric
round-trip is only possible where the engine has a native type), and
**validate against the real `oracledb` client** in `validation/`. Items are
ordered by value ÷ effort.

### Priority & dependencies

```
1. Large-SDU framing ─┬─► prerequisite for FAST_AUTH (needs version ≥ 318)  ✅ done
                      └─► lets single packets exceed 64 KB
2. INTERVAL codecs      (easy — mirrors the DATE work already shipped)  ✅ done
3. VECTOR codecs        (engine has native vectors → full round-trip)  ✅ done (dense)
4. JSON codecs          (text fallback easy; native OSON hard)
5. 12c PBKDF2 verifier  (independent — broadens client compatibility)
6. TLS / TCPS           (independent — SecureServerSocket)
7. FAST_AUTH            (after #1; a round-trip optimization, not a gap)
8. LOB locators + ttcLobOp streaming   (largest — a server LOB store)
```

### 0. Large-SDU framing (foundational) — ✅ done

- **Status:** shipped. The server negotiates TNS version **318** with a
  per-connection `_useLargeSdu` (set when the negotiated version ≥ 315).
  `TnsPacket.decode` / `frameLength` / `buildDataPacket` read & write a 4-byte
  DATA length when large SDU is active; CONNECT and ACCEPT stay on 2-byte
  framing. Verified by the full self-contained suite **and** the real
  `oracledb` client (which now drives 4-byte DATA framing end-to-end).
- **Why:** the server previously pinned TNS version **314** so DATA packets kept
  the classic 2-byte length header. Version ≥ 315 switches to a **4-byte**
  packet length, which unlocks the accept-flag word (≥ 318, needed for
  FAST_AUTH) and >64 KB single packets. Multi-packet already removes the
  *result-size* cap, so this is only needed for FAST_AUTH and larger SDUs.
- **Inverted:** `transport/packet.dart` `readTnsPacketLength` / `encodeTnsPacket`
  with `useLargeSdu` — the length moves to bytes 0–3 for DATA packets.

### 1. INTERVAL codecs (Phase 5) — type 182 / 183 — ✅ done

- **Status:** shipped. `_decodeBindValue` now handles type **182** (`INTERVAL
  YEAR TO MONTH`) and **183** (`INTERVAL DAY TO SECOND`), decoding each wire
  value to a signed literal string (`+2-06`, `+3 04:05:06.123456789`) the
  engine stores as text. Verified by a self-contained mirror test and a real
  `oracledb` client test binding `OracleIntervalYM` / `OracleIntervalDS`.
- **Inverted:** `oracle_interval.dart` + `data_types.dart`. `INTERVAL YEAR TO
  MONTH` (type **182**, 5 bytes: 4-byte years + 1-byte months, offset-encoded);
  `INTERVAL DAY TO SECOND` (type **183**, 11 bytes: 4-byte days, hour, minute,
  second, 4-byte fractional seconds, all offset-encoded).
- **Engine fit:** no native interval → decode a **bind** value to an Oracle
  interval literal / ISO-8601 duration **string** (same asymmetric shape as
  DATE); fetch returns it as VARCHAR2 text. Add the two cases to
  `_decodeBindValue`.
- **Validate:** bind an `OracleIntervalDS` / `Duration` from the real client.

### 2. VECTOR codecs (Phase 5) — type 127 — ✅ done (dense)

- **Status:** shipped for dense vectors. A VECTOR bind (type 127) decodes
  through the 40-byte value-based QLocator + inline image to the engine's
  native `Vector` (`Float32List`); the engine stores it. On fetch, a column of
  `Vector` values is described as VECTOR and each value is written in the
  LOB-prefetch inline shape (UB4 marker, UB8 size, UB4 chunk, length-prefixed
  image, empty locator). FLOAT32 / FLOAT64 / INT8 images decode (to the
  engine's Float32 storage); the fetch image is dense FLOAT32. Sparse and
  BINARY images are rejected for now. Verified by a self-contained mirror test
  and a real `oracledb` client `Float32List` round-trip.
- **Inverted:** `oracle_vector.dart` (dense `Float32List`/`Float64List`/
  `Int8List`/`Uint8List` by storage format; sparse `OracleSparseVector`) and
  the describe's 23.4 vector fields (dimensions / format / flags).
- **Engine fit:** the engine **has native vectors**, so the full
  bind→store→fetch round-trip works: decode a bound vector to the engine's
  `Vector`, and on fetch encode a vector column to the VECTOR wire form.
- **Remaining:** sparse (`OracleSparseVector`) and BINARY vectors, and a real
  `VECTOR_DISTANCE` query (the engine's similarity path).

### 3. JSON / OSON codecs (Phase 5) — type 119

- **Phase a (easy):** describe `JSON` columns as **VARCHAR2** and send the
  JSON text; a bound JSON value decodes from its text. Works immediately, no
  OSON.
- **Phase b (full):** invert `oson.dart` to encode `Map`/`List` →
  **OSON** binary (type 119) and decode OSON binds, so JSON round-trips as
  native `Map`/`List` on the client. This is the large sub-item (a full binary
  format).
- **Validate:** real client fetch of a `JSON` column as `Map`.

### 4. 12c PBKDF2 verifier + FAST_AUTH (Phase 2)

- **12c PBKDF2 (type 0x4815):** the server currently advertises the SHA512
  verifier (0x939), which the real client accepts. To also serve clients that
  require the 12c verifier, advertise `0x4815` and add the PBKDF2 branch from
  `crypto/auth.dart`: `passwordKey = PBKDF2(password, salt ‖
  "AUTH_PBKDF2_SPEEDY_KEY", iterations, 64)`, `passwordHash =
  SHA512(passwordKey ‖ salt)[0:32]`, plus the `AUTH_PBKDF2_SPEEDY_KEY`
  validation (decrypt with the combo key → compare `passwordKey`). Send
  `AUTH_PBKDF2_VGEN_COUNT` / `AUTH_PBKDF2_CSK_SALT` / `AUTH_PBKDF2_SDER_COUNT`
  in AUTH_PHASE_ONE. Store `{salt, iterations, mixingSalt, mixingIterations,
  passwordKey}` per user — still no plaintext. `oracle_crypto.dart` already has
  `pbkdf2Sha512`.
- **FAST_AUTH (23ai, 1 round trip):** depends on **#0** (advertise the
  `0x10000000` accept flag, which needs version ≥ 318). Then the client sends
  one FAST_AUTH envelope batching PROTOCOL + DATA-TYPES + AUTH_PHASE_ONE
  (`fast_auth_message.dart` / `transport.sendFastAuth`); the server decodes it
  and replies with all three responses in one packet. A round-trip
  optimization, not a functional gap.
- **Validate:** real client with a 12c-verifier user; node-oracledb FAST_AUTH.

### 5. TLS / TCPS (Phase 6)

- **Invert:** `transport/tls.dart`; mirror `mysql_wire.dart`'s `tlsContext`.
- **Do:** add an optional `SecurityContext` to `OracleServer`; when set, bind
  with `SecureServerSocket` so the client connects via `tcps://host:port/svc`.
  The TNS/TTC layers are unchanged above the socket. (Oracle **Native Network
  Encryption** — in-band TNS-negotiated crypto — is a separate, harder item;
  defer it.)
- **Validate:** real client over `tcps` with a self-signed test cert (as the
  MySQL TLS tests already do).

### 6. LOB locators + `ttcLobOp` streaming (Phase 5) — type 112 / 113

- **Phase a (inline, easier):** the client's default `fetchLobs: false`
  **materializes** a CLOB/BLOB inline. Describe the column as CLOB (112) /
  BLOB (113) and send the value in the fetch shape the client's inline
  materializer reads (length-prefixed, CLOB as UTF-8/UTF-16). This covers the
  common "just read the text/bytes" case without a locator.
- **Phase b (locators, hardest):** implement the LOB locator + the
  `ttcLobOp` RPC (func **0x60**, `lob_op_message.dart` / `lob_locator.dart`):
  a server-side LOB store keyed by locator, answering get-length, read, write,
  trim, get-chunk-size, and temporary-LOB create/free. Needed for
  `fetchLobs: true` streaming and temp LOBs.
- **Validate:** real client CLOB/BLOB read (Phase a), then `fetchLobs: true`
  streaming (Phase b).

### Cross-cutting

- **Describe metadata:** each new fetched type needs its exact
  `_writeColumnInfo` fields (csfrm for NCLOB, the 23.4 vector trio, LOB
  cont-flags). Get these from `_processColumnInfo` in `execute_message.dart`.
- **Every item** lands behind a `validation/` real-client test plus a
  self-contained mirror test, matching the existing cadence.

