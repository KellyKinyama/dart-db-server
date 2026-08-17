/// SQLite-format backend parity for vector indexes: specs persist to a
/// `<db>.vec.json` sidecar next to the `.sqlite` file. On reopen, the
/// sidecar is loaded after the SQLite import.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_vecsq_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in [
    '',
    '-wal',
    '-shm',
    '-journal',
    '.vec.json',
    '.tmp',
    '.vec.json.tmp'
  ]) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

Vector _rand(int dim, math.Random rng) =>
    Vector.fromList(List.generate(dim, (_) => rng.nextDouble() - 0.5));

void main() {
  final skipReason = sqliteSkipReason();

  group('SQLite backend + vector-index sidecar', () {
    test('spec persists to sidecar and reloads on reopen', () async {
      final f = _tmp('reopen');
      addTearDown(() => _cleanup(f));
      // Seed the .sqlite file via the oracle so our engine opens it in
      // SQLite-format mode.
      final ora = sq.sqlite3.open(f.path);
      ora.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'embedding BLOB);');
      ora.dispose();

      const dim = 4;
      final rng = math.Random(1);

      {
        final db = await Database.open(f.path);
        try {
          for (var i = 0; i < 10; i++) {
            final v = _rand(dim, rng);
            await db.execute(
              "INSERT INTO docs VALUES ($i, VEC('${v.toString()}'))",
            );
          }
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

      // Main file is still SQLite; sidecar exists with the spec.
      final raw = await f.readAsBytes();
      expect(String.fromCharCodes(raw.sublist(0, 15)), 'SQLite format 3');
      final sidecar = File('${f.path}.vec.json');
      expect(sidecar.existsSync(), isTrue);
      final sidecarText = sidecar.readAsStringSync();
      expect(sidecarText.contains('"kind":"hnsw"'), isTrue);
      expect(sidecarText.contains('"dim":4'), isTrue);

      // Reopen: binding is back.
      {
        final db = await Database.open(f.path);
        try {
          expect(db.vectorIndexes.length, 1);
          final spec = db.vectorIndexes.single;
          expect(spec.kind, VectorIndexKind.hnsw);
          expect(spec.dim, dim);
          expect(spec.m, 8);
          expect(spec.efConstruction, 40);
          expect(spec.efSearch, 32);
          expect(spec.seed, 7);

          // Fast path still works.
          final r = await db.execute(
            "SELECT id FROM docs "
            "ORDER BY VEC_L2(embedding, VEC('[0,0,0,0]')) ASC LIMIT 3",
          );
          expect(r.rows.length, 3);
        } finally {
          await db.close();
        }
      }
    }, skip: skipReason);

    test('DROP TABLE removes binding; next persist deletes sidecar', () async {
      final f = _tmp('drop');
      addTearDown(() => _cleanup(f));
      final ora = sq.sqlite3.open(f.path);
      ora.execute(
        'CREATE TABLE docs (id INTEGER PRIMARY KEY, embedding BLOB);',
      );
      ora.dispose();

      {
        final db = await Database.open(f.path);
        try {
          await db.execute("INSERT INTO docs VALUES (1, VEC('[1,0,0]'))");
          await db.execute(
            "CREATE VIRTUAL TABLE docs_vec USING vector_index("
            "table=docs, column=embedding, dim=3)",
          );
        } finally {
          await db.close();
        }
      }
      expect(File('${f.path}.vec.json').existsSync(), isTrue);

      {
        final db = await Database.open(f.path);
        try {
          await db.execute('DROP TABLE docs_vec');
          expect(db.vectorIndexes, isEmpty);
        } finally {
          await db.close();
        }
      }
      // Sidecar cleaned up.
      expect(File('${f.path}.vec.json').existsSync(), isFalse);
    }, skip: skipReason);

    test('missing sidecar on reopen is fine (empty vectorIndexes)', () async {
      final f = _tmp('nosidecar');
      addTearDown(() => _cleanup(f));
      final ora = sq.sqlite3.open(f.path);
      ora.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INT);");
      ora.execute("INSERT INTO t VALUES (1, 10);");
      ora.dispose();

      final db = await Database.open(f.path);
      try {
        expect(db.vectorIndexes, isEmpty);
        // Table itself opens fine.
        final r = await db.execute('SELECT v FROM t');
        expect(r.rows.single[0], 10);
      } finally {
        await db.close();
      }
    }, skip: skipReason);

    test('corrupt sidecar does not block open', () async {
      final f = _tmp('corrupt');
      addTearDown(() => _cleanup(f));
      final ora = sq.sqlite3.open(f.path);
      ora.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, v BLOB);');
      ora.dispose();
      await File('${f.path}.vec.json').writeAsString('{not json');

      final db = await Database.open(f.path);
      try {
        expect(db.vectorIndexes, isEmpty);
      } finally {
        await db.close();
      }
    }, skip: skipReason);
  });
}
