# dart-db-server

A small SQLite-style SQL database server written in pure Dart. In-memory
storage with JSON file persistence, TCP server with a JSON line protocol,
and an interactive REPL.

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

- **Storage engine**: no B-tree pages, no page cache, no WAL, no mmap.
  Persistence is a single JSON document re-serialised on every mutation.
- **Crash safety**: no journal, no rollback log, no fsync ordering guarantees.
- **Concurrency**: no multi-process locking and no internal MVCC; the engine
  assumes a single writer at a time.
- **SQLite C API & file format**: not produced or consumed; database files
  are not interchangeable with sqlite3.
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

