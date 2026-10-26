# Oracle thick-client spec plan (pure-Dart native driver)

> **Using the client?** See [oracle-thick-client-usage.md](oracle-thick-client-usage.md)
> for the public API (connect, service/SID login, queries, binds, PL/SQL, LOBs,
> DML). This file is the protocol/implementation plan.

A living, prioritized plan to grow `lib/oracle_thick_client.dart`
(`OracleThickClient`) from a native-TTC **smoke client** (NUMBER + VARCHAR2,
text binds, dart-db-server-only) into a **pure-Dart Oracle client to spec** —
full type system, typed binds, LOBs, cursors, and array DML — validated against
**both** the in-process `dart-db-server` native listener **and a real Oracle**.

## Validation targets
- **dart-db-server (in-process):** the existing `OracleServer` harness
  (`test/oracle_thick_client_roundtrip_test.dart`). Fast, no external DB. Only
  emits NUMBER/VARCHAR2 today, so new-type **decode** tests here require
  co-evolving the server encoder (optional) — otherwise decode is validated on
  real Oracle.
- **Real Oracle (Docker):** `gvenzl/oracle-free` **26ai (23.26)**, container
  `orafree`, `localhost:1521`, service `FREEPDB1`, `system` / `TestPw1234`.
  Round-trip every type against the real DB. Gate these tests behind an env flag
  (e.g. `RUN_ORACLE_TESTS=true`) so CI without a DB stays green.

## Current state (baseline)
- Native CONNECT/ACCEPT, break/reset, FAST_AUTH decline, DATA-TYPES negotiation,
  O5LOGON/PBKDF2 auth + mutual-auth validation — **works against dart-db-server**.
- OALL8 EXECUTE + FETCH pagination; describe decode for **NUMBER (dty 0x02)** and
  **VARCHAR2 (dty 0x60)** only; binds sent as **text** (`toString`).
- A recent edit **removed** the `host` arg and the inline real-Oracle CONNECT, so
  it currently only reaches the loopback dart-db-server. **T0 restores this.**
- Bidirectional NUMBER codec exists (`lib/server/oracle_number.dart`).

## How to use this file
- Build in order; **T0 is a hard prerequisite** (can't validate real types
  without connecting to real Oracle).
- Each type increment = describe-decode + cell-decode + typed-bind encode + a
  round-trip test on **real Oracle** (and in-process where the server emits it).
- Update **Status** per item; move finished items to "Landed".

## Status legend
`TODO` · `WIP` · `LANDED (<commit>)` · `WON'T` (with reason).

---

## Phase T0 — Real-Oracle connectivity & auth  ·  Status: LANDED (loginReal, works vs 26ai)
**Goal:** connect and authenticate against real Oracle 26ai, re-establishing the
capability a recent edit removed.
- [x] **Restore `host`.** `connect(int port, {String host})` (keep loopback
  default) so non-loopback / named hosts work.
- [x] **Inline CONNECT descriptor.** Re-added the standard real-Oracle CONNECT
  (inline descriptor + v315+ large SDU/TDU fields, no follow-up descriptor
  packet), via `buildNativeConnect(inline: true)`.
- [x] **Descriptor with service + CID.** `loginReal` builds
  `(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=..)(CID=..)))`.
- [x] **Canonical FAST_AUTH + O8LOGON against 26ai.** New
  `lib/oracle_native_handshake.dart` ports the thin driver's FAST_AUTH bundle
  (PROTOCOL + DATATYPES + AUTH_PHASE_ONE), locates the type-8 challenge via
  `findAuthChallenge`, computes the PBKDF2/AES O8LOGON proof, and validates
  `AUTH_SVR_RESPONSE`. END_OF_RPC (0x0800) data flag applied on 23ai+.
- [x] **A gated smoke test** (`RUN_ORACLE_TESTS`):
  `test/oracle_real_login_test.dart` logs in via `loginReal` and asserts
  `authenticated == true` + `AUTH_DBNAME`. **Passes vs Docker 26ai.**
- [ ] (follow-up) `SELECT 1 FROM dual` on the real connection — needs the
  canonical OALL8 execute path (T1).

## Phase T1 — Canonical OALL8 execute + describe metadata  ·  Status: LANDED (queryReal, works vs 26ai)
**Goal:** parse real column metadata and run real queries, not the
dart-db-server smoke format.
- [x] **New module `lib/oracle_native_execute.dart`** — canonical OALL8
  `buildQueryExecute` (al8i4 options, no binds) + `buildFetch`, ported from the
  thin driver, on the Oracle-compatible `oracle_codec.dart` UB buffers.
- [x] **`NativeColumn`** value type: name, `oracleType` (dty), `maxLength`,
  `precision`, `scale`, `csfrm`. Produced by the generalized DESCRIBE_INFO
  parser (version-gated 12.2 / 23.1 / 23.1Ext3 / 23.4 fields).
- [x] **Full response dispatcher**: DESCRIBE_INFO, ROW_HEADER, ROW_DATA,
  BIT_VECTOR (duplicate-column), ERROR (ORA-01403 end-of-fetch), STATUS,
  RETURN_PARAMETER, WARNING, SERVER_SIDE_PIGGYBACK, END_OF_REQUEST — with
  split-packet reassembly (`complete` flag + frame accumulation).
- [x] **`OracleThickClient.queryReal(sql)`** drives EXECUTE + FETCH rounds until
  the cursor drains. Decodes NUMBER, VARCHAR2/CHAR/STRING, RAW,
  BINARY_FLOAT/DOUBLE, DATE today; fail-loud `NativeUnsupportedTypeException`
  for the rest (T2 fills them in).
- [x] **Gated test** (`RUN_ORACLE_TESTS`) in `test/oracle_real_login_test.dart`:
  `SELECT 1`, mixed VARCHAR2+NUMBER, 5-row `all_tables` fetch, `sysdate` DATE.
  **Passes vs Docker 26ai.**
- [ ] (follow-up) typed binds (T3) so `queryReal` accepts parameters; array
  fetch tuning; `OracleThickResult`-shaped public wrapper.

## Phase T2 — Scalar type decoders  ·  Status: LANDED (temporal/interval/rowid, works vs 26ai)
Decoders live in `lib/oracle_native_execute.dart` `_decodeColumnValue`;
round-tripped on real Oracle in `test/oracle_real_login_test.dart`.
- [x] **DATE** (7-byte) and **TIMESTAMP** (11-byte) + fractional seconds →
  `DateTime` (microsecond precision).
- [x] **TIMESTAMP WITH TIME ZONE / WITH LOCAL TIME ZONE** (13-byte) → UTC
  `DateTime` instant (numeric-offset/region preservation is a later refinement).
- [x] **CHAR / NCHAR / NVARCHAR2** (csfrm UTF-16BE for national charset).
- [x] **RAW** → `Uint8List`.
- [x] **BINARY_FLOAT / BINARY_DOUBLE** (IEEE-754 with Oracle's sign flip).
- [x] **INTERVAL DAY TO SECOND** → `Duration`; **INTERVAL YEAR TO MONTH** →
  `OracleYearMonth`.
- [x] **ROWID** → Oracle's 18-char base64 text.
- [ ] (follow-up) **LONG / LONG RAW**, **UROWID**, **CLOB/BLOB** (T4),
  TSTZ numeric-offset wrapper.

## Phase T3 — Typed binds  ·  Status: LANDED (positional scalar binds, work vs 26ai)
**Goal:** send binds with real types, not `toString()`.
- [x] **Bind metadata block** per bind on the OALL8 request (wire type, maxSize,
  csfrm, charset field) + the `ttcExecOptionBind` flag + ROW_DATA value message.
- [x] **Encoders:** NUMBER (`encodeOracleNumber`), VARCHAR2 (UTF-8), RAW (bytes),
  TIMESTAMP (11-byte binary), and typed **NULL** (zero-length indicator).
- [x] **Positional binds** (`:1`, `:2` …) via `queryReal(sql, binds: [...])`;
  server-side WHERE filtering verified.
- [x] Round-trip test on real Oracle (NUMBER/String/RAW/DateTime/NULL + a
  WHERE-clause bind).
- [ ] (follow-up) named binds (`:name`→order), DATE vs TIMESTAMP distinction,
  NVARCHAR2/interval binds, OUT/IN OUT binds, array (executeMany) binds.

## Phase T4 — LOBs (CLOB / BLOB)  ·  Status: LANDED (read, works vs 26ai)
- [x] **LOB locator decode** (non-prefetch wire shape: UB4 locatorLen +
  length-prefixed locator) → `NativeLob` cell.
- [x] **`LOB GET_LENGTH` + `LOB READ` TTC ops** (`buildLobGetLength` /
  `buildLobRead`, function 96) with `decodeLobReadResponse` (LOB_DATA +
  RETURN_PARAMETER amount + split-packet reassembly).
- [x] **Materialization** in `queryReal`: CLOB/NCLOB → `String` (UTF-16BE),
  BLOB → `Uint8List`; empty LOB → empty value; multi-read loop for LOBs larger
  than one READ returns.
- [x] Gated test: 16-char CLOB, `BLOBDATA` BLOB, 9000-char multi-read CLOB,
  empty (NULL) CLOB. **Passes vs Docker 26ai.**
- [ ] (follow-up) `LOB WRITE` / temporary-LOB binds, large (>252 byte) scalar
  binds (chunked ROW_DATA encoding), `BFILE`.

## Phase T5 — Cursors & multiple results  ·  Status: LANDED (REF CURSOR, scalar OUT binds, implicit results)
- [x] **REF CURSOR OUT binds**: PL/SQL execute (`buildPlsqlExecute`) with one
  OUT cursor bind, IO_VECTOR parse, embedded-cursor describe decode, server
  cursor id extraction, and FETCH-drain via `openRefCursor`. LOB cells in cursor
  rows are materialized.
- [x] **Scalar OUT binds** (`NativeBind.outNumber/outVarchar/outDate/
  outTimestamp`) via `callPlsql(sql, binds)`; IN+OUT mix; decoded by declared
  type with the SB4 trailer. Positional binds follow Oracle's appearance order.
- [x] **Implicit result sets** (`DBMS_SQL.RETURN_RESULT`, TTC msg 27): decoded
  to `NativeImplicitResult` (cursor id + columns), FETCH-drained via
  `fetchImplicitResult`.
- [x] **IN OUT binds** (`NativeBind.inOut(value, {maxSize})`): the IN value
  ships in ROW_DATA and the modified value decodes back via the IO_VECTOR
  (direction 48). NUMBER/VARCHAR2 + mixed IN/IN OUT/OUT verified vs 26ai.
- [x] Gated tests pass vs 26ai (REF CURSOR, NUMBER/VARCHAR2/DATE OUT, IN→OUT,
  IN OUT, implicit result).
- [ ] (follow-up) nested `CURSOR(SELECT …)` columns; multiple REF CURSOR OUT
  binds in one call; oversized CLOB IN bind to a PL/SQL LOB parameter.

## Phase T6 — Bulk & RETURNING  ·  Status: LANDED (DML, array DML, RETURNING, works vs 26ai)
- [x] **DML execute** (`buildDmlExecute` + `executeDml`): INSERT/UPDATE/DELETE
  (and DDL) with positional IN binds → rows affected.
- [x] **Array DML** (`executeMany` via `bulkRows`): one ROW_DATA per iteration,
  `al8i4[1]=numExecs`, per-column maxSize widened to the column max.
- [x] **DML RETURNING … INTO** (`executeReturning`): OUT binds omitted from
  ROW_DATA, returned values stream back count-prefixed (one list per OUT bind).
- [x] **Break/RESET marker handling** (`_nextDataFrame`): a server BREAK marker
  (packet type 12, dataType 1) is answered with a RESET marker — this is what
  DDL/DML responses send; previously desynced the stream. Also unblocks DDL.
- [x] Gated test (single DML, 3-row array DML with varying string lengths,
  RETURNING) passes vs 26ai.
- [ ] (follow-up) array-DML per-row batch errors (`batchErrors`), array
  RETURNING (multiple rows per iteration), DML row-count array.

## Phase T7 — Robustness & parity  ·  Status: PARTIAL (TNS request fragmentation landed)
- [x] **TNS request fragmentation** (`_send`): large TTC requests (binds > one
  SDU, wide `executeMany`) are split across DATA packets sized to the negotiated
  SDU (parsed from the ACCEPT). Per Oracle's framing, intermediate packets carry
  data flags `0x0000` and only the FINAL packet carries END_OF_RPC (0x0800 on
  23ai+) — previously every request went out as one over-sized packet, which the
  server answered with a BREAK marker. Closes the large-bind gap flagged in
  T3/T4. (Values > 32767 bytes still need a CLOB bind — see below.)
- [ ] Full ORA error + warning decode; multi-error batches.
- [x] **Oversized string binds (> 32767 bytes) via temporary CLOBs**
  (`buildLobCreateTemp` / `buildLobWrite`): `queryReal` / `executeDml` detect a
  String past the VARCHAR2 limit, CREATE_TEMP a CLOB, WRITE it (UTF-16BE on this
  server), and bind the locator (CLOB wire shape + LOB-prefetch cont flag).
  50000-char round-trip verified vs 26ai.
- [x] **Oversized `Uint8List` binds (> 32767 bytes) via temporary BLOBs**: same
  path with a BLOB temp LOB (raw bytes, no charset). 60000-byte round-trip
  verified vs 26ai.
- [ ] Statement-cache reuse; cursor close/CLOSE_ALL.
- [ ] Session settings (NLS date/number formats, time zone) that affect decode.
- [ ] A behavioral parity pass vs `reference/node-oracledb` / the thin
  `../dart-oracledb` driver for the above.

## Test harness
- A `TestTarget` abstraction yielding a connected+authenticated client for
  either backend (in-process `OracleServer` or real Oracle via env).
- Real-Oracle suites gated on `RUN_ORACLE_TESTS=true` (+ host/port/user/pass/
  service env), mirroring the project's integration-test convention.
- Keep the dart-db-server round-trip suite green throughout; add real-Oracle
  round-trips per type.

## Code map
- `lib/oracle_thick_client.dart` — CONNECT/auth (T0), describe parser (T1),
  cell decoders (T2), bind encoders (T3), LOB/cursor ops (T4/T5), `OracleColumn`.
- `lib/server/oracle_number.dart` — reuse `encode/decodeOracleNumber` for binds.
- `lib/server/oracle_native_execute.dart` — the server encoder to co-evolve if
  in-process decode tests for new types are wanted.
- `reference/node-oracledb`, `../dart-oracledb` — wire/type references.

## Risks & mitigations
- **26ai vs v320 negotiation** → capture the real ACCEPT/DATA-TYPES; adjust
  version + flags; the DATA-TYPES blob
  (`lib/server/oracle_native_datatypes.dart`) is already a real-26ai capture.
- **Decode-only types** (server doesn't emit them) → validate those on real
  Oracle; optionally co-evolve the server encoder for in-process coverage.
- **Auth version sensitivity** → T0 proves auth before any type work.
- **Not stepping on the server** → changes stay in the client file +
  `oracle_number.dart` reuse; server encoder edits (if any) are additive.

## Milestones
1. **MT0:** real-Oracle login + `SELECT 1 FROM dual` green (gated).
2. **MT1:** every scalar type (T2) round-trips on real Oracle.
3. **MT2:** typed binds (T3) round-trip on real Oracle.
4. **MT3:** LOBs + REF CURSOR (T4/T5).
5. **MT4:** array DML + RETURNING (T6); parity pass (T7).
