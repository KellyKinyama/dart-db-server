/// Cross-engine parity tests for the planner. Even when our planner picks
/// different physical plans from SQLite the *result rows* must match.
library;

import 'package:test/test.dart';

import 'sqlite_oracle.dart';

void main() {
  final skip = sqliteSkipReason();

  group('SQLite parity (planner)', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
      await o
          .exec('CREATE TABLE t (id INTEGER PRIMARY KEY, k INTEGER, v TEXT)');
      for (var i = 0; i < 200; i++) {
        await o.exec("INSERT INTO t VALUES ($i, ${i % 50}, 'row$i')");
      }
      await o.exec('CREATE INDEX ix_t_k ON t(k)');
      await o.exec('ANALYZE');
    });
    tearDown(() => o.close());

    test('Equality on indexed column', () async {
      await o.expectSameRows('SELECT id FROM t WHERE k = 7 ORDER BY id');
    });

    test('Reversed equality (literal = column)', () async {
      await o.expectSameRows('SELECT id FROM t WHERE 7 = k ORDER BY id');
    });

    test('Range on indexed column', () async {
      await o.expectSameRows(
          'SELECT id FROM t WHERE k >= 10 AND k < 15 ORDER BY id');
    });

    test('BETWEEN on indexed column', () async {
      await o.expectSameRows(
          'SELECT id FROM t WHERE k BETWEEN 10 AND 14 ORDER BY id');
    });

    test(
        'Equality + non-indexed predicate (planner uses index, '
        'evaluator re-checks)', () async {
      await o.expectSameRows(
          "SELECT id FROM t WHERE k = 7 AND v LIKE 'row%' ORDER BY id");
    });

    test('IN list on indexed column', () async {
      await o
          .expectSameRows('SELECT id FROM t WHERE k IN (3, 7, 11) ORDER BY id');
    });

    test('No index on this column => still correct', () async {
      await o.expectSameRows("SELECT id FROM t WHERE v = 'row42'");
    });
  }, skip: skip);

  group('SQLite parity (join reordering)', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
    });
    tearDown(() => o.close());

    test('big JOIN small produces same rows whichever side drives', () async {
      await o.exec('CREATE TABLE big (id INTEGER, k INTEGER)');
      await o.exec('CREATE TABLE small (k INTEGER, label TEXT)');
      for (var i = 0; i < 200; i++) {
        await o.exec('INSERT INTO big VALUES ($i, ${i % 5})');
      }
      for (var i = 0; i < 5; i++) {
        await o.exec("INSERT INTO small VALUES ($i, 'L$i')");
      }
      await o.expectSameRows(
        'SELECT id, label FROM big INNER JOIN small ON big.k = small.k '
        'ORDER BY id',
      );
    });

    test('three-way INNER chain', () async {
      await o.exec('CREATE TABLE a (id INTEGER, b_id INTEGER)');
      await o.exec('CREATE TABLE b (id INTEGER, c_id INTEGER)');
      await o.exec('CREATE TABLE c (id INTEGER, label TEXT)');
      for (var i = 0; i < 50; i++) {
        await o.exec('INSERT INTO a VALUES ($i, ${i % 10})');
      }
      for (var i = 0; i < 10; i++) {
        await o.exec('INSERT INTO b VALUES ($i, ${i % 3})');
      }
      for (var i = 0; i < 3; i++) {
        await o.exec("INSERT INTO c VALUES ($i, 'C$i')");
      }
      await o.expectSameRows(
        'SELECT a.id, c.label FROM a '
        'INNER JOIN b ON a.b_id = b.id '
        'INNER JOIN c ON b.c_id = c.id '
        'ORDER BY a.id',
      );
    });

    test('LEFT JOIN order is preserved (no reorder)', () async {
      await o.exec('CREATE TABLE a (id INTEGER, k INTEGER)');
      await o.exec('CREATE TABLE b (k INTEGER, label TEXT)');
      await o.exec('INSERT INTO a VALUES (1,1),(2,2),(3,3)');
      await o.exec("INSERT INTO b VALUES (1, 'one')");
      await o.expectSameRows(
        'SELECT a.id, b.label FROM a LEFT JOIN b ON a.k = b.k ORDER BY a.id',
      );
    });
  }, skip: skip);
}
