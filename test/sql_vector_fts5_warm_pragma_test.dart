/// V48 PRAGMA fts5_warm — SQL entry point for `db.warmFts5(...)`.
/// Works synchronously by intercepting the async pragma at
/// `_maybeRunAsyncPragma` before the sync `_dispatch` layer.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec48_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V48 PRAGMA fts5_warm', () {
    test('warms paged FTS5 corpus so hybrid TVF works next call', () async {
      final db = await Database.open(_tmp('paged_warm'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, '
          'embedding BLOB VECTOR(dim=2))',
        );
        for (var i = 1; i <= 4; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, 'foo bar $i', "
            "VEC('[${i / 4.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        // Warm from SQL — no Dart call to db.warmFts5().
        final rw = await db.execute("PRAGMA fts5_warm('docs.body')");
        expect(rw.rows, isEmpty); // message-only response
        expect(rw.message, contains('warmed'));

        // Hybrid TVF should now work.
        final r = await db.execute(
          "SELECT rowid FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', VEC('[0, 0]'), 'foo', 2)",
        );
        expect(r.rows.length, greaterThan(0));
      } finally {
        await db.close();
      }
    });

    test('in-memory table primes the lazy cache too', () async {
      final db = await Database.open(_tmp('inmem_warm'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, '
          'embedding BLOB VECTOR(dim=2))',
        );
        await db.execute("INSERT INTO docs VALUES (1, 'hello', VEC('[1, 0]'))");
        await db.warmVectorIndexes();

        final r = await db.execute("PRAGMA fts5_warm('docs.body')");
        expect(r.message, contains('warmed'));
      } finally {
        await db.close();
      }
    });

    test('missing target throws with helpful message', () async {
      final db = await Database.open(_tmp('bad'));
      try {
        expect(
          () async => db.execute('PRAGMA fts5_warm'),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('fts5_warm'),
          )),
        );
      } finally {
        await db.close();
      }
    });

    test('fts5_warm appears in pragma_list', () async {
      final db = await Database.open(_tmp('list'));
      try {
        final r = await db.execute('PRAGMA pragma_list');
        final names = r.rows.map((row) => row[0]).toSet();
        expect(names, contains('fts5_warm'));
      } finally {
        await db.close();
      }
    });
  });
}
