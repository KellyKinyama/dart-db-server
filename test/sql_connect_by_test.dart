/// Tests the Oracle `CONNECT BY` hierarchical query clause.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute(
      'CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, mgr INTEGER)',
    );
    await db.execute("INSERT INTO emp VALUES (1, 'king', NULL)");
    await db.execute("INSERT INTO emp VALUES (2, 'bob', 1)");
    await db.execute("INSERT INTO emp VALUES (3, 'amy', 1)");
    await db.execute("INSERT INTO emp VALUES (4, 'carl', 2)");
    await db.execute("INSERT INTO emp VALUES (5, 'dan', 2)");
  });

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.toList()).toList();

  test('depth-first traversal with LEVEL', () async {
    expect(
      await rows('SELECT LEVEL, name FROM emp '
          'START WITH mgr IS NULL CONNECT BY PRIOR id = mgr'),
      [
        [1, 'king'],
        [2, 'bob'],
        [3, 'carl'],
        [3, 'dan'],
        [2, 'amy'],
      ],
    );
  });

  test('CONNECT_BY_ISLEAF flags leaf rows', () async {
    expect(
      await rows('SELECT name, CONNECT_BY_ISLEAF FROM emp '
          'START WITH mgr IS NULL CONNECT BY PRIOR id = mgr'),
      [
        ['king', 0],
        ['bob', 0],
        ['carl', 1],
        ['dan', 1],
        ['amy', 1],
      ],
    );
  });

  test('START WITH chooses a non-root anchor', () async {
    expect(
      await rows('SELECT LEVEL, name FROM emp '
          'START WITH id = 2 CONNECT BY PRIOR id = mgr'),
      [
        [1, 'bob'],
        [2, 'carl'],
        [2, 'dan'],
      ],
    );
  });

  test('ORDER SIBLINGS BY orders within each parent', () async {
    expect(
      await rows('SELECT name FROM emp START WITH mgr IS NULL '
          'CONNECT BY PRIOR id = mgr ORDER SIBLINGS BY name'),
      [
        ['king'],
        ['amy'],
        ['bob'],
        ['carl'],
        ['dan'],
      ],
    );
  });

  test('WHERE filters after the hierarchy is built', () async {
    expect(
      await rows('SELECT LEVEL, name FROM emp WHERE LEVEL <= 2 '
          'START WITH mgr IS NULL CONNECT BY PRIOR id = mgr'),
      [
        [1, 'king'],
        [2, 'bob'],
        [2, 'amy'],
      ],
    );
  });

  test('no START WITH treats every row as a root', () async {
    // Each row seeds its own subtree; the total row count is the sum of
    // every node's subtree size.
    final r =
        await rows('SELECT name FROM emp CONNECT BY PRIOR id = mgr');
    expect(r.length, greaterThan(5));
  });

  test('a self-referential cycle does not loop forever', () async {
    await db.execute('CREATE TABLE c (id INTEGER PRIMARY KEY, p INTEGER)');
    await db.execute('INSERT INTO c VALUES (1, 2)');
    await db.execute('INSERT INTO c VALUES (2, 1)');
    final r = await rows(
      'SELECT id FROM c START WITH id = 1 CONNECT BY PRIOR id = p',
    );
    // 1 -> 2 -> (back to 1, pruned by cycle guard).
    expect(r.map((x) => x.first).toList(), [1, 2]);
  });
}
