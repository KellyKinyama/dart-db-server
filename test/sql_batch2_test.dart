import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('WITH RECURSIVE', () {
    test('counts 1..5 with UNION ALL', () async {
      final r = await db.execute('WITH RECURSIVE cnt(x) AS ('
          '  SELECT 1 '
          '  UNION ALL '
          '  SELECT x + 1 FROM cnt WHERE x < 5'
          ') SELECT x FROM cnt');
      expect(r.rows.map((e) => e[0]).toList(), [1, 2, 3, 4, 5]);
    });

    test('UNION dedupes recursive results', () async {
      final r = await db.execute('WITH RECURSIVE step(x) AS ('
          '  SELECT 1 '
          '  UNION '
          '  SELECT (x + 1) FROM step WHERE x < 3'
          ') SELECT x FROM step ORDER BY x');
      expect(r.rows.map((e) => e[0]).toList(), [1, 2, 3]);
    });

    test('graph traversal: descendants of a node', () async {
      await db.execute('CREATE TABLE edges(parent INTEGER, child INTEGER)');
      await db
          .execute('INSERT INTO edges VALUES (1,2),(1,3),(2,4),(3,5),(5,6)');
      final r = await db.execute('WITH RECURSIVE descs(n) AS ('
          '  SELECT child FROM edges WHERE parent = 1 '
          '  UNION '
          '  SELECT e.child FROM edges e INNER JOIN descs d ON e.parent = d.n'
          ') SELECT n FROM descs ORDER BY n');
      expect(r.rows.map((e) => e[0]).toList(), [2, 3, 4, 5, 6]);
    });
  });
}
