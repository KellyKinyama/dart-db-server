// Tests for MySQL `INSERT ... ON DUPLICATE KEY UPDATE` (desugars to
// SQLite-style `ON CONFLICT DO UPDATE` with `excluded.col` references).
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('INSERT ... ON DUPLICATE KEY UPDATE', () {
    late Database db;

    setUp(() async {
      db = await Database.open(null);
      await db.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, hits INTEGER)',
      );
      await db.execute("INSERT INTO t VALUES (1, 'alice', 1)");
    });

    test('inserts a new row when no key conflict', () async {
      await db.execute(
        "INSERT INTO t VALUES (2, 'bob', 5) ON DUPLICATE KEY UPDATE hits = hits + 1",
      );
      final r = await db.execute('SELECT id, name, hits FROM t ORDER BY id');
      expect(r.rows, [
        [1, 'alice', 1],
        [2, 'bob', 5],
      ]);
    });

    test('updates the existing row on PK collision', () async {
      await db.execute(
        "INSERT INTO t VALUES (1, 'alice', 99) ON DUPLICATE KEY UPDATE hits = hits + 1",
      );
      final r = await db.execute('SELECT id, name, hits FROM t WHERE id = 1');
      expect(r.rows.single, [1, 'alice', 2]);
    });

    test('VALUES(col) references the would-be-inserted row', () async {
      await db.execute(
        "INSERT INTO t VALUES (1, 'ALICE', 7) ON DUPLICATE KEY UPDATE name = VALUES(name), hits = hits + VALUES(hits)",
      );
      final r = await db.execute('SELECT id, name, hits FROM t WHERE id = 1');
      expect(r.rows.single, [1, 'ALICE', 8]);
    });

    test('multiple assignments', () async {
      await db.execute(
        "INSERT INTO t VALUES (1, 'a2', 10) ON DUPLICATE KEY UPDATE name = VALUES(name), hits = VALUES(hits)",
      );
      final r = await db.execute('SELECT id, name, hits FROM t WHERE id = 1');
      expect(r.rows.single, [1, 'a2', 10]);
    });
  });
}
