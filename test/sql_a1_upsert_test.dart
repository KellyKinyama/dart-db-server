import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
    await db.execute(
        'CREATE TABLE kv(k TEXT PRIMARY KEY, v INTEGER, hits INTEGER DEFAULT 0)');
    await db.execute("INSERT INTO kv (k, v) VALUES ('a', 1), ('b', 2)");
  });

  group('UPSERT (ON CONFLICT)', () {
    test('DO NOTHING swallows conflict', () async {
      await db.execute(
          "INSERT INTO kv (k, v) VALUES ('a', 99) ON CONFLICT (k) DO NOTHING");
      final r = await db.execute("SELECT v FROM kv WHERE k = 'a'");
      expect(r.rows, [
        [1],
      ]);
    });

    test('DO UPDATE SET col = excluded.col overwrites on conflict', () async {
      await db.execute("INSERT INTO kv (k, v) VALUES ('a', 99) "
          "ON CONFLICT (k) DO UPDATE SET v = excluded.v");
      final r = await db.execute("SELECT v FROM kv WHERE k = 'a'");
      expect(r.rows, [
        [99],
      ]);
    });

    test('DO UPDATE references existing row column too', () async {
      await db.execute("INSERT INTO kv (k, v) VALUES ('a', 5) "
          "ON CONFLICT (k) DO UPDATE SET v = v + excluded.v, hits = hits + 1");
      final r = await db.execute("SELECT v, hits FROM kv WHERE k = 'a'");
      expect(r.rows, [
        [6, 1],
      ]);
    });

    test('DO UPDATE WHERE filter skips non-matching conflicts', () async {
      await db.execute("INSERT INTO kv (k, v) VALUES ('a', 99) "
          "ON CONFLICT (k) DO UPDATE SET v = excluded.v WHERE v > 100");
      final r = await db.execute("SELECT v FROM kv WHERE k = 'a'");
      // existing v=1, predicate "v > 100" false => no change
      expect(r.rows, [
        [1],
      ]);
    });

    test('UPSERT inserts when no conflict', () async {
      await db.execute("INSERT INTO kv (k, v) VALUES ('c', 3) "
          "ON CONFLICT (k) DO UPDATE SET v = excluded.v");
      final r = await db.execute("SELECT k, v FROM kv ORDER BY k");
      expect(r.rows, [
        ['a', 1],
        ['b', 2],
        ['c', 3],
      ]);
    });

    test('ON CONFLICT without column list catches any unique conflict',
        () async {
      await db.execute(
          "INSERT INTO kv (k, v) VALUES ('a', 42) ON CONFLICT DO NOTHING");
      final r = await db.execute("SELECT v FROM kv WHERE k = 'a'");
      expect(r.rows, [
        [1],
      ]);
    });
  });
}
