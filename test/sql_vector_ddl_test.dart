/// SQL DDL for vector indexes: `CREATE VIRTUAL TABLE ... USING
/// vector_index(...)` builds an entry visible to the planner, and
/// `DROP TABLE` cascades to the binding.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Vector _randomVec(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

Future<Database> _dbWithDocs(int dim, int n, math.Random rng) async {
  final db = await Database.open();
  await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
      'title TEXT, embedding BLOB)');
  for (var i = 0; i < n; i++) {
    final v = _randomVec(dim, rng);
    await db.execute(
      "INSERT INTO docs VALUES ($i, 'doc_$i', VEC('${v.toString()}'))",
    );
  }
  return db;
}

void main() {
  group('CREATE VIRTUAL TABLE ... USING vector_index', () {
    test('basic flat index: registered + queryable via fast path', () async {
      const dim = 4;
      final rng = math.Random(1);
      final db = await _dbWithDocs(dim, 20, rng);
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_vec USING vector_index("
          "table=docs, column=embedding, dim=$dim, metric=l2)",
        );
        expect(db.vectorIndexes.length, 1);
        expect(db.vectorIndexes.single.table, 'docs');
        expect(db.vectorIndexes.single.column, 'embedding');
        expect(db.vectorIndexes.single.kind, VectorIndexKind.flat);
        expect(db.vectorIndexes.single.metric, VectorMetric.l2);

        final query = _randomVec(dim, rng);
        final qLit = "VEC('${query.toString()}')";
        final r = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 3",
        );
        expect(r.rows.length, 3);
      } finally {
        await db.close();
      }
    });

    test('hnsw with full param set is honored', () async {
      final db = await _dbWithDocs(4, 20, math.Random(2));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_hnsw USING vector_index("
          "table=docs, column=embedding, dim=4, kind=hnsw, metric=l2, "
          "m=32, ef_construction=100, ef_search=64, seed=7)",
        );
        final spec = db.vectorIndexes.single;
        expect(spec.kind, VectorIndexKind.hnsw);
        expect(spec.m, 32);
        expect(spec.efConstruction, 100);
        expect(spec.efSearch, 64);
        expect(spec.seed, 7);
      } finally {
        await db.close();
      }
    });

    test('ivf parses nlist/nprobe and inner_product alias', () async {
      final db = await _dbWithDocs(4, 20, math.Random(3));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_ivf USING vector_index("
          "table=docs, column=embedding, dim=4, kind=ivf, "
          "metric=inner_product, nlist=8, nprobe=4)",
        );
        final spec = db.vectorIndexes.single;
        expect(spec.kind, VectorIndexKind.ivf);
        expect(spec.metric, VectorMetric.innerProduct);
        expect(spec.nlist, 8);
        expect(spec.nprobe, 4);
      } finally {
        await db.close();
      }
    });

    test('DROP TABLE cascades to binding removal', () async {
      final db = await _dbWithDocs(3, 5, math.Random(4));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_vec USING vector_index("
          "table=docs, column=embedding, dim=3)",
        );
        expect(db.vectorIndexes.length, 1);
        await db.execute('DROP TABLE docs_vec');
        expect(db.vectorIndexes, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('missing required arg throws FormatException', () async {
      final db = await _dbWithDocs(3, 5, math.Random(5));
      try {
        expect(
          () => db.execute(
            'CREATE VIRTUAL TABLE bad USING vector_index('
            'table=docs, column=embedding)',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => db.execute(
            'CREATE VIRTUAL TABLE bad USING vector_index('
            'table=docs, dim=3)',
          ),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await db.close();
      }
    });

    test('unknown kind / metric throws FormatException', () async {
      final db = await _dbWithDocs(3, 5, math.Random(6));
      try {
        expect(
          () => db.execute(
            'CREATE VIRTUAL TABLE bad USING vector_index('
            'table=docs, column=embedding, dim=3, kind=bogus)',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => db.execute(
            'CREATE VIRTUAL TABLE bad USING vector_index('
            'table=docs, column=embedding, dim=3, metric=bogus)',
          ),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await db.close();
      }
    });

    test('unknown target column bubbles up from createVectorIndex', () async {
      final db = await _dbWithDocs(3, 5, math.Random(7));
      try {
        expect(
          () => db.execute(
            'CREATE VIRTUAL TABLE bad USING vector_index('
            'table=docs, column=nope, dim=3)',
          ),
          throwsStateError,
        );
      } finally {
        await db.close();
      }
    });

    test('duplicate registration on same (table, col) throws', () async {
      final db = await _dbWithDocs(3, 5, math.Random(8));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_vec USING vector_index("
          "table=docs, column=embedding, dim=3)",
        );
        expect(
          () => db.execute(
            "CREATE VIRTUAL TABLE docs_vec2 USING vector_index("
            "table=docs, column=embedding, dim=3)",
          ),
          throwsStateError,
        );
      } finally {
        await db.close();
      }
    });

    test('IF NOT EXISTS returns success on second CREATE', () async {
      final db = await _dbWithDocs(3, 5, math.Random(9));
      try {
        await db.execute(
          "CREATE VIRTUAL TABLE docs_vec USING vector_index("
          "table=docs, column=embedding, dim=3)",
        );
        final r = await db.execute(
          "CREATE VIRTUAL TABLE IF NOT EXISTS docs_vec USING vector_index("
          "table=docs, column=embedding, dim=3)",
        );
        expect(r.rows, isEmpty);
        expect(db.vectorIndexes.length, 1);
      } finally {
        await db.close();
      }
    });
  });
}
