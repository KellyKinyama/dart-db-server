/// Tests the procedural routine core (Phase 3a): the dialect-neutral block
/// interpreter underpinning MySQL stored routines and Oracle PL/SQL.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
  });

  test('variables, WHILE and RETURN compute a value', () async {
    final factorial = RoutineBlock(
      [
        RoutineAssign('acc', '1'),
        RoutineWhile(':i > 1', [
          RoutineAssign('acc', ':acc * :i'),
          RoutineAssign('i', ':i - 1'),
        ]),
        RoutineReturn(exprSql: ':acc'),
      ],
      declarations: [RoutineDecl('acc')],
    );
    expect((await db.runRoutine(factorial, args: {'i': 5})).returnValue, 120);
    expect((await db.runRoutine(factorial, args: {'i': 1})).returnValue, 1);
  });

  test('DECLARE initialisers evaluate in order', () async {
    final block = RoutineBlock(
      [RoutineReturn(exprSql: ':b')],
      declarations: [
        RoutineDecl('a', initSql: '10'),
        RoutineDecl('b', initSql: ':a * 2'),
      ],
    );
    expect((await db.runRoutine(block)).returnValue, 20);
  });

  test('IF / ELSIF / ELSE picks the first true branch', () async {
    final classify = RoutineBlock([
      RoutineIf([
        RoutineBranch(':x < 0', [RoutineReturn(exprSql: "'neg'")]),
        RoutineBranch(':x = 0', [RoutineReturn(exprSql: "'zero'")]),
      ], elseBody: [
        RoutineReturn(exprSql: "'pos'")
      ]),
    ]);
    expect((await db.runRoutine(classify, args: {'x': -3})).returnValue, 'neg');
    expect((await db.runRoutine(classify, args: {'x': 0})).returnValue, 'zero');
    expect((await db.runRoutine(classify, args: {'x': 7})).returnValue, 'pos');
  });

  test('numeric FOR loop with EXIT WHEN drives embedded DML', () async {
    final fill = RoutineBlock([
      RoutineForNumeric('k', '1', '5', [
        RoutineExit(whenSql: ':k = 4'),
        RoutineSql('INSERT INTO t VALUES (:k, :k * 10)'),
      ]),
    ]);
    await db.runRoutine(fill);
    final rows = await db.execute('SELECT id, n FROM t ORDER BY id');
    expect(rows.rows.map((r) => r.toList()).toList(), [
      [1, 10],
      [2, 20],
      [3, 30],
    ]);
  });

  test('REVERSE FOR counts down', () async {
    final block = RoutineBlock([
      RoutineForNumeric('k', '1', '3', [RoutinePrint(':k')], reverse: true),
    ]);
    expect((await db.runRoutine(block)).output, ['3', '2', '1']);
  });

  test('LOOP with EXIT WHEN', () async {
    final countdown = RoutineBlock([
      RoutineLoop([
        RoutinePrint(':x'),
        RoutineAssign('x', ':x - 1'),
        RoutineExit(whenSql: ':x = 0'),
      ]),
    ]);
    expect(
        (await db.runRoutine(countdown, args: {'x': 3})).output, ['3', '2', '1']);
  });

  test('SELECT INTO assigns result columns to locals', () async {
    await db.execute('INSERT INTO t VALUES (1, 10), (2, 20), (3, 30)');
    final avg = RoutineBlock([
      RoutineSelectInto('SELECT COUNT(*), SUM(n) FROM t', ['cnt', 'total']),
      RoutineReturn(exprSql: ':total / :cnt'),
    ]);
    expect((await db.runRoutine(avg)).returnValue, 20);
  });

  test('SELECT INTO with no row yields NULLs', () async {
    final block = RoutineBlock([
      RoutineSelectInto('SELECT n FROM t WHERE id = :missing', ['v']),
      RoutineReturn(exprSql: ':v IS NULL'),
    ]);
    final r = await db.runRoutine(block, args: {'missing': 99});
    expect(r.returnValue == true || r.returnValue == 1, isTrue);
  });

  test('nested loops: inner EXIT only breaks the inner loop', () async {
    final block = RoutineBlock([
      RoutineForNumeric('i', '1', '2', [
        RoutineForNumeric('j', '1', '9', [
          RoutineExit(whenSql: ':j = 2'),
          RoutinePrint(':i || \'-\' || :j'),
        ]),
      ]),
    ]);
    expect((await db.runRoutine(block)).output, ['1-1', '2-1']);
  });

  test('final variable scope is reported', () async {
    final block = RoutineBlock([
      RoutineAssign('a', '41'),
      RoutineAssign('a', ':a + 1'),
    ]);
    expect((await db.runRoutine(block)).variables['a'], 42);
  });

  test('a routine can mutate the database', () async {
    final block = RoutineBlock([
      RoutineSql('INSERT INTO t VALUES (:id, :val)'),
    ]);
    await db.runRoutine(block, args: {'id': 7, 'val': 70});
    final r = await db.execute('SELECT n FROM t WHERE id = 7');
    expect(r.rows.first.first, 70);
  });
}
