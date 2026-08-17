/// Vector-index persistence: `VectorIndexSpec` + vtab bookkeeping
/// survive a `Database.close()` → reopen cycle via the JSON backend.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vecpers_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

Future<void> _seedDocs(Database db, int dim, int n, math.Random rng) async {
  await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
      'title TEXT, embedding BLOB)');
  for (var i = 0; i < n; i++) {
    final v = _rand(dim, rng);
    await db.execute(
      "INSERT INTO docs VALUES ($i, 'doc_$i', VEC('${v.toString()}'))",
    );
  }
}

void main() {
  group('JSON persistence of vector indexes', () {
    test('DDL-registered spec survives reopen and stays queryable', () async {
      final path = _tmp('ddl_reopen');
      const dim = 4;
      final rng = math.Random(1);

      // Session 1: create table + register + query.
      {
        final db = await Database.open(path);
        try {
          await _seedDocs(db, dim, 12, rng);
          await db.execute(
            "CREATE VIRTUAL TABLE docs_vec USING vector_index("
            "table=docs, column=embedding, dim=$dim, kind=hnsw, "
            "metric=l2, m=8, ef_construction=40, ef_search=32, seed=7)",
          );
          expect(db.vectorIndexes.length, 1);
        } finally {
          await db.close();
        }
      }

      // Session 2: reopen — spec must be back, with all params intact.
      {
        final db = await Database.open(path);
        try {
          expect(db.vectorIndexes.length, 1);
          final spec = db.vectorIndexes.single;
          expect(spec.table, 'docs');
          expect(spec.column, 'embedding');
          expect(spec.dim, dim);
          expect(spec.kind, VectorIndexKind.hnsw);
          expect(spec.metric, VectorMetric.l2);
          expect(spec.m, 8);
          expect(spec.efConstruction, 40);
          expect(spec.efSearch, 32);
          expect(spec.seed, 7);

          // Fast path still works after reopen (index rebuilds lazily).
          final query = _rand(dim, rng);
          final qLit = "VEC('${query.toString()}')";
          final r = await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, $qLit) ASC LIMIT 3",
          );
          expect(r.rows.length, 3);
        } finally {
          await db.close();
        }
      }
    });

    test('DROP TABLE after reopen still cascades to binding', () async {
      final path = _tmp('drop_after_reopen');
      const dim = 3;
      final rng = math.Random(2);
      {
        final db = await Database.open(path);
        try {
          await _seedDocs(db, dim, 5, rng);
          await db.execute(
            "CREATE VIRTUAL TABLE docs_vec USING vector_index("
            "table=docs, column=embedding, dim=$dim)",
          );
        } finally {
          await db.close();
        }
      }
      {
        final db = await Database.open(path);
        try {
          expect(db.vectorIndexes.length, 1);
          await db.execute('DROP TABLE docs_vec');
          expect(db.vectorIndexes, isEmpty);
        } finally {
          await db.close();
        }
      }
      // Third reopen: DROP must have persisted.
      {
        final db = await Database.open(path);
        try {
          expect(db.vectorIndexes, isEmpty);
        } finally {
          await db.close();
        }
      }
    });

    test('programmatically-registered binding (no vtab) survives reopen',
        () async {
      final path = _tmp('prog_reopen');
      const dim = 4;
      final rng = math.Random(3);
      {
        final db = await Database.open(path);
        try {
          await _seedDocs(db, dim, 5, rng);
          db.createVectorIndex(VectorIndexSpec(
            table: 'docs',
            column: 'embedding',
            dim: dim,
            kind: VectorIndexKind.flat,
            metric: VectorMetric.l2,
          ));
          // Force a persist by executing a trivial mutation.
          await db.execute("INSERT INTO docs VALUES (99, 'x', "
              "VEC('[0.1, 0.2, 0.3, 0.4]'))");
        } finally {
          await db.close();
        }
      }
      {
        final db = await Database.open(path);
        try {
          expect(db.vectorIndexes.length, 1);
          final spec = db.vectorIndexes.single;
          expect(spec.table, 'docs');
          expect(spec.column, 'embedding');
          expect(spec.kind, VectorIndexKind.flat);
          // No vtab was ever created, so DROP TABLE has nothing to
          // cascade — the binding stays.
          expect(
            () => db.execute('DROP TABLE nothing_here'),
            throwsStateError,
          );
        } finally {
          await db.close();
        }
      }
    });

    test('empty vector_indexes → JSON does not carry the key', () async {
      final path = _tmp('no_indexes');
      {
        final db = await Database.open(path);
        try {
          await db.execute('CREATE TABLE t(a INT)');
          await db.execute('INSERT INTO t VALUES (1)');
        } finally {
          await db.close();
        }
      }
      final text = await File(path).readAsString();
      expect(text.contains('vector_indexes'), isFalse);
    });

    test('malformed vector_indexes entries are skipped, not fatal', () async {
      final path = _tmp('bad_entry');
      // Seed a real DB with one good binding, then rewrite the JSON
      // to inject an extra malformed entry alongside the good one.
      {
        final db = await Database.open(path);
        try {
          await _seedDocs(db, 3, 3, math.Random(0));
          db.createVectorIndex(const VectorIndexSpec(
            table: 'docs',
            column: 'embedding',
            dim: 3,
          ));
          // Trigger persist via a trivial mutation.
          await db.execute("INSERT INTO docs VALUES (99, 'x', "
              "VEC('[0.1, 0.2, 0.3]'))");
        } finally {
          await db.close();
        }
      }
      // Inject `{"bogus":true}` as an additional entry in the array.
      var text = await File(path).readAsString();
      text = text.replaceFirst(
        '"vector_indexes":[',
        '"vector_indexes":[{"bogus":true},',
      );
      await File(path).writeAsString(text);

      final db = await Database.open(path);
      try {
        // Only the well-formed binding should have been recovered.
        expect(db.vectorIndexes.length, 1);
        expect(db.vectorIndexes.single.table, 'docs');
      } finally {
        await db.close();
      }
    });
  });
}
