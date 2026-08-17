/// V44 paged hybrid search — extends V41/V42 to paged tables via
/// `warmFts5(...)`, which builds the FTS5 corpus from `pt.scan()`.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec44_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

Future<Database> _seedPaged(String tag) async {
  final db = await Database.open(_tmp(tag));
  await db.execute('PRAGMA default_table_kind = paged');
  await db.execute(
    'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
    "body TEXT, embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
  );
  final rows = <(int, int, String, String)>[
    (1, 0, 'quantum leap forward', '[1, 0]'),
    (2, 0, 'quantum theory basics', '[0.9, 0.1]'),
    (3, 1, 'apple pie recipe', '[10, 10]'),
    (4, 1, 'apple orchard sunrise', '[11, 11]'),
    (5, 0, 'nothing related here', '[0.1, 0]'),
    (6, 1, 'apple quantum theory', '[5, 5]'),
  ];
  for (final r in rows) {
    await db.execute(
      "INSERT INTO docs VALUES (${r.$1}, ${r.$2}, '${r.$3}', "
      "VEC('${r.$4}'))",
    );
  }
  await db.warmVectorIndexes();
  await db.warmFts5('docs', 'body');
  return db;
}

void main() {
  group('V44 paged hybrid search', () {
    test('single-query hybrid search on paged returns fused ranking', () async {
      final db = await _seedPaged('single');
      try {
        final r = await db.execute(
          "SELECT rowid, rrf_score FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', "
          "VEC('[0, 0]'), 'quantum', 3)",
        );
        expect(r.rows.length, greaterThan(0));
        // The nearest-to-origin AND text-matching row is id=2 or id=1
        // (both have 'quantum' and small vec distance).
        final ids = r.rows.map((row) => row[0]).toSet();
        expect(ids, anyOf(contains(1), contains(2)));
      } finally {
        await db.close();
      }
    });

    test('batch hybrid search on paged returns per-query results', () async {
      final db = await _seedPaged('batch');
      try {
        final r = await db.execute(
          "SELECT query_idx, rowid FROM vec_hybrid_search_batch("
          "'docs', 'embedding', 'body', "
          r"""'[{"vec":[0,0],"text":"quantum"},"""
          r"""{"vec":[10,10],"text":"apple"}]',"""
          "3)",
        );
        expect(r.rows.length, greaterThan(0));
        final byQ = <int, List<int>>{};
        for (final row in r.rows) {
          byQ.putIfAbsent(row[0] as int, () => []).add(row[1] as int);
        }
        expect(byQ.keys, containsAll([0, 1]));
        // Query 1 ("apple") should surface id 3 or 4 (apple text).
        expect(byQ[1]!, anyElement(anyOf(3, 4)));
      } finally {
        await db.close();
      }
    });

    test('paged hybrid with filter_json restricts to filtered rows', () async {
      final db = await _seedPaged('filter');
      try {
        final r = await db.execute(
          "SELECT rowid FROM vec_hybrid_search("
          "'docs', 'embedding', 'body', VEC('[10, 10]'), "
          "'apple', 3, 60, '{\"tenant\":1}')",
        );
        // Only tenant=1 rows (3, 4, 6) may appear.
        for (final row in r.rows) {
          final id = row[0] as int;
          expect([3, 4, 6], contains(id));
        }
      } finally {
        await db.close();
      }
    });

    test('missing warmFts5 → clear error message', () async {
      final db = await Database.open(_tmp('unwarmed'));
      try {
        await db.execute('PRAGMA default_table_kind = paged');
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, '
          'body TEXT, embedding BLOB VECTOR(dim=2))',
        );
        await db.execute(
          "INSERT INTO docs VALUES (1, 'hello', VEC('[0, 0]'))",
        );
        await db.warmVectorIndexes();
        // Intentionally skip warmFts5.
        expect(
          () async => db.execute(
            "SELECT rowid FROM vec_hybrid_search("
            "'docs', 'embedding', 'body', VEC('[0, 0]'), 'hello', 3)",
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('warmFts5'),
          )),
        );
      } finally {
        await db.close();
      }
    });
  });
}
