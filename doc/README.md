# dart_db_server — vector database docs

Real-world recipes for the vector-search engine that ships with
`dart_db_server`. Each doc is self-contained: paste the SQL into any
running `Database`, or lift the Dart snippets into your app.

For a runnable walkthrough, see
[`example/vector_semantic_search.dart`](../example/vector_semantic_search.dart).

## Recipes

| Doc | When to reach for it |
| --- | --- |
| [rag-semantic-search.md](rag-semantic-search.md) | Retrieval-augmented generation over a document corpus (Q&A, chatbots, search). |
| [multi-tenant-search.md](multi-tenant-search.md) | SaaS or B2B product where each tenant's rows must never leak into another tenant's search results. |
| [hybrid-search.md](hybrid-search.md) | You want both semantic recall (embeddings) and lexical precision (BM25 keywords) fused into one ranking. |
| [recommendations.md](recommendations.md) | User → item recommendations, "customers who bought this also…" patterns, collaborative filtering. |
| [duplicate-detection.md](duplicate-detection.md) | Find near-duplicates within a threshold (deduplication, plagiarism, clustering). |
| [index-selection.md](index-selection.md) | Which of Flat / HNSW / IVFFlat / LSH / PQ / IVFPQ to pick for your dataset size + recall / speed / memory trade-off. |
| [operations.md](operations.md) | Warming, rebuilding, verifying, and monitoring vector indexes in production. |

## Concept map

| SQL surface | What it does | See |
| --- | --- | --- |
| `BLOB VECTOR(dim=..., kind=..., metric=..., filter_cols='...')` | Inline column-level DDL for the vector index. | Any recipe |
| `VEC('[1.0, 2.0, ...]')` / `VEC_F32(...)` | Cast a JSON array literal → BLOB vector. | Any recipe |
| `VEC_L2` / `VEC_L2SQ` / `VEC_IP` / `VEC_COSINE` | Scalar distance functions (used in `ORDER BY` for the fast path). | RAG, recommendations |
| `vec_search(t, col, q, k)` | k-NN as a table-valued function (composable with JOINs / CTEs). | Any recipe |
| `vec_search_filtered(t, col, q, k, filter_json)` | k-NN restricted to rows matching a payload filter map. | Multi-tenant |
| `vec_range_search(t, col, q, threshold)` | Every row within a distance threshold. | Duplicate detection |
| `vec_hybrid_search(t, vec_col, text_col, q_vec, q_text, k)` | Vector + BM25 fused via Reciprocal Rank Fusion. | Hybrid |
| `vec_search_join(a, ac, b, bc, k)` | Row-to-row k-NN join between two tables. | Recommendations |
| `PRAGMA vector_index_list` / `_stats` / `_verify[_all]` / `_rebuild[_all]` / `_warm[_all]` | Admin surface. | Operations |

## Choosing embeddings

Every recipe assumes you have a way to compute an embedding vector for a
piece of text (or image, or whatever). Common choices:

| Provider | Model | Dim | Notes |
| --- | --- | --- | --- |
| OpenAI | `text-embedding-3-small` | 1536 | Cheap, strong baseline for English + code. |
| OpenAI | `text-embedding-3-large` | 3072 | Higher quality, ~5x cost. |
| Cohere | `embed-english-v3.0` | 1024 | Strong on retrieval benchmarks. |
| Local (ONNX) | `all-MiniLM-L6-v2` | 384 | Free, fast, no network. |
| Local (llama.cpp) | `nomic-embed-text-v1.5` | 768 | Free, better quality than MiniLM. |

Pick a model, then set `dim=<that number>` on your column DDL. The engine
does not care where the vector came from — the same schema works for any
provider.

## Sanity checklist before going to production

- [ ] Every vector column has an explicit `dim=` matching your embedder.
- [ ] `metric=` matches how your embedder was trained
      (`cosine` is safe for most modern text embedders; some use `l2`).
- [ ] `kind=` is chosen for your dataset size — see
      [index-selection.md](index-selection.md).
- [ ] Payload-filter columns are declared with `filter_cols='a,b,c'`
      when you actually filter — see [multi-tenant-search.md](multi-tenant-search.md).
- [ ] Paged tables (`USING paged`) are warmed at startup:
      `PRAGMA vector_index_warm_all` after `Database.open`.
- [ ] A recurring `PRAGMA vector_verify_all` runs in a health check.
- [ ] `PRAGMA vector_analyze('t.col')` has been run once on real data
      to record the expected recall of the chosen index kind.
