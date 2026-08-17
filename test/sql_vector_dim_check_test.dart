/// V35 dim-check at INSERT/UPDATE time — catches embedding-shape
/// mismatches at write time instead of silently skipping rows at
/// query time.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec35_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V35 write-time dim check', () {
    test('INSERT with wrong dim throws with actionable message', () async {
      final db = await Database.open(_tmp('insert_wrong'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB VECTOR(dim=3))');
        // dim=3 in DDL; supplying a 4-d vector.
        expect(
          () async => db.execute(
            "INSERT INTO docs VALUES (1, VEC('[1, 2, 3, 4]'))",
          ),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('dim=3'))),
        );
      } finally {
        await db.close();
      }
    });

    test('NULL vector is allowed (row not indexed)', () async {
      final db = await Database.open(_tmp('null_ok'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB VECTOR(dim=3))');
        await db.execute("INSERT INTO docs VALUES (1, NULL)");
        final c = await db.execute('SELECT COUNT(*) FROM docs');
        expect(c.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('UPDATE with wrong dim throws', () async {
      final db = await Database.open(_tmp('update_wrong'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB VECTOR(dim=2))');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 0]'))");
        expect(
          () async => db.execute(
            "UPDATE docs SET embedding = VEC('[1, 2, 3]') WHERE id = 1",
          ),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });

    test('correct dim insert succeeds', () async {
      final db = await Database.open(_tmp('correct'));
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB VECTOR(dim=3))');
        await db.execute("INSERT INTO docs VALUES (1, VEC('[1, 2, 3]'))");
        final c = await db.execute('SELECT COUNT(*) FROM docs');
        expect(c.rows.single[0], 1);
      } finally {
        await db.close();
      }
    });

    test('no binding registered → no dim check', () async {
      // A BLOB column without a VECTOR() attribute is a plain BLOB.
      final db = await Database.open(_tmp('no_binding'));
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, e BLOB)');
        await db.execute("INSERT INTO t VALUES (1, VEC('[1, 2]'))");
        await db.execute("INSERT INTO t VALUES (2, VEC('[1, 2, 3]'))");
        final c = await db.execute('SELECT COUNT(*) FROM t');
        expect(c.rows.single[0], 2);
      } finally {
        await db.close();
      }
    });
  });
}
