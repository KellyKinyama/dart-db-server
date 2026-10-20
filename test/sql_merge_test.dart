/// Tests the Oracle `MERGE INTO ... USING ... ON ...` statement.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute(
      'CREATE TABLE target (id INTEGER PRIMARY KEY, name TEXT, v INTEGER)',
    );
    await db.execute("INSERT INTO target VALUES (1, 'a', 10)");
    await db.execute("INSERT INTO target VALUES (2, 'b', 20)");
    await db.execute(
      'CREATE TABLE src (id INTEGER PRIMARY KEY, name TEXT, v INTEGER)',
    );
    await db.execute("INSERT INTO src VALUES (2, 'B', 200)");
    await db.execute("INSERT INTO src VALUES (3, 'C', 300)");
  });

  Future<List<List<Object?>>> target() async =>
      (await db.execute('SELECT id, name, v FROM target ORDER BY id'))
          .rows
          .map((r) => r.toList())
          .toList();

  test('MERGE updates matched and inserts unmatched (subquery source)',
      () async {
    final r = await db.execute('''
      MERGE INTO target t USING (SELECT id, name, v FROM src) s ON (t.id = s.id)
      WHEN MATCHED THEN UPDATE SET name = s.name, v = s.v
      WHEN NOT MATCHED THEN INSERT (id, name, v) VALUES (s.id, s.name, s.v)
    ''');
    expect(r.affected, 2);
    expect(await target(), [
      [1, 'a', 10],
      [2, 'B', 200],
      [3, 'C', 300],
    ]);
  });

  test('MERGE with a table source and alias', () async {
    final r = await db.execute('''
      MERGE INTO target t USING src s ON (t.id = s.id)
      WHEN MATCHED THEN UPDATE SET v = s.v
      WHEN NOT MATCHED THEN INSERT (id, name, v) VALUES (s.id, s.name, s.v)
    ''');
    expect(r.affected, 2);
    expect(await target(), [
      [1, 'a', 10],
      [2, 'b', 200],
      [3, 'C', 300],
    ]);
  });

  test('matched-only MERGE leaves unmatched source rows alone', () async {
    final r = await db.execute('''
      MERGE INTO target t USING src s ON (t.id = s.id)
      WHEN MATCHED THEN UPDATE SET v = s.v
    ''');
    expect(r.affected, 1);
    expect(await target(), [
      [1, 'a', 10],
      [2, 'b', 200],
    ]);
  });

  test('not-matched-only MERGE only inserts', () async {
    final r = await db.execute('''
      MERGE INTO target t USING src s ON (t.id = s.id)
      WHEN NOT MATCHED THEN INSERT (id, name, v) VALUES (s.id, s.name, s.v)
    ''');
    expect(r.affected, 1);
    expect(await target(), [
      [1, 'a', 10],
      [2, 'b', 20],
      [3, 'C', 300],
    ]);
  });

  test('WHEN MATCHED ... WHERE filters which matched rows update', () async {
    await db.execute("UPDATE src SET v = 999 WHERE id = 2");
    final r = await db.execute('''
      MERGE INTO target t USING src s ON (t.id = s.id)
      WHEN MATCHED THEN UPDATE SET v = s.v WHERE s.v < 500
    ''');
    // The only matched row (id=2) has s.v = 999, filtered out.
    expect(r.affected, 0);
    expect((await target())[1], [2, 'b', 20]);
  });

  test('computed expressions in SET and INSERT', () async {
    final r = await db.execute('''
      MERGE INTO target t USING src s ON (t.id = s.id)
      WHEN MATCHED THEN UPDATE SET v = t.v + s.v
      WHEN NOT MATCHED THEN INSERT (id, name, v) VALUES (s.id, s.name, s.v * 2)
    ''');
    expect(r.affected, 2);
    expect(await target(), [
      [1, 'a', 10],
      [2, 'b', 220], // 20 + 200
      [3, 'C', 600], // 300 * 2
    ]);
  });

  test('inserted rows do not match later source rows', () async {
    // Two source rows map to the same new id; only one insert should land
    // (the second would violate the PK if it also inserted).
    await db.execute('DELETE FROM src');
    await db.execute("INSERT INTO src VALUES (9, 'x', 1)");
    final r = await db.execute('''
      MERGE INTO target t USING src s ON (t.id = s.id)
      WHEN NOT MATCHED THEN INSERT (id, name, v) VALUES (s.id, s.name, s.v)
    ''');
    expect(r.affected, 1);
    expect((await target()).last, [9, 'x', 1]);
  });
}
