/// Tests Phase 3d: stored FUNCTIONs invoked inside SQL expressions
/// (projection, WHERE, nested calls) across MySQL and Oracle dialects.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
    await db.execute('INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)');
  });

  Future<Object?> scalar(String sql) async =>
      (await db.execute(sql)).rows.first.first;

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.toList()).toList();

  test('MySQL function in a scalar SELECT', () async {
    await db.execute('''
      CREATE FUNCTION dbl(x INT) RETURNS INT
      BEGIN
        RETURN x * 2;
      END
    ''');
    expect(await scalar('SELECT dbl(21)'), 42);
  });

  test('function evaluated per row in projection', () async {
    await db.execute('''
      CREATE FUNCTION dbl(x INT) RETURNS INT
      BEGIN
        RETURN x * 2;
      END
    ''');
    expect(await rows('SELECT id, dbl(n) FROM t ORDER BY id'), [
      [1, 20],
      [2, 40],
      [3, 60],
    ]);
  });

  test('function in WHERE clause', () async {
    await db.execute('''
      CREATE FUNCTION dbl(x INT) RETURNS INT
      BEGIN
        RETURN x * 2;
      END
    ''');
    expect(await rows('SELECT id FROM t WHERE dbl(n) > 40 ORDER BY id'), [
      [3],
    ]);
  });

  test('nested function calls', () async {
    await db.execute('''
      CREATE FUNCTION dbl(x INT) RETURNS INT
      BEGIN
        RETURN x * 2;
      END
    ''');
    expect(await scalar('SELECT dbl(dbl(5))'), 20);
  });

  test('Oracle function with IF/ELSIF control flow', () async {
    await db.execute('''
      CREATE FUNCTION classify(x IN NUMBER) RETURN VARCHAR2 IS
        r VARCHAR2(10);
      BEGIN
        IF x < 15 THEN
          r := 'low';
        ELSIF x < 25 THEN
          r := 'mid';
        ELSE
          r := 'high';
        END IF;
        RETURN r;
      END;
    ''');
    expect(await rows('SELECT n, classify(n) FROM t ORDER BY id'), [
      [10, 'low'],
      [20, 'mid'],
      [30, 'high'],
    ]);
  });

  test('function that queries the database via SELECT INTO', () async {
    await db.execute('''
      CREATE FUNCTION row_count() RETURNS INT
      BEGIN
        DECLARE c INT;
        SELECT COUNT(*) INTO c FROM t;
        RETURN c;
      END
    ''');
    expect(await scalar('SELECT row_count()'), 3);
    await db.execute('INSERT INTO t VALUES (4, 40)');
    expect(await scalar('SELECT row_count()'), 4);
  });

  test('unknown function still raises an error', () async {
    expect(
      () => db.execute('SELECT nope(1)'),
      throwsA(isA<StateError>()),
    );
  });
}
