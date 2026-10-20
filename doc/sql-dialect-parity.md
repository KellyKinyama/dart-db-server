# SQL dialect & wire parity

How the single SQL engine in `dart_db_server` lines up against **Oracle** and
**MySQL** — both at the wire-protocol level and at the SQL-surface level.

> **One engine, two front-ends.** Every statement, function, and type below is
> executed by the same core ([`lib/server/database.dart`](../lib/server/database.dart),
> [`lib/server/expression.dart`](../lib/server/expression.dart)). The Oracle TTC
> server ([`oracle_wire.dart`](../lib/server/oracle_wire.dart)) and the MySQL
> classic-protocol server ([`mysql_wire.dart`](../lib/server/mysql_wire.dart))
> are thin translation layers over it. A feature added to the engine is
> therefore available to clients of **both** protocols at once.

The dialect is SQLite-rooted (the parser/engine started from a SQLite-compatible
core) with Oracle and MySQL compatibility layered on top. Where the three
dialects disagree on syntax, the parser accepts all of the common spellings.

---

## 1. Wire-protocol parity

| Capability | Oracle (TTC/TNS) | MySQL (classic) |
| --- | --- | --- |
| Handshake + auth | 11g O5LOGON, 12c PBKDF2 verifier (`0x4815`), FAST_AUTH | `mysql_native_password`, `caching_sha2_password` |
| TLS | server-side upgrade implemented; **real-client TLS blocked by a client-SDK bug** | ✅ `SSLRequest` upgrade, works with real clients |
| Prepared statements | ✅ TTC execute, bind/define | ✅ `COM_STMT_PREPARE/EXECUTE/CLOSE/RESET` (binary protocol) |
| Result sets | ✅ describe + row data, ref cursors, nested cursors, implicit result sets | ✅ text protocol + binary protocol |
| Array / batch DML | ✅ execute-many, array binds, DML-returning, row-level batch errors | via multi-statement |
| Large-SDU framing | ✅ (TNS ≥ 315, 4-byte DATA length) | n/a |
| LOB streaming | ✅ temp LOBs, chunked transfer, `ttcLobOp` | n/a (values inline) |
| Multi-statement | n/a | ✅ `CLIENT_MULTI_STATEMENTS` |
| Compression | ❌ | ❌ |
| Proprietary extras | — | ❌ X protocol (DevAPI, port 33060) |
| Real third-party driver test | ✅ `oracledb` (Node) over the wire | ✅ `package:mysql_client` (Dart) |

Validated against **Oracle 23ai + 21c** and the **`mysql_client`** driver.

---

## 2. Statement coverage (shared engine)

| Category | Supported |
| --- | --- |
| DQL | `SELECT` (joins, subqueries, correlated subqueries, `WITH`/`WITH RECURSIVE` CTEs, set ops `UNION`/`INTERSECT`/`EXCEPT`, `GROUP BY` + `ROLLUP`/`CUBE`/`GROUPING SETS`, `HAVING`, window functions, `DISTINCT`) |
| DML | `INSERT` (multi-row, `INSERT … SELECT`), `UPDATE` (incl. `… FROM`), `DELETE`, **`MERGE`**, `RETURNING`, UPSERT (`ON CONFLICT`, `ON DUPLICATE KEY UPDATE`) |
| DDL | `CREATE/DROP/ALTER TABLE`, `CREATE/DROP INDEX` (incl. partial, expression, multi-column), `VIEW`, `TRIGGER`, **`SEQUENCE`**, virtual tables (FTS5, R-tree, vector) |
| Transactions | `BEGIN`/`COMMIT`/`ROLLBACK`, `SAVEPOINT`/`RELEASE`/`ROLLBACK TO`, snapshot isolation |
| Admin / meta | `PRAGMA`, `EXPLAIN [QUERY PLAN]`, `ANALYZE`, `VACUUM`, `REINDEX`, `ATTACH`/`DETACH`, `SHOW`/`USE`/`SET`/`DESCRIBE` (MySQL surface) |

Row limiting accepts every dialect's spelling: `LIMIT [offset,] n` / `LIMIT n
OFFSET m` (MySQL/SQLite), `OFFSET n ROWS FETCH FIRST m ROWS ONLY` (SQL
standard / Oracle 12c+), and `WHERE ROWNUM <= n` (Oracle legacy).

---

## 3. Oracle compatibility

### Idioms
| Feature | Status | Notes |
| --- | --- | --- |
| `DUAL` one-row table | ✅ | synthesized unless a real `DUAL` exists |
| `ROWNUM` | ✅ | `WHERE ROWNUM <= n` → limit; in the select list → numbered rows (lowered to `ROW_NUMBER() OVER ()`) |
| `SEQUENCE` + `seq.NEXTVAL` / `seq.CURRVAL` | ✅ | `START WITH`/`INCREMENT BY`/`MIN`/`MAXVALUE`/`CYCLE`; non-transactional like Oracle |
| `MERGE INTO … USING … ON …` | ✅ | `WHEN MATCHED THEN UPDATE [WHERE]`, `WHEN NOT MATCHED THEN INSERT [WHERE]`, table or subquery source |
| `(+)` outer-join operator | ✅ | comma joins → CROSS; `(+)` rewrites to LEFT/RIGHT (3+-table chains best-effort) |
| `FETCH FIRST … ROWS ONLY` / `OFFSET … ROWS` | ✅ | `WITH TIES` ≈ `ONLY` |
| `CONNECT BY` hierarchical queries | ✅ | `PRIOR`, `LEVEL`, `CONNECT_BY_ISLEAF`, `START WITH`, `ORDER SIBLINGS BY`, cycle guard (`SYS_CONNECT_BY_PATH` / `CONNECT_BY_ROOT` deferred) |
| PL/SQL anonymous blocks + `CREATE PROCEDURE`/`FUNCTION` | ✅ | `DECLARE`/`:=`/`IF`-`ELSIF`/`WHILE`/`FOR lo..hi`/`LOOP`+`EXIT`/`SELECT INTO`/`DBMS_OUTPUT`; stored FUNCTIONs callable in expressions (`SELECT f(x)`, `WHERE`, nested); `EXCEPTION` + cursors deferred |
| `INSERT ALL` / `INSERT FIRST` multi-table insert | ✅ | unconditional, conditional `WHEN`/`ELSE`, `INTO` without `VALUES` |

### Scalar idioms & functions
`SYSDATE`, `SYSTIMESTAMP`, `TO_CHAR` (format model accepted, not interpreted),
`TO_NUMBER`, `NVL`, `NVL2`, `COALESCE`, `DECODE`, `EXTRACT(field FROM src)`,
`SUBSTR`, `INSTR`, `INITCAP`, `LPAD`/`RPAD`, `TRUNC`, `ROUND`, `CEIL`, `GREATEST`,
`LEAST`, `LISTAGG`, `REGEXP_LIKE`/`REGEXP_SUBSTR`/`REGEXP_REPLACE`, `||` concat,
typed literals `DATE '…'` / `TIMESTAMP '…'`.

### Data types over the TTC wire
| Type | Bind (client → server) | Fetch (server → client) |
| --- | --- | --- |
| `NUMBER`, `VARCHAR2`/`CHAR`, `RAW` | ✅ | ✅ |
| `DATE`, `TIMESTAMP`, `TIMESTAMP WITH [LOCAL] TIME ZONE` | ✅ | ✅ (region-name decode/preserve) |
| `INTERVAL YEAR TO MONTH` / `DAY TO SECOND` | ✅ | ✅ |
| `CLOB` / `BLOB` | ✅ (temp-LOB locator) | ✅ (column locator + inline prefetch) |
| `JSON` (native OSON, 21c+/23ai) | ✅ | ✅ (rich scalars: date/bytes, v3 long names) |
| `VECTOR` (23ai) — dense / binary / sparse | ✅ | ✅ (dense via wire; binary/sparse in-memory) |
| `NCLOB` (national-charset CLOB) | ✅ (UTF-16BE) | ✅ (csfrm=2 + national locator flag) |

---

## 4. MySQL compatibility

| Feature | Status |
| --- | --- |
| Backtick identifiers, `# comment`, `-- comment` | ✅ |
| `AUTO_INCREMENT`, `ON DUPLICATE KEY UPDATE` | ✅ |
| `LIMIT offset, count` | ✅ |
| `SHOW TABLES` / `SHOW COLUMNS` / `DESCRIBE` / `USE db` / `SET` | ✅ |
| `@@system_variables`, `DATABASE()`/`SCHEMA()`, `LAST_INSERT_ID` | ✅ |
| Date/time functions (`NOW`, `CURDATE`, `DATE_FORMAT`, `STR_TO_DATE`, `DATEDIFF`, `UNIX_TIMESTAMP`, …) | ✅ |
| String functions (`CONCAT`, `CONCAT_WS`, `SUBSTRING`, `LEFT`/`RIGHT`, `LPAD`/`RPAD`, `REPLACE`, `REVERSE`, `SOUNDEX`, …) | ✅ |
| `JSON_*` / `JSONB_*` function family | ✅ |
| `INFORMATION_SCHEMA` views | ✅ `TABLES` / `COLUMNS` / `SCHEMATA` / `VIEWS` (sqlite_master-backed; no `KEY_COLUMN_USAGE` / `STATISTICS` yet) |
| Stored procedures / `DELIMITER` | ✅ `CREATE`/`DROP PROCEDURE`, `CALL` (IN params, result passthrough); `DELIMITER` no-op. Stored FUNCTIONS callable in expressions (`SELECT f(x)`, projection, `WHERE`, nested, DB-reading via `SELECT … INTO`); OUT-param `@var` writeback not yet |

---

## 5. Analytics, search & vector (beyond both dialects)

The engine ships capabilities neither stock Oracle nor MySQL expose the same way:

- **Window functions:** `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `LAG`, `LEAD`,
  `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE`, `NTILE`, `PERCENT_RANK`, `CUME_DIST`,
  plus aggregate `OVER (…)` with `PARTITION BY` / `ORDER BY` / frames.
- **Aggregates:** `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, `GROUP_CONCAT`/`LISTAGG`/
  `STRING_AGG`, `STDDEV[_POP|_SAMP]`, `VARIANCE`, `MEDIAN`, `TOTAL`,
  `JSON_GROUP_ARRAY`/`JSON_GROUP_OBJECT`.
- **Full-text search:** FTS5 virtual tables with `BM25` ranking.
- **Vector search:** `VECTOR` columns with Flat / HNSW / IVFFlat / LSH / PQ /
  IVFPQ indexes, `VEC_L2`/`VEC_COSINE`/`VEC_IP` distances, `vec_search*` table
  functions, and hybrid (vector + BM25 RRF) search. See [README.md](README.md).

---

## 6. Known gaps & non-goals

- **Oracle:** PL/SQL `EXCEPTION` handlers and cursors (`OPEN`/`FETCH`/`CLOSE`,
  `%ROWTYPE`/`%FOUND`) — the rest of PL/SQL (blocks, procedures, functions,
  control flow, `SELECT INTO`) is supported; `SYS_CONNECT_BY_PATH` /
  `CONNECT_BY_ROOT`; real-client TLS (client-SDK bug, not server).
- **MySQL:** X protocol, wire compression, stored procedures, and the rest of
  `INFORMATION_SCHEMA` (`TABLES`/`COLUMNS`/`SCHEMATA`/`VIEWS` are supported;
  `KEY_COLUMN_USAGE` / `STATISTICS` / constraint views are not yet).
- **Engine quirks:** `(+)` RIGHT joins on 3+-table chains null the whole
  accumulated left side (best-effort vs Oracle's per-table semantics).

---

*Generated from the engine source; function and statement lists reflect
[`expression.dart`](../lib/server/expression.dart),
[`parser.dart`](../lib/server/parser.dart), and
[`database.dart`](../lib/server/database.dart). Keep this table in sync when the
dialect surface changes.*
