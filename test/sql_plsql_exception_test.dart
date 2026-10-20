/// Tests PL/SQL EXCEPTION handlers: `RAISE`, `WHEN exc [OR exc] THEN`,
/// `WHEN OTHERS`, nested propagation, and re-raise.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO t VALUES (1)');
    await db.execute('CREATE TABLE log (msg TEXT)');
  });

  Future<List<Object?>> logRows() async =>
      (await db.execute('SELECT msg FROM log')).rows.map((r) => r.first).toList();

  test('named exception via RAISE is caught', () async {
    await db.execute('''
      BEGIN
        RAISE my_exc;
      EXCEPTION
        WHEN my_exc THEN INSERT INTO log VALUES ('caught');
      END;
    ''');
    expect(await logRows(), ['caught']);
  });

  test('WHEN OTHERS catches a runtime error', () async {
    await db.execute('''
      BEGIN
        INSERT INTO t VALUES (1);
      EXCEPTION
        WHEN OTHERS THEN INSERT INTO log VALUES ('others');
      END;
    ''');
    expect(await logRows(), ['others']);
  });

  test('unhandled exception propagates past an inner block', () async {
    await db.execute('''
      BEGIN
        BEGIN
          RAISE inner_exc;
        END;
      EXCEPTION
        WHEN OTHERS THEN INSERT INTO log VALUES ('outer');
      END;
    ''');
    expect(await logRows(), ['outer']);
  });

  test('WHEN ... OR ... matches either name', () async {
    await db.execute('''
      BEGIN
        RAISE second;
      EXCEPTION
        WHEN first THEN INSERT INTO log VALUES ('first');
        WHEN second OR third THEN INSERT INTO log VALUES ('second-or-third');
        WHEN OTHERS THEN INSERT INTO log VALUES ('others');
      END;
    ''');
    expect(await logRows(), ['second-or-third']);
  });

  test('bare RAISE re-raises and propagates to the caller', () async {
    expect(
      () => db.execute('''
        BEGIN
          RAISE boom;
        EXCEPTION
          WHEN boom THEN RAISE;
        END;
      '''),
      throwsA(anything),
    );
  });

  test('a procedure body can handle its own exception', () async {
    await db.execute('''
      CREATE PROCEDURE safe_insert IS
      BEGIN
        INSERT INTO t VALUES (1);
      EXCEPTION
        WHEN OTHERS THEN INSERT INTO log VALUES ('proc caught');
      END;
    ''');
    await db.execute('CALL safe_insert');
    expect(await logRows(), ['proc caught']);
  });
}
