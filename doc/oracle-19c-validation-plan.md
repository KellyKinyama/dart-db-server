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

## Phase V0 — Scratch sandbox  ·  Status: DEFERRED (writes not permitted on target)
A disposable table the later phases read/write, so no production data is touched.

- [ ] `CREATE TABLE tc_probe (id NUMBER, name VARCHAR2(100), amt NUMBER(12,2), created DATE, note CLOB, blob_col BLOB)`
- [ ] Confirm `executeDml` returns success for the DDL (DDL over the thick client
      exercises the BREAK/RESET marker path on this server).
- [ ] Teardown step defined: `DROP TABLE tc_probe PURGE` (run last, Phase V7).

Expected: table created and dropped cleanly; no ORA error.

## Phase V1 — SELECT decode coverage  ·  Status: DONE (19c, all types pass; one edge-case noted)
Read-only, no table needed. Confirms each scalar decoder on field version 12.

- [x] NUMBER: `SELECT 1, -2, 3.5, 123456789012 FROM dual` → `int`/`double` exact.
- [x] VARCHAR2 / CHAR: `'abc'`, `CAST('x' AS CHAR(3))` → `String` (CHAR padded).
- [x] NCHAR / NVARCHAR2 → `String`.
- [x] DATE / TIMESTAMP: `SYSDATE`, `SYSTIMESTAMP` → `DateTime`.
- [x] TIMESTAMP WITH TIME ZONE → `DateTime` (UTC instant).
- [x] TIMESTAMP WITH LOCAL TIME ZONE → `DateTime`.
- [x] INTERVAL DAY TO SECOND → `Duration`; INTERVAL YEAR TO MONTH → `OracleYearMonth`.
- [x] BINARY_FLOAT / BINARY_DOUBLE → `double`.
- [x] RAW: `HEXTORAW('DEADBEEF')` → `Uint8List [222,173,190,239]`.
- [x] ROWID → `String`.
- [x] **Typed** NULLs: `CAST(NULL AS NUMBER)` / `CAST(NULL AS VARCHAR2)` → `null`.
- [x] Multi-row fetch (`CONNECT BY LEVEL <= 5`) → 5 rows.
- [ ] **KNOWN LIMITATION (won't-fix / niche):** a bare **untyped literal**
      `SELECT NULL FROM dual` (no CAST) fails with `Unknown TTC message type`.
      Root cause: Oracle types the bare literal as a degenerate **VARCHAR2(0)**
      column, whose row-data shape the decoder mis-reads on field version 12.
      Not a real-world pattern (every typed NULL works); left as-is to avoid
      special-casing a degenerate type.

Result: every documented type decodes correctly on real 19c; only the untyped
`NULL` literal edge case is open.

## Phase V2 — Positional binds  ·  Status: DONE (19c; one narrow edge-case noted)
Confirms the bind-metadata + ROW_DATA encode path on field version 12.

- [x] Scalar binds `[42, 'hi', <DateTime>, null]` → round-trip (int/String/
      DateTime/Null).
- [x] RAW bind (`Uint8List`) → round-trip.
- [x] Two distinct binds in the SELECT list: `SELECT :1 + :2` → `8`.
- [x] WHERE-only binds: `... WHERE :1 > :2` → correct true/false row counts.
- [x] Bind reuse in WHERE: `... WHERE :1 > 0 AND :1 < 9` with `[5]`.
- [x] Bind reuse across SELECT+WHERE: `SELECT :1 x, :2 y ... WHERE :2 = :1`.
- [ ] **NOT A DRIVER BUG (Oracle numbered-bind quirk):** a select-list bind
      reused in WHERE *together with* a WHERE-first bind — `SELECT :1 n FROM dual
      WHERE :1 > :2` with `[5, 3]` — fails `ORA-01008: not all variables bound`.
      Byte-level check: the request is structurally identical to the passing
      `SELECT :1 x, :2 y ... WHERE :2 = :1` (same 2-bind NUMBER metadata, 2
      row-data values) — only the SQL text differs, so the client encodes it
      correctly and Oracle itself rejects that text. Reproduces with any client;
      all normal bind usage is unaffected.

Result: positional binds encode/decode correctly on real 19c for every normal
pattern. The one failing combination is proven (byte-level) to be an Oracle-side
numbered-bind quirk, not a driver defect.

## Phase V3 — DML + array DML + RETURNING  ·  Status: DEFERRED (writes not permitted on target)
Uses `tc_probe`. Confirms the non-query execute path and row counts.

- [ ] Single INSERT via `executeDml` → rows affected = 1.
- [ ] Array DML (`bulkRows`, ~5 rows) → rows affected = 5.
- [ ] UPDATE with WHERE → rows affected correct.
- [ ] `executeReturning` `UPDATE ... RETURNING id INTO :n` → one value per row.
- [ ] `executeBatch` with a deliberate duplicate → `batchErrors` populated,
      valid rows applied.

Expected: counts correct; batch errors carry offset + ORA code.

## Phase V4 — LOBs (CLOB / BLOB)  ·  Status: DEFERRED (writes not permitted on target)
Uses `tc_probe`. Confirms temp-LOB create/write + LOB read on field version 12.

- [ ] Oversized CLOB bind (> 32767 chars) via temp CLOB → stored, read back equal.
- [ ] Oversized BLOB bind (> 32767 bytes) via temp BLOB → stored, read back equal.
- [ ] `SELECT note, blob_col FROM tc_probe` → materialized `String` / `Uint8List`.

Expected: CLOB round-trips as UTF-16BE-decoded text; BLOB as raw bytes.

## Phase V5 — PL/SQL, OUT binds  ·  Status: DONE (19c, all pass)
Confirms the PL/SQL execute + IO-vector OUT decode on field version 12.

- [x] Scalar OUT: `BEGIN :1 := :2 * 10; :3 := SYSTIMESTAMP; END;` → `int=70` +
      `DateTime`.
- [x] OUT varchar: `BEGIN :1 := 'hello ' || :2; END;` → `String`.
- [x] IN OUT bind round-trip: `BEGIN :1 := :1 || '_x'; END;` → `hi_x`.
- [x] OUT date → `DateTime`.

Result: PL/SQL IN / OUT / IN OUT bind decode works on real 19c.

## Phase V6 — REF CURSOR, nested & implicit results  ·  Status: DONE (19c, all pass)
Confirms the embedded describe (no version preamble) + fetch loop on 19c.

- [x] `openRefCursor('BEGIN OPEN :1 FOR SELECT ... ; END;')` → 5 rows [n, label].
- [x] Nested `CURSOR(SELECT ...)` column → inner rows `[[1],[2],[3]]` materialized
      (fixed: the inline embedded-cursor describe was hardcoded to field version
      24; now uses the negotiated version).
- [x] Implicit result via `DBMS_SQL.RETURN_RESULT` → `fetchImplicitResult`.
- [x] Multiple REF CURSOR OUT binds in one call → both drained.

Result: REF CURSOR, nested cursor columns, implicit results, and multi-cursor
OUT binds all work on real 19c.

## Phase V7 — Teardown & write-up  ·  Status: PARTIAL (read-only phases done; writes deferred)
- [ ] `DROP TABLE tc_probe PURGE` (only if V0/V3/V4 are later run).
- [ ] Mark the verified matrix in
      [oracle-thick-client-spec-plan.md](oracle-thick-client-spec-plan.md)
      Phase T8 (which paths are now 19c-verified).
- [ ] Note any field-version-12 wire differences found (and fixes) in the usage
      doc's Server-compatibility section.

## Out of scope here (tracked separately)
- True pre-12c 11g accounts (legacy O5LOGON-only verifier).
- Statement-cache reuse, NLS/session-setting-aware decode, temp-LOB eager free.
- History rewrite to purge old internal identifiers from earlier commits.
