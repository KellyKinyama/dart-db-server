import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('C planner upgrades', () {
    test('Indexed col=lit lookup returns correct rows', () async {
      await db.execute('CREATE TABLE t(id INTEGER, v TEXT)');
      await db.execute('CREATE INDEX ix ON t(id)');
      for (var i = 0; i < 100; i++) {
        await db.execute("INSERT INTO t VALUES ($i, 'r$i')");
      }
      final r = await db.execute('SELECT v FROM t WHERE id = 42');
      expect(r.rows.first.first, 'r42');
    });

    test('Indexed lookup ignored when no index on column', () async {
      await db.execute('CREATE TABLE t(id INTEGER, v TEXT)');
      await db.execute('CREATE INDEX ix_v ON t(v)');
      await db.execute("INSERT INTO t VALUES (1,'a'),(2,'b')");
      // No index on id — falls back to full scan, still correct.
      final r = await db.execute('SELECT v FROM t WHERE id = 2');
      expect(r.rows.first.first, 'b');
    });
  });
}
