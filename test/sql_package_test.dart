/// Tests Phase 3d packages: Oracle `CREATE PACKAGE` / `PACKAGE BODY` and
/// qualified `pkg.func(args)` / `CALL pkg.proc(args)`.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
    await db.execute('INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)');
    await db.execute('CREATE TABLE log (msg TEXT)');
    await db.execute('''
      CREATE OR REPLACE PACKAGE math_pkg IS
        FUNCTION square(x NUMBER) RETURN NUMBER;
        FUNCTION add_one(x NUMBER) RETURN NUMBER;
        PROCEDURE log_it(msg VARCHAR2);
      END math_pkg;
    ''');
    await db.execute('''
      CREATE OR REPLACE PACKAGE BODY math_pkg IS
        FUNCTION square(x NUMBER) RETURN NUMBER IS
        BEGIN
          RETURN x * x;
        END square;

        FUNCTION add_one(x NUMBER) RETURN NUMBER IS
          r NUMBER;
        BEGIN
          r := x + 1;
          RETURN r;
        END add_one;

        PROCEDURE log_it(msg VARCHAR2) IS
        BEGIN
          INSERT INTO log VALUES (msg);
        END log_it;
      END math_pkg;
    ''');
  });

  Future<Object?> scalar(String sql) async =>
      (await db.execute(sql)).rows.first.first;

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.toList()).toList();

  test('package function in a scalar SELECT', () async {
    expect(await scalar('SELECT math_pkg.square(7)'), 49);
  });

  test('package functions per row, including nested calls', () async {
    expect(
      await rows(
        'SELECT id, math_pkg.square(n), '
        'math_pkg.add_one(math_pkg.square(n)) FROM t ORDER BY id',
      ),
      [
        [1, 100, 101],
        [2, 400, 401],
        [3, 900, 901],
      ],
    );
  });

  test('package function in WHERE', () async {
    expect(
      await rows('SELECT id FROM t WHERE math_pkg.square(n) > 150 ORDER BY id'),
      [
        [2],
        [3],
      ],
    );
  });

  test('CALL a package procedure', () async {
    await db.execute("CALL math_pkg.log_it('hello')");
    expect(await rows('SELECT msg FROM log'), [
      ['hello'],
    ]);
  });

  test('DROP PACKAGE removes all members', () async {
    await db.execute('DROP PACKAGE math_pkg');
    expect(
      () => db.execute('SELECT math_pkg.square(2)'),
      throwsA(isA<StateError>()),
    );
  });

  test('DROP PACKAGE IF EXISTS on a missing package is a no-op', () async {
    await db.execute('DROP PACKAGE IF EXISTS no_such_pkg');
  });

  test('CREATE OR REPLACE PACKAGE BODY replaces members', () async {
    await db.execute('''
      CREATE OR REPLACE PACKAGE BODY math_pkg IS
        FUNCTION square(x NUMBER) RETURN NUMBER IS
        BEGIN
          RETURN x * x * x;
        END square;
      END math_pkg;
    ''');
    expect(await scalar('SELECT math_pkg.square(3)'), 27);
    // add_one was dropped by the replacement.
    expect(
      () => db.execute('SELECT math_pkg.add_one(1)'),
      throwsA(isA<StateError>()),
    );
  });
}
