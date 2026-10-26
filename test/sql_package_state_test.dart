/// Tests persistent Oracle package state: body-level package variables that
/// survive across member calls.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute('''
      CREATE PACKAGE counter_pkg IS
        PROCEDURE reset;
        FUNCTION next_val RETURN NUMBER;
      END;
    ''');
    await db.execute('''
      CREATE PACKAGE BODY counter_pkg IS
        g_count NUMBER := 0;
        g_step  NUMBER := 10;
        PROCEDURE reset IS
        BEGIN
          g_count := 0;
        END;
        FUNCTION next_val RETURN NUMBER IS
        BEGIN
          g_count := g_count + g_step;
          RETURN g_count;
        END;
      END;
    ''');
  });

  Future<Object?> scalar(String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('package state persists across function calls', () async {
    expect(await scalar('SELECT counter_pkg.next_val()'), 10);
    expect(await scalar('SELECT counter_pkg.next_val()'), 20);
    expect(await scalar('SELECT counter_pkg.next_val()'), 30);
  });

  test('a package procedure mutates state seen by a function', () async {
    await scalar('SELECT counter_pkg.next_val()'); // 10
    await scalar('SELECT counter_pkg.next_val()'); // 20
    await db.execute('CALL counter_pkg.reset');
    expect(await scalar('SELECT counter_pkg.next_val()'), 10);
  });

  test('CREATE OR REPLACE BODY re-seeds package state', () async {
    await scalar('SELECT counter_pkg.next_val()'); // 10
    await db.execute('''
      CREATE OR REPLACE PACKAGE BODY counter_pkg IS
        g_count NUMBER := 100;
        PROCEDURE reset IS BEGIN g_count := 0; END;
        FUNCTION next_val RETURN NUMBER IS
        BEGIN g_count := g_count + 1; RETURN g_count; END;
      END;
    ''');
    expect(await scalar('SELECT counter_pkg.next_val()'), 101);
  });

  test('DROP PACKAGE clears package state', () async {
    await scalar('SELECT counter_pkg.next_val()');
    await db.execute('DROP PACKAGE counter_pkg');
    expect(
      () => db.execute('SELECT counter_pkg.next_val()'),
      throwsA(isA<StateError>()),
    );
  });
}
