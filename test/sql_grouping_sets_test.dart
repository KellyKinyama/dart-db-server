/// GROUPING SETS / ROLLUP / CUBE expand into a per-set aggregation that
/// is unioned together; columns rolled up by a given set come back NULL,
/// and GROUPING(expr) reports 1 for those rolled-up columns.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<void> seed(Database db) async {
    await db.execute('CREATE TABLE s(region TEXT, dept TEXT, sal INT)');
    await db.execute("INSERT INTO s VALUES "
        "('east','sales',100),('east','eng',200),"
        "('west','sales',300),('west','eng',400)");
  }

  group('ROLLUP', () {
    test('produces region/dept, region totals, grand total', () async {
      final db = await Database.open();
      try {
        await seed(db);
        final r = await db.execute('SELECT region, dept, sum(sal) AS s FROM s '
            'GROUP BY ROLLUP(region, dept) ORDER BY region, dept');
        // 4 leaf rows + 2 region subtotals + 1 grand total = 7
        expect(r.rows.length, 7);
        // Grand total has both keys NULL.
        final grand =
            r.rows.firstWhere((row) => row[0] == null && row[1] == null);
        expect(grand[2], 1000);
        // Region subtotals: dept NULL, region non-null.
        final eastSub =
            r.rows.firstWhere((row) => row[0] == 'east' && row[1] == null);
        expect(eastSub[2], 300);
      } finally {
        await db.close();
      }
    });
  });

  group('CUBE', () {
    test('produces every subset of grouping keys', () async {
      final db = await Database.open();
      try {
        await seed(db);
        final r = await db.execute('SELECT region, dept, sum(sal) AS s FROM s '
            'GROUP BY CUBE(region, dept)');
        // 4 leaves + 2 region totals + 2 dept totals + 1 grand = 9
        expect(r.rows.length, 9);
        // Dept-only subtotal: region NULL, dept set.
        final salesAll =
            r.rows.firstWhere((row) => row[0] == null && row[1] == 'sales');
        expect(salesAll[2], 400);
      } finally {
        await db.close();
      }
    });
  });

  group('GROUPING SETS', () {
    test('explicit list controls which subtotals appear', () async {
      final db = await Database.open();
      try {
        await seed(db);
        final r = await db.execute('SELECT region, dept, sum(sal) AS s FROM s '
            'GROUP BY GROUPING SETS ((region), (dept), ())');
        // 2 region + 2 dept + 1 grand = 5
        expect(r.rows.length, 5);
        final grand =
            r.rows.firstWhere((row) => row[0] == null && row[1] == null);
        expect(grand[2], 1000);
      } finally {
        await db.close();
      }
    });
  });

  group('GROUPING() function', () {
    test('returns 1 for rolled-up columns, 0 otherwise', () async {
      final db = await Database.open();
      try {
        await seed(db);
        final r =
            await db.execute('SELECT region, dept, GROUPING(region) AS gr, '
                'GROUPING(dept) AS gd, sum(sal) AS s '
                'FROM s GROUP BY ROLLUP(region, dept)');
        final grand =
            r.rows.firstWhere((row) => row[0] == null && row[1] == null);
        expect(grand[2], 1);
        expect(grand[3], 1);
        final regionSub =
            r.rows.firstWhere((row) => row[0] == 'east' && row[1] == null);
        expect(regionSub[2], 0);
        expect(regionSub[3], 1);
        final leaf =
            r.rows.firstWhere((row) => row[0] == 'east' && row[1] == 'sales');
        expect(leaf[2], 0);
        expect(leaf[3], 0);
      } finally {
        await db.close();
      }
    });
  });
}
