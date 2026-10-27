# Oracle 19c (pre-23ai) validation plan

Goal: turn "implemented and 23ai-proven" into "verified on real 19c" for the
whole `OracleThickClient` real-Oracle API, following the field-version-12 wire
paths end to end. Work top-down — each phase builds on the previous, and every
phase is a single, runnable checkpoint.

## How to run each checkpoint

All checkpoints run through the credential-free-safe runner, which reads a
gitignored `.env` and performs exactly one login. Drive the specific check with
the `ORACLE_QUERY` / `ORACLE_PLSQL` keys (added per phase), then:

```bash
dart run tool/oracle_login.dart
```

Reset `RUN_ORACLE_LOGIN=` to empty after each run so the tool never re-hits the
server by accident. No password is ever printed.

Target: the live 19c listener (SID connect, user from `.env`). All DDL/DML runs
against a **throwaway table** created in the connecting user's own schema and
dropped at the end — nothing touches existing data.

## Legend

`TODO` · `WIP` · `DONE (<note>)` · `BLOCKED (<reason>)`

---

## Phase V0 — Scratch sandbox  ·  Status: TODO
A disposable table the later phases read/write, so no production data is touched.

- [ ] `CREATE TABLE tc_probe (id NUMBER, name VARCHAR2(100), amt NUMBER(12,2), created DATE, note CLOB, blob_col BLOB)`
- [ ] Confirm `executeDml` returns success for the DDL (DDL over the thick client
      exercises the BREAK/RESET marker path on this server).
- [ ] Teardown step defined: `DROP TABLE tc_probe PURGE` (run last, Phase V7).

Expected: table created and dropped cleanly; no ORA error.

## Phase V1 — SELECT decode coverage  ·  Status: TODO
Read-only, no table needed. Confirms each scalar decoder on field version 12.

- [ ] NUMBER: `SELECT 1, -2, 3.5, 123456789012 FROM dual` → `num` values exact.
- [ ] VARCHAR2 / CHAR: `SELECT 'abc', CAST('x' AS CHAR(3)) FROM dual`.
- [ ] DATE / TIMESTAMP: `SELECT SYSDATE, SYSTIMESTAMP FROM dual` → `DateTime`.
- [ ] TIMESTAMP WITH TIME ZONE: `SELECT SYSTIMESTAMP AT TIME ZONE 'UTC' ...`.
- [ ] INTERVAL: `SELECT INTERVAL '2' DAY, INTERVAL '3' YEAR FROM dual`.
- [ ] BINARY_FLOAT / BINARY_DOUBLE: `SELECT 1.5f, 2.5d FROM dual`.
- [ ] RAW: `SELECT HEXTORAW('DEADBEEF') FROM dual` → `Uint8List`.
- [ ] ROWID: `SELECT ROWID FROM dual`.
- [ ] NULLs: `SELECT NULL, CAST(NULL AS NUMBER) FROM dual` → `null`.

Expected: every column decodes to the documented Dart type (see usage-doc table).

## Phase V2 — Positional binds  ·  Status: TODO
Confirms the bind-metadata + ROW_DATA encode path on field version 12.

- [ ] `SELECT :1, :2, :3, :4 FROM dual` with binds `[42, 'hi', <DateTime>, null]`
      → values round-trip.
- [ ] Server-side filter: `SELECT :1 FROM dual WHERE :1 > :2` with `[5, 3]`.
- [ ] Appearance-order check: `SELECT :1, :2 FROM dual WHERE :2 = :1`.

Expected: binds encode/echo correctly; no ORA-03120 / ORA-01460.

## Phase V3 — DML + array DML + RETURNING  ·  Status: TODO
Uses `tc_probe`. Confirms the non-query execute path and row counts.

- [ ] Single INSERT via `executeDml` → rows affected = 1.
- [ ] Array DML (`bulkRows`, ~5 rows) → rows affected = 5.
- [ ] UPDATE with WHERE → rows affected correct.
- [ ] `executeReturning` `UPDATE ... RETURNING id INTO :n` → one value per row.
- [ ] `executeBatch` with a deliberate duplicate → `batchErrors` populated,
      valid rows applied.

Expected: counts correct; batch errors carry offset + ORA code.

## Phase V4 — LOBs (CLOB / BLOB)  ·  Status: TODO
Uses `tc_probe`. Confirms temp-LOB create/write + LOB read on field version 12.

- [ ] Oversized CLOB bind (> 32767 chars) via temp CLOB → stored, read back equal.
- [ ] Oversized BLOB bind (> 32767 bytes) via temp BLOB → stored, read back equal.
- [ ] `SELECT note, blob_col FROM tc_probe` → materialized `String` / `Uint8List`.

Expected: CLOB round-trips as UTF-16BE-decoded text; BLOB as raw bytes.

## Phase V5 — PL/SQL, OUT binds  ·  Status: TODO
Confirms the PL/SQL execute + IO-vector OUT decode on field version 12.

- [ ] Scalar OUT: `BEGIN :1 := :2 * 10; :3 := SYSTIMESTAMP; END;`.
- [ ] IN OUT bind round-trip.
- [ ] Known risk: oversized CLOB as a PL/SQL parameter (PLS-00306 on 23ai) —
      record 19c behavior, don't block.

Expected: `outBindValues` decode in declaration order.

## Phase V6 — REF CURSOR, nested & implicit results  ·  Status: TODO
Confirms the embedded describe (no version preamble) + fetch loop on 19c.

- [ ] `openRefCursor('BEGIN OPEN :1 FOR SELECT ... ; END;')` → rows.
- [ ] Nested `CURSOR(SELECT ...)` column → inner rows materialized.
- [ ] Implicit result via `DBMS_SQL.RETURN_RESULT` → `fetchImplicitResult`.
- [ ] Multiple REF CURSOR OUT binds in one call.

Expected: columns + rows for each; describe fields gated ≥17/≥20/≥24 stay off.

## Phase V7 — Teardown & write-up  ·  Status: TODO
- [ ] `DROP TABLE tc_probe PURGE`.
- [ ] Mark the verified matrix in
      [oracle-thick-client-spec-plan.md](oracle-thick-client-spec-plan.md)
      Phase T8 (which paths are now 19c-verified).
- [ ] Note any field-version-12 wire differences found (and fixes) in the usage
      doc's Server-compatibility section.

## Out of scope here (tracked separately)
- True pre-12c 11g accounts (legacy O5LOGON-only verifier).
- Statement-cache reuse, NLS/session-setting-aware decode, temp-LOB eager free.
- History rewrite to purge old internal identifiers from earlier commits.
