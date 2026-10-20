/// Tests the PL/SQL cursor FOR loop: `FOR rec IN (<select>) LOOP … END LOOP`
/// with `rec.col` record access.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute(
        'CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, sal INTEGER)');
    await db.execute(
        "INSERT INTO emp VALUES (1,'A',100),(2,'B',200),(3,'C',300)");
    await db.execute('CREATE TABLE out (id INTEGER, label TEXT)');
  });

  Future<List<List<Object?>>> outRows() async =>
      (await db.execute('SELECT id, label FROM out ORDER BY id'))
          .rows
          .map((r) => r.toList())
          .toList();

  test('iterates rows exposing rec.col', () async {
    await db.execute('''
      BEGIN
        FOR rec IN (SELECT id, name, sal FROM emp ORDER BY id) LOOP
          INSERT INTO out VALUES (rec.id, rec.name || ':' || rec.sal);
        END LOOP;
      END;
    ''');
    expect(await outRows(), [
      [1, 'A:100'],
      [2, 'B:200'],
      [3, 'C:300'],
    ]);
  });

  test('EXIT WHEN breaks a cursor loop', () async {
    await db.execute('''
      BEGIN
        FOR rec IN (SELECT id FROM emp ORDER BY id) LOOP
          EXIT WHEN rec.id > 2;
          INSERT INTO out VALUES (rec.id, 'x');
        END LOOP;
      END;
    ''');
    expect((await outRows()).map((r) => r.first).toList(), [1, 2]);
  });

  test('cursor loop inside a procedure aggregates into an OUT param', () async {
    await db.execute('''
      CREATE PROCEDURE total_sal(OUT t INTEGER) IS
      BEGIN
        t := 0;
        FOR rec IN (SELECT sal FROM emp) LOOP
          t := t + rec.sal;
        END LOOP;
      END;
    ''');
    await db.execute('CALL total_sal(@tot)');
    expect((await db.execute('SELECT @tot')).rows.first.first, 600);
  });

  test('cursor loop body can filter with rec.col', () async {
    await db.execute('''
      BEGIN
        FOR rec IN (SELECT id, sal FROM emp ORDER BY id) LOOP
          IF rec.sal >= 200 THEN
            INSERT INTO out VALUES (rec.id, 'big');
          END IF;
        END LOOP;
      END;
    ''');
    expect((await outRows()).map((r) => r.first).toList(), [2, 3]);
  });
}
