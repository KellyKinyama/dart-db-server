/// Two SQLite-parity gaps closed: window-frame RANGE / GROUPS bounds and
/// the JSONB family of functions (text-encoded; round-trips with JSON).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Window frame: RANGE n PRECEDING/FOLLOWING', () {
    test('RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING sums by value', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(k INT)');
        await db.execute('INSERT INTO t VALUES(1),(2),(2),(5),(6)');
        // For k=2 the value-window [1..3] includes 1,2,2 → sum 5.
        // For k=5 the window [4..6] includes 5,6 → sum 11.
        // For k=6 the window [5..7] includes 5,6 → sum 11.
        final r = await db.execute('SELECT k, sum(k) OVER (ORDER BY k '
            'RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS s '
            'FROM t ORDER BY k');
        final got = r.rows.map((row) => [row[0], row[1]]).toList();
        expect(got, [
          [1, 5], // 1+2+2 (1's window is [0..2])
          [2, 5], // 1+2+2
          [2, 5], // 1+2+2 (peers share the same frame)
          [5, 11], // 5+6
          [6, 11], // 5+6
        ]);
      } finally {
        await db.close();
      }
    });

    test('GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW counts peer groups',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(k INT)');
        await db.execute('INSERT INTO t VALUES(1),(2),(2),(3)');
        // For k=2 (peer group {2,2}): previous group is {1}, current is
        // {2,2} → frame includes 1,2,2 → sum 5. For k=3: prev group
        // {2,2}, current {3} → 2+2+3 = 7.
        final r = await db.execute('SELECT k, sum(k) OVER (ORDER BY k '
            'GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW) AS s '
            'FROM t ORDER BY k');
        final got = r.rows.map((row) => [row[0], row[1]]).toList();
        expect(got, [
          [1, 1],
          [2, 5],
          [2, 5],
          [3, 7],
        ]);
      } finally {
        await db.close();
      }
    });
  });

  group('JSONB family', () {
    test('jsonb(x) returns canonical JSON text', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT jsonb('{\"b\":2,\"a\":1}') AS s");
        // We don't reorder keys (text JSON path).
        expect(r.rows.first[0], '{"b":2,"a":1}');
      } finally {
        await db.close();
      }
    });

    test('jsonb_extract reads paths like json_extract', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT jsonb_extract('{\"a\":1,\"b\":[10,20]}', '\$.b[1]') AS v");
        expect(r.rows.first[0], 20);
      } finally {
        await db.close();
      }
    });

    test('jsonb_set / jsonb_remove round-trip', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT jsonb_remove(jsonb_set('{\"a\":1}', '\$.b', 2), '\$.a') AS s");
        expect(r.rows.first[0], '{"b":2}');
      } finally {
        await db.close();
      }
    });

    test('jsonb_group_array / jsonb_group_object aggregates', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(g INT, k TEXT, v INT)');
        await db
            .execute("INSERT INTO t VALUES(1,'a',10),(1,'b',20),(2,'c',30)");
        final r = await db.execute('SELECT g, jsonb_group_array(v) AS arr, '
            'jsonb_group_object(k, v) AS obj '
            'FROM t GROUP BY g ORDER BY g');
        expect(r.rows[0][0], 1);
        expect(r.rows[0][1], '[10,20]');
        expect(r.rows[0][2], '{"a":10,"b":20}');
        expect(r.rows[1][2], '{"c":30}');
      } finally {
        await db.close();
      }
    });
  });
}
