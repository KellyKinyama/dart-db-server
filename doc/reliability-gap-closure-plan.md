# Reliability gap-closure plan

A living, prioritized plan to close the engine bugs surfaced by the reliability
harness in
[`dart-db-reliability/findings/FINDINGS.md`](../../dart-db-reliability/findings/FINDINGS.md)
(18 confirmed bugs, F1–F18, each pinned by a skipped `KNOWN ENGINE BUG`
regression guard). Severity and repro come from that report; the **root cause**,
**location**, and **approach** here are grounded in this engine's code.

## How to use this file
- Work top-down: **P0 (data loss / silent wrong results) first.** Several bugs
  share a root cause — fix the family, not the symptom.
- For each item: un-skip its `KNOWN ENGINE BUG` guard, implement, and confirm the
  guard passes plus the differential/fuzz suites stay green
  (`dart run bin/scorecard.dart` in `dart-db-reliability`).
- Update **Status** as you go; move finished items to "Landed".

## Status legend
`TODO` · `WIP` · `LANDED (<commit>)` · `WON'T` (with reason).

## Engine code map (where the fixes live)
- Boolean / arithmetic eval: `lib/server/expression.dart` → `BinaryExpr.eval`
  (AND/OR at ~L275; arithmetic casts just below).
- UPDATE write path: `lib/server/database.dart` → `_update` (L5628) and
  `_pagedUpdate` (L4249).
- INSERT / constraint checks: `database.dart` constraint helpers
  (`_deferredCheckTables`, CHECK/UNIQUE/PK validation).
- Persistence: `database.dart` → `_persist` (L16408) / `_persistLocked` (L16414)
  / `_persistSqlite` (L16687).
- Views: `database.dart` view resolution / expansion.
- Lexer: `lib/server/lexer.dart`. Parser: `lib/server/parser.dart`.

---

## P0 — critical: data loss & silently wrong results

### F7 · Broken three-valued logic (NULL-left AND/OR)
- **Bug:** `BinaryExpr.eval` returns `NULL` whenever the **left** operand is
  `NULL`, without checking a decisive right operand — `NULL OR 1=1` yields `NULL`
  instead of `TRUE`, `NULL AND 1=0` yields `NULL` instead of `FALSE`. Corrupts
  any `WHERE`/`CASE`/`CHECK`/`HAVING` with a NULL-producing predicate left of a
  decisive operand (fuzzer: 1173 divergences / 32k queries).
- **Root cause (confirmed):** after the short-circuit checks, the code does
  `final r = right.eval(row); if (l == null || r == null) return null;` — it
  never applies `AND`'s *false-dominates* / `OR`'s *true-dominates* rule to `r`.
- **Approach:** replace the tail with full Kleene logic:
  `AND` → `false` if either operand is `false`, else `null` if either is `null`,
  else `true`; `OR` → `true` if either is `true`, else `null` if either is
  `null`, else `false`. Keep the left short-circuit as an optimization.
- **Verify:** F7 guard truth table; re-enable `fuzz/random_differential_fuzz_test.dart`.
- **Effort:** S. **Status:** LANDED (batch 1).

### F15 · Persistence is not crash-atomic (committed data lost)
- **Bug:** `flush()`/persist rewrites the data file **in place**; a hard kill
  mid-rewrite leaves it truncated, so reopen loses already-committed rows
  (intermittent, both JSON and SQLite backends).
- **Root cause:** `_persistLocked` / `_persistSqlite` write directly over the
  target path with no temp-file-plus-atomic-rename and no fsync ordering.
- **Approach:** write to a sibling temp file, `fsync` it, atomically `rename`
  over the target, then `fsync` the directory. Apply to **both** backends and the
  vector-index sidecar. (SQLite-format backend: ensure WAL/journal ordering, or
  reuse the same temp-rename for the whole-file rewrite.)
- **Verify:** `durability/crash_recovery_test.dart` (un-skip) + `durability_worker.dart`.
- **Effort:** M. **Status:** TODO.

---

## P1 — integrity: constraints & atomicity (silent corruption)

### Family A — constraints not enforced on the UPDATE write path (F1, F10)
- **F1** CHECK and **F10** UNIQUE are validated on INSERT but **not on UPDATE**
  (`_update` / `_pagedUpdate` skip the constraint pass), so `UPDATE t SET age=-1`
  or setting a duplicate `UNIQUE` value is wrongly accepted.
- **Approach:** factor the INSERT-side constraint validation (CHECK + UNIQUE +
  PK + FK) into one `_validateRow(table, newRow, {excludingRowId})` and call it
  from the UPDATE paths for each modified row (UNIQUE/PK must exclude the row
  being updated). Honour `defer_checks` the same way.
- **Verify:** `constraints/constraints_test.dart` (F1), `constraint_write_paths_test.dart` (F10).
- **Effort:** M. **Status:** LANDED (batch 3).

### F2 · Composite PRIMARY KEY does not enforce uniqueness
- **Bug:** a duplicate composite key `(1,1)` is accepted; the uniqueness index
  keys on a single column (or not at all) for multi-column PKs.
- **Approach:** build the PK uniqueness check over the **tuple** of PK columns
  (same `_validateRow` path as Family A); add a composite index/lookup.
- **Verify:** `constraints/constraints_test.dart` (composite PK).
- **Effort:** M. **Status:** LANDED (batch 3).

### F14 · Multi-row INSERT / batch write is not statement-atomic
- **Bug:** `INSERT … VALUES (2),(3),(1),(4)` where `1` violates the PK leaves
  `2,3` committed. A failed statement must roll back entirely.
- **Approach:** stage all rows of a statement, validate the whole batch, and
  commit only if every row passes (or wrap the statement in an implicit
  savepoint and roll back on any failure). Same for mid-batch CHECK failures.
- **Verify:** `constraints/constraint_write_paths_test.dart` (F14).
- **Effort:** M. **Status:** LANDED (batch 3). *(Shares the `_validateRow` work above.)*

### F9 · Division by zero yields `Infinity` instead of `NULL`
- **Bug:** real division leaks IEEE `Infinity` into results/stored data.
- **Approach:** in `BinaryExpr.eval` for `/` (and `%`), return `NULL` when the
  divisor is `0`/`0.0` (SQLite semantics) before performing the division.
- **Verify:** F9 guard. **Effort:** S. **Status:** LANDED (batch 1).

---

## P2 — internal exception leaks on valid SQL (crash instead of result)

Same family: unguarded `as num` casts in `BinaryExpr`. A fuzz run hit the text
case **1991×**, so this is pervasive, not an edge.

### F6 · `'abc' + 0` throws `String is not a subtype of num`
### F12 · `(a>0) - (a<0)` throws `bool is not a subtype of num`
- **Approach:** add one `_toNum(Object?)` coercion used by every arithmetic
  branch in `BinaryExpr.eval`: `num`→itself, `bool`→`1/0`, numeric `String`→
  parsed value, non-numeric `String`→`0` (SQLite) , `null`→`null` (propagate).
  Never cast raw with `as num`.
- **Verify:** F6 and F12 guards; re-run the arithmetic fuzz slice.
- **Effort:** S–M. **Status:** LANDED (batch 1).

### F11 · Lexer applies C-style `\` escaping in single-quoted strings
- **Bug:** `'\'` / `LIKE '100\%' ESCAPE '\'` → `Unterminated string`. SQL
  escapes a quote by doubling (`''`); `\` is a literal backslash.
- **Approach:** in the string scanner (`lexer.dart`), stop treating `\` as an
  escape; only `''` closes-and-continues. (Keep any MySQL `\`-escape behind a
  mode flag if needed for that dialect.)
- **Verify:** F11 guard. **Effort:** S. **Status:** LANDED (batch 1).

---

## P3 — correctness (wrong results, not crashes)

### F16 · View over a JOIN — output columns not exposed
### F17 · View projecting `alias.*` leaks the inner alias
- **Approach:** at `CREATE VIEW`, resolve and **freeze the view's output column
  list** (expand `a.*`/`alias.*` against the view's own FROM at creation time),
  and expose those names to the outer query instead of re-resolving the inner
  aliases. Fixes both.
- **Verify:** `sql_features/views_test.dart` (F16, F17). **Effort:** M. **Status:** LANDED (batch 4).

### F4 · Correlated subquery binds outer ref to inner table on base-name clash
- **Bug:** `… FROM s x WHERE x.g = s.g` inside a scan over `s` binds `s.g` to the
  inner `s` (ignoring the alias), losing the correlation; distinct aliases work.
- **Approach:** scope name resolution by **alias**, not base table name; an outer
  unqualified/base-qualified reference must resolve to the outer range, and the
  inner alias must shadow only itself.
- **Verify:** F4 guard. **Effort:** M. **Status:** TODO.

### F3 · Date month-underflow doesn't decrement the year
- **Bug:** `date('2021-01-01','-1 month')` → `2021-12-01` (should be `2020-12-01`).
- **Approach:** in the month-arithmetic helper, carry the year when the month
  index underflows below 1 (and overflows above 12) via floor-div / mod on a
  zero-based month.
- **Verify:** F3 guard. **Effort:** S. **Status:** LANDED (batch 1).

### F13 · `ORDER BY agg DESC` mis-sorts a NULL group key
- **Bug:** a NULL group sorts to the front regardless of its aggregate value.
- **Approach:** in the sort comparator, order by the aggregate first (NULLs last
  for DESC per the engine's NULL-ordering rule), then the group key — don't let a
  NULL group short-circuit the primary key comparison.
- **Verify:** F13 guard. **Effort:** S. **Status:** LANDED (batch 2).

---

## P4 — dialect parity (nice-to-have; standard SQL doesn't require these)

### F5 · `GROUP BY` / `ORDER BY` can't reference a SELECT-list alias
- MySQL/SQLite allow it (Oracle/standard don't). **Approach:** when resolving a
  GROUP BY / ORDER BY identifier that isn't a column, check the SELECT-list
  aliases before erroring. **Effort:** S. **Status:** TODO.

### F18 · `HAVING` without `GROUP BY` is a parse error
- **Approach:** accept `HAVING` with no `GROUP BY` and apply it to the implicit
  single group. **Effort:** S. **Status:** TODO.

### F8 · `SUBSTR` negative length
- SQLite returns the character(s) preceding the start; the engine returns `''`.
  **Approach:** support negative length by walking backward from `start`.
  **Effort:** S. **Status:** TODO.

---

## Suggested sequencing (batches)
1. **Quick, high-value P0/P1 scalars:** F7, F9, F3, F13 — all small, in
   `expression.dart` / the date+sort helpers.
2. **Exception-leak family:** F6 + F12 (shared `_toNum`), then F11 (lexer).
3. **Write-path integrity family:** F1 + F10 + F2 + F14 (shared `_validateRow`
   + batch staging).
4. **Durability:** F15 (temp-file + atomic rename + fsync, both backends).
5. **Views:** F16 + F17 (freeze view output columns). Then F4 (alias scoping).
6. **Parity:** F5, F18, F8.

## Deliberately out of scope here
Dialect differences D1–D5 in the findings are **not** bugs (engine matches
MySQL/Oracle); they stay recorded in the differential suite, not fixed.

## Landed

### Batch 1 — scalar correctness & exception-leak fixes (`expression.dart`, `lexer.dart`)
Reliability scorecard: 211 pass / 19 skip / 0 fail (was 205 / 25); all six
un-skipped guards green; 99 targeted engine unit tests green.
- **F7** three-valued logic: `BinaryExpr.eval` AND/OR now applies full Kleene
  rules (`false`/`true` dominates even when the other operand is `NULL`).
- **F9** division/modulo by zero returns `NULL` instead of IEEE `Infinity`.
- **F6 / F12** arithmetic operands coerced through a shared `_toNum`
  (num→self, bool→1/0, numeric string→parsed, other→0) — no more raw
  `as num` casts leaking `String/bool is not a subtype of num`.
- **F3** `date(ts, '±N month')` carries the year on under/overflow via floor
  division (`~/` truncated toward zero and kept the year).
- **F11** lexer no longer applies C-style `\` escaping in single-quoted
  strings — only `''` escapes a quote (SQL standard).

### Batch 2 — aggregate ORDER BY (`database.dart`)
Reliability scorecard: 212 pass / 18 skip / 0 fail; 160 group/order/aggregate
unit tests green.
- **F13** `ORDER BY <aggregate>` that is **not** projected is now computed per
  group in `_runAggregate` (stashed as `__orderagg<n>` in the group context)
  and resolved by the post-aggregation sort — previously the comparator saw a
  single group row, couldn't recompute the aggregate, treated all groups as
  tied, and let the secondary key drive the order (NULL group to the front).

### Batch 3 — write-path integrity: validate before mutate (`database.dart`)
Reliability scorecard: 219 pass / 11 skip / 0 fail; full 1580-test engine suite
green. Root cause for F1/F10 was **mutate-before-validate**: `_update` wrote
`t.rows[ri]` in place and only failed at the end (`_rebuildIndexes`) or after the
row was already corrupted.
- **F1 / F10** UPDATE now builds a row copy, runs CHECK + vector-dim + FK +
  UNIQUE/PK validation on it (`_assertRowUniqueExcluding`), and commits in place
  only if it passes — a violation rejects the row and leaves stored data intact.
- **F2** composite PRIMARY KEY / UNIQUE tuples (no row-store index) are now
  checked explicitly via `_assertNoCompositeConflict` on the plain INSERT path.
- **F14** plain INSERT is statement-atomic: the row loop is wrapped so any
  failure (CHECK, FK, single- or composite-key duplicate) rolls back rows the
  statement already committed. OR IGNORE / OR REPLACE / UPSERT keep their
  per-row conflict semantics and are excluded from the rollback.

### Batch 4 — views expose SQLite-style columns (`database.dart`)
Reliability scorecard: 223 pass / 7 skip / 0 fail; `sql_features` 34/0; full
1580-test engine suite green.
- **F16** a view's public column names are now unqualified (`_viewPublicColumns`
  strips the inner `alias.`/`table.` prefix from projection labels), so
  `SELECT id FROM v` resolves instead of leaking `a.id`. The engine keeps
  qualified labels *internally* to avoid map-key collisions on joins, so the
  fix is scoped to the view's materialized output, mirroring a derived table.
- **F17** `SELECT alias.*` now resolves the qualifier as a FROM/JOIN **alias**
  (`_starColumns`) before falling back to a table name — `SELECT e.* FROM emp e`
  (directly or inside a view) no longer throws `No such table or view: e`.
