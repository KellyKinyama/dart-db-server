/// Oracle date/number formatting, arithmetic, regex and analytic gaps closed
/// in the round-23..24 sweeps: TO_CHAR format models, DATE arithmetic, INTERVAL
/// literals, REGEXP_REPLACE/SUBSTR/COUNT/INSTR, WIDTH_BUCKET, GROUPING_ID,
/// PERCENTILE_CONT, RATIO_TO_REPORT, FIRST_VALUE IGNORE NULLS, CONNECT_BY_ROOT.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('TO_CHAR(date, fmt) honours the format model', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TO_DATE('2021-06-15','YYYY-MM-DD'), 'MON')"),
          'JUN');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TO_DATE('2021-06-15','YYYY-MM-DD'), 'Mon')"),
          'Jun');
      expect(
          await scalar(db,
              "SELECT TO_CHAR(TO_DATE('2021-06-15','YYYY-MM-DD'), 'Q')"),
          '2');
    } finally {
      await db.close();
    }
  });

  test('TO_CHAR(number, fmt) honours the number format model', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT TO_CHAR(1234.5, 'FM9,999.00')"),
          '1,234.50');
    } finally {
      await db.close();
    }
  });

  test('DATE arithmetic computes day counts and shifts', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_DATE('2020-03-01','YYYY-MM-DD') - "
              "TO_DATE('2020-01-01','YYYY-MM-DD')"),
          60);
      expect(
          await scalar(db,
              "SELECT TO_DATE('2020-01-01','YYYY-MM-DD') + 5"),
          '2020-01-06');
    } finally {
      await db.close();
    }
  });

  test('INTERVAL literal composes with DATE arithmetic', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              "SELECT TO_DATE('2020-01-01','YYYY-MM-DD') + INTERVAL '5' DAY"),
          '2020-01-06');
    } finally {
      await db.close();
    }
  });

  test('REGEXP_REPLACE substitutes backreferences', () async {
    final db = await Database.open(null);
    try {
      expect(
          await scalar(db,
              r"SELECT REGEXP_REPLACE('John Smith', '(\w+) (\w+)', '\2 \1')"),
          'Smith John');
    } finally {
      await db.close();
    }
  });

  test('REGEXP_SUBSTR/COUNT/INSTR honour position and occurrence', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT REGEXP_SUBSTR('a1b2c3', '[0-9]', 1, 2)"),
          '2');
      expect(await scalar(db, "SELECT REGEXP_COUNT('a1b2c3', '[0-9]')"), 3);
      expect(await scalar(db, "SELECT REGEXP_INSTR('a1b2c3', '[0-9]', 1, 2)"),
          4);
    } finally {
      await db.close();
    }
  });

  test('WIDTH_BUCKET assigns equi-width histogram buckets', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, 'SELECT WIDTH_BUCKET(25, 0, 50, 5)'), 3);
      expect(await scalar(db, 'SELECT WIDTH_BUCKET(-1, 0, 50, 5)'), 0);
      expect(await scalar(db, 'SELECT WIDTH_BUCKET(99, 0, 50, 5)'), 6);
    } finally {
      await db.close();
    }
  });

  group('analytic aggregates', () {
    Future<Database> seed() async {
      final db = await Database.open(null);
      await db.execute('CREATE TABLE t (id NUMBER, g NUMBER, v NUMBER)');
      await db.execute('INSERT INTO t VALUES (1,1,10),(2,1,30),(3,2,NULL)');
      return db;
    }

    test('RATIO_TO_REPORT divides each value by the partition total', () async {
      final db = await seed();
      try {
        final r = await db.execute('SELECT RATIO_TO_REPORT(v) OVER () FROM t');
        expect(r.rows, [
          [0.25],
          [0.75],
          [null]
        ]);
      } finally {
        await db.close();
      }
    });

    test('PERCENTILE_CONT interpolates the median', () async {
      final db = await seed();
      try {
        expect(
            await scalar(db,
                'SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY v) FROM t'),
            20.0);
      } finally {
        await db.close();
      }
    });

    test('FIRST_VALUE IGNORE NULLS skips leading NULLs', () async {
      final db = await seed();
      try {
        final r = await db.execute(
            'SELECT FIRST_VALUE(v IGNORE NULLS) OVER (ORDER BY id) FROM t');
        expect(r.rows.first.first, 10);
      } finally {
        await db.close();
      }
    });

    test('GROUPING_ID flags rolled-up grouping keys', () async {
      final db = await seed();
      try {
        final r =
            await db.execute('SELECT GROUPING_ID(g) FROM t GROUP BY ROLLUP(g)');
        final vals = r.rows.map((e) => e.first).toSet();
        // Detail rows report 0; the rolled-up grand total reports 1.
        expect(vals.contains(0), isTrue);
        expect(vals.contains(1), isTrue);
      } finally {
        await db.close();
      }
    });

    test('CONNECT_BY_ROOT runs over a hierarchy', () async {
      final db = await seed();
      try {
        final r = await db.execute(
            'SELECT CONNECT_BY_ROOT g FROM t CONNECT BY PRIOR id = id - 1');
        expect(r.rows, isNotEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
