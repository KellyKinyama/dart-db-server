import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
    await db.execute('CREATE TABLE sales(region TEXT, amount INTEGER)');
    await db.execute("INSERT INTO sales VALUES "
        "('east', 10), ('east', 20), ('east', 30), "
        "('west', 5), ('west', 15)");
  });

  group('Window functions', () {
    test('ROW_NUMBER() OVER (ORDER BY amount)', () async {
      final r = await db
          .execute('SELECT amount, ROW_NUMBER() OVER (ORDER BY amount) AS rn '
              'FROM sales ORDER BY amount');
      expect(r.rows, [
        [5, 1],
        [10, 2],
        [15, 3],
        [20, 4],
        [30, 5],
      ]);
    });

    test('RANK() / DENSE_RANK() handle ties', () async {
      await db.execute('CREATE TABLE t(s INTEGER)');
      await db.execute('INSERT INTO t VALUES (10),(10),(20),(30)');
      final r = await db.execute('SELECT s, RANK() OVER (ORDER BY s) AS r, '
          'DENSE_RANK() OVER (ORDER BY s) AS d '
          'FROM t ORDER BY s');
      expect(r.rows, [
        [10, 1, 1],
        [10, 1, 1],
        [20, 3, 2],
        [30, 4, 3],
      ]);
    });

    test('PARTITION BY restarts numbering per partition', () async {
      final r = await db.execute('SELECT region, amount, '
          'ROW_NUMBER() OVER (PARTITION BY region ORDER BY amount) AS rn '
          'FROM sales ORDER BY region, amount');
      expect(r.rows, [
        ['east', 10, 1],
        ['east', 20, 2],
        ['east', 30, 3],
        ['west', 5, 1],
        ['west', 15, 2],
      ]);
    });

    test('SUM(...) OVER (PARTITION BY ...) computes per-partition total',
        () async {
      final r = await db.execute('SELECT region, amount, '
          'SUM(amount) OVER (PARTITION BY region) AS total '
          'FROM sales ORDER BY region, amount');
      expect(r.rows, [
        ['east', 10, 60],
        ['east', 20, 60],
        ['east', 30, 60],
        ['west', 5, 20],
        ['west', 15, 20],
      ]);
    });

    test('SUM(...) OVER (ORDER BY ...) is a running total', () async {
      final r = await db.execute('SELECT amount, '
          'SUM(amount) OVER (ORDER BY amount) AS running '
          'FROM sales ORDER BY amount');
      expect(r.rows, [
        [5, 5],
        [10, 15],
        [15, 30],
        [20, 50],
        [30, 80],
      ]);
    });

    test('LAG / LEAD with default offset 1', () async {
      final r = await db.execute('SELECT amount, '
          'LAG(amount) OVER (ORDER BY amount) AS prev, '
          'LEAD(amount) OVER (ORDER BY amount) AS next '
          'FROM sales ORDER BY amount');
      expect(r.rows, [
        [5, null, 10],
        [10, 5, 15],
        [15, 10, 20],
        [20, 15, 30],
        [30, 20, null],
      ]);
    });
  });
}
