## 0.1.0

Initial pub.dev release.

### Highlights

- **Pure-Dart SQL engine** — SQLite-inspired surface: DDL, DML, joins,
  subqueries, CTEs, window functions, aggregate `ORDER BY` / `FILTER`,
  `RETURNING`, upsert, common table expressions, and transactions with
  savepoints.
- **Three storage backends** — in-memory (JSON-persistable), out-of-core
  paged (`USING paged`), and SQLite on-disk format (`.sqlite` files
  round-trip through the real SQLite format).
- **Vector database** built into the SQL surface:
  - Six index kinds: `flat`, `hnsw`, `ivf`, `lsh`, `pq`, `ivfpq`.
  - Four metrics: `l2`, `l2sq`, `inner_product`, `cosine`.
  - DDL: `BLOB VECTOR(dim=..., kind=..., metric=..., ...)` inline attribute
    or `CREATE VIRTUAL TABLE ... USING vector_index(...)`.
  - Table-valued functions: `vec_search`, `vec_search_batch`,
    `vec_search_filtered`, `vec_search_filtered_batch`,
    `vec_range_search`, `vec_range_search_batch`,
    `vec_hybrid_search`, `vec_hybrid_search_batch`,
    `vec_search_join`, `vec_batch_insert`, `vec_import_csv`.
  - Payload-filter pruning: declare `filter_cols='tenant,kind'` on the
    index and the query engine intersects payload buckets before touching
    the vector index.
  - Fast-path planner: `SELECT ... ORDER BY VEC_L2(col, const) LIMIT k`
    is served by the built index automatically; `EXPLAIN QUERY PLAN`
    surfaces the choice.
  - Admin PRAGMAs: `vector_index_list`, `vector_index_stats`,
    `vector_index_rebuild[_all]`, `vector_index_warm[_all]`,
    `vector_verify[_all]`, `vector_analyze`, `fts5_warm`.
- **FTS5-lite** — BM25 ranking, `MATCH` operator, and hybrid retrieval
  via Reciprocal Rank Fusion.
- **TCP server** — JSON line protocol on any port + interactive REPL.
- **MySQL wire compatibility** — a subset of the MySQL 8 auth / query
  protocol so ORMs like `mysql_client` can talk to the server unchanged.
- **1500+ tests** covering every surface above.

See `example/vector_semantic_search.dart` for a runnable end-to-end
semantic-search walkthrough.

## 1.0.0

- Initial version.
