/// V21 incremental vector-index maintenance: plain INSERT into a
/// vector-indexed table no longer invalidates the built index; new
/// rows are appended incrementally on the next query. UPDATE only
/// invalidates when the SET clause touches a vector-indexed column.
/// DELETE and INSERT OR REPLACE still trigger full invalidation.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

/// Instrumented FlatIndex helper: builds one from scratch and compares
/// its search output to the SQL fast path's result.
void _sameTopKAsBruteForce(
  List<int> got,
  List<int> expected,
  String kind,
) {
  expect(got.toSet(), expected.toSet(),
      reason: 'kind=$kind: fast path returned different ids');
}

void main() {
  group('V21 incremental append: INSERT-only workload', () {
    test('plain INSERT does not invalidate; index picks up new row', () async {
      const dim = 4;
      final rng = math.Random(1);
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        // Bulk-load, register, warm.
        for (var i = 0; i < 20; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Insert a new row with a distinctive vector.
        await db.execute("INSERT INTO docs VALUES (999, VEC('[5, 0, 0, 0]'))");

        // Query near the new vector — it must appear first.
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[5, 0, 0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 999,
            reason:
                'newly-inserted row must be visible via incremental append');
      } finally {
        await db.close();
      }
    });

    test('multiple sequential INSERTs each land in the index', () async {
      const dim = 2;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        await db.execute("INSERT INTO docs VALUES (2, VEC('[2, 0]'))");
        await db.execute("INSERT INTO docs VALUES (3, VEC('[3, 0]'))");
        await db.execute("INSERT INTO docs VALUES (4, VEC('[4, 0]'))");

        // All four rows should be searchable.
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 4",
        );
        expect(r.rows.map((r) => r[0]).toList(), [1, 2, 3, 4]);
      } finally {
        await db.close();
      }
    });

    test('HNSW incremental add works', () async {
      const dim = 8;
      final rng = math.Random(2);
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 0; i < 30; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
          efConstruction: 40,
          efSearch: 32,
        ));
        await db.warmVectorIndexes();

        // Append a very distinctive vector.
        await db.execute(
          "INSERT INTO docs VALUES (999, VEC('[10, 10, 10, 10, 10, 10, 10, 10]'))",
        );

        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[10, 10, 10, 10, 10, 10, 10, 10]')) "
          "ASC LIMIT 1",
        );
        expect(r.rows.single[0], 999);
      } finally {
        await db.close();
      }
    });
  });

  group('V21 UPDATE column-aware invalidation', () {
    test('UPDATE non-vector column does not invalidate', () async {
      const dim = 2;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'title TEXT, embedding BLOB)');
        for (var i = 0; i < 10; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, 'doc_$i', VEC('[$i, 0]'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Update title — must NOT invalidate the vector index.
        await db.execute("UPDATE docs SET title = 'renamed' WHERE id = 5");

        // Query still works; row 0 still nearest to [0,0].
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 0);
      } finally {
        await db.close();
      }
    });

    test('UPDATE vector column DOES invalidate', () async {
      const dim = 2;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[100, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Nearest to [0,0] is id=1.
        var r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 1);

        // Move id=2's embedding onto [0.1, 0] — now id=2 should be nearest.
        await db.execute(
          "UPDATE docs SET embedding = VEC('[0.1, 0]') WHERE id = 2",
        );
        r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 2,
            reason: 'UPDATE of vector col must invalidate; rebuilt index '
                'should reflect new embedding');
      } finally {
        await db.close();
      }
    });
  });

  group('V21 DELETE and INSERT OR REPLACE still invalidate', () {
    test('DELETE invalidates so subsequent queries do not return deleted row',
        () async {
      const dim = 2;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[0, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (3, VEC('[2, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        await db.execute('DELETE FROM docs WHERE id = 1');

        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 3",
        );
        expect(r.rows.map((r) => r[0]).toList(), [2, 3]);
      } finally {
        await db.close();
      }
    });

    test('INSERT OR REPLACE invalidates (positions can shift)', () async {
      const dim = 2;
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[2, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // REPLACE id=1 with a very different vector.
        await db.execute(
          "INSERT OR REPLACE INTO docs VALUES (1, VEC('[100, 0]'))",
        );

        // Nearest to [0,0] should now be id=2 (dist 2).
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });
  });

  group('V21 correctness: incremental vs full rebuild ranking parity', () {
    test('incremental result set matches fresh-rebuild result set', () async {
      const dim = 4;
      final rng = math.Random(42);
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 0; i < 15; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();
        // Insert 5 more rows.
        for (var i = 15; i < 20; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
          );
        }
        final query = _rand(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final gotIncremental = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 5",
        );

        // Independently build a fresh FlatIndex over all 20 rows to
        // get ground truth.
        final all = await db.execute('SELECT id, embedding FROM docs');
        final flat = FlatIndex(dim, defaultMetric: VectorMetric.l2);
        for (final row in all.rows) {
          flat.add(row[0], decodeVectorBlob(row[1] as List<int>));
        }
        final truth = flat.search(query, 5).map((h) => h.id).toList();
        _sameTopKAsBruteForce(
          gotIncremental.rows.map((r) => r[0] as int).toList(),
          truth.cast<int>(),
          'flat',
        );
      } finally {
        await db.close();
      }
    });
  });
}
