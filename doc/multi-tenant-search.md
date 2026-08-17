# Recipe: multi-tenant vector search (SaaS pattern)

**Scenario.** A single database serves many tenants (customers,
organisations, workspaces). Every vector search must be strictly
scoped to the calling tenant. You may also want secondary filters
like `kind`, `status`, `language`.

**Wrong way — filter after search.** Post-filtering top-k results
often returns fewer than k rows (or none) because the raw top-k was
dominated by other tenants. You end up over-fetching by 10–100×,
which defeats the point of an ANN index.

**Right way — filter before search.** Declare filter columns on the
index; the engine keeps an inverse index per filter column and
intersects the candidate row set in O(1) **before** touching the
vector index.

## Schema

Add `filter_cols='...'` to the vector column DDL. Every column named
here gets a `Map<value, Set<row_position>>` maintained incrementally
alongside the index:

```sql
CREATE TABLE products (
  id INTEGER PRIMARY KEY,
  tenant_id INTEGER NOT NULL,
  kind TEXT NOT NULL,          -- 'electronics' | 'wearables' | 'books' | ...
  status TEXT NOT NULL,        -- 'published' | 'draft' | 'archived'
  language TEXT NOT NULL,      -- 'en' | 'es' | 'fr' | ...
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  price REAL NOT NULL,
  embedding BLOB VECTOR(
    dim=1536,
    kind=hnsw,
    metric=cosine,
    filter_cols='tenant_id,kind,status,language'
  )
);
```

You can declare up to any number of filter columns — the engine tracks
them all incrementally. Cardinality doesn't matter for correctness, but
low-cardinality columns give the biggest speed win.

## Query — one filter column

Either the plain-SQL fast path (usable inside larger queries):

```sql
SELECT id, title
FROM products
WHERE tenant_id = 42
ORDER BY VEC_COSINE(embedding, VEC('[0.1, 0.4, ...]'))
LIMIT 10;
```

`EXPLAIN QUERY PLAN` will show:

```
SEARCH products USING VECTOR INDEX (hnsw) WITH FILTER
```

…or the table-valued function form (composable with JOINs):

```sql
SELECT p.id, p.title, s.distance
FROM vec_search_filtered(
       'products', 'embedding',
       VEC('[0.1, 0.4, ...]'),
       10,
       '{"tenant_id": 42}'
     ) AS s
JOIN products p ON p.id = s.rowid
ORDER BY s.distance;
```

## Query — multiple filter columns

The `filter_json` map is an AND of equalities. All values must be present
and non-empty; if the intersection of matching rows is empty, the query
returns zero rows without touching the vector index:

```sql
SELECT p.id, p.title
FROM vec_search_filtered(
       'products', 'embedding',
       VEC('[0.1, 0.4, ...]'),
       10,
       '{"tenant_id": 42, "kind": "wearables", "status": "published", "language": "en"}'
     ) AS s
JOIN products p ON p.id = s.rowid;
```

## Dart helper

```dart
class TenantSearch {
  TenantSearch(this.db, this.tenantId);
  final Database db;
  final int tenantId;

  Future<List<Row>> nearest(
    List<double> queryVec, {
    required int k,
    Map<String, Object> extra = const {},
  }) async {
    final filter = {'tenant_id': tenantId, ...extra};
    final vecJson = '[${queryVec.join(",")}]';
    final filterJson = jsonEncode(filter);
    final r = await db.execute('''
      SELECT p.id, p.title, p.price, s.distance
      FROM vec_search_filtered(
             'products', 'embedding',
             VEC('$vecJson'),
             $k,
             ?
           ) AS s
      JOIN products p ON p.id = s.rowid
      ORDER BY s.distance
    ''', params: [filterJson]);
    return [
      for (final row in r.rows)
        Row(id: row[0] as int, title: row[1] as String,
            price: (row[2] as num).toDouble(), distance: (row[3] as num).toDouble()),
    ];
  }
}
```

## Batch retrieval — many queries, same tenant

When you're computing recommendations or batching an autocomplete
endpoint, use the batch variant. The engine resolves the filter set
**once** and reuses it across all query vectors:

```sql
SELECT query_idx, rowid, distance
FROM vec_search_filtered_batch(
       'products', 'embedding',
       '[[0.1, 0.4, ...], [0.2, 0.5, ...], [0.3, 0.6, ...]]',
       10,
       '{"tenant_id": 42, "status": "published"}'
     )
ORDER BY query_idx, distance;
```

## Range search + filter fusion

`vec_range_search` also honours filters — useful for "show me every
similar-enough product in this tenant":

```sql
SELECT p.id, p.title, s.distance
FROM vec_range_search(
       'products', 'embedding',
       VEC('[0.1, 0.4, ...]'),
       0.25,                                -- threshold (cosine distance)
       'cosine',                            -- explicit metric
       '{"tenant_id": 42, "status": "published"}'
     ) AS s
JOIN products p ON p.id = s.rowid
ORDER BY s.distance;
```

## Gotchas

- **`filter_cols` must be declared at index-creation time.** Adding a
  new filter column later requires `PRAGMA vector_index_rebuild('t.col')`.
- **Filter values are matched by `==`** on the stored value. Store
  strings as canonical case (`'wearables'` vs `'Wearables'`) or add a
  computed / normalized column.
- **UPDATEs to filter columns keep the index warm** — the payload
  buckets are updated incrementally. No manual rebuild needed.
- **The filter_json values may be null** if you're storing null values.
  Store an explicit sentinel like `'none'` if you also want "no
  category" as a filterable value.
- **`kind` in your table name conflicts with `kind` as an index attribute** —
  since the JSON parser treats them differently, this is fine, but keep an
  eye on error messages when the filter key clashes with an SQL keyword.
