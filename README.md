# dart-db-server

A small SQLite-style SQL database server written in pure Dart. In-memory
storage with JSON file persistence, TCP server with a JSON line protocol,
and an interactive REPL.

> **What ships in the box**
>
> - Full SQL surface (DDL, DML, joins, CTEs, window functions, transactions).
> - Three storage backends: in-memory (JSON), out-of-core paged, SQLite
>   on-disk format.
> - **Vector database** — six index kinds (Flat / HNSW / IVFFlat / LSH / PQ
>   / IVFPQ), four metrics (l2 / l2sq / inner_product / cosine),
>   payload-filter pruning, range search, hybrid vector + BM25 retrieval.
> - **FTS5-lite** full-text search with BM25.
> - TCP server + JSON line protocol.
> - **MySQL wire compatibility** — ORMs like `mysql_client` connect
>   unchanged.

## Install

```yaml
dependencies:
  dart_db_server: ^0.1.0
```

## Run

```powershell
# Server + REPL, persisting to mydatabase.json
dart run bin/dart_db_server.dart --repl

# Server only on a custom port
dart run bin/dart_db_server.dart --port 4555 --file data.json

# Connect a client REPL to a running server
dart run bin/dart_db_client.dart --port 4555
```

## Use as a library

```dart
import 'package:dart_db_server/dart_db_server.dart';

final db = await Database.open('data.json');
await db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
await db.execute("INSERT INTO users VALUES (1, 'Alice')");
final r = await db.execute('SELECT * FROM users');
print(r.rows); // [[1, Alice]]
```

## Supported SQL

- **DDL**:
  - `CREATE TABLE [IF NOT EXISTS]` with column-level `PRIMARY KEY [AUTOINCREMENT]`,
    `NOT NULL`, `UNIQUE`, `DEFAULT`, `CHECK (...)`, `REFERENCES t(col) [ON DELETE/UPDATE ...]`.
  - Table-level constraints: `PRIMARY KEY (cols...)`, `UNIQUE (cols...)`,
    `CHECK (...)`, `FOREIGN KEY (cols...) REFERENCES t(col) [ON DELETE/UPDATE
    CASCADE | SET NULL | RESTRICT | NO ACTION]`.
  - `DROP TABLE [IF EXISTS]`, `TRUNCATE [TABLE] t`, `ALTER TABLE ... ADD COLUMN`.
  - `CREATE [UNIQUE] INDEX ... ON t(col)`, `DROP INDEX`.
  - `CREATE VIEW [IF NOT EXISTS] v AS SELECT ...`, `DROP VIEW [IF EXISTS]`.
- **DML**:
  - `INSERT [OR REPLACE | OR IGNORE] INTO ... VALUES (...) [, (...)]`,
    `REPLACE INTO ...` (alias of `INSERT OR REPLACE`).
  - `UPDATE`, `DELETE`.
  - `SELECT [DISTINCT] cols [FROM t [JOIN ... ON ...]] [WHERE ...]
    [GROUP BY ... [HAVING ...]] [ORDER BY ... [NULLS FIRST|LAST]]
    [LIMIT n] [OFFSET n] [UNION [ALL] | INTERSECT | EXCEPT ...]`.
  - `FROM` is optional (e.g. `SELECT 'foo' || 'bar'`).
- **Expressions**: `AND`/`OR`/`NOT`, comparisons (`=`, `!=`, `<>`, `<`, `<=`,
  `>`, `>=`), arithmetic (`+ - * /`), string `||`, `IS [NOT] NULL`,
  `[NOT] IN (list | SELECT ...)`, `[NOT] BETWEEN`, `LIKE` (`%`, `_`),
  `EXISTS (SELECT ...)`, scalar subqueries `(SELECT ...)`,
  `CASE WHEN ... THEN ... [ELSE ...] END` (simple and searched),
  `CAST(expr AS type)`, parentheses.
- **Aggregates**: `COUNT(*)`, `COUNT([DISTINCT] x)`, `SUM`, `AVG`, `MIN`, `MAX`
  with `GROUP BY` and `HAVING`.
- **Scalar functions**: `UPPER`, `LOWER`, `LENGTH`, `TRIM`/`LTRIM`/`RTRIM`,
  `SUBSTR`/`SUBSTRING`, `REPLACE`, `CONCAT`, `COALESCE`, `IFNULL`, `NULLIF`,
  `ABS`, `ROUND`, `MOD`.
- **Joins**: `INNER`, `LEFT [OUTER]`, `RIGHT [OUTER]`, `CROSS`.
- **Subqueries**: scalar, `IN (SELECT ...)`, `EXISTS (SELECT ...)` —
  correlated references to the outer query are supported.
- **Transactions**: `BEGIN`, `COMMIT`, `ROLLBACK` (snapshot isolation).
- **Types**: `INTEGER`, `REAL`, `TEXT`, `BOOLEAN`, plus `NULL`.
- **Introspection / utility**: `SHOW TABLES`, `DESCRIBE <table>`,
  `EXPLAIN <stmt>`, `PRAGMA name [= value]` (no-op acknowledgement).

> **Note on persistence:** tables (rows + schema + indexes + AUTOINCREMENT
> counters) round-trip through JSON. Views are best-effort and may not
> survive process restart in the current build.

## Vector database

`dart_db_server` ships a full vector-search engine wired into the SQL
surface. Six index kinds are available (`flat`, `hnsw`, `ivf`, `lsh`,
`pq`, `ivfpq`) with four metrics (`l2`, `l2sq`, `inner_product`,
`cosine`).

**Declare an index inline on the column:**

```sql
CREATE TABLE products (
  id INTEGER PRIMARY KEY,
  tenant INTEGER,
  kind TEXT,
  description TEXT,
  embedding BLOB VECTOR(
    dim=384,
    kind=hnsw,
    metric=cosine,
    m=16, ef_construction=64,
    filter_cols='tenant,kind'
  )
);
```

`filter_cols` opts into **payload-filter pruning**: the engine maintains
an inverse index (`col=value → row-position set`) and intersects
candidate rows in O(1) **before** touching the vector index. On a query
like `WHERE tenant = 3 AND kind = 'wearables' ORDER BY VEC_COSINE(...)
LIMIT 10`, this is often 10-100× faster than a plain over-fetch.

**k-NN via the planner fast path** — plain SQL, no TVF needed:

```sql
SELECT id, title
FROM products
WHERE tenant = 3 AND kind = 'wearables'
ORDER BY VEC_COSINE(embedding, VEC('[0.1, 0.4, ...]'))
LIMIT 10;
```

`EXPLAIN QUERY PLAN` shows the plan chose the built index:
```
SEARCH products USING VECTOR INDEX (hnsw) WITH FILTER
```

**k-NN via a table-valued function** — composable with joins and CTEs:

```sql
SELECT p.id, p.title, s.distance
FROM vec_search('products', 'embedding',
                VEC('[0.1, 0.4, ...]'), 10) AS s
JOIN products p ON p.id = s.rowid
ORDER BY s.distance;
```

**Filtered / range / hybrid / batch retrieval** — all available as TVFs:

| TVF                              | Purpose                                       |
| -------------------------------- | --------------------------------------------- |
| `vec_search`                     | Single-query k-NN                             |
| `vec_search_batch`               | Multi-query k-NN                              |
| `vec_search_filtered`            | k-NN with `filter_json` payload intersection  |
| `vec_search_filtered_batch`      | Batch variant of the above                    |
| `vec_range_search`               | All rows within a distance threshold          |
| `vec_range_search_batch`         | Batch variant of the above                    |
| `vec_hybrid_search`              | Fuse vector distance + BM25 via RRF           |
| `vec_hybrid_search_batch`        | Batch variant of the above                    |
| `vec_search_join`                | Row-to-row k-NN join between two tables       |
| `vec_batch_insert`               | Bulk insert (id, vec) pairs from JSON         |
| `vec_import_csv`                 | Bulk insert (id, vec) pairs from a CSV file   |

**Admin PRAGMAs:**

```sql
PRAGMA vector_index_list;              -- what's registered
PRAGMA vector_index_stats('t.col');    -- kind, n, live, tombstones, bytes
PRAGMA vector_verify('t.col');         -- consistency check vs t.rows
PRAGMA vector_verify_all;              -- verify every binding
PRAGMA vector_analyze('t.col');        -- top-k recall via random probes
PRAGMA vector_index_rebuild('t.col');  -- drop + reprime
PRAGMA vector_index_rebuild_all;       -- rebuild everything
PRAGMA vector_index_warm('t.col');     -- targeted async warm (paged)
PRAGMA vector_index_warm_all;          -- warm every binding
PRAGMA fts5_warm('t.col');             -- warm FTS5 corpus (paged)
```

For an end-to-end walkthrough — seed, k-NN, filtered k-NN, range,
hybrid, batch, EXPLAIN, and PRAGMAs — see
[`example/vector_semantic_search.dart`](example/vector_semantic_search.dart).
Run it with:

```powershell
dart run example/vector_semantic_search.dart
```

Deeper real-world recipes live in [`doc/`](doc/README.md):

- [RAG semantic search](doc/rag-semantic-search.md) — retrieval-augmented Q&A over a document corpus.
- [Multi-tenant search](doc/multi-tenant-search.md) — payload-filter pruning for SaaS.
- [Hybrid vector + BM25](doc/hybrid-search.md) — RRF fusion for lexical + semantic ranking.
- [Recommendations](doc/recommendations.md) — collaborative filtering with `vec_search_join`.
- [Duplicate detection](doc/duplicate-detection.md) — threshold-based range search.
- [Index selection](doc/index-selection.md) — which of the six index kinds to pick.
- [Operations](doc/operations.md) — warming, verifying, rebuilding, and monitoring.

## Wire protocol

Each TCP client sends one JSON object per line and receives one JSON
object per line in response.

```jsonc
// request
{"id": 1, "sql": "SELECT * FROM users"}
// response
{"id": 1, "ok": true, "columns": ["id","name"], "rows": [[1,"Alice"]], "affected": 1}
```

## Layout

```
bin/
  dart_db_server.dart     # server entry point (TCP + optional REPL)
  dart_db_client.dart     # CLI client REPL
lib/
  dart_db_server.dart     # public library exports
  server/
    schema.dart           # types, ColumnDef, coercion
    expression.dart       # WHERE/HAVING expression AST + evaluator
    statement.dart        # parsed SQL statement nodes
    lexer.dart            # SQL tokenizer
    parser.dart           # recursive-descent SQL parser
    table.dart            # row storage + ordered indexes + JSON I/O
    database.dart         # tables, transactions, executor, persistence
    result.dart           # QueryResult
    server.dart           # TCP server (JSON line protocol)
    client.dart           # TCP client
test/
  db_server_test.dart     # core test suite
  sql_features_test.dart  # extended SQL surface (aggregates, subqueries, FK, ...)
```

The legacy experimental files (`lib/parser{,2..9}.dart`, `lib/gpt*.dart`,
`lib/database_engine/*`, etc.) remain as historical references and are
**not** used by the active server.

## Test

```powershell
dart test
```


## Known limitations vs SQLite

This engine targets SQL surface compatibility, not byte-for-byte SQLite parity.
The following SQLite features are intentionally out of scope and will not be
implemented:

- **Storage engine**: no B-tree pages, no page cache, no mmap. JSON-backed
  databases re-serialise the whole document on every mutation; SQLite-format
  databases (`.sqlite` / `.db`) write incremental `-wal` page diffs and
  auto-checkpoint when the change ratio exceeds 75%.
- **Crash safety**: every persist (JSON or SQLite-format, main file or
  `-wal`) goes through `<path>.tmp` + fsync + atomic rename, so a crash
  mid-write leaves the previous good file fully intact. Stale `.tmp`
  siblings from a crashed writer are reaped on the next `Database.open`.
  There is still no per-statement journal, so an uncommitted in-memory
  transaction is lost if the process dies before `_persist` runs.
- **Concurrency**: a sidecar `<path>.lock` file gives best-effort
  cross-process advisory locking via `RandomAccessFile.lock()` (shared
  for readers, exclusive for writers); within a process an
  `AsyncRwLock` serialises executor mutations. There is no internal
  MVCC — readers see the writer's committed state.
- **SQLite C API & file format**: paths ending in `.sqlite`, `.sqlite3`,
  or `.db` are read and written in the real SQLite on-disk format
  (validated by package:sqlite3 round-trip tests). The SQLite C API
  itself is not linked.
- **Out-of-core datasets**: regular SQL tables still load into RAM,
  but you can now opt a single table into the out-of-core backend with
  `CREATE TABLE name (...) USING paged` (path-backed databases only).
  Such a table is stored as `<dbpath>.paged/<name>.{heap,idx,meta.json}`,
  is opened on demand from disk through an LRU page cache + B+-tree
  index + slotted-page row heap with a crash-safe undo journal, and is
  not loaded into the in-memory `_tables` map. The SQL surface for
  paged tables currently supports: INSERT VALUES; arbitrary `WHERE`
  predicates (PK comparisons `= < <= > >=`, `BETWEEN`, and AND-chains
  drive an index range; everything else — non-PK `=`, `LIKE`, `IN`,
  `IS NULL`, OR-trees, function calls — is evaluated row-by-row as a
  residual post-filter); `ORDER BY <pk> [ASC|DESC]` paired with
  `LIMIT` / `OFFSET`; `COUNT(*)`; scalar projection expressions
  (`SELECT id + 1, upper(name) FROM t`); bulk UPDATE / DELETE under
  the same predicates; `DROP TABLE`, `TRUNCATE TABLE`, and `DESCRIBE`.
  Secondary indexes are supported via
  `CREATE INDEX idx ON t(col1, col2, ...)` / `DROP INDEX idx`,
  including composite indexes. Equality predicates on indexed columns
  (`WHERE col = literal`, or a leading-column equality prefix) are
  routed through the index, and an equality prefix followed by a
  range comparison (`<`, `<=`, `>`, `>=`, or `BETWEEN`) on the next
  indexed column drives an index range scan; remaining residual
  conjuncts are re-applied per row. `GROUP BY`, `HAVING`, and the
  full aggregate set (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, including
  `COUNT(DISTINCT ...)`) work on paged tables. `INSERT … SELECT`
  (including self-referential `INSERT INTO t SELECT … FROM t`) and
  `RETURNING` on `INSERT` / `UPDATE` / `DELETE` are supported.
  Multi-statement transactions (`BEGIN … COMMIT/ROLLBACK`) atomically
  cover paged-table writes via per-file undo journals; paged DDL
  (`CREATE TABLE USING paged`, `CREATE/DROP INDEX`, `DROP TABLE`,
  `TRUNCATE`) is rejected inside a transaction, and paged DML is
  rejected while a `SAVEPOINT` is open. Joins involving paged tables
  (any combination of `INNER` / `LEFT` / `RIGHT` / `FULL` / `CROSS` /
  `NATURAL` / `USING`, including joins between two paged tables)
  work by snapshotting each paged participant into a transient
  in-memory table; when the query is an equi-join between exactly
  one paged participant and an in-memory partner, the planner
  restricts that snapshot to rows whose join-key value appears on
  the in-memory side (via primary-key lookup, secondary-index
  lookup, or filtered scan, whichever applies), so the out-of-core
  benefit is preserved on selective joins. `CREATE UNIQUE INDEX` on
  paged tables is supported (NULL components don't participate in the
  constraint, matching SQLite); expression and partial indexes on
  paged tables raise `UnsupportedError`; so do triggers. `UPDATE …
  SET pk = …` reassigns the primary key on paged tables (rejected on
  collision with another existing row, or on NULL). `INSERT OR
  IGNORE`, `INSERT OR REPLACE` (including the `REPLACE INTO …`
  alias), and `INSERT … ON CONFLICT (cols) DO NOTHING | DO UPDATE
  SET … [WHERE …]` are supported on paged tables and respect both PK
  and UNIQUE-index conflicts. The lower-level `PagedTable` API in
  `lib/server/paged_table.dart` exposes the full primitives directly.
- **SQLite wire protocol**: clients speak this engine's JSON line protocol,
  not SQLite's native protocol.
- **Production-grade FTS5 / R*Tree**: `CREATE VIRTUAL TABLE ... USING fts5`n  and `USING rtree` are accepted and create regular tables; `MATCH` does a
  simple case-insensitive AND-of-substrings match. There is no inverted
  index, ranking, tokenizer plug-in system, BM25, or true R*Tree spatial index.
- **Cost-based query planner**: a single-column `col = literal` index
  fast-path is implemented, but there is no statistics-driven join
  reordering, automatic index creation on join keys, or index-only scans.
- **Cross-database transactions**: ATTACH-ed databases share the same
  transaction scope; there is no two-phase commit.
- **Per-page encryption (SEE / SQLCipher)** and **online backup API**.

