## 0.1.5

- Publishing hygiene: ignore runtime vector-store data files
  (`kb_vectors.json` / `*.lock`) so they are never bundled into the
  published package.

## 0.1.4

- Docs-only release. Fix all 13 unresolved-symbol warnings that
  `dart doc` emitted on the previous versions:
  - `vector.dart`: `[M]` → `[m]`, `[0, 2]` / `[-1, 1]` backticked.
  - `expression.dart`: `WindowSpec` doc + `fts5CorpusLookup` doc.
  - `paged_file.dart`: library-level `[pageSize]` / `[commit]` refs
    backticked (they were member refs at library scope).
  - `paged_table.dart`: `[columnName]` → `columnName`, `[database.dart]`
    backticked.
  - `rtree.dart`: `[this]` in `BBox.intersects` doc → prose.
- `dart doc --dry-run` now reports **0 warnings**.

## 0.1.3

- **New: `vec_search_join_filtered` TVF.**
  - Signature: `vec_search_join_filtered(target_table, target_column,
    query_table, query_column, k, filter_json[, metric])`.
  - Payload-filtered companion to V16 `vec_search_join`. Every query
    row's k-NN is restricted to target rows matching `filter_json`;
    the filter is intersected once up front and reused across queries.
  - In-memory target tables only, matching V39 / V43 semantics.
- Small tightening: the paged branch of `vec_search_filtered_batch`
  now uses the shared `_runVectorSearch` dispatcher (a leftover
  copy-paste V51 missed).
- 5 new tests; suite now at 1542.

## 0.1.2

- **New: FTS5 admin PRAGMAs.**
  - `PRAGMA fts5_list` — one row per warmed FTS5 corpus with
    `(tbl, col, doc_count, vocab_size, avg_doc_length)`.
  - `PRAGMA fts5_stats('tbl.col')` — same columns for a single corpus;
    throws a clear `StateError` when the corpus hasn't been warmed.
- `Fts5Index` grew a `vocabSize` getter (distinct-term count).
- `dart format` sweep across 18 files (test suite + 3 lib files); no
  code changes, purely whitespace so pub.dev's format check passes.
- Fix a `dangling_library_doc_comments` info in the example script by
  adding an explicit `library;` directive.
- Add pub.dev + CI + license badges to the README.
- GitHub Actions workflow: `dart format`, `dart analyze --fatal-infos`,
  and `dart test` on every push / PR (Dart stable + beta), plus a
  `dart pub publish --dry-run` job.
- 6 new tests; suite now at 1537.

## 0.1.1

- Docs-only release. Adds a `doc/` folder with real-world vector-database
  recipes: RAG semantic search, multi-tenant search, hybrid vector +
  BM25, recommendations, duplicate detection, index selection, and
  production operations.
- README: index of the new recipes.

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
