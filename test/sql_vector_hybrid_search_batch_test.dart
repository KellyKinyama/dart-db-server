/// V42 vec_hybrid_search_batch — multi-query RRF-fused vec+FTS5,
/// amortising the FTS5 corpus + payload filter build across queries.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec42_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

Future<void> _seed(Database db) async {
  await db.execute(
    'CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT, '
    'embedding BLOB VECTOR(dim=2))',
  );
  final rows = [
    (1, 'quantum leap forward', '[1, 0]'),
    (2, 'quantum theory basics', '[0.9, 0.1]'),
    (3, 'apple pie recipe', '[10, 10]'),
    (4, 'apple orchard sunrise', '[11, 11]'),
    (5, 'nothing related here', '[0.1, 0]'),
    (6, 'apple quantum theory', '[5, 5]'),
  ];
  for (final r in rows) {
    await db.execute(
      "INSERT INTO docs VALUES (${r.$1}, '${r.$2}', VEC('${r.$3}'))",
    );
  }
  await db.warmVectorIndexes();
}

void main() {
  group('V42 vec_hybrid_search_batch', () {
    test('two queries return per-query result blocks', () async {
      final db = await Database.open(_tmp('two'));
      try {
        await _seed(db);

        final r = await db.execute(
          "SELECT query_idx, rowid FROM vec_hybrid_search_batch("
          "'docs', 'embedding', 'body', "
          r"""'[{"vec":[0,0],"text":"quantum"},"""
          r"""{"vec":[10,10],"text":"apple"}]',"""
          "3)",
        );
        // Rows must be grouped by query_idx (0, 1) — each query
        // contributes at most k=3 rows.
        expect(r.rows.length, greaterThan(0));
        expect(r.rows.length, lessThanOrEqualTo(6));
        final byQ = <int, List<int>>{};
        for (final row in r.rows) {
          byQ.putIfAbsent(row[0] as int, () => []).add(row[1] as int);
        }
        expect(byQ.keys, containsAll([0, 1]));
        // Query 0 asks about "quantum" near [0,0] — expect id in 1..2.
        expect(byQ[0]!, anyElement(anyOf(1, 2)));
        // Query 1 asks about "apple" near [10,10] — expect 3 or 4.
        expect(byQ[1]!, anyElement(anyOf(3, 4)));
      } finally {
        await db.close();
      }
    });

    test('empty queries JSON returns no rows', () async {
      final db = await Database.open(_tmp('empty'));
      try {
        await _seed(db);
        final r = await db.execute(
          "SELECT rowid FROM vec_hybrid_search_batch("
          "'docs', 'embedding', 'body', '[]', 3)",
        );
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });

    test('malformed entry is skipped but valid entries still work', () async {
      final db = await Database.open(_tmp('malformed'));
      try {
        await _seed(db);
        // First entry has vec of wrong dim; second is valid.
        final r = await db.execute(
          "SELECT query_idx FROM vec_hybrid_search_batch("
          "'docs', 'embedding', 'body', "
          r"""'[{"vec":[1,2,3],"text":"foo"},"""
          r"""{"vec":[0.5,0.5],"text":"quantum"}]',"""
          "3)",
        );
        // Query_idx=1 must appear (valid). Query_idx=0 could
        // appear if we tolerated its bad dim, but we skip → absent.
        final ids = r.rows.map((r) => r[0]).toSet();
        expect(ids, contains(1));
        expect(ids, isNot(contains(0)));
      } finally {
        await db.close();
      }
    });

    test('respects filter_json across every query', () async {
      final db = await Database.open(_tmp('filter'));
      try {
        await db.execute(
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, tenant INTEGER, '
          "body TEXT, embedding BLOB VECTOR(dim=2, filter_cols='tenant'))",
        );
        for (var i = 1; i <= 8; i++) {
          await db.execute(
            "INSERT INTO docs VALUES ($i, ${i % 2}, 'foo $i', "
            "VEC('[${i / 8.0}, 0]'))",
          );
        }
        await db.warmVectorIndexes();

        final r = await db.execute(
          "SELECT rowid FROM vec_hybrid_search_batch("
          "'docs', 'embedding', 'body', "
          r"""'[{"vec":[0,0],"text":"foo"},"""
          r"""{"vec":[1,0],"text":"foo"}]',"""
          "3, 60, '{\"tenant\":0}')",
        );
        // Only tenant=0 rows (even IDs) may appear.
        for (final row in r.rows) {
          final id = row[0] as int;
          expect(id % 2, 0);
        }
      } finally {
        await db.close();
      }
    });

    test('rrf_score decreases within each query block', () async {
      final db = await Database.open(_tmp('mono'));
      try {
        await _seed(db);
        final r = await db.execute(
          "SELECT query_idx, rrf_score FROM vec_hybrid_search_batch("
          "'docs', 'embedding', 'body', "
          r"""'[{"vec":[0,0],"text":"quantum"}]',"""
          "5)",
        );
        for (var i = 1; i < r.rows.length; i++) {
          expect(r.rows[i][0], r.rows[i - 1][0]);
          final prev = (r.rows[i - 1][1] as num).toDouble();
          final curr = (r.rows[i][1] as num).toDouble();
          expect(curr, lessThanOrEqualTo(prev));
        }
      } finally {
        await db.close();
      }
    });
  });
}
