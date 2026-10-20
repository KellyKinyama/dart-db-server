/// Tests Oracle PL/SQL (Phase 3c): anonymous blocks and CREATE PROCEDURE/
/// FUNCTION over the shared procedural core.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
  });

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.toList()).toList();

  test('anonymous block: DECLARE, FOR range, IF, assignment, INSERT', () async {
    await db.execute('''
      DECLARE
        total NUMBER := 0;
      BEGIN
        FOR i IN 1..5 LOOP
          IF MOD(i, 2) = 0 THEN
            INSERT INTO t VALUES (i, i * 100);
          END IF;
          total := total + i;
        END LOOP;
        INSERT INTO t VALUES (99, total);
      END;
    ''');
    expect(await rows('SELECT id, v FROM t ORDER BY id'), [
      [2, 200],
      [4, 400],
      [99, 15],
    ]);
  });

  test('REVERSE FOR loop', () async {
    await db.execute('CREATE TABLE c (n INTEGER PRIMARY KEY)');
    await db.execute('''
      BEGIN
        FOR k IN REVERSE 1..3 LOOP
          INSERT INTO c VALUES (k);
        END LOOP;
      END;
    ''');
    expect((await rows('SELECT n FROM c ORDER BY n')).map((r) => r.first),
        [1, 2, 3]);
  });

  test('WHILE LOOP and EXIT WHEN', () async {
    await db.execute('''
      DECLARE
        k NUMBER := 1;
      BEGIN
        LOOP
          EXIT WHEN k > 3;
          INSERT INTO t VALUES (k, k);
          k := k + 1;
        END LOOP;
      END;
    ''');
    expect((await rows('SELECT id FROM t ORDER BY id')).map((r) => r.first),
        [1, 2, 3]);
  });

  test('IF / ELSIF / ELSE', () async {
    await db.execute('''
      DECLARE
        x NUMBER := 5;
        label VARCHAR2(10);
      BEGIN
        IF x < 0 THEN
          label := 'neg';
        ELSIF x = 0 THEN
          label := 'zero';
        ELSE
          label := 'pos';
        END IF;
        INSERT INTO t VALUES (1, 0);
        UPDATE t SET v = LENGTH(label) WHERE id = 1;
      END;
    ''');
    expect((await db.execute('SELECT v FROM t WHERE id = 1')).rows.first.first,
        3); // 'pos'
  });

  test('SELECT INTO drives logic', () async {
    await db.execute('INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)');
    await db.execute('''
      DECLARE
        total NUMBER;
      BEGIN
        SELECT SUM(v) INTO total FROM t;
        INSERT INTO t VALUES (99, total);
      END;
    ''');
    expect((await db.execute('SELECT v FROM t WHERE id = 99')).rows.first.first,
        60);
  });

  test('CREATE OR REPLACE PROCEDURE and call via a block', () async {
    await db.execute('''
      CREATE OR REPLACE PROCEDURE seed(p_start IN NUMBER, p_count IN NUMBER) IS
        i NUMBER := 0;
      BEGIN
        WHILE i < p_count LOOP
          INSERT INTO t VALUES (p_start + i, 0);
          i := i + 1;
        END LOOP;
      END;
    ''');
    await db.execute('BEGIN seed(200, 3); END;');
    expect(
      (await rows('SELECT id FROM t WHERE id >= 200 ORDER BY id'))
          .map((r) => r.first),
      [200, 201, 202],
    );
  });

  test('DBMS_OUTPUT.PUT_LINE does not error', () async {
    await db.execute('''
      BEGIN
        DBMS_OUTPUT.PUT_LINE('hello ' || (1 + 1));
      END;
    ''');
    // No output surfaced to the caller yet, but the block must run cleanly.
  });

  test('a PL/SQL procedure is also callable via CALL', () async {
    await db.execute('''
      CREATE PROCEDURE one_row IS
      BEGIN
        INSERT INTO t VALUES (7, 70);
      END;
    ''');
    await db.execute('CALL one_row()');
    expect((await db.execute('SELECT v FROM t WHERE id = 7')).rows.first.first,
        70);
  });

  test('transaction BEGIN is not mistaken for a PL/SQL block', () async {
    await db.execute('CREATE TABLE c (n INTEGER PRIMARY KEY)');
    await db.execute('BEGIN');
    await db.execute('INSERT INTO c VALUES (1)');
    await db.execute('ROLLBACK');
    expect((await db.execute('SELECT COUNT(*) FROM c')).rows.first.first, 0);
  });
}
