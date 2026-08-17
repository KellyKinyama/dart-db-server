/// V56 bulk admin PRAGMAs.
/// * `vector_verify_all` — V50 verify across every registered in-memory
///   built binding.
/// * `vector_index_rebuild_all` — V47 rebuild across every binding.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec56_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V56 PRAGMA vector_verify_all', () {
    test('emits one row per verifiable in-memory binding', () async {
      final db = await Database.open(_tmp('two'));
      try {
        await db.execute(
          'CREATE TABLE a (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute(
          'CREATE TABLE b (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=3, metric=l2))',
        );
        for (var i = 1; i <= 3; i++) {
          await db.execute("INSERT INTO a VALUES ($i, VEC('[$i, 0]'))");
          await db.execute("INSERT INTO b VALUES ($i, VEC('[$i, 0, 0]'))");
        }
        await db.warmVectorIndexes();

        final r = await db.execute('PRAGMA vector_verify_all');
        expect(r.columns, contains('tbl'));
        expect(r.columns, contains('missing_from_index'));
        expect(r.rows.length, 2);
        final tables =
            r.rows.map((row) => row[r.columns.indexOf('tbl')]).toSet();
        expect(tables, {'a', 'b'});
        for (final row in r.rows) {
          expect(row[r.columns.indexOf('missing_from_index')], 0);
          expect(row[r.columns.indexOf('extra_in_index')], 0);
          expect(row[r.columns.indexOf('dim_bad')], 0);
        }
      } finally {
        await db.close();
      }
    });

    test('silently skips paged and unbuilt bindings', () async {
      final db = await Database.open(_tmp('mixed'));
      try {
        await db.execute(
          'CREATE TABLE mem (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute("INSERT INTO mem VALUES (1, VEC('[1,0]'))");
        await db.warmVectorIndex('mem', 'embedding');

        // Paged binding.
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE p (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute("INSERT INTO p VALUES (1, VEC('[1,0]'))");
        // Deliberately DO NOT warm p — its index is null.

        final r = await db.execute('PRAGMA vector_verify_all');
        // Only the in-memory built binding should appear.
        expect(r.rows.length, 1);
        expect(r.rows.first[r.columns.indexOf('tbl')], 'mem');
      } finally {
        await db.close();
      }
    });

    test('empty when no bindings registered', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA vector_verify_all');
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('V56 PRAGMA vector_index_rebuild_all', () {
    test('rebuilds all in-memory bindings and reports counts', () async {
      final db = await Database.open(_tmp('rebuild_mem'));
      try {
        await db.execute(
          'CREATE TABLE a (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute(
          'CREATE TABLE b (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 3; i++) {
          await db.execute("INSERT INTO a VALUES ($i, VEC('[$i, 0]'))");
          await db.execute("INSERT INTO b VALUES ($i, VEC('[$i, 0]'))");
        }
        await db.warmVectorIndexes();

        final r = await db.execute('PRAGMA vector_index_rebuild_all');
        expect(r.message, contains('vector_index_rebuild_all:'));
        expect(r.message, contains('2 binding(s) rebuilt'));
        expect(r.message, contains('0 paged binding(s) invalidated'));

        // Post-rebuild, searches must still return results.
        final s = await db.execute(
          "SELECT rowid FROM vec_search('a', 'embedding', VEC('[1,0]'), 1)",
        );
        expect(s.rows, isNotEmpty);
      } finally {
        await db.close();
      }
    });

    test('reports paged bindings as invalidated', () async {
      final db = await Database.open(_tmp('rebuild_paged'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE p (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute("INSERT INTO p VALUES (1, VEC('[1,0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute('PRAGMA vector_index_rebuild_all');
        expect(r.message, contains('0 binding(s) rebuilt'));
        expect(r.message, contains('1 paged binding(s) invalidated'));
      } finally {
        await db.close();
      }
    });

    test('both new PRAGMAs appear in pragma_list', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA pragma_list');
        final names = r.rows.map((row) => row[0]).toSet();
        expect(names, contains('vector_verify_all'));
        expect(names, contains('vector_index_rebuild_all'));
      } finally {
        await db.close();
      }
    });
  });
}
