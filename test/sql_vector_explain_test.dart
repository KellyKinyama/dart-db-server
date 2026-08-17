/// V26 EXPLAIN QUERY PLAN surfaces vector-index fast paths.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec26_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V26 EXPLAIN QUERY PLAN for vector fast paths', () {
    test('KNN ORDER BY reports SEARCH USING VECTOR INDEX', () async {
      final db = await Database.open(_tmp('knn_plain'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "EXPLAIN QUERY PLAN "
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 5",
        );
        final detail = r.rows.first[3] as String;
        expect(detail, contains('VECTOR INDEX (flat)'));
        expect(detail, isNot(contains('WITH FILTER')));
        expect(detail, isNot(contains('WITH RESCORE')));
      } finally {
        await db.close();
      }
    });

    test('KNN with WHERE reports WITH FILTER', () async {
      final db = await Database.open(_tmp('knn_filter'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, 1, VEC('[1, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "EXPLAIN QUERY PLAN "
          "SELECT id FROM docs WHERE tenant = 1 "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 5",
        );
        final detail = r.rows.first[3] as String;
        expect(detail, contains('VECTOR INDEX (hnsw)'));
        expect(detail, contains('WITH FILTER'));
      } finally {
        await db.close();
      }
    });

    test('Rescore-enabled binding reports WITH RESCORE', () async {
      final db = await Database.open(_tmp('knn_rescore'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.lsh,
          metric: VectorMetric.l2,
          nbits: 16,
          rescoreFactor: 3,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "EXPLAIN QUERY PLAN "
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 5",
        );
        final detail = r.rows.first[3] as String;
        expect(detail, contains('VECTOR INDEX (lsh)'));
        expect(detail, contains('WITH RESCORE'));
      } finally {
        await db.close();
      }
    });

    test('Range WHERE reports RANGE suffix', () async {
      final db = await Database.open(_tmp('range_suffix'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "EXPLAIN QUERY PLAN "
          "SELECT id FROM docs WHERE VEC_L2(embedding, VEC('[0, 0]')) < 5",
        );
        final detail = r.rows.first[3] as String;
        expect(detail, contains('VECTOR INDEX (flat)'));
        expect(detail, contains('RANGE'));
      } finally {
        await db.close();
      }
    });

    test('No binding on column returns SCAN detail', () async {
      final db = await Database.open(_tmp('no_binding'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        // No createVectorIndex — the plan must NOT claim VECTOR INDEX.
        final r = await db.execute(
          "EXPLAIN QUERY PLAN "
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 5",
        );
        final detail = r.rows.first[3] as String;
        expect(detail, isNot(contains('VECTOR INDEX')));
      } finally {
        await db.close();
      }
    });
  });
}
