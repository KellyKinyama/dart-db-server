# Parity test-data catalog

Standard sample schemas and benchmark datasets used to validate Oracle and
MySQL parity. Each entry lists the dialect it targets, what it exercises, the
**official download location**, and load notes.

> **Licensing.** These datasets are distributed by Oracle, the MySQL project,
> and the TPC under their own licenses. Download them yourself; do **not** commit
> the data into this repo. Drop extracted files under [`datasets/`](datasets).

---

## Downloaded locally (git-ignored)

Fetched into [`datasets/`](datasets) via GitHub mirrors (the official MySQL CDN
blocks programmatic download — see "manual only" below). Paths are relative to
`parity/datasets/`:

| Dataset | Local load file(s) | Dialect |
| --- | --- | --- |
| **employees** (test_db) | `mysql-employees/test_db-master/employees.sql` (`objects.sql`, `*_partitioned.sql`) | MySQL |
| **sakila** | `mysql-sakila/sakila-main/mysql-sakila-db/` → `mysql-sakila-schema.sql` + `mysql-sakila-insert-data.sql` | MySQL |
| **sakila (Oracle)** | `mysql-sakila/sakila-main/oracle-sakila-db/` | Oracle |
| **Oracle sample schemas** | `oracle-db-sample-schemas/db-sample-schemas-main/` (`human_resources/`, `order_entry/`, `sales_history/`, `product_media/`, `customer_orders/`, `info_exchange/`) | Oracle |

> The jOOQ/sakila mirror also ships Postgres/SQLite/DB2/SQL-Server variants under
> the same `sakila-main/` tree — handy for cross-dialect diffing.

**Manual-only (CDN-blocked / must build yourself):**
- MySQL `world`, `menagerie` — download the zips from the official page below in
  a browser and drop the `.sql` into `datasets/`.
- TPC-H / TPC-C / TPC-DS — run the generator (`dbgen`/`dsdgen`) at the chosen
  scale factor; the raw data is not redistributable.

Re-fetch everything with:

```powershell
# from parity/datasets/
$ua = 'Mozilla/5.0'
Invoke-WebRequest 'https://codeload.github.com/datacharmer/test_db/zip/refs/heads/master'            -OutFile mysql-employees.zip            -Headers @{'User-Agent'=$ua}
Invoke-WebRequest 'https://codeload.github.com/jOOQ/sakila/zip/refs/heads/main'                      -OutFile mysql-sakila.zip               -Headers @{'User-Agent'=$ua}
Invoke-WebRequest 'https://codeload.github.com/oracle-samples/db-sample-schemas/zip/refs/heads/main' -OutFile oracle-db-sample-schemas.zip   -Headers @{'User-Agent'=$ua}
Get-ChildItem *.zip | ForEach-Object { Expand-Archive $_.FullName $_.BaseName -Force }
```

---

## MySQL sample databases

### 1. `world` — small relational, joins & aggregates
- **Exercises:** basic joins, `GROUP BY`, aggregates, foreign keys. Good first
  smoke test for the MySQL wire path.
- **Download:** https://dev.mysql.com/doc/index-other.html (section
  "Example Databases" → *world database*).
- **Direct:** https://downloads.mysql.com/docs/world-db.zip
- **Load:** `SOURCE world.sql;` (plain SQL, no engine-specific features).

### 2. `sakila` — full-featured OLTP (DVD rental)
- **Exercises:** views, stored procedures, triggers, functions, `JOIN`-heavy
  queries, `DECIMAL`/`DATETIME`/`BLOB`/`ENUM` types.
- **Download:** https://dev.mysql.com/doc/index-other.html → *sakila database*.
- **Direct:** https://downloads.mysql.com/docs/sakila-db.zip
- **Load:** `SOURCE sakila-schema.sql;` then `SOURCE sakila-data.sql;`
- **Parity value:** stresses views/triggers/procedures — maps to roadmap **G8**
  (procedural routines).

### 3. `employees` (test_db) — large dataset, performance
- **Exercises:** ~4M rows, partitioning-friendly, good for `LIMIT`/`ORDER BY`,
  index selection, and bulk-load throughput.
- **Download:** https://github.com/datacharmer/test_db
- **Load:** `mysql < employees.sql` (or the dump variant).

### 4. `menagerie` — minimal tutorial dataset
- **Exercises:** date functions, simple DML. Smallest possible MySQL fixture.
- **Download:** https://dev.mysql.com/doc/index-other.html → *menagerie*.

---

## Oracle sample schemas

### 5. Oracle `db-sample-schemas` (HR, OE, SH, PM, IX, CO)
- **Exercises:** the canonical Oracle schemas:
  - **HR** — human resources: FKs, hierarchical `CONNECT BY` (employee→manager).
  - **OE** — order entry: object types, `VARRAY`, nested tables, LOBs.
  - **SH** — sales history: large fact/dim tables, analytics, materialized views.
  - **PM** — product media: `BLOB`/`CLOB`/`BFILE` multimedia.
  - **IX** — information exchange: Advanced Queuing.
  - **CO** — customer orders (newer 23ai schema).
- **Download:** https://github.com/oracle-samples/db-sample-schemas
  (pick the branch/tag matching your Oracle version, e.g. `v23.3`).
- **Parity value:**
  - HR → **Oracle `CONNECT BY`** (roadmap G6, done), sequences, `DUAL`.
  - SH → window functions, `ROLLUP`/`CUBE`, `LISTAGG`.
  - OE/PM → LOB streaming over the TTC wire (NCLOB/BLOB codecs).

### 6. Classic `HR` schema (standalone)
- **Exercises:** smallest Oracle fixture for wire + idiom smoke tests
  (`SELECT … FROM dual`, `SYSDATE`, `ROWNUM`, `NVL`, `DECODE`).
- **Download:** bundled in `db-sample-schemas` above (`human_resources/`).

### 7. Oracle 23ai AI Vector Search samples
- **Exercises:** `VECTOR` datatype, `VECTOR_DISTANCE`, vector indexes — maps to
  the engine's built-in vector DB.
- **Download:** https://github.com/oracle-samples/oracle-db-examples
  (`ai-vector-search/`).

---

## Cross-engine benchmark datasets (both dialects)

### 8. TPC-H — ad-hoc analytics / decision support
- **Exercises:** 22 analytic queries, joins across 8 tables, aggregation,
  subqueries. Scale factor configurable (SF1 ≈ 1 GB).
- **Download / spec + `dbgen`:** https://www.tpc.org/tpch/
- **Portable generator:** https://github.com/electrum/tpch-dbgen
- **Parity value:** exercises the optimizer, window/aggregate parity, and the
  SQL surface identically on both wire front-ends.

### 9. TPC-C — OLTP throughput
- **Exercises:** transactional mix, `SELECT … FOR UPDATE`, isolation, high
  write concurrency (stresses the engine's session-gate/locking model).
- **Download / spec:** https://www.tpc.org/tpcc/

### 10. TPC-DS — complex decision support
- **Exercises:** 99 queries, deep analytics, `ROLLUP`/`CUBE`/`GROUPING SETS`,
  window functions. Heaviest SQL-surface workout.
- **Download / spec:** https://www.tpc.org/tpcds/

---

## Suggested smoke-to-full progression

| Stage | MySQL | Oracle | Validates |
| --- | --- | --- | --- |
| Smoke | `world` | `HR` | wire connect, joins, aggregates, idioms |
| Feature | `sakila` | `OE` / `SH` | views, routines, LOBs, analytics |
| Scale | `employees` | `SH` (large) | bulk load, `ORDER BY`/`LIMIT`, indexes |
| Benchmark | TPC-H / TPC-C / TPC-DS (both) | optimizer, concurrency, full surface |

## Loading against `dart_db_server`

```powershell
# Start the server with both front-ends
dart run bin/dart_db_server.dart --port 4555 --mysql-port 3306 --oracle-port 1521 --file parity.json

# MySQL path — load a sample schema with any MySQL client
mysql --host 127.0.0.1 --port 3306 < datasets/world.sql

# Oracle path — load via the oracledb thin client (see validation/ harness)
```

See [`../validation/`](../validation) for the real-client round-trip harness.
