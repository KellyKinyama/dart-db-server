# Oracle thick-client spec plan (pure-Dart native driver)

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

## Phase T1 — Full describe metadata  ·  Status: TODO
**Goal:** parse real column metadata, not just name + is-number.
- [ ] **`OracleColumn`** value type: name, `dataType` (dty), length, precision,
  scale, nullable, charsetId/charsetForm. Expose on `OracleThickResult`.
- [ ] **Generalized describe parser** keyed on dty (replace the 0x02/0x60
  special-case), validated against real Oracle describe records for each type.

## Phase T2 — Scalar type decoders  ·  Status: TODO
One increment each (describe + cell decode + round-trip on real Oracle):
- [ ] **DATE** (7-byte) and **TIMESTAMP** (11-byte) + fractional seconds.
- [ ] **TIMESTAMP WITH TIME ZONE / WITH LOCAL TIME ZONE** (13-byte + tz).
- [ ] **CHAR / NCHAR / NVARCHAR2** (charsetForm, blank-pad semantics).
- [ ] **RAW / LONG RAW** (bytes, not UTF-8).
- [ ] **BINARY_FLOAT / BINARY_DOUBLE** (IEEE-754 with Oracle's sign flip).
- [ ] **ROWID / UROWID**, **LONG**.

## Phase T3 — Typed binds  ·  Status: TODO
**Goal:** send binds with real types, not `toString()`.
- [ ] **Bind describe + dty tagging** on the OALL8 request (per-bind type, max
  size, scale; IN/OUT/INOUT; array size).
- [ ] **Encoders:** NUMBER (`encodeOracleNumber`), DATE/TIMESTAMP (binary),
  RAW (bytes), BINARY_FLOAT/DOUBLE, CHAR/VARCHAR2 charset-correct.
- [ ] **Named binds** (`:name`) → wire order mapping; **NULL** typed binds.
- [ ] Round-trip binds of every T2 type on real Oracle.

## Phase T4 — LOBs (CLOB / BLOB)  ·  Status: TODO
- [ ] LOB locator decode; `LOB READ`/`WRITE`/`GETLEN` TTC ops; streamed read of
  CLOB (char) and BLOB (bytes); temporary-LOB write for binds.

## Phase T5 — Cursors & multiple results  ·  Status: TODO
- [ ] **REF CURSOR** OUT binds (describe + fetch the nested cursor).
- [ ] **Nested cursors** in a row; **implicit result sets**
  (`DBMS_SQL.RETURN_RESULT`).

## Phase T6 — Bulk & RETURNING  ·  Status: TODO
- [ ] **Array DML** (`executeMany`) with per-row batch errors.
- [ ] **DML RETURNING … INTO** OUT binds (incl. array returning).

## Phase T7 — Robustness & parity  ·  Status: TODO
- [ ] Full ORA error + warning decode; multi-error batches.
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
