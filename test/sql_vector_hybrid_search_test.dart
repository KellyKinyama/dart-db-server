/// V41 vec_hybrid_search TVF — fuses vector KNN with FTS5 BM25 via
/// Reciprocal Rank Fusion. This is the marquee hybrid retrieval RAG
/// pipelines use.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec41_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V41 vec_hybrid_search', () {
    test('fuses vector and BM25 ranks — top result matches both signals',
        () async {
      final db = await Database.open(_tmp('basic'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, '
          'embedding BLOB VECTOR(dim=2))',
        );
        // id=1: strong text match "quantum", far vec.
        // id=2: no text match, close vec.
        // id=3: closest vec AND text match — SHOULD win RRF.
        await db.execute(
          "INSERT INTO docs VALUES "
          "(1, 'quantum physics is amazing', VEC('[10, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES "
          "(2, 'ordinary boring content', VEC('[0.5, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES "
          "(3, 'a quantum leap in learning', VEC('[0.1, 0]'))",
        );
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid, distance, bm25, rrf_score "
          "FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', "
          "VEC('[0, 0]'), 'quantum', 3)",
        );
        expect(r.rows.length, 3);
        // id=3 has both moderate vector proximity AND text match.
        // id=1 has text but far vec. id=2 has vec but no text.
        // RRF should rank id=3 first.
        expect(r.rows.first[0], 3);
      } finally {
        await db.close();
      }
    });

    test('pure text side only surfaces via RRF', () async {
      final db = await Database.open(_tmp('text_only'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, '
          'embedding BLOB VECTOR(dim=2))',
        );
        await db.execute(
          "INSERT INTO docs VALUES "
          "(1, 'apple orchard scenery', VEC('[100, 100]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES "
          "(2, 'apple pie recipe', VEC('[99, 99]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES "
          "(3, 'nothing related here', VEC('[0.1, 0]'))",
        );
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', VEC('[0, 0]'), 'apple', 3)",
        );
        final ids = r.rows.map((r) => r[0]).toList();
        // Vector says id=3 is nearest. Text says id=1, id=2 match.
        // RRF (default k=60) should include all three but rank the
        // text-matchers reasonably close.
        expect(ids, contains(1));
        expect(ids, contains(2));
      } finally {
        await db.close();
      }
    });

    test('with filter_json only considers filtered rows', () async {
      final db = await Database.open(_tmp('filter'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "body TEXT, embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 10; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, 'foo bar $i', "
            "VEC('[${i / 10.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', VEC('[0, 0]'), 'foo', 3, 60, "
          "'{\"tenant\":1}')",
        );
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 2, 1);
        }
      } finally {
        await db.close();
      }
    });

    test('returns empty when both sides find no matches', () async {
      final db = await Database.open(_tmp('empty'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, '
          'embedding BLOB VECTOR(dim=2))',
        );
        // No warm and no rows: hybrid should return empty.
        final r = await db.execute(
          "SELECT rowid FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', VEC('[0, 0]'), 'anything', 5)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('rrf_score is monotone: higher rank → higher score', () async {
      final db = await Database.open(_tmp('score'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, '
          'embedding BLOB VECTOR(dim=2))',
        );
        for (var i = 1; i <= 8; i++) {
          final vecVal = i.toDouble();
          await db.execute(
            "INSERT INTO docs VALUES ($i, 'searchable $i', "
            "VEC('[$vecVal, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rrf_score FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', VEC('[0, 0]'), 'searchable', 5)",
        );
        expect(r.rows.length, 5);
        for (var i = 1; i < r.rows.length; i++) {
          final prev = (r.rows[i - 1][0] as num).toDouble();
          final curr = (r.rows[i][0] as num).toDouble();
          expect(curr, lessThanOrEqualTo(prev));
        }
      } finally {
        await db.close();
      }
    });
  });
}
