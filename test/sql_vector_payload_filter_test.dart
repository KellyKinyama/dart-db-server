/// V36 payload-filter pruning — declared `filterColumns` on a
/// VectorIndexSpec turn equality-only WHERE clauses into O(1) set
/// intersections against a pre-computed row-position posting list,
/// short-circuiting V11's O(k*over-fetch) filter attrition.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() * 2 - 1));

String _vecLit(Vector v) => '[${v.values.join(", ")}]';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec36_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V36 payload-filter pruning', () {
    test('single equality filter uses payload index and returns k', () async {
      final db = await Database.open(_tmp('single'));
      try {
        final rng = math.Random(9);
        const dim = 8;
        const n = 400;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          final t = i % 10;
          await db.execute(
            "INSERT INTO docs VALUES ($i, $t, VEC('${_vecLit(v)}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
          filterColumns: ['tenant'],
        ));
        await db.warmVectorIndexes();

        final q = _rand(dim, rng);
        final r = await db.execute(
          "SELECT id, tenant FROM docs WHERE tenant = 3 "
          "ORDER BY VEC_L2(embedding, VEC('${_vecLit(q)}')) ASC LIMIT 10",
        );
        expect(r.rows.length, 10);
        for (final row in r.rows) {
          expect(row[1], 3);
        }
      } finally {
        await db.close();
      }
    });

    test('AND of two equalities intersects sets', () async {
      final db = await Database.open(_tmp('and'));
      try {
        final rng = math.Random(11);
        const dim = 8;
        const n = 400;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, kind INTEGER, embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          final t = i % 5;
          final k = i % 4;
          await db.execute(
            "INSERT INTO docs VALUES ($i, $t, $k, VEC('${_vecLit(v)}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
          filterColumns: ['tenant', 'kind'],
        ));
        await db.warmVectorIndexes();

        final q = _rand(dim, rng);
        final r = await db.execute(
          "SELECT id, tenant, kind FROM docs "
          "WHERE tenant = 2 AND kind = 1 "
          "ORDER BY VEC_L2(embedding, VEC('${_vecLit(q)}')) ASC LIMIT 5",
        );
        for (final row in r.rows) {
          expect(row[1], 2);
          expect(row[2], 1);
        }
      } finally {
        await db.close();
      }
    });

    test('UPDATE of filter column dirties and rebuilds', () async {
      final db = await Database.open(_tmp('update_dirty'));
      try {
        const dim = 2;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, embedding BLOB)');
        await db.execute(
          "INSERT INTO docs VALUES (1, 0, VEC('[1, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (2, 1, VEC('[0.5, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (3, 0, VEC('[10, 0]'))",
        );
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
          filterColumns: ['tenant'],
        ));
        await db.warmVectorIndexes();

        // Move id=1 to tenant=1. After: tenant=1 has {id=1, id=2}.
        await db.execute("UPDATE docs SET tenant = 1 WHERE id = 1");

        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 1 "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 2",
        );
        expect(r.rows.length, 2);
        final ids = r.rows.map((r) => r[0]).toSet();
        expect(ids, {1, 2});
      } finally {
        await db.close();
      }
    });

    test('INSERT extends payload index incrementally', () async {
      final db = await Database.open(_tmp('insert_extend'));
      try {
        const dim = 2;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, embedding BLOB)');
        await db.execute(
          "INSERT INTO docs VALUES (1, 0, VEC('[1, 0]'))",
        );
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
          filterColumns: ['tenant'],
        ));
        await db.warmVectorIndexes();

        // Insert new row with tenant=5; ensure payload index sees it.
        await db.execute(
          "INSERT INTO docs VALUES (2, 5, VEC('[0.5, 0]'))",
        );

        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 5 "
          "ORDER BY VEC_L2(embedding, VEC('[0, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });

    test('WHERE with non-filter-column term falls back to over-fetch',
        () async {
      final db = await Database.open(_tmp('fallback'));
      try {
        final rng = math.Random(13);
        const dim = 4;
        const n = 50;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, score INTEGER, embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES "
            "($i, ${i % 5}, ${i * 10}, VEC('${_vecLit(v)}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
          filterColumns: ['tenant'],
        ));
        await db.warmVectorIndexes();

        final q = _rand(dim, rng);
        // `score < 200` is not on a filter column → payload path bails,
        // legacy over-fetch handles it.
        final r = await db.execute(
          "SELECT id FROM docs WHERE score < 200 "
          "ORDER BY VEC_L2(embedding, VEC('${_vecLit(q)}')) ASC LIMIT 3",
        );
        expect(r.rows.length, 3);
      } finally {
        await db.close();
      }
    });
  });
}
