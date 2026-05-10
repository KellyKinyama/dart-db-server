import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open();
    await db.execute('CREATE TABLE s(dept TEXT, name TEXT, sal INTEGER)');
    final rows = [
      ['eng', 'a', 100],
      ['eng', 'b', 200],
      ['eng', 'c', 200],
      ['eng', 'd', 300],
      ['sales', 'e', 150],
      ['sales', 'f', 250],
    ];
    for (final r in rows) {
      await db.execute("INSERT INTO s VALUES ('${r[0]}','${r[1]}',${r[2]})");
    }
  });

  group('A3 window extras', () {
    test('NTILE buckets', () async {
      final r = await db
          .execute('SELECT name, NTILE(2) OVER (ORDER BY sal) AS b FROM s');
      final m = {for (final row in r.rows) row[0]: row[1]};
      expect(m['a'], 1);
      expect(m['e'], 1);
      expect(m['b'], 1);
      expect(m['f'], 2);
      expect(m['c'], 2);
      expect(m['d'], 2);
    });

    test('FIRST_VALUE / LAST_VALUE / NTH_VALUE', () async {
      final r = await db.execute('SELECT name, FIRST_VALUE(name) OVER w AS f, '
          'NTH_VALUE(name, 2) OVER w AS n2 '
          'FROM s WINDOW w AS (PARTITION BY dept ORDER BY sal '
          'ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)');
      final m = {
        for (final row in r.rows) row[0]: [row[1], row[2]]
      };
      expect(m['a']![0], 'a');
      expect(m['a']![1], 'b');
      expect(m['e']![0], 'e');
      expect(m['e']![1], 'f');
    });

    test('PERCENT_RANK and CUME_DIST', () async {
      final r = await db
          .execute('SELECT name, PERCENT_RANK() OVER (ORDER BY sal) AS p, '
              'CUME_DIST() OVER (ORDER BY sal) AS c FROM s');
      // Just sanity-check type / non-empty.
      expect(r.rows.length, 6);
      for (final row in r.rows) {
        expect(row[1], isA<num>());
        expect(row[2], isA<num>());
      }
    });

    test('FILTER (WHERE) on aggregate', () async {
      final r = await db.execute(
          'SELECT dept, COUNT(*) FILTER (WHERE sal > 150) FROM s GROUP BY dept');
      final m = {for (final row in r.rows) row[0]: row[1]};
      expect(m['eng'], 3);
      expect(m['sales'], 1);
    });

    test('ROWS BETWEEN n PRECEDING AND CURRENT ROW running sum', () async {
      final r = await db.execute('SELECT name, SUM(sal) OVER (ORDER BY name '
          'ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM s');
      final m = {for (final row in r.rows) row[0]: row[1]};
      expect(m['a'], 100);
      expect(m['b'], 300);
      expect(m['c'], 400);
      expect(m['d'], 500);
    });

    test('Named WINDOW w AS (...)', () async {
      final r = await db.execute('SELECT name, ROW_NUMBER() OVER w FROM s '
          'WINDOW w AS (PARTITION BY dept ORDER BY sal)');
      expect(r.rows.length, 6);
    });
  });
}
