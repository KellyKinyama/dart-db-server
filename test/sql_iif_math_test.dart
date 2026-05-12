/// IIF() function and SQLite 3.35+ math scalar functions.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('IIF', () {
    test('returns then-branch when condition is true', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT IIF(1=1, 'yes', 'no')");
        expect(r.rows.first.first, 'yes');
      } finally {
        await db.close();
      }
    });

    test('returns else-branch when condition is false', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT IIF(1=2, 'yes', 'no')");
        expect(r.rows.first.first, 'no');
      } finally {
        await db.close();
      }
    });

    test('NULL condition treated as false', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT IIF(NULL, 'yes', 'no')");
        expect(r.rows.first.first, 'no');
      } finally {
        await db.close();
      }
    });

    test('Works in WHERE / projections per row', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (x INTEGER)');
        await db.execute('INSERT INTO t VALUES (1), (2), (3), (4)');
        final r = await db.execute(
            "SELECT x, IIF(x % 2 = 0, 'even', 'odd') AS p FROM t ORDER BY x");
        expect(
            r.rows.map((r) => r[1]).toList(), ['odd', 'even', 'odd', 'even']);
      } finally {
        await db.close();
      }
    });
  });

  group('Math scalar functions', () {
    test('PI() constant', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT PI()');
        expect(r.rows.first.first, closeTo(3.14159265, 1e-7));
      } finally {
        await db.close();
      }
    });

    test('EXP / LN inverse round-trip', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT LN(EXP(1.5))');
        expect(r.rows.first.first as num, closeTo(1.5, 1e-9));
      } finally {
        await db.close();
      }
    });

    test('LOG10 and LOG2', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT LOG10(1000), LOG2(1024)');
        expect((r.rows.first[0] as num).round(), 3);
        expect((r.rows.first[1] as num).round(), 10);
      } finally {
        await db.close();
      }
    });

    test('LOG(b, x) is logarithm base b', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT LOG(2, 8), LOG(10, 100)');
        expect((r.rows.first[0] as num).round(), 3);
        expect((r.rows.first[1] as num).round(), 2);
      } finally {
        await db.close();
      }
    });

    test('LN / LOG domain returns NULL on non-positive', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT LN(0), LN(-1), LOG10(-2)');
        expect(r.rows.first, [null, null, null]);
      } finally {
        await db.close();
      }
    });

    test('SIN / COS / TAN at 0 and PI', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT SIN(0), COS(0), SIN(PI()), COS(PI())');
        expect(r.rows.first[0], 0);
        expect(r.rows.first[1], 1);
        expect((r.rows.first[2] as num).abs(), lessThan(1e-10));
        expect(r.rows.first[3] as num, closeTo(-1, 1e-10));
      } finally {
        await db.close();
      }
    });

    test('ASIN / ACOS / ATAN inverse', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT ASIN(1), ACOS(0), ATAN(1), ATAN2(1, 1)');
        expect(r.rows.first[0] as num, closeTo(mathPi / 2, 1e-10));
        expect(r.rows.first[1] as num, closeTo(mathPi / 2, 1e-10));
        expect(r.rows.first[2] as num, closeTo(mathPi / 4, 1e-10));
        expect(r.rows.first[3] as num, closeTo(mathPi / 4, 1e-10));
      } finally {
        await db.close();
      }
    });

    test('ASIN / ACOS out of range -> NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT ASIN(2), ACOS(-3)');
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });

    test('RADIANS / DEGREES', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT RADIANS(180), DEGREES(PI())');
        expect(r.rows.first[0] as num, closeTo(mathPi, 1e-10));
        expect(r.rows.first[1] as num, closeTo(180, 1e-10));
      } finally {
        await db.close();
      }
    });

    test('TRUNC removes fractional part toward zero', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT TRUNC(3.7), TRUNC(-3.7)');
        expect(r.rows.first, [3, -3]);
      } finally {
        await db.close();
      }
    });

    test('SINH / COSH / TANH', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT SINH(0), COSH(0), TANH(0), TANH(1000)');
        expect(r.rows.first[0], 0);
        expect(r.rows.first[1], 1);
        expect(r.rows.first[2], 0);
        expect(r.rows.first[3] as num, closeTo(1, 1e-10));
      } finally {
        await db.close();
      }
    });

    test('NULL inputs propagate', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT EXP(NULL), LN(NULL), SIN(NULL), ATAN2(NULL, 1)');
        expect(r.rows.first, [null, null, null, null]);
      } finally {
        await db.close();
      }
    });
  });
}

const double mathPi = 3.141592653589793;
