# Production operations

Everything you need to keep a vector-backed `dart_db_server` running.

## Startup

For **in-memory** tables you don't need to do anything — vector indexes
are built lazily on first read.

For **paged** tables warm indexes explicitly at process boot so the
first user query doesn't stall on a full-scan build:

```dart
final db = await Database.open('/var/lib/myapp/data.json');
await db.execute('PRAGMA vector_index_warm_all');
await db.execute('PRAGMA fts5_warm(\'articles.body\')'); // if you use hybrid
```

Or with the Dart API (equivalent):

```dart
await db.warmVectorIndexes();
await db.warmFts5('articles', 'body');
```

Warming is idempotent — safe to call from a health check that re-runs
periodically.

## Health check

Run this every 30-60 seconds and page on drift:

```sql
PRAGMA vector_verify_all;
```

Columns: `(tbl, col, n_rows, n_index, missing_from_index, extra_in_index, dim_bad)`.

Expected state: `missing_from_index = 0`, `extra_in_index = 0`,
`dim_bad = 0`. Anything else means either a bug or an out-of-band write
went sideways.

Sample Dart health check:

```dart
Future<void> checkVectorHealth(Database db) async {
  final r = await db.execute('PRAGMA vector_verify_all');
  for (final row in r.rows) {
    final missing = row[r.columns.indexOf('missing_from_index')] as int;
    final extra   = row[r.columns.indexOf('extra_in_index')] as int;
    final dimBad  = row[r.columns.indexOf('dim_bad')] as int;
    if (missing != 0 || extra != 0 || dimBad != 0) {
      alertOncall('vector index drift', row.toString());
    }
  }
}
```

## Recall monitoring

`PRAGMA vector_analyze('t.col')` samples random queries, computes the
brute-force top-k, then compares to the built index's top-k. It's an
honest recall estimate on your actual data:

```sql
PRAGMA vector_analyze('articles.embedding:10:128');
--                    │           │  │
--                    │           │  └─ sample_size (# probe queries)
--                    │           └──── k (top-K)
--                    └──────────────── target
```

Returns one row `(tbl, col, k, sample_size, mean_recall)`. Alert if
`mean_recall < 0.90`.

## Stats

Two PRAGMAs give you an inventory of every vector index:

```sql
PRAGMA vector_index_list;
--   → (tbl, col, dim, kind, metric, built, n)

PRAGMA vector_index_stats('articles.embedding');
--   → (tbl, col, kind, metric, dim, n, live, tombstones, approx_bytes)
```

`tombstones` grows on `UPDATE` / `DELETE` for HNSW. When
`tombstones / n > 0.3` the binding auto-rebuilds on the next query, but
you can force it earlier:

```sql
PRAGMA vector_index_rebuild('articles.embedding');
```

## Rebuild patterns

**One binding, sync in-memory rebuild:**
```sql
PRAGMA vector_index_rebuild('articles.embedding');
```

**Every binding (in-memory sync, paged marked invalid):**
```sql
PRAGMA vector_index_rebuild_all;
-- 'vector_index_rebuild_all: X binding(s) rebuilt, Y paged binding(s) invalidated'
PRAGMA vector_index_warm_all;   -- follow up to actually rebuild paged bindings
```

Do this after a large batch retraining run or a bulk import.

## Bulk import

Skip per-row SQL parsing when loading millions of rows:

```sql
SELECT * FROM vec_batch_insert('articles', 'id', 'embedding',
  '[{"id":1,"vec":[0.01,...]},{"id":2,"vec":[0.02,...]}, ...]');
```

Or straight from a CSV:

```sql
SELECT * FROM vec_import_csv('articles', 'id', 'embedding',
                             '/tmp/embeddings.csv', 0);   -- has_header=0
```

CSV format: `<id>,<vec_json>` per line, e.g.:

```
1,[0.01,0.02,0.03]
2,[0.04,0.05,0.06]
```

`vec_batch_insert` and `vec_import_csv` both persist automatically at
end of call.

## Transactions

Vector-index maintenance is deferred until commit. Inside a transaction,
INSERT / UPDATE / DELETE accumulate as pending deltas; the built index is
only touched when the query engine actually needs to read from it.

If you're mixing DDL and DML in one transaction, remember:

- Paged DDL (`CREATE TABLE USING paged`, `CREATE/DROP INDEX`, `DROP`,
  `TRUNCATE`) is rejected inside a transaction.
- Paged DML is rejected inside a `SAVEPOINT`.

Both restrictions exist to keep the paged-file undo journal simple.

## Persistence

Every writable public API (`execute`, `close`, `flush`, TVF bulk
inserters) triggers a chained `_persist()` after the mutation. Chaining
serialises overlapping calls so the atomic tmp+rename doesn't race on
Windows.

If you want a synchronous flush point:

```dart
await db.flush();
```

`db.close()` also drains the persist chain unconditionally before
releasing the file lock.

## Backup

The engine uses atomic tmp+rename, so a raw file copy is safe as long
as it happens **between** two persist cycles:

```powershell
Copy-Item data.json data.json.bak
Copy-Item data.json.vec.json data.json.vec.json.bak   # SQLite-format sidecar
```

Or use the SQL surface:

```sql
BACKUP TO 'data.snapshot.json';
```

Both approaches produce a self-contained snapshot including all vector
indexes and their built state.

## Monitoring dashboard SQL

Copy-paste these into your ops dashboard:

```sql
-- Every registered binding, size + build status:
SELECT tbl, col, kind, metric, n, live, tombstones,
       approx_bytes / 1024.0 / 1024.0 AS mb
FROM pragma_vector_index_stats();

-- (approximated as a TVF over pragma_vector_index_list)
-- Combined health:
SELECT tbl, col,
       n_index, missing_from_index, extra_in_index, dim_bad
FROM pragma_vector_verify_all();
```

## Common failure modes and their fixes

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Query returns 0 rows unexpectedly | `filter_json` had a key not in `filter_cols`, or filter values don't match stored types (int vs string) | Check `PRAGMA vector_index_list` for the declared `filterColumns`; make sure you serialise the filter map with types that match your columns. |
| Recall dropped after a batch import | The freshly-imported rows haven't been baked into the built index yet | Run the next `SELECT` (which drains deltas) or `PRAGMA vector_index_rebuild('t.col')`. |
| HNSW binding uses too much RAM | Tombstones from `UPDATE` / `DELETE` accumulated | The engine auto-rebuilds at 30% tombstones; force earlier with `PRAGMA vector_index_rebuild('t.col')`. |
| `StateError: paged FTS5 corpus for … not warmed` | You called `vec_hybrid_search` on a paged table without warming first | `await db.warmFts5(tbl, col)` OR `PRAGMA fts5_warm('t.col')` at startup. |
| Startup takes 30+ seconds | Paged vector index building from disk on first query | Warm at boot: `PRAGMA vector_index_warm_all`. |
| `dim_bad > 0` in `vector_verify` | Someone inserted a wrong-dimension vector | Enforce dim at write time (already done since V35); look for out-of-band JSON edits or missed model version bumps. |
