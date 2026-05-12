/// Standalone VALUES rowset queries.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('VALUES rowset', () {
    test('single row, multiple columns', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("VALUES (1, 'a', 2.5)");
        expect(r.columns, ['column1', 'column2', 'column3']);
        expect(r.rows, [
          [1, 'a', 2.5]
        ]);
      } finally {
        await db.close();
      }
    });

    test('multiple rows', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("VALUES (1, 'a'), (2, 'b'), (3, 'c')");
        expect(r.columns, ['column1', 'column2']);
        expect(r.rows, [
          [1, 'a'],
          [2, 'b'],
          [3, 'c'],
        ]);
      } finally {
        await db.close();
      }
    });

    test('with ORDER BY and LIMIT', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            'VALUES (3), (1), (4), (1), (5), (9) ORDER BY column1 LIMIT 3');
        expect(r.rows.map((r) => r.first).toList(), [1, 1, 3]);
      } finally {
        await db.close();
      }
    });

    test('VALUES with expressions', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('VALUES (1 + 1, 2 * 3), (10, 20)');
        expect(r.rows, [
          [2, 6],
          [10, 20],
        ]);
      } finally {
        await db.close();
      }
    });

    test('mismatched column count fails', () async {
      final db = await Database.open();
      try {
        await expectLater(
          db.execute('VALUES (1, 2), (3)'),
          throwsA(isA<FormatException>()),
        );
      } finally {
        await db.close();
      }
    });
  });
}
