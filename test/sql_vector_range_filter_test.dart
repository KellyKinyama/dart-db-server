/// V45 range + payload filter fusion — V18 range fast path now
/// intersects the payload buckets when the remainder of WHERE is
/// only equality conjuncts on declared filter columns. V46 exposes
/// range search via `vec_range_search` TVF for JOIN/subquery use.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() * 2 - 1));

String _vecLit(Vector v) => '[${v.values.join(", ")}]';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec45_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V45 range + payload filter fusion', () {
    test('WHERE VEC_L2(...) < thr AND tenant=X uses payload set', () async {
      final db = await Database.open(_tmp('fused'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 40; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 4}, "
            "VEC('[${i / 40.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0, 0]')) < 0.5 AND tenant = 2",
        );
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 4, 2);
        }
      } finally {
        await db.close();
      }
    });

    test('range + non-payload WHERE still works via per-hit eval', () async {
      final db = await Database.open(_tmp('mixed'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "score INTEGER, embedding BLOB "
          "VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 20; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, ${i * 10}, "
            "VEC('[${i / 20.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        // `score < 100` is NOT on a filter column → payload path bails,
        // remainder is still evaluated per-hit.
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0, 0]')) < 0.6 AND score < 100",
        );
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id * 10, lessThan(100));
        }
      } finally {
        await db.close();
      }
    });

    test('empty payload intersection short-circuits to zero rows', () async {
      final db = await Database.open(_tmp('empty'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 4; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, "
            "VEC('[${i / 4.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        // No tenant=99 rows exist — payload set is empty.
        final r = await db.execute(
          "SELECT id FROM docs "
          "WHERE VEC_L2(embedding, VEC('[0, 0]')) < 1.0 AND tenant = 99",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('V46 vec_range_search TVF', () {
    test('returns rows within threshold sorted by distance', () async {
      final db = await Database.open(_tmp('basic'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 20; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid, distance FROM vec_range_search("
          "'docs', 'embedding', VEC('[0, 0]'), 5)",
        );
        // All ids 1..5 must appear with distance <= 5.
        final ids = r.rows.map((r) => r[0] as int).toSet();
        expect(ids, {1, 2, 3, 4, 5});
        // Sorted best-first.
        for (var i = 1; i < r.rows.length; i++) {
          final prev = (r.rows[i - 1][1] as num).toDouble();
          final curr = (r.rows[i][1] as num).toDouble();
          expect(curr, greaterThanOrEqualTo(prev));
        }
      } finally {
        await db.close();
      }
    });

    test('LSH binding is rejected (non-monotone metric)', () async {
      final db = await Database.open(_tmp('lsh_reject'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=8, kind=lsh))',
        );
        final rng = math.Random(1);
        for (var i = 1; i <= 20; i++) {
          final v = _rand(8, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${_vecLit(v)}'))",
          );
        }
        await db.warmVectorIndexes();

        // Range API refuses to serve approx-metric bindings.
        final r = await db.execute(
          "SELECT rowid FROM vec_range_search("
          "'docs', 'embedding', VEC('[0, 0, 0, 0, 0, 0, 0, 0]'), 1)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('vec_range_search on paged tables works via warm', () async {
      final db = await Database.open(_tmp('paged'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 8; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_range_search("
          "'docs', 'embedding', VEC('[0, 0]'), 3)",
        );
        final ids = r.rows.map((r) => r[0] as int).toSet();
        expect(ids, {1, 2, 3});
      } finally {
        await db.close();
      }
    });

    test('filter_json argument intersects payload buckets', () async {
      final db = await Database.open(_tmp('filter'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 20; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 4}, "
            "VEC('[$i, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_range_search("
          "'docs', 'embedding', VEC('[0, 0]'), 12, 'l2', "
          "'{\"tenant\":2}')",
        );
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 4, 2);
        }
      } finally {
        await db.close();
      }
    });

    test('empty result when threshold is 0 and no exact match', () async {
      final db = await Database.open(_tmp('nomatch'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB '
          'VECTOR(dim=2, metric=l2))',
        );
        for (var i = 1; i <= 5; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('[$i, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_range_search("
          "'docs', 'embedding', VEC('[100, 100]'), 0.5)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
