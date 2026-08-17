/// V49/V50 admin PRAGMAs.
/// * `vector_index_warm` — targeted async warm for one binding.
/// * `vector_verify` — consistency check between binding and rows.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec49_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V49 PRAGMA vector_index_warm', () {
    test('warms just one binding (paged)', () async {
      final db = await Database.open(_tmp('paged'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 3; i++) {
          await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
        }
        // Do NOT call warmVectorIndexes — use PRAGMA instead.
        final r = await db
            .execute("PRAGMA vector_index_warm('docs.embedding')");
        expect(r.message, contains('warmed'));

        // Confirm binding is now usable.
        final q = await db.execute(
          "SELECT rowid FROM vec_search("
          "'docs', 'embedding', VEC('[0, 0]'), 1)",
        );
        expect(q.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('warms an in-memory binding (idempotent)', () async {
      final db = await Database.open(_tmp('inmem'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");

        var r = await db
            .execute("PRAGMA vector_index_warm('docs.embedding')");
        expect(r.message, contains('warmed'));

        // Second call is a no-op (binding.index already set).
        r = await db.execute("PRAGMA vector_index_warm('docs.embedding')");
        expect(r.message, contains('warmed'));
      } finally {
        await db.close();
      }
    });

    test('unknown binding throws', () async {
      final db = await Database.open(_tmp('bad'));
      try {
        expect(
          () async => db
              .execute("PRAGMA vector_index_warm('nope.nada')"),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });
  });

  group('V50 PRAGMA vector_verify', () {
    test('healthy binding reports all zeroes', () async {
      final db = await Database.open(_tmp('healthy'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 5; i++) {
          await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
        }
        await db.warmVectorIndexes();

        final r = await db.execute("PRAGMA vector_verify('docs.embedding')");
        expect(r.rows.length, 1);
        expect(r.columns, containsAll(['n_rows', 'n_index',
            'missing_from_index', 'extra_in_index', 'dim_bad']));
        final row = r.rows.single;
        expect(row[2], 5); // n_rows
        expect(row[3], 5); // n_index
        expect(row[4], 0); // missing
        expect(row[5], 0); // extra
        expect(row[6], 0); // dim_bad
      } finally {
        await db.close();
      }
    });

    test('NULL vector column not counted as missing', () async {
      final db = await Database.open(_tmp('null'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, NULL)");
        await db.warmVectorIndexes();

        final r = await db.execute("PRAGMA vector_verify('docs.embedding')");
        final row = r.rows.single;
        expect(row[2], 2); // n_rows = 2
        expect(row[3], 1); // n_index = 1
        expect(row[4], 0); // missing = 0 (NULL doesn't count)
      } finally {
        await db.close();
      }
    });

    test('unbuilt binding throws with clear message', () async {
      final db = await Database.open(_tmp('unbuilt'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2))',
        );
        expect(
          () async => db.execute("PRAGMA vector_verify('docs.embedding')"),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not built'),
          )),
        );
      } finally {
        await db.close();
      }
    });

    test('paged binding is rejected', () async {
      final db = await Database.open(_tmp('paged_verify'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2))',
        );
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.warmVectorIndexes();

        expect(
          () async => db.execute("PRAGMA vector_verify('docs.embedding')"),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('paged'),
          )),
        );
      } finally {
        await db.close();
      }
    });

    test('vector_index_warm and vector_verify appear in pragma_list',
        () async {
      final db = await Database.open(_tmp('list'));
      try {
        final r = await db.execute('PRAGMA pragma_list');
        final names = r.rows.map((row) => row[0]).toSet();
        expect(names, contains('vector_index_warm'));
        expect(names, contains('vector_verify'));
      } finally {
        await db.close();
      }
    });
  });
}
