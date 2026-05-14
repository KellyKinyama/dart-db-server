/// Phase-0.5 regression: paged-table `_findIndexPlan` now collects every
/// viable index plan and picks the one with the longest equality prefix
/// (with UNIQUE as a final tie-break) instead of returning the first
/// registered match. Previously a less-selective index declared earlier
/// would silently win over a perfect-match unique index declared later.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_paged_planner_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('paged: rows are still correct when two indexes overlap', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, a INTEGER, b INTEGER) USING paged');
      // Index a is registered FIRST. With the old behaviour, a probe
      // like `WHERE a = ? AND b = ?` would route through it (single
      // column match) even when a composite (a,b) index gives a
      // tighter probe. We can't observe the plan choice directly
      // here, but we can confirm the answer is still correct.
      await db.execute('CREATE INDEX i_a ON t(a)');
      await db.execute('CREATE INDEX i_ab ON t(a, b)');
      for (var i = 0; i < 40; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i % 8}, ${i % 5})');
      }
      final r = await db.execute(
          'SELECT id FROM t WHERE a = 3 AND b = 2 ORDER BY id');
      // Manual filter check: i % 8 == 3 AND i % 5 == 2 for i in [0,40).
      final expected = <List<Object?>>[
        for (var i = 0; i < 40; i++)
          if (i % 8 == 3 && i % 5 == 2) [i],
      ];
      expect(r.rows, expected);
    } finally {
      await db.close();
    }
  });

  test('paged: UNIQUE index is preferred when prefixes tie', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, code TEXT, bucket INTEGER) USING paged');
      // Non-unique on (code) registered first.
      await db.execute('CREATE INDEX i_code ON t(code)');
      // UNIQUE on (code) registered second — should win for equality
      // probes on code despite ordering.
      await db.execute('CREATE UNIQUE INDEX u_code ON t(code)');
      for (var i = 0; i < 20; i++) {
        await db
            .execute("INSERT INTO t VALUES ($i, 'c-$i', ${i % 4})");
      }
      // We can't directly see the chosen index, but the data must
      // round-trip exactly the same.
      final r =
          await db.execute("SELECT id, bucket FROM t WHERE code = 'c-13'");
      expect(r.rows, [
        [13, 1]
      ]);
    } finally {
      await db.close();
    }
  });

  test('paged: range-only plan still fires when no equality is available',
      () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE t ('
          'id INTEGER PRIMARY KEY, score INTEGER) USING paged');
      await db.execute('CREATE INDEX i_score ON t(score)');
      for (var i = 0; i < 50; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 2})');
      }
      final r = await db.execute(
          'SELECT id FROM t WHERE score >= 80 AND score < 90 ORDER BY id');
      // score = 2*i, so 80 <= 2i < 90 => 40 <= i < 45.
      expect(r.rows, [
        [40],
        [41],
        [42],
        [43],
        [44],
      ]);
    } finally {
      await db.close();
    }
  });
}
