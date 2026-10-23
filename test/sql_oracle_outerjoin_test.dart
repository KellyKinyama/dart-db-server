/// Tests comma joins (`FROM a, b`) and the Oracle legacy `(+)` outer-join
/// operator, plus the RIGHT/FULL-join NULL-side fix they exercise.
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
  });

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.toList()).toList();

  // F60: a self LEFT JOIN must keep the left instance's own columns for an
  // unmatched row (the right null-pad used to clobber them via the shared base
  // table name).
  test('self LEFT JOIN keeps the left row own column when unmatched', () async {
    expect(
      await rows('SELECT e.id FROM emp e LEFT JOIN emp m ON e.mgr = m.id '
          'ORDER BY e.id'),
      [
        [1], // king: mgr NULL, unmatched — e.id must stay 1
        [2],
        [3],
      ],
    );
    expect(
      await rows('SELECT e.name, m.name FROM emp e LEFT JOIN emp m '
          'ON e.mgr = m.id ORDER BY e.id'),
      [
        ['king', null],
        ['bob', 'king'],
        ['amy', 'king'],
      ],
    );
  });

  test('comma join behaves as an inner join filtered by WHERE', () async {
    expect(
      await rows('SELECT e.name, m.name FROM emp e, emp m '
          'WHERE e.mgr = m.id ORDER BY e.id'),
      [
        ['bob', 'king'],
        ['amy', 'king'],
      ],
    );
  });

  test('(+) on the right operand is a LEFT outer join', () async {
    expect(
      await rows('SELECT e.name, m.name FROM emp e, emp m '
          'WHERE e.mgr = m.id(+) ORDER BY e.id'),
      [
        ['king', null],
        ['bob', 'king'],
        ['amy', 'king'],
      ],
    );
  });

  test('(+) on the left operand is a RIGHT outer join', () async {
    expect(
      await rows('SELECT e.name, m.name FROM emp e, emp m '
          'WHERE e.mgr(+) = m.id ORDER BY m.id'),
      [
        ['bob', 'king'],
        ['amy', 'king'],
        [null, 'bob'],
        [null, 'amy'],
      ],
    );
  });

  test('(+) left join still applies non-join WHERE predicates', () async {
    expect(
      await rows("SELECT e.name, m.name FROM emp e, emp m "
          "WHERE e.mgr = m.id(+) AND e.name <> 'king' ORDER BY e.id"),
      [
        ['bob', 'king'],
        ['amy', 'king'],
      ],
    );
  });

  test('ANSI RIGHT JOIN nulls the left side (regression)', () async {
    expect(
      await rows('SELECT e.name, m.name FROM emp e '
          'RIGHT JOIN emp m ON e.mgr = m.id ORDER BY m.id'),
      [
        ['bob', 'king'],
        ['amy', 'king'],
        [null, 'bob'],
        [null, 'amy'],
      ],
    );
  });

  test('ANSI FULL JOIN nulls both sides (regression)', () async {
    await db.execute('CREATE TABLE a (x INTEGER PRIMARY KEY)');
    await db.execute('CREATE TABLE b (y INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO a VALUES (1)');
    await db.execute('INSERT INTO a VALUES (2)');
    await db.execute('INSERT INTO b VALUES (2)');
    await db.execute('INSERT INTO b VALUES (3)');
    final r = await rows(
      'SELECT a.x, b.y FROM a FULL JOIN b ON a.x = b.y ORDER BY a.x, b.y',
    );
    // Oracle sorts NULLs last for ASC.
    expect(r, [
      [1, null],
      [2, 2],
      [null, 3],
    ]);
  });
}
