/// Planner integration: rtree virtual tables should use the in-memory
/// R-tree spatial index for bounding-box / point queries.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('rtree planner', () {
    test('point-in-box query is served by the R-tree index', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE VIRTUAL TABLE shapes USING rtree(id, x0, x1, y0, y1)');
        await db.execute('INSERT INTO shapes VALUES '
            '(1, 0.0, 10.0, 0.0, 10.0),'
            '(2, 20.0, 30.0, 20.0, 30.0),'
            '(3, 4.0, 6.0,  4.0, 6.0)');
        final r =
            await db.execute('SELECT id FROM shapes WHERE x0 <= 5 AND x1 >= 5 '
                'AND y0 <= 5 AND y1 >= 5 ORDER BY id');
        expect(r.rows, [
          [1],
          [3]
        ]);
        expect(db.lastPlanTrace.join(' '), contains('RTREE'),
            reason: 'expected RTREE plan, got: ${db.lastPlanTrace}');
      } finally {
        await db.close();
      }
    });

    test('large rtree: index returns the same rows as a brute scan', () async {
      final db = await Database.open();
      try {
        await db
            .execute('CREATE VIRTUAL TABLE s USING rtree(id, x0, x1, y0, y1)');
        final rnd = math.Random(7);
        final stored = <List<double>>[];
        for (var i = 0; i < 300; i++) {
          final x = rnd.nextDouble() * 1000;
          final y = rnd.nextDouble() * 1000;
          stored.add([x, x + 1, y, y + 1]);
          await db.execute('INSERT INTO s VALUES ($i, ${x.toStringAsFixed(4)}, '
              '${(x + 1).toStringAsFixed(4)}, ${y.toStringAsFixed(4)}, '
              '${(y + 1).toStringAsFixed(4)})');
        }
        final r = await db.execute('SELECT id FROM s '
            'WHERE x0 <= 600 AND x1 >= 400 AND y0 <= 600 AND y1 >= 400 '
            'ORDER BY id');
        final actual = r.rows.map((r) => r.first as int).toList();
        final expected = <int>[];
        for (var i = 0; i < stored.length; i++) {
          final box = stored[i];
          if (box[0] <= 600 &&
              box[1] >= 400 &&
              box[2] <= 600 &&
              box[3] >= 400) {
            expected.add(i);
          }
        }
        expected.sort();
        expect(actual, expected);
        expect(db.lastPlanTrace.join(' '), contains('RTREE'));
      } finally {
        await db.close();
      }
    });

    test('rtree cache is invalidated after INSERT', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE VIRTUAL TABLE s USING rtree(id, x0, x1)');
        await db.execute('INSERT INTO s VALUES (1, 0.0, 1.0)');
        // First query builds the cache.
        await db.execute('SELECT id FROM s WHERE x0 <= 0.5 AND x1 >= 0.5');
        // Insert a second box that the next query must see.
        await db.execute('INSERT INTO s VALUES (2, 10.0, 11.0)');
        final r = await db
            .execute('SELECT id FROM s WHERE x0 <= 10.5 AND x1 >= 10.5');
        expect(r.rows, [
          [2]
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
