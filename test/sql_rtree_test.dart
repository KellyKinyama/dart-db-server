/// CREATE VIRTUAL TABLE ... USING rtree: range query semantics.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('rtree virtual table', () {
    test('2D rtree: bounding-box query returns intersecting rows', () async {
      final db = await Database.open();
      await db.execute(
          'CREATE VIRTUAL TABLE shapes USING rtree(id, x0, x1, y0, y1)');
      // Three boxes; the query asks for shapes that intersect (5,5).
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
    });

    test('rtree id behaves like INTEGER PRIMARY KEY', () async {
      final db = await Database.open();
      await db.execute('CREATE VIRTUAL TABLE r USING rtree(id, x0, x1)');
      await db.execute('INSERT INTO r VALUES (1, 0.0, 1.0)');
      // Duplicate id should fail (PRIMARY KEY UNIQUE).
      Object? err;
      try {
        await db.execute('INSERT INTO r VALUES (1, 2.0, 3.0)');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
    });
  });
}
