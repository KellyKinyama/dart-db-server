/// Tests the SQL-standard `EXTRACT(field FROM source)` datetime accessor.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE ev (id INTEGER PRIMARY KEY, ts TEXT)');
    await db.execute("INSERT INTO ev VALUES (1, '2024-03-15 09:42:07')");
  });

  Future<Object?> one(String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('EXTRACT from a string-valued datetime', () async {
    expect(await one("SELECT EXTRACT(YEAR FROM '2024-03-15 09:42:07') "
        'FROM DUAL'), 2024);
    expect(await one("SELECT EXTRACT(MONTH FROM '2024-03-15 09:42:07') "
        'FROM DUAL'), 3);
    expect(await one("SELECT EXTRACT(DAY FROM '2024-03-15 09:42:07') "
        'FROM DUAL'), 15);
  });

  test('EXTRACT time fields from a column', () async {
    expect(await one('SELECT EXTRACT(HOUR FROM ts) FROM ev'), 9);
    expect(await one('SELECT EXTRACT(MINUTE FROM ts) FROM ev'), 42);
    expect(await one('SELECT EXTRACT(SECOND FROM ts) FROM ev'), 7);
  });

  test('EXTRACT field keyword is case-insensitive', () async {
    expect(await one('SELECT EXTRACT(year FROM ts) FROM ev'), 2024);
  });

  test('EXTRACT of NULL is NULL', () async {
    expect(await one('SELECT EXTRACT(YEAR FROM NULL) FROM DUAL'), isNull);
  });

  test('EXTRACT in WHERE / projection over rows', () async {
    await db.execute("INSERT INTO ev VALUES (2, '2023-11-01 00:00:00')");
    final r = await db
        .execute('SELECT id FROM ev WHERE EXTRACT(YEAR FROM ts) = 2024');
    expect(r.rows.map((x) => x.first).toList(), [1]);
  });
}
