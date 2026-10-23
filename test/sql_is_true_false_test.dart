/// IS TRUE / IS FALSE / IS NOT TRUE / IS NOT FALSE predicates.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('IS TRUE / FALSE', () {
    test('boolean literals', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT TRUE IS TRUE, FALSE IS TRUE, '
            '       TRUE IS FALSE, FALSE IS FALSE');
        expect(r.rows.first, [true, false, false, true]);
      } finally {
        await db.close();
      }
    });

    test('numeric truthiness: 0 is FALSE, non-zero is TRUE', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT 1 IS TRUE, 0 IS TRUE, 5 IS TRUE, 0 IS FALSE');
        expect(r.rows.first, [true, false, true, true]);
      } finally {
        await db.close();
      }
    });

    test('NULL is neither TRUE nor FALSE', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT NULL IS TRUE, NULL IS FALSE, '
            '       NULL IS NOT TRUE, NULL IS NOT FALSE');
        expect(r.rows.first, [false, false, true, true]);
      } finally {
        await db.close();
      }
    });

    test('IS NOT TRUE inverts', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT 1 IS NOT TRUE, 0 IS NOT TRUE, NULL IS NOT TRUE');
        expect(r.rows.first, [false, true, true]);
      } finally {
        await db.close();
      }
    });

    test('used as filter in WHERE', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (x INTEGER)');
        await db.execute('INSERT INTO t VALUES (0),(1),(2),(NULL)');
        final r =
            await db.execute('SELECT x FROM t WHERE x IS TRUE ORDER BY x');
        expect(r.rows.map((r) => r.first).toList(), [1, 2]);
        final r2 =
            await db.execute('SELECT x FROM t WHERE x IS NOT TRUE ORDER BY x');
        // 0 and NULL satisfy IS NOT TRUE.
        expect(r2.rows.map((r) => r.first).toList(), [null, 0]);
      } finally {
        await db.close();
      }
    });
  });
}
