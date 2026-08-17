/// End-to-end **vector database** walkthrough for `dart_db_server`.
///
/// This example builds a tiny knowledge base of product descriptions,
/// stores them as vectors alongside SQL columns (tenant, kind, price),
/// then exercises every retrieval mode the engine offers:
///
///   1. Plain k-NN search               → `vec_search`
///   2. Filtered k-NN search            → payload-filter pruning
///   3. Range search                    → `vec_range_search`
///   4. Hybrid vector + BM25 retrieval  → `vec_hybrid_search`
///   5. Batch multi-query k-NN          → `vec_search_batch`
///   6. Fast-path planner + EXPLAIN     → auto-uses the built index
///
/// Run:
///   dart run example/vector_semantic_search.dart
///
/// This example uses toy 4-D vectors that are easy to reason about. In a
/// real system you would swap them for embeddings from a model like
/// `text-embedding-3-small` (dim=1536), Cohere Embed (dim=1024), or a
/// local ONNX / GGUF encoder.

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';

Future<void> main() async {
  final dbPath =
      '${Directory.systemTemp.path}${Platform.pathSeparator}vecstore.json';
  // Fresh run every time.
  try {
    await File(dbPath).delete();
  } catch (_) {}

  final db = await Database.open(dbPath);
  try {
    await _seed(db);
    await _plainKnn(db);
    await _filteredKnn(db);
    await _rangeSearch(db);
    await _hybridSearch(db);
    await _batchSearch(db);
    await _fastPathPlanner(db);
    await _adminPragmas(db);
  } finally {
    await db.close();
  }
}

// ---------------------------------------------------------------------------
// Schema + data
// ---------------------------------------------------------------------------

Future<void> _seed(Database db) async {
  // A vector index is declared *inline* on the column definition. The
  // engine builds & maintains the index automatically on INSERT /
  // UPDATE / DELETE.
  //
  // `filter_cols='tenant,kind'` opts into payload-filter pruning: the
  // engine keeps an inverse index (col=value → row-position set) so that
  // filtered searches intersect candidate rows in O(1) BEFORE touching
  // the vector index.
  await db.execute('''
    CREATE TABLE products (
      id INTEGER PRIMARY KEY,
      tenant INTEGER NOT NULL,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      price REAL NOT NULL,
      embedding BLOB VECTOR(
        dim=4,
        kind=hnsw,
        metric=cosine,
        m=16,
        ef_construction=64,
        filter_cols='tenant,kind'
      )
    )
  ''');

  // Toy 4-D vectors: dimensions are (has_screen, is_wearable, has_audio,
  // premium_tier). Real code would compute these with a model call.
  final rows = <List<Object?>>[
    [1, 1, 'electronics', '4K OLED TV', 'A 55-inch 4K OLED television',
        1299.0, '[1.0, 0.0, 0.9, 0.9]'],
    [2, 1, 'electronics', 'Bluetooth Headphones',
        'Wireless noise-cancelling headphones', 249.0,
        '[0.0, 0.5, 1.0, 0.7]'],
    [3, 1, 'wearables', 'Fitness Watch',
        'Waterproof activity tracker with HR sensor', 149.0,
        '[0.4, 1.0, 0.2, 0.4]'],
    [4, 1, 'wearables', 'Smart Ring',
        'Sleep and recovery ring', 299.0, '[0.0, 1.0, 0.0, 0.8]'],
    [5, 2, 'electronics', 'Desk Monitor',
        '27-inch 1440p IPS panel', 349.0, '[1.0, 0.0, 0.0, 0.6]'],
    [6, 2, 'electronics', 'Streaming Speaker',
        'Compact bookshelf smart speaker', 129.0, '[0.0, 0.0, 1.0, 0.3]'],
    [7, 2, 'wearables', 'GPS Running Watch',
        'Trail-runner GPS watch with topo maps', 449.0,
        '[0.4, 1.0, 0.1, 0.9]'],
    [8, 2, 'books', 'Cookbook: Weeknight',
        'Fast recipes for busy families', 24.0, '[0.0, 0.0, 0.0, 0.1]'],
  ];

  for (final r in rows) {
    await db.execute(
      'INSERT INTO products VALUES '
      "(${r[0]}, ${r[1]}, '${r[2]}', '${r[3]}', '${r[4]}', "
      "${r[5]}, VEC('${r[6]}'))",
    );
  }

  _banner('Seeded 8 products across 2 tenants');
}

// ---------------------------------------------------------------------------
// 1. Plain k-NN — "find the 3 nearest products to a query vector"
// ---------------------------------------------------------------------------

Future<void> _plainKnn(Database db) async {
  _banner('1. Plain k-NN via vec_search');
  final r = await db.execute('''
    SELECT p.id, p.title, s.distance
    FROM vec_search('products', 'embedding',
                    VEC('[1.0, 0.0, 0.9, 0.9]'), 3) AS s
    JOIN products p ON p.id = s.rowid
    ORDER BY s.distance
  ''');
  _dump(r);
}

// ---------------------------------------------------------------------------
// 2. Filtered k-NN — same query, but only within tenant=1 and kind='wearables'
// ---------------------------------------------------------------------------

Future<void> _filteredKnn(Database db) async {
  _banner('2. Filtered k-NN via payload-filter pruning');
  // Two equivalent ways to invoke:
  //
  //   a) TVF form with an explicit filter_json (portable across joins):
  final r = await db.execute('''
    SELECT p.id, p.title, s.distance
    FROM vec_search_filtered(
           'products', 'embedding',
           VEC('[0.4, 1.0, 0.2, 0.4]'),  -- query
           5,                              -- k
           '{"tenant": 1, "kind": "wearables"}'
         ) AS s
    JOIN products p ON p.id = s.rowid
    ORDER BY s.distance
  ''');
  _dump(r);

  //   b) Fast-path form — plain SELECT with ORDER BY + LIMIT + WHERE
  //      on filter columns is auto-routed through the built index:
  _banner('2b. Same query as a plain SELECT (uses the fast path)');
  final r2 = await db.execute('''
    SELECT id, title, VEC_COSINE(embedding, VEC('[0.4, 1.0, 0.2, 0.4]')) AS d
    FROM products
    WHERE tenant = 1 AND kind = 'wearables'
    ORDER BY VEC_COSINE(embedding, VEC('[0.4, 1.0, 0.2, 0.4]'))
    LIMIT 5
  ''');
  _dump(r2);
}

// ---------------------------------------------------------------------------
// 3. Range search — "everything within distance <= threshold"
// ---------------------------------------------------------------------------

Future<void> _rangeSearch(Database db) async {
  _banner('3. Range search via vec_range_search');
  final r = await db.execute('''
    SELECT p.id, p.title, s.distance
    FROM vec_range_search(
           'products', 'embedding',
           VEC('[0.0, 0.5, 1.0, 0.7]'),
           0.15                              -- threshold
         ) AS s
    JOIN products p ON p.id = s.rowid
    ORDER BY s.distance
  ''');
  _dump(r);
}

// ---------------------------------------------------------------------------
// 4. Hybrid search — fuse vector distance with BM25 text score via RRF
// ---------------------------------------------------------------------------

Future<void> _hybridSearch(Database db) async {
  _banner('4. Hybrid vector + BM25 via vec_hybrid_search');
  final r = await db.execute('''
    SELECT p.id, p.title, s.distance, s.bm25, s.rrf_score
    FROM vec_hybrid_search(
           'products', 'embedding', 'description',
           VEC('[0.4, 1.0, 0.2, 0.4]'),      -- query vector
           'gps watch runner',                -- query text
           5                                  -- k
         ) AS s
    JOIN products p ON p.id = s.rowid
    ORDER BY s.rrf_score DESC
  ''');
  _dump(r);
}

// ---------------------------------------------------------------------------
// 5. Batch multi-query k-NN
// ---------------------------------------------------------------------------

Future<void> _batchSearch(Database db) async {
  _banner('5. Batch multi-query search via vec_search_batch');
  final r = await db.execute('''
    SELECT s.query_idx, p.id, p.title, s.distance
    FROM vec_search_batch(
           'products', 'embedding',
           '[[1.0,0.0,0.9,0.9], [0.0,1.0,0.0,0.8]]',
           2
         ) AS s
    JOIN products p ON p.id = s.rowid
    ORDER BY s.query_idx, s.distance
  ''');
  _dump(r);
}

// ---------------------------------------------------------------------------
// 6. Fast-path planner + EXPLAIN
// ---------------------------------------------------------------------------

Future<void> _fastPathPlanner(Database db) async {
  _banner('6. EXPLAIN QUERY PLAN surfaces the vector index choice');
  final r = await db.execute('''
    EXPLAIN QUERY PLAN
    SELECT id FROM products
    WHERE tenant = 1
    ORDER BY VEC_COSINE(embedding, VEC('[1.0, 0.0, 0.9, 0.9]'))
    LIMIT 3
  ''');
  _dump(r);
}

// ---------------------------------------------------------------------------
// Admin PRAGMAs — inspect + verify + rebuild
// ---------------------------------------------------------------------------

Future<void> _adminPragmas(Database db) async {
  _banner('7. PRAGMA vector_index_list');
  _dump(await db.execute('PRAGMA vector_index_list'));

  _banner('8. PRAGMA vector_index_stats');
  _dump(
      await db.execute("PRAGMA vector_index_stats('products.embedding')"));

  _banner('9. PRAGMA vector_verify_all');
  _dump(await db.execute('PRAGMA vector_verify_all'));
}

// ---------------------------------------------------------------------------
// Tiny console helpers
// ---------------------------------------------------------------------------

void _banner(String s) {
  print('');
  print('=== $s ===');
}

void _dump(QueryResult r) {
  if (r.message != null && r.message!.isNotEmpty) {
    print(r.message);
    return;
  }
  print(r.columns.join(' | '));
  print(List.filled(r.columns.length, '---').join(' | '));
  for (final row in r.rows) {
    print(row.map((c) => c ?? '').join(' | '));
  }
}
