/// V30 inline VECTOR(...) column attribute in CREATE TABLE — auto-
/// registers a vector index binding at DDL time.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec30_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V30 inline VECTOR() column attribute', () {
    test('minimal: dim only defaults kind=flat, metric=l2sq', () async {
      final db = await Database.open(_tmp('minimal'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB VECTOR(dim=3))',
        );
        // Binding should exist even before any INSERT.
        final r = await db.execute('PRAGMA vector_index_list');
        expect(r.rows.length, 1);
        expect(r.rows.single[0], 'docs');
        expect(r.rows.single[1], 'embedding');
        expect(r.rows.single[2], 3);
        expect(r.rows.single[3], 'flat');
        expect(r.rows.single[4], 'l2sq');
      } finally {
        await db.close();
      }
    });

    test('full: kind + metric override', () async {
      final db = await Database.open(_tmp('full'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB VECTOR(dim=384, kind=hnsw, metric=cosine, '
          'm=16, ef_construction=64))',
        );
        final r = await db.execute('PRAGMA vector_index_list');
        expect(r.rows.single[3], 'hnsw');
        expect(r.rows.single[4], 'cosine');
      } finally {
        await db.close();
      }
    });

    test('inline binding works end-to-end with warm + KNN query', () async {
      final db = await Database.open(_tmp('e2e'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB VECTOR(dim=2, kind=flat, metric=l2))',
        );
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[0, 1]'))");
        await db.execute("INSERT INTO docs VALUES (3, VEC('[10, 10]'))");
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[1, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('inline binding persists across close+reopen', () async {
      final path = _tmp('persist');
      {
        final db = await Database.open(path);
        try {
          await db.execute(
            'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB VECTOR(dim=2, kind=flat, metric=l2))',
          );
        } finally {
          await db.close();
        }
      }
      {
        final db = await Database.open(path);
        try {
          final r = await db.execute('PRAGMA vector_index_list');
          expect(r.rows.length, 1);
          expect(r.rows.single[3], 'flat');
        } finally {
          await db.close();
        }
      }
    });

    test('missing dim throws', () async {
      final db = await Database.open(_tmp('bad'));
      try {
        expect(
          () async => db.execute(
            'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB VECTOR(kind=flat))',
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });
  });
}
