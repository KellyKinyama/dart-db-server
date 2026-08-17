# Choosing a vector index kind

`dart_db_server` ships six index kinds. The right choice depends on
**corpus size**, **recall target**, and **memory budget**.

## The six kinds

| Kind | Memory | Build time | Query time | Recall | Notes |
| --- | --- | --- | --- | --- | --- |
| `flat` | 4 × dim × N bytes | O(N) | O(N × dim) per query | 100% | Baseline. Best under ~50k rows. |
| `hnsw` | ~1.5× flat | O(N × log N) | O(log N × dim) | ~99% | Default choice for RAG. |
| `ivf` | ~flat + centroids | O(N × dim × nlist) | O(dim × nlist / nprobe + hits × dim) | ~95% (tunable) | Good when nlist ≈ √N and you can afford some recall loss. |
| `lsh` | ~nbits / 8 bytes per row | O(N × nbits × dim) | O(candidates × dim) | ~85-95% | Compact. Only supports L2. |
| `pq` | m × 1 byte per row | O(N × m × ksub × dim) | O(m + candidates × dim) | ~90-95% | Best compression ratio. |
| `ivfpq` | m + centroid overhead per row | O(N × m × ksub × dim) | O(nprobe × avg_cell + rerank × dim) | ~90-97% | Best for very large N. |

## Rules of thumb by corpus size

### < 10k rows

Use `flat`. Query cost is trivial (< 1 ms), recall is exact, memory is
fine. Anything else is premature optimisation.

```sql
BLOB VECTOR(dim=1536, kind=flat, metric=cosine)
```

### 10k - 100k rows

Use `flat` still if latency budget allows (a few ms per query with
dim=1536), or step up to `hnsw` for < 1 ms:

```sql
BLOB VECTOR(dim=1536, kind=hnsw, metric=cosine, m=16, ef_construction=64)
```

### 100k - 1M rows

`hnsw` is the sweet spot:

```sql
BLOB VECTOR(
  dim=1536, kind=hnsw, metric=cosine,
  m=32,                    -- more edges per node → higher recall
  ef_construction=128,     -- more thorough build → higher recall
  ef_search=64             -- search-time exploration knob
)
```

For memory-constrained deployments, consider `pq` at this size:

```sql
BLOB VECTOR(
  dim=1536, kind=pq, metric=l2,
  m=48                     -- 48 sub-quantizers × 8 bits = 384 bits per row
)
```

Then add rescoring for recall:

```sql
BLOB VECTOR(
  dim=1536, kind=pq, metric=l2, m=48, rescore_factor=10
)
```

`rescore_factor=10` means "fetch 10× k candidates from the PQ index, then
exact-rerank the top-k using the full float32 vectors". You get most of
PQ's memory savings and near-flat recall.

### 1M - 100M rows

Use `ivfpq` and partition by a filter column (tenant, region, category):

```sql
BLOB VECTOR(
  dim=1536, kind=ivfpq, metric=l2,
  nlist=4096,              -- √N is a good default
  nprobe=32,               -- probes per query
  m=48,                    -- PQ sub-quantizers
  rescore_factor=8,
  filter_cols='tenant_id'
)
```

Payload-filter pruning combines beautifully with IVF partitioning: only
cells overlapping the filter set are probed.

### > 100M rows

You're beyond a single-node vector database. `dart_db_server` does not
target this scale. Look at `pgvector` + sharding, Vespa, Milvus, or
Weaviate.

## Metric selection

| Metric | Use when |
| --- | --- |
| `cosine` | Text embeddings from most modern models (OpenAI, Cohere, MiniLM). |
| `l2` / `l2sq` | Vectors are already normalised, or the embedder was trained with L2 loss. `l2sq` (squared L2) is faster if you only care about ranking. |
| `inner_product` / `dot` / `ip` | Learned recommendation embeddings (ALS, LightFM, Two-Tower). |

If in doubt, try `cosine`. Every modern text embedder is compatible.

## When to switch kinds

Symptoms → change:

- **Latency > budget** → move from `flat` → `hnsw` → `ivfpq`.
- **Memory > budget** → add `pq` (with `rescore_factor`), then `ivfpq`.
- **Recall too low** → increase `ef_search` (HNSW), `nprobe` (IVF/IVFPQ),
  or `rescore_factor`. As a last resort, drop back to `flat`.
- **Build time too high** → reduce `ef_construction` (HNSW) or `nlist` (IVF).
  If cold-start latency matters, use `hnsw` (incremental) instead of
  `ivf`/`ivfpq` (require a full re-train on large mutations).

## Verifying your choice

Once you've chosen an index kind, run `PRAGMA vector_analyze` to see the
actual recall against ground-truth on your data:

```sql
PRAGMA vector_analyze('articles.embedding:10:64');
```

That runs 64 random queries at k=10, brute-force-ranks the ground-truth
top-10, and computes mean recall against the built index. Expect:

- `flat` → 1.0
- `hnsw` (defaults) → 0.98 – 1.0
- `hnsw` (m=16, ef_search=16) → 0.85 – 0.95
- `ivfpq` (tuned) → 0.90 – 0.98

Numbers below `0.9` usually mean your `nprobe` / `ef_search` /
`rescore_factor` is too low.

## Migration

Changing `kind` is a schema change: drop the vector index and recreate it.

```sql
-- Cheap for small tables:
PRAGMA vector_index_rebuild('articles.embedding');

-- Or via a full ALTER cycle for the full DDL change:
ALTER TABLE articles DROP COLUMN embedding;
ALTER TABLE articles ADD COLUMN embedding BLOB VECTOR(dim=1536, kind=hnsw, metric=cosine);
UPDATE articles SET embedding = VEC(?) WHERE id = ?;   -- reingest
```

For paged tables always follow with:

```sql
PRAGMA vector_index_warm('articles.embedding');
```

to make the rebuild synchronous rather than lazy on first query.
