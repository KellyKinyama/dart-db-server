/// Bitwise operators, `||` NULL semantics, IS / IS DISTINCT FROM.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Bitwise operators', () {
    test('AND / OR / XOR-via-combos', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT 6 & 3, 6 | 3, 6 & 3 | 8, (6 | 3) & 5');
        expect(r.rows.first, [2, 7, 10, 5]);
      } finally {
        await db.close();
      }
    });

    test('shifts', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT 1 << 4, 64 >> 2, -1 >> 1');
        expect(r.rows.first[0], 16);
        expect(r.rows.first[1], 16);
        // Dart's >> is arithmetic shift on signed ints; -1 >> 1 == -1.
        expect(r.rows.first[2], -1);
      } finally {
        await db.close();
      }
    });

    test('bitwise NOT (unary ~)', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT ~0, ~1, ~-1');
        expect(r.rows.first, [-1, -2, 0]);
      } finally {
        await db.close();
      }
    });

    test('precedence: + binds tighter than &', () async {
      final db = await Database.open();
      try {
        // 1 + 2 & 7  parses as (1 + 2) & 7  =>  3 & 7 == 3
        final r = await db.execute('SELECT 1 + 2 & 7');
        expect(r.rows.first.first, 3);
      } finally {
        await db.close();
      }
    });

    test('precedence: << binds looser than +', () async {
      final db = await Database.open();
      try {
        // 1 << 1 + 2  parses as 1 << (1 + 2)  =>  1 << 3 == 8
        final r = await db.execute('SELECT 1 << 1 + 2');
        expect(r.rows.first.first, 8);
      } finally {
        await db.close();
      }
    });

    test('bitwise propagates NULL', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT NULL & 1, 1 | NULL, NULL << 1, 1 >> NULL, ~NULL');
        expect(r.rows.first, [null, null, null, null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('|| concatenation NULL semantics', () {
    test("'a' || NULL returns NULL", () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT 'a' || NULL, NULL || 'b'");
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });

    test('non-null operands concatenate as strings', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT 'foo' || 'bar', 1 || 2");
        expect(r.rows.first, ['foobar', '12']);
      } finally {
        await db.close();
      }
    });
  });

  group('IS / IS NOT (NULL-safe equality)', () {
    test('IS / IS NOT against non-NULL operands', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT 1 IS 1, 1 IS 2, 1 IS NOT 2, 1 IS NOT 1');
        expect(r.rows.first, [true, false, true, false]);
      } finally {
        await db.close();
      }
    });

    test('IS against NULL is NULL-safe', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            'SELECT NULL IS NULL, NULL IS 1, 1 IS NULL, NULL IS NOT 1');
        expect(r.rows.first, [true, false, false, true]);
      } finally {
        await db.close();
      }
    });
  });

  group('IS DISTINCT FROM / IS NOT DISTINCT FROM', () {
    test('IS DISTINCT FROM treats NULLs as equal', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT NULL IS DISTINCT FROM NULL, '
            '       1 IS DISTINCT FROM NULL, '
            '       1 IS DISTINCT FROM 1, '
            '       1 IS DISTINCT FROM 2');
        expect(r.rows.first, [false, true, false, true]);
      } finally {
        await db.close();
      }
    });

    test('IS NOT DISTINCT FROM is the inverse', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT NULL IS NOT DISTINCT FROM NULL, '
            '       1 IS NOT DISTINCT FROM NULL, '
            '       1 IS NOT DISTINCT FROM 1');
        expect(r.rows.first, [true, false, true]);
      } finally {
        await db.close();
      }
    });

    test('DISTINCT FROM in WHERE clause filters NULLs correctly', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db.execute(
            'INSERT INTO t VALUES (1, 1), (1, 2), (NULL, NULL), (1, NULL)');
        final r = await db
            .execute('SELECT a, b FROM t WHERE a IS NOT DISTINCT FROM b '
                'ORDER BY a NULLS FIRST, b NULLS FIRST');
        // Equal pairs: (NULL,NULL), (1,1).
        expect(r.rows, [
          [null, null],
          [1, 1],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
