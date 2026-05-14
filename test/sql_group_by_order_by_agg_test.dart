/// Phase-3.6 regression: GROUP BY fast-path now satisfies ORDER BY
/// MIN/MAX/AVG of the group col via the index walk (each equals key
/// within a group).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Database> seed() async {
    final db = await Database.open();
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await db.execute('CREATE INDEX i_v ON t(v)');
    var id = 1;
    for (final v in [1, 2, 2, 3, 3, 3, 4, 5, 5]) {
      await db.execute('INSERT INTO t VALUES (${id++}, $v)');
    }
    return db;
  }

  test('ORDER BY MIN(v) ASC matches ORDER BY v', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY MIN(v)');
      expect(r.rows, [
        [1, 1],
        [2, 2],
        [3, 3],
        [4, 1],
        [5, 2],
      ]);
    } finally {
      await db.close();
    }
  });

  test('ORDER BY MAX(v) DESC matches ORDER BY v DESC', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t GROUP BY v ORDER BY MAX(v) DESC');
      expect(r.rows, [
        [5, 2],
        [4, 1],
        [3, 3],
        [2, 2],
        [1, 1],
      ]);
    } finally {
      await db.close();
    }
  });

  test('ORDER BY AVG(v) ASC', () async {
    final db = await seed();
    try {
      final r = await db
          .execute('SELECT v, AVG(v) FROM t GROUP BY v ORDER BY AVG(v)');
      expect(r.rows.length, 5);
      expect(r.rows.first[0], 1);
      expect(r.rows.last[0], 5);
    } finally {
      await db.close();
    }
  });

  test('WHERE + GROUP BY + ORDER BY MAX(v)', () async {
    final db = await seed();
    try {
      final r = await db.execute(
          'SELECT v, COUNT(*) FROM t WHERE v BETWEEN 2 AND 5 GROUP BY v '
          'ORDER BY MAX(v) DESC');
      expect(r.rows, [
        [5, 2],
        [4, 1],
        [3, 3],
        [2, 2],
      ]);
    } finally {
      await db.close();
    }
  });
}
