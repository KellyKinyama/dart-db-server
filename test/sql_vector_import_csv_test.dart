/// V34 VEC_IMPORT_CSV — bulk-load `(id, vec)` rows from a CSV file.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec34_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

String _tmpCsv(String content) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec34csv_');
  final p = '${dir.path}${Platform.pathSeparator}data.csv';
  File(p).writeAsStringSync(content);
  return p;
}

void main() {
  group('V34 VEC_IMPORT_CSV', () {
    test('bulk-imports rows from CSV without header', () async {
      final db = await Database.open(_tmp('noheader'));
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

        final csv = _tmpCsv(
          '1,"[1, 0, 0]"\n'
          '2,"[0, 1, 0]"\n'
          '3,"[0, 0, 1]"\n',
        );

        final r = await db.execute(
          "SELECT inserted FROM vec_import_csv("
          "'docs', 'id', 'embedding', '$csv')",
        );
        expect(r.rows.single[0], 3);

        final c = await db.execute("SELECT COUNT(*) FROM docs");
        expect(c.rows.single[0], 3);

        await db.warmVectorIndexes();
        final q = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[1, 0, 0]')) ASC LIMIT 1",
        );
        expect(q.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('respects has_header flag', () async {
      final db = await Database.open(_tmp('header'));
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

        final csv = _tmpCsv(
          'id,embedding\n'
          '10,"[1, 2]"\n'
          '20,"[3, 4]"\n',
        );

        final r = await db.execute(
          "SELECT inserted FROM vec_import_csv("
          "'docs', 'id', 'embedding', '$csv', 1)",
        );
        expect(r.rows.single[0], 2);

        final ids = await db.execute("SELECT id FROM docs ORDER BY id");
        expect(ids.rows.map((r) => r[0]).toList(), [10, 20]);
      } finally {
        await db.close();
      }
    });

    test('dim mismatch entries are skipped', () async {
      final db = await Database.open(_tmp('dim'));
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

        final csv = _tmpCsv(
          '1,"[1, 2]"\n'
          '2,"[3, 4, 5]"\n'
          '3,"[6, 7]"\n',
        );

        final r = await db.execute(
          "SELECT inserted FROM vec_import_csv("
          "'docs', 'id', 'embedding', '$csv')",
        );
        expect(r.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });

    test('empty file returns inserted=0', () async {
      final db = await Database.open(_tmp('empty'));
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
        final csv = _tmpCsv('');
        final r = await db.execute(
          "SELECT inserted FROM vec_import_csv("
          "'docs', 'id', 'embedding', '$csv')",
        );
        expect(r.rows.single[0], 0);
      } finally {
        await db.close();
      }
    });
  });
}
