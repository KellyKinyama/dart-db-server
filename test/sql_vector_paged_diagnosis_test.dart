/// Vector-index on paged tables — Phase V22.
///
/// * Registration and DDL succeed on paged tables (no more "paged
///   storage not supported" error).
/// * `warmVectorIndexes()` streams paged rows via `pt.scan()` and
///   builds the index using each row's PK as the id.
/// * The `vec_search` TVF serves paged tables after warm — no need
///   to hit paged storage at query time.
/// * The planner fast paths (`_tryVectorKnnFast`, `_tryVectorRangeFast`)
///   bail on paged sources — the generic executor already handles
///   paged queries correctly via its own async streaming path.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vecpaged_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  test('createVectorIndex on a paged table no longer throws', () async {
    final db = await Database.open(_tmp('reg'));
    try {
      await db.execute('PRAGMA default_table_kind = paged');
      await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB)');
      db.createVectorIndex(const VectorIndexSpec(
        table: 'docs',
        column: 'embedding',
        dim: 3,
      ));
      expect(db.vectorIndexes.length, 1);
    } finally {
      await db.close();
    }
  });

  test('CREATE VIRTUAL TABLE ... USING vector_index on paged succeeds',
      () async {
    final db = await Database.open(_tmp('ddl'));
    try {
      await db.execute('PRAGMA default_table_kind = paged');
      await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB)');
      await db.execute(
        "CREATE VIRTUAL TABLE docs_vec USING vector_index("
        "table=docs, column=embedding, dim=3, kind=flat, metric=l2)",
      );
      expect(db.vectorIndexes.length, 1);
    } finally {
      await db.close();
    }
  });

  test('warmVectorIndexes builds a paged index and vec_search serves it',
      () async {
    final db = await Database.open(_tmp('warm'));
    try {
      await db.execute('PRAGMA default_table_kind = paged');
      await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'title TEXT, embedding BLOB)');
      await db.execute(
        "INSERT INTO docs VALUES (1, 'a', VEC('[1, 0, 0]'))",
      );
      await db.execute(
        "INSERT INTO docs VALUES (2, 'b', VEC('[0, 1, 0]'))",
      );
      await db.execute(
        "INSERT INTO docs VALUES (3, 'c', VEC('[0, 0, 1]'))",
      );
      db.createVectorIndex(const VectorIndexSpec(
        table: 'docs',
        column: 'embedding',
        dim: 3,
        kind: VectorIndexKind.flat,
        metric: VectorMetric.l2,
      ));
      await db.warmVectorIndexes();

      final r = await db.execute(
        "SELECT rowid, distance FROM vec_search("
        "'docs', 'embedding', VEC('[1, 0, 0]'), 1)",
      );
      expect(r.rows.single[0], 1); // Nearest is doc 1.
    } finally {
      await db.close();
    }
  });

  test('paged INSERT incrementally updates built index (V29)', () async {
    final db = await Database.open(_tmp('mutate'));
    try {
      await db.execute('PRAGMA default_table_kind = paged');
      await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB)');
      await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
      db.createVectorIndex(const VectorIndexSpec(
        table: 'docs',
        column: 'embedding',
        dim: 2,
        kind: VectorIndexKind.flat,
        metric: VectorMetric.l2,
      ));
      await db.warmVectorIndexes();

      // V29: paged INSERT no longer full-invalidates. The captured
      // delta is applied at vec_search time.
      await db.execute("INSERT INTO docs VALUES (2, VEC('[0, 1]'))");

      final r = await db.execute(
        "SELECT rowid FROM vec_search('docs', 'embedding', "
        "VEC('[0, 1]'), 1)",
      );
      expect(r.rows.single[0], 2);
    } finally {
      await db.close();
    }
  });

  test('in-memory tables still register normally', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB)');
      db.createVectorIndex(const VectorIndexSpec(
        table: 'docs',
        column: 'embedding',
        dim: 4,
      ));
      expect(db.vectorIndexes.length, 1);
    } finally {
      await db.close();
    }
  });
}
