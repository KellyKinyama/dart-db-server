# Recipe: near-duplicate detection

**Scenario.** You want to find rows that are nearly identical to a
given input — for deduplication, plagiarism detection, image
fingerprinting, or clustering.

**Pattern.** Unlike top-k search, you don't know how many results
you'll get back. Instead you set a **distance threshold** — "everything
within `X` of my query" — and let the engine return however many rows
match. `vec_range_search` is the built-in TVF for this.

## Threshold selection

The threshold is metric-specific. Sample your corpus first:

```sql
-- What's the actual distance distribution of a random query?
SELECT VEC_L2(a.embedding, b.embedding) AS d
FROM articles a, articles b
WHERE a.id < b.id
ORDER BY d
LIMIT 200;
```

Then pick a threshold below which you're comfortable calling the pair
"duplicates". For `cosine` this is usually somewhere around `0.05 – 0.15`;
for `l2` on unnormalised vectors it depends heavily on your embedder's
scale.

`PRAGMA vector_analyze('t.col')` also samples the recall of your
chosen index kind, which is helpful before committing to a threshold.

## Schema

Range search only works on **monotone** metrics — Flat, HNSW, and
IVFFlat — because it uses a progressive-doubling stopping criterion
that assumes each retrieved batch's furthest distance is a lower bound
on future distances. LSH / PQ / IVFPQ bindings are rejected at
runtime:

```sql
CREATE TABLE docs (
  id INTEGER PRIMARY KEY,
  hash TEXT,
  content TEXT,
  embedding BLOB VECTOR(
    dim=384,
    kind=hnsw,          -- required: flat | hnsw | ivf
    metric=l2           -- l2 | l2sq | cosine | inner_product
  )
);
```

## Query

```sql
SELECT id, hash, s.distance
FROM vec_range_search(
       'docs', 'embedding',
       VEC('[0.11, -0.03, ...]'),
       0.10                              -- threshold
     ) AS s
JOIN docs ON docs.id = s.rowid
ORDER BY s.distance;
```

## Detect duplicates within the corpus itself

For every row, find every other row within the threshold. This is the
"union-find" primitive for clustering:

```sql
SELECT a.id AS a_id, s.rowid AS b_id, s.distance
FROM docs a,
     vec_range_search('docs', 'embedding', a.embedding, 0.10) AS s
WHERE a.id < s.rowid;                    -- avoid self-matches + double-count
```

That's an $O(n \cdot \bar{k})$ scan where $\bar{k}$ is the average
number of near-duplicates per row — usually 0-3 for a healthy corpus.

## Batch: many queries at once

For an eval set or a re-ingestion pipeline, use the batch variant:

```sql
SELECT query_idx, rowid, distance
FROM vec_range_search_batch(
       'docs', 'embedding',
       '[[0.11,-0.03,...], [0.20,0.05,...]]',
       0.10
     )
ORDER BY query_idx, distance;
```

The engine resolves the index + remap function once and reuses them
across every query.

## Range + filter

Same `filter_json` arg as the KNN variants — restrict to a subset:

```sql
SELECT id, s.distance
FROM vec_range_search(
       'docs', 'embedding',
       VEC('[0.11,-0.03,...]'),
       0.10,
       'l2',                             -- explicit metric
       '{"language": "en"}'              -- payload filter
     ) AS s;
```

## Dart wrapper — "is this document a duplicate?"

```dart
class DuplicateChecker {
  DuplicateChecker(this.db, this.embed, {this.threshold = 0.10});
  final Database db;
  final Future<List<double>> Function(String) embed;
  final double threshold;

  Future<List<DuplicateHit>> findNearDuplicates(String content) async {
    final v = await embed(content);
    final vecJson = '[${v.join(",")}]';
    final r = await db.execute('''
      SELECT s.rowid, s.distance, d.hash, d.content
      FROM vec_range_search(
             'docs', 'embedding',
             VEC('$vecJson'),
             $threshold
           ) AS s
      JOIN docs d ON d.id = s.rowid
      ORDER BY s.distance
    ''');
    return [
      for (final row in r.rows)
        DuplicateHit(
          id: row[0] as int,
          distance: (row[1] as num).toDouble(),
          hash: row[2] as String?,
          preview: (row[3] as String).substring(0,
              (row[3] as String).length.clamp(0, 200)),
        ),
    ];
  }
}
```

## Compare with a plain SELECT

The engine also has a fast-path plan for `WHERE VEC_L2(col, const) < threshold`
— you don't have to use the TVF form:

```sql
SELECT id, hash
FROM docs
WHERE VEC_L2(embedding, VEC('[0.11,-0.03,...]')) < 0.10;
```

`EXPLAIN QUERY PLAN` will show:

```
SEARCH docs USING VECTOR INDEX (hnsw) RANGE
```

The TVF and the fast path return the same rows in the same order.
Prefer the plain SELECT for one-off queries; prefer the TVF for
composability inside larger CTEs, JOINs, or subqueries.

## Clustering hint

Range search is the atomic primitive for near-duplicate clustering.
The typical pipeline:

1. `vec_range_search` from every row against itself (self-join above).
2. Union-find on the resulting edges → connected components.
3. Each component is one duplicate cluster.

This scales linearly in corpus size as long as the average number of
near-duplicates per row stays small.
