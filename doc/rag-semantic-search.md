# Recipe: RAG semantic search over a document corpus

**Scenario.** You have a knowledge base — support articles, docs pages,
policy PDFs, chat logs — and want a Q&A system that retrieves the most
relevant passages for a user question, then hands them to an LLM.

**Pattern.** Classic Retrieval-Augmented Generation (RAG):

```
user question
     │
     ├── embed(question)  →  query vector
     │
     ├── vec_search / vec_hybrid_search  →  top-k passages
     │
     └── LLM(question, retrieved_passages)  →  grounded answer
```

## Schema

Chunk your documents into passages of a few hundred tokens each — that
tends to give the best retrieval quality. Store each chunk as its own
row so the granularity of retrieval matches the granularity of relevance.

```sql
CREATE TABLE chunks (
  id           INTEGER PRIMARY KEY,
  doc_id       INTEGER NOT NULL,          -- foreign key to a documents table
  ord          INTEGER NOT NULL,          -- position of this chunk within the doc
  title        TEXT    NOT NULL,          -- document title (denormalised for display)
  url          TEXT,                      -- deep link back to the source
  chunk_text   TEXT    NOT NULL,          -- the passage the LLM will actually see
  updated_at   TEXT    NOT NULL,
  embedding    BLOB VECTOR(
    dim=1536,                             -- text-embedding-3-small
    kind=hnsw,                            -- best recall / latency for < ~1M rows
    metric=cosine,
    m=16,
    ef_construction=64
  )
);

CREATE INDEX idx_chunks_doc ON chunks(doc_id);
```

## Ingest

Compute the embedding in your app, then pass the raw `[f, f, f, ...]`
JSON array through `VEC(...)`:

```dart
Future<void> ingest(
  Database db,
  int docId,
  int ord,
  String title,
  String url,
  String chunkText,
  List<double> embedding,
) async {
  final vecJson = '[${embedding.join(",")}]';
  await db.execute(
    "INSERT INTO chunks (doc_id, ord, title, url, chunk_text, updated_at, embedding) "
    "VALUES (?, ?, ?, ?, ?, datetime('now'), VEC(?))",
    params: [docId, ord, title, url, chunkText, vecJson],
  );
}
```

For a bulk load, use `vec_batch_insert` — it bypasses per-row SQL
parsing and lets you push thousands of rows per second:

```sql
SELECT * FROM vec_batch_insert(
  'chunks', 'id', 'embedding',
  '[{"id":123,"vec":[0.01,0.02,...]},
    {"id":124,"vec":[0.03,0.04,...]}, ...]'
);
```

## Retrieve

The simplest form — pure semantic top-k:

```sql
SELECT c.id, c.title, c.url, c.chunk_text
FROM vec_search('chunks', 'embedding',
                VEC('[0.11, -0.03, ...]'),  -- embed(user_question)
                8) AS s
JOIN chunks c ON c.id = s.rowid
ORDER BY s.distance;
```

## Retrieve — hybrid (recommended for RAG)

Pure vector retrieval misses exact keyword hits ("SKU-1234", "AWS Lambda",
proper names). Hybrid search fuses vector rank with BM25 keyword rank via
Reciprocal Rank Fusion, which is nearly always strictly better than either
signal alone:

```sql
SELECT c.id, c.title, c.chunk_text,
       s.distance, s.bm25, s.rrf_score
FROM vec_hybrid_search(
       'chunks', 'embedding', 'chunk_text',
       VEC('[0.11, -0.03, ...]'),          -- vector side: embed(question)
       'aws lambda cold start timeout',    -- text side: raw question
       8,                                   -- k
       60                                   -- RRF constant (default)
     ) AS s
JOIN chunks c ON c.id = s.rowid
ORDER BY s.rrf_score DESC;
```

## End-to-end Dart wrapper

```dart
class RagRetriever {
  RagRetriever(this.db, this.embed);
  final Database db;
  final Future<List<double>> Function(String) embed;

  Future<List<Passage>> retrieve(String question, {int k = 8}) async {
    final qv = await embed(question);
    final vecJson = '[${qv.join(",")}]';
    final r = await db.execute('''
      SELECT c.id, c.doc_id, c.title, c.url, c.chunk_text,
             s.distance, s.bm25, s.rrf_score
      FROM vec_hybrid_search(
             'chunks', 'embedding', 'chunk_text',
             VEC('$vecJson'), ?, $k, 60
           ) AS s
      JOIN chunks c ON c.id = s.rowid
      ORDER BY s.rrf_score DESC
    ''', params: [question]);

    return [
      for (final row in r.rows)
        Passage(
          id: row[0] as int,
          docId: row[1] as int,
          title: row[2] as String,
          url: row[3] as String?,
          text: row[4] as String,
          score: (row[7] as num).toDouble(),
        ),
    ];
  }
}

class Passage {
  Passage({
    required this.id, required this.docId, required this.title,
    required this.url, required this.text, required this.score,
  });
  final int id, docId;
  final String title;
  final String? url;
  final String text;
  final double score;
}
```

## Update / delete flow

The engine keeps the index incrementally consistent — no manual rebuild
needed for regular DML:

```sql
UPDATE chunks
   SET chunk_text = ?, embedding = VEC(?), updated_at = datetime('now')
 WHERE id = ?;

DELETE FROM chunks WHERE doc_id = ?;
```

HNSW uses tombstones on `DELETE` / `UPDATE`; when the tombstone ratio
exceeds 30% the binding auto-rebuilds on the next query. You can also
force a clean rebuild:

```sql
PRAGMA vector_index_rebuild('chunks.embedding');
```

## Scaling notes

- **Up to ~100k chunks**: `kind=flat` gives 100% recall and no build
  cost. Perfectly fine for docs, wikis, small product catalogs.
- **100k – 1M chunks**: `kind=hnsw` (default choice for RAG).
- **> 1M chunks**: consider `kind=ivfpq` with `filter_cols` to prune by
  tenant / category first — see
  [index-selection.md](index-selection.md).
- **Corpus larger than RAM**: use `CREATE TABLE chunks (…) USING paged`
  and call `PRAGMA vector_index_warm('chunks.embedding')` at startup to
  build the index from disk once.
