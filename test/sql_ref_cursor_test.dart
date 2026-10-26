/// Tests Phase 3d ref cursors: Oracle `SYS_REFCURSOR`, `OPEN cur FOR <select>`,
/// and surfacing the opened cursor from an `OUT` parameter or function RETURN.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute(
        'CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept TEXT)');
    await db.execute(
        "INSERT INTO emp VALUES (1,'Alice','eng'), (2,'Bob','sales'), "
        "(3,'Carol','eng')");
  });

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.toList()).toList();

  test('procedure with an OUT SYS_REFCURSOR surfaces the result set', () async {
    await db.execute('''
      CREATE PROCEDURE all_emps(OUT rc SYS_REFCURSOR) IS
      BEGIN
        OPEN rc FOR SELECT id, name FROM emp ORDER BY id;
      END;
    ''');
    final r = await db.execute('CALL all_emps(@rc)');
    expect(r.columns, ['id', 'name']);
    expect(r.rows.map((x) => x.toList()).toList(), [
      [1, 'Alice'],
      [2, 'Bob'],
      [3, 'Carol'],
    ]);
  });

  test('function returning SYS_REFCURSOR surfaces the result set', () async {
    await db.execute('''
      CREATE FUNCTION emps_in(d VARCHAR2) RETURN SYS_REFCURSOR IS
        c SYS_REFCURSOR;
      BEGIN
        OPEN c FOR SELECT name FROM emp WHERE dept = d ORDER BY id;
        RETURN c;
      END;
    ''');
    final r = await db.execute("CALL emps_in('eng')");
    expect(r.rows.map((x) => x.first).toList(), ['Alice', 'Carol']);
  });

  test('cursor query binds a routine parameter', () async {
    await db.execute('''
      CREATE PROCEDURE emps_by_dept(d VARCHAR2, OUT rc SYS_REFCURSOR) IS
      BEGIN
        OPEN rc FOR SELECT id, name FROM emp WHERE dept = d ORDER BY id;
      END;
    ''');
    expect(await rows("CALL emps_by_dept('sales', @rc)"), [
      [2, 'Bob'],
    ]);
  });

  test('anonymous block can RETURN a cursor', () async {
    final r = await db.execute('''
      DECLARE c SYS_REFCURSOR;
      BEGIN
        OPEN c FOR SELECT COUNT(*) AS n FROM emp;
        RETURN c;
      END;
    ''');
    expect(r.rows.first.first, 3);
  });
}
