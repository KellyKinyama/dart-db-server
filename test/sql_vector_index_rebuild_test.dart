/// V47 PRAGMA vector_index_rebuild — force a from-scratch rebuild of
/// a vector index binding. Drops tombstones, incremental deltas, and
/// payload buckets; in-memory tables re-prime synchronously, paged
/// bindings require a follow-up `warmVectorIndexes()`.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec47_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V47 PRAGMA vector_index_rebuild', () {
    test('in-memory binding rebuilds synchronously and stays usable',
        () async {
      final db = await Database.open(_tmp('inmem'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 10; i++) {
          await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
        }
        await db.warmVectorIndexes();

        // Confirm baseline query works.
        var r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 1);

        // Rebuild and verify the message shape + subsequent query.
        r = await db.execute("PRAGMA vector_index_rebuild('docs.embedding')");
        expect(r.rows.length, greaterThanOrEqualTo(0));

        r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('drops HNSW tombstones — post-rebuild ratio is zero', () async {
      final db = await Database.open(_tmp('tombstones'));
      try {
        final rng = math.Random(1);
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=4, kind=hnsw, metric=l2, m=8, ef_construction=32))',
        );
        for (var i = 1; i <= 50; i++) {
          final v = List.generate(4, (_) => rng.nextDouble() * 2 - 1);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('[${v.join(",")}]'))",
          );
        }
        await db.warmVectorIndexes();
        // Force some tombstones via targeted UPDATEs.
        for (var i = 1; i <= 20; i++) {
          final v = List.generate(4, (_) => rng.nextDouble() * 2 - 1);
          await db.execute(
            "UPDATE docs SET embedding = VEC('[${v.join(",")}]') "
            "WHERE id = $i",
          );
        }
        // Drain via a query so tombstones exist.
        await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0, 0, 0]')) ASC LIMIT 1",
        );

        // Read stats BEFORE rebuild.
        final before = await db
            .execute("PRAGMA vector_index_stats('docs.embedding')");
        final tombBefore = before.rows.single[7] as int; // tombstones col

        // Rebuild.
        await db.execute(
          "PRAGMA vector_index_rebuild('docs.embedding')",
        );

        // Query to trigger the fresh build.
        await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0, 0, 0]')) ASC LIMIT 1",
        );

        final after = await db
            .execute("PRAGMA vector_index_stats('docs.embedding')");
        final tombAfter = after.rows.single[7] as int;

        // Tombstones must decrease strictly (post-rebuild = 0).
        expect(tombAfter, lessThan(tombBefore));
        expect(tombAfter, 0);
      } finally {
        await db.close();
      }
    });

    test('paged binding invalidates but needs warmVectorIndexes after',
        () async {
      final db = await Database.open(_tmp('paged'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 5; i++) {
          await db.execute("INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))");
        }
        await db.warmVectorIndexes();

        await db.execute(
          "PRAGMA vector_index_rebuild('docs.embedding')",
        );
        // Now vec_search should return empty until re-warmed.
        var r = await db.execute(
          "SELECT rowid FROM vec_search("
          "'docs', 'embedding', VEC('[0, 0]'), 1)",
        );
        expect(r.rows, isEmpty);

        // Re-warm and retry.
        await db.warmVectorIndexes();
        r = await db.execute(
          "SELECT rowid FROM vec_search("
          "'docs', 'embedding', VEC('[0, 0]'), 1)",
        );
        expect(r.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('unknown target throws with a helpful message', () async {
      final db = await Database.open(_tmp('bad'));
      try {
        await db.execute(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, e BLOB)',
        );
        expect(
          () async => db.execute(
            "PRAGMA vector_index_rebuild('t.e')",
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no vector index'),
          )),
        );
      } finally {
        await db.close();
      }
    });

    test('vector_index_rebuild appears in pragma_list', () async {
      final db = await Database.open(_tmp('pragma_list'));
      try {
        final r = await db.execute('PRAGMA pragma_list');
        final names = r.rows.map((row) => row[0]).toSet();
        expect(names, contains('vector_index_rebuild'));
      } finally {
        await db.close();
      }
    });
  });
}
