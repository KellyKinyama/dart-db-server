/// V31 IVF cell pruning under categorical filters. When a WHERE
/// filter accompanies an IVF KNN query, we expand nprobe so filter
/// attrition doesn't starve the k-hit budget.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() * 2 - 1));

String _vecLit(Vector v) => '[${v.values.join(", ")}]';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec31_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V31 IVF filter-aware nprobe expansion', () {
    test('IVF + WHERE returns k results when a naive nprobe would starve',
        () async {
      final db = await Database.open(_tmp('ivf_filter'));
      try {
        final rng = math.Random(42);
        const dim = 16;
        const n = 400;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'tenant INTEGER, embedding BLOB)');

        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          final t = i % 10; // 10 tenants, ~40 rows each.
          await db.execute(
            "INSERT INTO docs VALUES ($i, $t, VEC('${_vecLit(v)}'))",
          );
        }
        // nlist=16, nprobe=1 — naive would only probe one cell of ~25.
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.ivf,
          metric: VectorMetric.l2,
          nlist: 16,
          nprobe: 1,
        ));
        await db.warmVectorIndexes();

        final q = _rand(dim, rng);
        final r = await db.execute(
          "SELECT id FROM docs WHERE tenant = 3 "
          "ORDER BY VEC_L2(embedding, VEC('${_vecLit(q)}')) ASC LIMIT 5",
        );
        // With expanded nprobe we should reliably get 5 hits back
        // (40 tenant-3 rows spread across all cells; expanded nprobe=4
        // guarantees plenty of candidates).
        expect(r.rows.length, 5);
        // Every returned row must satisfy the filter.
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 10, 3);
        }
      } finally {
        await db.close();
      }
    });

    test('IVF without WHERE still uses the configured nprobe', () async {
      final db = await Database.open(_tmp('ivf_nofilter'));
      try {
        final rng = math.Random(1);
        const dim = 16;
        const n = 200;

        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB)');
        for (var i = 1; i <= n; i++) {
          final v = _rand(dim, rng);
          await db.execute(
            "INSERT INTO docs VALUES ($i, VEC('${_vecLit(v)}'))",
          );
        }
        db.createVectorIndex(VectorIndexSpec(
          table: 'docs',
          column: 'embedding',
          dim: dim,
          kind: VectorIndexKind.ivf,
          metric: VectorMetric.l2,
          nlist: 8,
          nprobe: 2,
        ));
        await db.warmVectorIndexes();

        final q = _rand(dim, rng);
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('${_vecLit(q)}')) ASC LIMIT 5",
        );
        expect(r.rows.length, 5);
      } finally {
        await db.close();
      }
    });
  });
}
