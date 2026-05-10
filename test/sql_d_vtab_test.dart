import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('D virtual tables', () {
    test('CREATE VIRTUAL TABLE ... USING fts5 + MATCH', () async {
      await db.execute("CREATE VIRTUAL TABLE docs USING fts5(title, body)");
      await db.execute("INSERT INTO docs(title, body) VALUES "
          "('hello world', 'a tale of greetings'),"
          "('SQL primer', 'select join group window'),"
          "('window guide', 'rank dense_rank lead lag')");
      final r =
          await db.execute("SELECT title FROM docs WHERE body MATCH 'window'");
      expect(r.rows.map((e) => e[0]).toSet(), {'SQL primer'});
    });

    test('MATCH supports multi-term AND', () async {
      await db.execute("CREATE VIRTUAL TABLE docs USING fts5(body)");
      await db.execute(
          "INSERT INTO docs VALUES ('alpha bravo charlie'),('delta echo')");
      final r = await db
          .execute("SELECT body FROM docs WHERE body MATCH 'alpha charlie'");
      expect(r.rows.length, 1);
    });

    test('CREATE VIRTUAL TABLE ... USING rtree behaves like a normal table',
        () async {
      await db.execute(
          "CREATE VIRTUAL TABLE places USING rtree(id, minx, maxx, miny, maxy)");
      await db.execute("INSERT INTO places VALUES (1, 0, 1, 0, 1)");
      await db.execute("INSERT INTO places VALUES (2, 5, 6, 5, 6)");
      final r = await db
          .execute("SELECT id FROM places WHERE minx >= 4 AND maxy <= 7");
      expect(r.rows.first.first, 2);
    });
  });
}
