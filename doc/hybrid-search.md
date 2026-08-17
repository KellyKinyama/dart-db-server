# Recipe: hybrid vector + BM25 search

**Scenario.** Pure vector search misses exact keyword matches
("SKU-12345", proper names, error codes, code identifiers). Pure BM25
misses paraphrases and synonyms ("how do I sign in" vs "login trouble").
Combine both.

**Pattern.** Compute rank on both sides, then fuse via Reciprocal Rank
Fusion (RRF):

$$\text{rrf}(d) = \sum_{r_i \in \text{ranks}(d)} \frac{1}{k + r_i}$$

where `k=60` is the standard constant. RRF is remarkably robust: it
needs no per-corpus tuning and behaves well even when the two sides
have very different score distributions.

## Schema

You need both an embedding column and a text column on the same row —
usually the vector is computed from the same text you'll BM25 against
(or from a longer version of it):

```sql
CREATE TABLE articles (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,              -- BM25 target
  embedding BLOB VECTOR(
    dim=1536,
    kind=hnsw,
    metric=cosine
  )
);

-- FTS5 tokenizer defaults are usually fine; the engine autoruns a
-- Porter-lite stemmer and lowercases.
```

## Retrieve

`vec_hybrid_search(table, vec_col, text_col, query_vec, query_text, k)`
runs both sides in parallel, fuses via RRF, returns `k` rows:

```sql
SELECT a.id, a.title,
       s.distance,       -- raw vector distance (lower = better)
       s.bm25,           -- raw BM25 score (higher = better)
       s.rrf_score       -- fused score (higher = better)
FROM vec_hybrid_search(
       'articles', 'embedding', 'body',
       VEC('[0.11, -0.03, ...]'),        -- embed(question)
       'aws lambda cold start timeout',   -- raw text query
       10                                 -- k
     ) AS s
JOIN articles a ON a.id = s.rowid
ORDER BY s.rrf_score DESC;
```

## Tune the fusion

The optional 7th argument tunes the RRF constant `k` (not to be
confused with the top-k):

```sql
-- Higher k = smoother mixing, less influence from top ranks
SELECT * FROM vec_hybrid_search(
  'articles', 'embedding', 'body',
  VEC('[...]'), 'query text', 10,
  120       -- rrf_k
);
```

Rules of thumb:
- `rrf_k = 60` (default, from the original paper). Safe for most corpora.
- `rrf_k = 20 – 40`: sharper — trust top-ranked results more. Good when
  both signals are reliable.
- `rrf_k = 100 – 200`: smoother — lets more of the tail contribute. Good
  when either signal is noisy.

## Filter + hybrid

The 8th argument is a `filter_json` map (same shape as
`vec_search_filtered`). It gates both sides so BM25 doesn't score rows
that will be filtered out anyway:

```sql
SELECT * FROM vec_hybrid_search(
  'articles', 'embedding', 'body',
  VEC('[...]'), 'query text', 10, 60,
  '{"language": "en", "status": "published"}'
);
```

## Batch hybrid

For multi-question workflows (e.g. batching an eval set):

```sql
SELECT query_idx, rowid, distance, bm25, rrf_score
FROM vec_hybrid_search_batch(
  'articles', 'embedding', 'body',
  '[
    {"vec":[0.1,...], "text":"question one"},
    {"vec":[0.2,...], "text":"question two"}
  ]',
  10
)
ORDER BY query_idx, rrf_score DESC;
```

## Dart wrapper

```dart
class HybridSearch {
  HybridSearch(this.db, this.embed);
  final Database db;
  final Future<List<double>> Function(String) embed;

  Future<List<Hit>> search(String question, {int k = 10}) async {
    final qv = await embed(question);
    final vecJson = '[${qv.join(",")}]';
    final r = await db.execute('''
      SELECT a.id, a.title, s.rrf_score
      FROM vec_hybrid_search(
             'articles', 'embedding', 'body',
             VEC('$vecJson'), ?, $k, 60
           ) AS s
      JOIN articles a ON a.id = s.rowid
      ORDER BY s.rrf_score DESC
    ''', params: [question]);
    return [
      for (final row in r.rows)
        Hit(id: row[0] as int, title: row[1] as String,
            score: (row[2] as num).toDouble()),
    ];
  }
}
```

## Paged tables

The FTS5 corpus is built in-memory the first time it's used, but for
paged tables you must warm it explicitly at startup so the first query
doesn't stall on a full-scan build:

```sql
PRAGMA fts5_warm('articles.body');
```

Then hybrid queries work exactly the same. Vector index deltas from
INSERT/UPDATE/DELETE are drained on every read, so the paged and
in-memory paths return the same results.

## When hybrid isn't worth it

- **Small corpus (< 1000 rows).** Just use pure vector search — BM25's
  win is marginal at that scale.
- **Fully-formed natural-language queries only.** BM25 barely helps if
  users never type identifiers or exact keywords.
- **Vectors already encode text well and users type well.** e.g.
  customer-support search over long, well-written articles — pure
  vector may be enough.

Ship hybrid by default anyway. It's rarely worse than pure vector and
often noticeably better on real user queries.
