/// V60 FTS5 admin PRAGMAs: `fts5_list` and `fts5_stats('tbl.col')`.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec60_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V60 PRAGMA fts5_list', () {
    test('empty when no FTS5 corpus warmed', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA fts5_list');
        expect(r.columns, contains('doc_count'));
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('lists warmed corpora with doc_count / vocab_size / avg length',
        () async {
      final db = await Database.open(_tmp('list'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT)',
        );
        await db.execute("INSERT INTO docs VALUES (1, 'the quick brown fox')");
        await db.execute("INSERT INTO docs VALUES (2, 'lazy dog sleeps')");
        await db.execute("INSERT INTO docs VALUES (3, 'fox and dog play')");

        await db.warmFts5('docs', 'body');

        final r = await db.execute('PRAGMA fts5_list');
        expect(r.rows.length, 1);
        final row = r.rows.first;
        expect(row[r.columns.indexOf('tbl')], 'docs');
        expect(row[r.columns.indexOf('col')], 'body');
        expect(row[r.columns.indexOf('doc_count')], 3);
        expect(row[r.columns.indexOf('vocab_size')] as int, greaterThan(0));
        expect(
          (row[r.columns.indexOf('avg_doc_length')] as num).toDouble(),
          greaterThan(0.0),
        );
      } finally {
        await db.close();
      }
    });
  });

  group('V60 PRAGMA fts5_stats', () {
    test('returns one row for the targeted warm corpus', () async {
      final db = await Database.open(_tmp('stats'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)',
        );
        for (var i = 1; i <= 5; i++) {
          await db.execute("INSERT INTO notes VALUES ($i, 'note number $i')");
        }
        await db.warmFts5('notes', 'body');

        final r = await db.execute("PRAGMA fts5_stats('notes.body')");
        expect(r.rows.length, 1);
        expect(r.rows.first[r.columns.indexOf('doc_count')], 5);
      } finally {
        await db.close();
      }
    });

    test('throws when the corpus has not been warmed', () async {
      final db = await Database.open(_tmp('unwarmed'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT)',
        );
        expect(
          () async => db.execute("PRAGMA fts5_stats('docs.body')"),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });

    test('rejects malformed target', () async {
      final db = await Database.open();
      try {
        expect(
          () async => db.execute("PRAGMA fts5_stats('nodot')"),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });

    test('both PRAGMAs appear in pragma_list', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA pragma_list');
        final names = r.rows.map((row) => row[0]).toSet();
        expect(names, contains('fts5_list'));
        expect(names, contains('fts5_stats'));
      } finally {
        await db.close();
      }
    });
  });
}
