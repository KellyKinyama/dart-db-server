# Native thick-client — tightening plan

A living checklist for hardening the native (OCI/OCCI thick-client) Oracle wire
path. Pick any item, work it, tick it. Each item states the **risk**, the
**evidence** (confirmed vs suspected), a **proposed approach**, and **how to
verify**. The "Won't do" section is deliberate scope control — don't gold-plate
beyond it without a real failing case.

Scope: the native path only (`_nativeClient == true`). Thin clients
(node/python/dart oracledb) are already covered by their own tests.

## How to use this file
- Keep items small and independently shippable. One fix = one commit.
- Prefer **confirming the failure first** (a live `oci8` repro or a unit test)
  before changing code — avoid speculative hardening.
- Update the **Status** of an item when you touch it. Move finished items to
  "Landed".
- The relevant code lives in
  [lib/server/oracle_execute.dart](../lib/server/oracle_execute.dart),
  [lib/server/oracle_native_execute.dart](../lib/server/oracle_native_execute.dart),
  and [lib/server/oracle_wire.dart](../lib/server/oracle_wire.dart). Field notes
  (the "why") are in
  [doc/oracle-native-thick-client-auth.md](oracle-native-thick-client-auth.md).

## Status legend
- `TODO` — not started.
- `WIP` — in progress.
- `BLOCKED` — needs a capture / decision.
- `LANDED` — done and verified (list the commit).
- `WON'T` — intentionally out of scope (see "Won't do").

---

## P1 — correctness that real apps hit

### 1. Native error responses (any failing statement hangs the client)
- **Risk:** On a native client, a statement that the engine rejects (syntax
  error, missing table, unique-constraint violation, etc.) falls into the
  `catch` in `_handleExecute`, which returns the **thin** `buildExecuteError`.
  Native OCI cannot parse the thin error and **hangs** — the same failure mode
  that `ALTER SESSION` and the "unsupported shape" path showed. So today any SQL
  error against a native client is a hang, not a surfaced `ORA-xxxxx`.
- **Evidence:** Suspected-high. Same mechanism proven for `ALTER SESSION` (thin
  error → hang) and the long-bind misfire. A real listener sends a native error
  as **TTC message type `0x04`** (captured earlier: 78 / 126 / 144-byte msg-04
  frames carrying the `ORA-` text).
- **Approach:** Add `buildNativeExecuteError(code, message)` modelled on the
  captured msg-04 frame (reuse the trailing `1d` terminator and the native
  marshaling), and route native errors through it in `_handleExecute`'s `catch`
  and anywhere else native currently calls `buildExecuteError`.
- **Verify:** `oci8` runs `select * from no_such_table` and
  `insert` that violates a constraint → expect a non-hanging `oci_error()` with
  the right `ORA-` code, then the connection stays usable for the next
  statement. Add a live-loopback unit test.
- **Effort:** M (needs a small capture of a real msg-04 error to template).
- **Status:** TODO

### 2. Row-count status fields wrap past 255 rows
- **Risk:** In `buildNativeQueryResponse` the multi-row status slots are written
  as single bytes (`status[11/42/52/106] = n`, `status[40] = 10 + n`,
  `status[80] = n + 4`). A query returning > ~245 rows overflows these bytes, so
  the client may under-read the row array or mis-track the cursor.
- **Evidence:** Suspected. All multi-row captures were ≤ 5 rows; the formulas
  were derived there. The DML count at `[42]` is already a proper LE32, so the
  status block clearly *can* carry wider counts — the describe-status slots just
  haven't been checked at scale.
- **Approach:** Capture a real `select … union all …` (or a table select) with
  300+ rows, diff the status block, and widen whichever slots are LE-scalars
  rather than single bytes.
- **Verify:** `oci8` fetches a 300-row and a 1000-row result; assert the full
  set comes back and `oci_close` is clean.
- **Effort:** M.
- **Status:** TODO

### 3. NULL bind values and NULL column values
- **Risk:** `_encodeValue(null, …)` emits a zero-length value and
  `_scanNativeBindValues` assumes every bind is a present length-prefixed text
  run. A bound `NULL` (or a row with a NULL column) may be mis-counted or
  mis-encoded, shifting the whole value block.
- **Evidence:** Suspected — never exercised. oci8 sends NULL binds with a
  distinct indicator the current scanner doesn't model.
- **Approach:** Capture an `insert … values (:a, :b)` with one bound `NULL`;
  confirm how the length/indicator is marshaled; handle it in the scanner and in
  the row encoder (NULL column → the Oracle NULL indicator the client expects).
- **Verify:** `oci8` binds a NULL and selects a NULL column; both round-trip.
- **Effort:** M.
- **Status:** TODO

---

## P2 — robustness / breadth

### 4. Cursor reuse (statement caching) on re-execute
- **Risk:** `decodeNativeExecuteRequest` always reports `cursorId 0` and relies
  on inline SQL. If a client re-executes a cached statement by cursor id
  **without** re-sending the SQL, `info.sql` is empty and `_handleNativeCall`
  treats it as a control call (commit/close) — wrong.
- **Evidence:** Suspected. `oci8` re-parses in practice (we always saw inline
  SQL), but prepared-statement reuse / `oci_execute` on a kept handle could trip
  it.
- **Approach:** Track a per-connection `cursorId → sql` map keyed off the native
  cursor field; on an empty-SQL execute with a non-zero cursor, replay the cached
  SQL. Needs the native cursor id located in the OALL8 header.
- **Verify:** `oci8` prepares once and `oci_execute`s the same handle in a loop.
- **Effort:** L.
- **Status:** TODO

### 5. Typed binds (NUMBER / DATE columns)
- **Risk:** All binds are decoded as text and handed to the engine as strings.
  Inserting `'42'` into a NUMBER column or `'2026-01-01'` into a DATE relies on
  engine coercion; comparisons/range predicates on bound values may behave
  differently than Oracle.
- **Evidence:** Works for display today (verified). Correctness for typed
  predicates is untested.
- **Approach:** Only if a real case fails — coerce bound text to num/date when
  the engine's target column type is known, or when the value is unambiguously
  numeric. Keep it minimal.
- **Verify:** `where num_col = :v` and `where date_col > :d` return the right
  rows.
- **Effort:** M.
- **Status:** TODO

### 6. Bind-count edge cases in the placeholder regex
- **Risk:** `_scanNativeBindValues` counts distinct binds with `RegExp(r':(\w+)')`
  over the raw SQL. False positives from `:` inside string literals or comments,
  and positional `:1`/`:2` vs named reuse, can mis-count and shift the value
  block.
- **Evidence:** Suspected. Common Laravel SQL is clean, but a literal like
  `'12:30'` or `'a:b'` would add phantom placeholders.
- **Approach:** Count placeholders with the same `Lexer` `_executeWithBinds`
  uses (so literals/comments are skipped), instead of a raw regex. Shares one
  source of truth for "what is a bind".
- **Verify:** Unit test with a `'HH:MI'`-style literal plus a real bind.
- **Effort:** S.
- **Status:** TODO

### 7. Multi-column (3+) inter-row marker formula
- **Risk:** The inter-row marker `15 <ncols> 00 <2·ncols−1>` was derived from
  1- and 2-column captures. The `2·ncols−1` tail is extrapolated; 3+ columns are
  unverified and could desync multi-row fetches of wide rows.
- **Evidence:** Suspected (extrapolation). 1-col and 2-col are byte-confirmed.
- **Approach:** Capture a 3- and 4-column multi-row `select … union all …`,
  confirm or correct the marker, and widen the unit test.
- **Verify:** `oci8` fetches a 3-col/5-row and 4-col/5-row result intact.
- **Effort:** S.
- **Status:** TODO

### 8. NUMBER value encoding coverage (negatives, decimals, large/small)
- **Risk:** Query row values use `encodeOracleNumber`; the native path has only
  been exercised with small positive integers. Negatives, decimals, very large /
  very small magnitudes, and zero should be confirmed on the native encoder.
- **Evidence:** Suspected — thin path likely covers these; native round-trip not
  explicitly checked.
- **Approach:** Live `select -1, 3.14, 0, 1e30, -1e-30` style via `oci8`; if any
  differ, fix the encoder or fall back to encoding as text.
- **Verify:** Values match `oci8`'s read.
- **Effort:** S.
- **Status:** TODO

---

## P3 — nice to have

### 9. Extend / revisit the SQL verb set
- **Risk:** `_scanNativeSqlText` falls back to longest-printable when the
  statement doesn't start with a known verb; an exotic leading keyword plus a
  long string bind could re-trigger the original misfire.
- **Evidence:** Narrow. The verb set already covers the common DML/DDL/PLSQL and
  transaction-control leads.
- **Approach:** Add verbs only when a real statement form needs them (e.g. `WITH`
  already present; consider vendor forms if they appear).
- **Status:** TODO

---

## Won't do (intentional scope control)
- **Binary (non-text) binds** (SQLT_INT, RAW, native DATE, LOB locators): `oci8`
  and PDO bind as text; decoding the OCI-RPC binary value section is speculative
  until a client that does binary binds shows up.
- **DML byte `[120]` "widening":** it is a fixed-width field in Oracle's own
  layout; the authoritative count is the LE32 at `[42]`. Matching the wire is
  correct — don't "fix" it.
- **Reproducing the unvalidated describe/status/mid counters** (signature, date,
  session sequence, prefetch/buffer hints): the client ignores them; writing
  "accurate" values is churn with no behavioral effect.
- **The full ~500-byte `ALTER SESSION` NLS parameter block:** the no-op success
  is accepted by `oci8`; the server models no NLS state.

---

## Verification harness (how to repro at any time)
Start the server (non-zero `--port`, else it drops to a REPL and exits):
```powershell
dart run bin/dart_db_server.dart --oracle-port 1522 `
  --oracle-pbkdf2-user app/Secret123 --host 127.0.0.1 --port 4556 --memory
```
Native clients need a `TNS_ADMIN` dir with a plaintext `sqlnet.ora`:
```
SQLNET.AUTHENTICATION_SERVICES=(NONE)
SQLNET.ENCRYPTION_CLIENT=REJECTED
SQLNET.CRYPTO_CHECKSUM_CLIENT=REJECTED
```
Drive it with `php` + `oci8` against `//127.0.0.1:1522/FREEPDB1`
(`app` / `Secret123`). The engine is SQLite-like: **no `dual`, no `connect by`**
— use `select … union all select …` for multi-row.

Capture real Oracle for reference bytes via a TCP proxy (`1523 → 1521`), with
the same `sqlnet.ora` so traffic is plaintext; the `app` user needs
`grant create table, unlimited tablespace to app` for DDL/DML captures.

Run the unit suite:
```powershell
dart test (Get-ChildItem test -Filter 'oracle*test.dart' | % FullName)
```

## Landed
- Verb-anchored native SQL scan (long string binds no longer mistaken for SQL) —
  `2714087`.
- `ALTER SESSION` no-op interception — `702414e`.
- Native bind variables (trailing `0x07` text value block) — `7558c05`.
- Native DML row counts + native end-of-call terminal (clean `oci_close`) —
  `13a93e7`.
- Native multi-row query execution (single- and multi-column) — `7a84e13`.
- Laravel `oci8` end-to-end verified (docs) — `54f5b00`.
