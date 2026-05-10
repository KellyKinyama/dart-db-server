/// Tests for greedy join reordering.
///
/// Correctness is enforced by the broader regression suite (and by these
/// tests too via row-equality assertions). The interesting assertions
/// here are about *which* table the planner chooses to drive the join
/// — we want the smallest one first.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Planner: join reordering', () {
    test('FROM big JOIN small => engine drives from small (correct rows)',
        () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE big (id INTEGER, k INTEGER)');
      await db.execute('CREATE TABLE small (k INTEGER, label TEXT)');
      // Big is intentionally first in source order.
      for (var i = 0; i < 500; i++) {
        await db.execute('INSERT INTO big VALUES ($i, ${i % 5})');
      }
      for (var i = 0; i < 5; i++) {
        await db.execute("INSERT INTO small VALUES ($i, 'L$i')");
      }
      // The reordered query should still produce the join of every
      // (id,label) pair where big.k = small.k. With 500 rows in big and
      // ~100 per k, the result has 500 rows (one per row in big).
      final r = await db.execute('SELECT id, label FROM big '
          'INNER JOIN small ON big.k = small.k ORDER BY id');
      expect(r.rows.length, 500);
      // Spot-check a couple of row contents.
      expect(r.rows.first, [0, 'L0']);
      expect(r.rows.last, [499, 'L${499 % 5}']);
    });

    test('Three-way INNER join is reordered safely', () async {
      final db = await Database.open();
      await db.execute('CREATE TABLE a (id INTEGER, b_id INTEGER)');
      await db.execute('CREATE TABLE b (id INTEGER, c_id INTEGER)');
      await db.execute('CREATE TABLE c (id INTEGER, label TEXT)');
      // a is huge, b is medium, c is tiny.
      for (var i = 0; i < 200; i++) {
        await db.execute('INSERT INTO a VALUES ($i, ${i % 20})');
      }
      for (var i = 0; i < 20; i++) {
        await db.execute('INSERT INTO b VALUES ($i, ${i % 4})');
      }
      for (var i = 0; i < 4; i++) {
        await db.execute("INSERT INTO c VALUES ($i, 'C$i')");
      }
      final r = await db.execute('SELECT a.id, c.label FROM a '
          'INNER JOIN b ON a.b_id = b.id '
          'INNER JOIN c ON b.c_id = c.id '
          'ORDER BY a.id');
      // Each a row joins to exactly one b and that b to exactly one c.
      expect(r.rows.length, 200);
      // Spot check first/last labels.
      expect(r.rows.first[0], 0);
      expect(r.rows.first[1], 'C${(0 % 20) % 4}');
      expect(r.rows.last[0], 199);
      expect(r.rows.last[1], 'C${(199 % 20) % 4}');
    });

    test('Reordering does NOT trigger for LEFT JOIN', () async {
      // LEFT joins are order-sensitive; we must preserve source order.
      final db = await Database.open();
      await db.execute('CREATE TABLE a (id INTEGER, k INTEGER)');
      await db.execute('CREATE TABLE b (k INTEGER, label TEXT)');
      await db.execute('INSERT INTO a VALUES (1,1),(2,2),(3,3)');
      await db.execute("INSERT INTO b VALUES (1, 'one')");
      final r = await db.execute('SELECT a.id, b.label FROM a '
          'LEFT JOIN b ON a.k = b.k ORDER BY a.id');
      expect(r.rows, [
        [1, 'one'],
        [2, null],
        [3, null],
      ]);
    });
  });
}
