/// V33 `PRAGMA vector_analyze('tbl.col[:k[:sample_size]]')` — samples
/// random rows as queries, computes recall@K vs brute-force top-K.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() * 2 - 1));

String _vecLit(Vector v) => '[${v.values.join(", ")}]';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec33_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V33 PRAGMA vector_analyze', () {
    test('Flat index recall == 1.0 (self-check)', () async {
      final db = await Database.open(_tmp('flat_recall'));
      try {
        final rng = math.Random(1);
        const dim = 8;
        const n = 100;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          await db
              .execute("INSERT INTO docs VALUES ($i, VEC('${_vecLit(v)}'))");
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "PRAGMA vector_analyze('docs.embedding:10:20')",
        );
        expect(r.rows.single[2], 10); // k
        expect(r.rows.single[3], 20); // sample_size
        expect((r.rows.single[4] as num).toDouble(), 1.0);
      } finally {
        await db.close();
      }
    });

    test('HNSW recall is high but not necessarily 1.0', () async {
      final db = await Database.open(_tmp('hnsw_recall'));
      try {
        final rng = math.Random(2);
        const dim = 8;
        const n = 200;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          await db
              .execute("INSERT INTO docs VALUES ($i, VEC('${_vecLit(v)}'))");
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.hnsw,
          metric: VectorMetric.l2,
          m: 8,
          efConstruction: 32,
          efSearch: 32,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute(
          "PRAGMA vector_analyze('docs.embedding:5:20')",
        );
        final recall = (r.rows.single[4] as num).toDouble();
        // HNSW at k=5 with efSearch=32 on random 8-d data recalls
        // essentially perfectly; loosen the bound to guard against
        // pathological seeds.
        expect(recall, greaterThan(0.7));
      } finally {
        await db.close();
      }
    });

    test('default k and sample_size (target only)', () async {
      final db = await Database.open(_tmp('defaults'));
      try {
        final rng = math.Random(3);
        const dim = 4;
        const n = 50;
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          await db
              .execute("INSERT INTO docs VALUES ($i, VEC('${_vecLit(v)}'))");
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.flat,
          metric: VectorMetric.l2,
        ));
        await db.warmVectorIndexes();

        final r = await db.execute("PRAGMA vector_analyze('docs.embedding')");
        expect(r.rows.single[2], 10); // default k
        expect(r.rows.single[3], 32); // default sample_size
      } finally {
        await db.close();
      }
    });

    test('errors on missing binding', () async {
      final db = await Database.open(_tmp('nope'));
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, e BLOB)');
        expect(
          () async => db.execute("PRAGMA vector_analyze('t.e')"),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });
  });
}
