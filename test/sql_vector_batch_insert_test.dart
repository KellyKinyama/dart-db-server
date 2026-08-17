/// V27 VEC_BATCH_INSERT table-valued function — bulk-insert `{id, vec}`
/// pairs from a JSON batch into a vector-indexed table. Drives the V21
/// incremental append path (built index survives; catches up at next
/// query).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec27_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V27 VEC_BATCH_INSERT', () {
    test('object-form batch inserts and search finds new rows', () async {
      final db = await Database.open(_tmp('obj_form'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        // Seed a couple of rows first so the binding has data to warm on.
        await db.execute("INSERT INTO docs VALUES (1, VEC('[10, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Bulk-insert 3 more rows via TVF.
        final r = await db.execute(
          "SELECT inserted FROM vec_batch_insert('docs', 'id', 'embedding', "
          "'[{\"id\": 2, \"vec\": [0.5, 0]}, "
          " {\"id\": 3, \"vec\": [5, 0]}, "
          " {\"id\": 4, \"vec\": [1, 0]}]')",
        );
        expect(r.rows.single[0], 3);

        // Verify the new rows land AND the built index sees them.
        final q = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(q.rows.single[0], 2);

        // Count all rows.
        final c = await db.execute("SELECT COUNT(*) FROM docs");
        expect(c.rows.single[0], 4);
      } finally {
        await db.close();
      }
    });

    test('positional-form batch also works', () async {
      final db = await Database.open(_tmp('pos_form'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 3,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT inserted FROM vec_batch_insert('docs', 'id', 'embedding', "
          "'[[10, [1, 2, 3]], [11, [4, 5, 6]]]')",
        );
        expect(r.rows.single[0], 2);

        final c = await db.execute("SELECT COUNT(*) FROM docs");
        expect(c.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });

    test('dim mismatch entries are skipped, valid ones inserted', () async {
      final db = await Database.open(_tmp('dim_skip'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        // Second entry has dim=3, mismatched with binding.dim=2.
        final r = await db.execute(
          "SELECT inserted FROM vec_batch_insert('docs', 'id', 'embedding', "
          "'[{\"id\": 1, \"vec\": [1, 2]}, "
          " {\"id\": 2, \"vec\": [1, 2, 3]}, "
          " {\"id\": 3, \"vec\": [4, 5]}]')",
        );
        expect(r.rows.single[0], 2);

        final c = await db.execute("SELECT COUNT(*) FROM docs");
        expect(c.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });

    test('batch persists across close+reopen', () async {
      final path = _tmp('persist');
      final db = await Database.open(path);
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        await db.execute(
          "SELECT inserted FROM vec_batch_insert('docs', 'id', 'embedding', "
          "'[{\"id\": 1, \"vec\": [1, 0]}, "
          " {\"id\": 2, \"vec\": [5, 0]}]')",
        );
        // Force query to bake current state into persisted index.
        await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
      } finally {
        await db.close();
      }

      final db2 = await Database.open(path);
      try {
        final q = await db2.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(q.rows.single[0], 1);

        final c = await db2.execute("SELECT COUNT(*) FROM docs");
        expect(c.rows.single[0], 2);
      } finally {
        await db2.close();
      }
    });
  });
}
