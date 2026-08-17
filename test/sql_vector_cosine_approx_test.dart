/// V25 cosine metric for approximate indexes (LSH, PQ, IvfPq) via
/// L2-normalized ingest and query. On the unit sphere, squared-L2
/// preserves cosine ordering.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() * 2 - 1));

String _vecLit(Vector v) => '[${v.values.join(", ")}]';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec25_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V25 cosine metric on approximate indexes', () {
    test('LSH accepts cosine ORDER BY and ranks correctly', () async {
      final db = await Database.open(_tmp('lsh_cos'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        // Two vectors nearly opposite (cos far), one nearly parallel
        // to the query [1, 0]. Cosine-nearest MUST be id=1.
        await db.execute("INSERT INTO docs VALUES (1, VEC('[10, 0.1]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[-5, 0]'))");
        await db.execute("INSERT INTO docs VALUES (3, VEC('[0.1, 100]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.lsh,
          metric: VectorMetric.cosine,
          nbits: 32,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_COSINE(embedding, VEC('[1, 0]')) ASC LIMIT 1",
        );
        expect(r.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('PQ accepts cosine and matches Flat cosine top-K on synthetic',
        () async {
      final db = await Database.open(_tmp('pq_cos'));
      try {
        final rng = math.Random(7);
        const dim = 16;
        const n = 400;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        final vectors = <Vector>[];
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          vectors.add(v);
          await db
              .execute("INSERT INTO docs VALUES ($i, VEC('${_vecLit(v)}'))");
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.pq,
          metric: VectorMetric.cosine,
          m: 4,
          rescoreFactor: 4,
        ));
        await db.warmVectorIndexes();

        final q = _rand(dim, rng);
        final qLit = _vecLit(q);
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_COSINE(embedding, VEC('$qLit')) ASC LIMIT 5",
        );
        expect(r.rows.length, 5);

        // Sanity: verify top-1 is one of the actual top-3 cosine matches.
        final scored = <(int, double)>[];
        for (var i = 0; i < n; i++) {
          final dot = vecInnerProduct(q, vectors[i]);
          final nq = vecNorm(q);
          final nv = vecNorm(vectors[i]);
          final cos = dot / (nq * nv);
          scored.add((i + 1, 1.0 - cos));
        }
        scored.sort((a, b) => a.$2.compareTo(b.$2));
        final expectedTop3 = {scored[0].$1, scored[1].$1, scored[2].$1};
        expect(expectedTop3, contains(r.rows.first[0]));
      } finally {
        await db.close();
      }
    });

    test('LSH cosine binding still rejects L2 query? no — L2 also accepted',
        () async {
      // Historical accept-list: L2 / L2SQ / (V25) COSINE-when-spec-is-cosine.
      // A COSINE-configured binding should ALSO handle L2 queries — the
      // stored vectors are unit-normalized so L2² and COSINE-distance
      // are monotone on the sphere anyway.
      final db = await Database.open(_tmp('lsh_cos_l2q'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[0, 1]'))");
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.lsh,
          metric: VectorMetric.cosine,
          nbits: 16,
        ));
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

    test('non-cosine LSH binding rejects cosine query (bails to generic)',
        () async {
      final db = await Database.open(_tmp('lsh_l2_cosq'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        await db.execute("INSERT INTO docs VALUES (2, VEC('[0, 1]'))");
        // Binding built as L2 — cosine query should still work but go
        // through generic executor (correct answer, no crash).
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: 2,
          kind: VectorIndexKind.lsh,
          metric: VectorMetric.l2,
          nbits: 16,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_COSINE(embedding, VEC('[1, 0]')) ASC LIMIT 1",
        );
        // Full scan via generic executor returns exact cosine nearest.
        expect(r.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });
  });
}
