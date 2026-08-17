# Recipe: recommendations & collaborative filtering

**Scenario.** You have users and items (products, videos, articles).
You want to recommend items a user is likely to interact with next.

**Pattern.** Both users and items get vectors. Item vectors are usually
learned from content (title / description embeddings) or from an
implicit-feedback matrix factorisation (ALS, LightFM, Two-Tower). User
vectors are either learned the same way or built dynamically as a
weighted average of items they've interacted with.

The engine's `inner_product` metric makes dot-product ranking a
one-liner. That's what most learned embedding models produce.

## Schema

Two tables share a vector dimension:

```sql
CREATE TABLE items (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  category TEXT NOT NULL,
  price REAL NOT NULL,
  embedding BLOB VECTOR(
    dim=128,                      -- typical for learned rec vectors
    kind=hnsw,
    metric=inner_product,         -- dot-product ranking
    filter_cols='category'
  )
);

CREATE TABLE user_vecs (
  user_id INTEGER PRIMARY KEY,
  embedding BLOB VECTOR(
    dim=128,
    kind=flat,                    -- there are typically far fewer users than items
    metric=inner_product
  )
);
```

Note the metric choice: `inner_product` ranks by ↑ dot product. Use
`cosine` instead if your vectors are pre-normalised and you want unit
comparisons.

## Recommend items for one user

```sql
SELECT i.id, i.title, s.distance   -- 'distance' is -dot for inner_product
FROM user_vecs u,
     vec_search('items', 'embedding',
                u.embedding, 20) AS s
JOIN items i ON i.id = s.rowid
WHERE u.user_id = 42
ORDER BY s.distance;
```

Or the filtered variant, if you want "recommend electronics only":

```sql
SELECT i.id, i.title, s.distance
FROM user_vecs u,
     vec_search_filtered('items', 'embedding',
                         u.embedding, 20,
                         '{"category": "electronics"}') AS s
JOIN items i ON i.id = s.rowid
WHERE u.user_id = 42
ORDER BY s.distance;
```

## Batch: recommend for many users at once

`vec_search_join` is a table-to-table k-NN join. For every row in the
"query" table, it produces the top-k matches in the "target" table:

```sql
SELECT s.query_rowid AS user_id,
       i.id AS item_id,
       i.title,
       s.distance
FROM vec_search_join(
       'items', 'embedding',        -- target table
       'user_vecs', 'embedding',    -- query table
       20                            -- top-k per user
     ) AS s
JOIN items i ON i.id = s.rowid
ORDER BY s.query_rowid, s.distance;
```

That's a full "top-k per user" recommendation matrix in one SQL
statement. Under the hood the target index is built once and probed N
times — dramatically faster than N `vec_search` calls.

## User vector from interaction history

If you don't have a learned user embedding, build one on the fly by
averaging (or weighting) recent-item vectors:

```dart
Future<List<double>> userVectorFromHistory(
  Database db, int userId, {int lastN = 50}) async {
  final r = await db.execute('''
    SELECT VEC_TO_JSON(VEC_AVG(i.embedding))
    FROM interactions x
    JOIN items i ON i.id = x.item_id
    WHERE x.user_id = ?
    ORDER BY x.ts DESC
    LIMIT ?
  ''', params: [userId, lastN]);
  final json = jsonDecode(r.rows.first[0] as String) as List;
  return json.cast<num>().map((n) => n.toDouble()).toList();
}
```

`VEC_AVG` is a built-in vector aggregate that returns an element-wise
mean over a group. Once you have a user vector, feed it back into
`vec_search`.

## "Users who bought this also bought" (item-to-item)

Skip the user side entirely — vector-nearest items to a given item:

```sql
SELECT j.id, j.title, s.distance
FROM items i,
     vec_search('items', 'embedding',
                i.embedding, 6) AS s
JOIN items j ON j.id = s.rowid
WHERE i.id = ?     -- source item
  AND j.id <> i.id  -- exclude self
ORDER BY s.distance;
```

## Cold-start users

For brand-new users with no history, fall back to a content-based
signal (e.g. their signup preferences):

```dart
Future<List<Recommendation>> coldStart(
  Database db, List<String> favoriteCategories, {int k = 20}) async {
  final filter = jsonEncode({'category': favoriteCategories.first});
  // Use category centroid as pseudo-user vector.
  final centroid = await db.execute('''
    SELECT VEC_TO_JSON(VEC_AVG(embedding))
    FROM items WHERE category = ?
  ''', params: [favoriteCategories.first]);
  final vec = (jsonDecode(centroid.rows.first[0] as String) as List)
      .cast<num>().map((n) => n.toDouble()).toList();
  // ... then a normal vec_search_filtered ...
}
```

## Excluding already-seen items

Simple approach — join out interactions in SQL:

```sql
SELECT i.id, i.title, s.distance
FROM user_vecs u,
     vec_search('items', 'embedding', u.embedding, 40) AS s
JOIN items i ON i.id = s.rowid
LEFT JOIN interactions x
  ON x.user_id = u.user_id AND x.item_id = i.id
WHERE u.user_id = 42
  AND x.item_id IS NULL   -- not yet interacted with
ORDER BY s.distance
LIMIT 20;
```

The over-fetch (40) leaves headroom for the LEFT JOIN filter.

## Freshness

Recommendation embeddings often change nightly (retraining) or with
every interaction (online updates):

```sql
-- Retraining: bulk-refresh all user vectors, one big batch
SELECT * FROM vec_batch_insert('user_vecs', 'user_id', 'embedding',
                               '[{"id":1,"vec":[...]}, ...]');

-- Or per-user online updates
UPDATE user_vecs
   SET embedding = VEC(?)
 WHERE user_id = ?;
```

Both keep the vector index incrementally consistent. For a full clean
rebuild after a large retraining run:

```sql
PRAGMA vector_index_rebuild_all;
```
