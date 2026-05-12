/// ORDER BY referring to SELECT-list aliases inside composite expressions.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('ORDER BY alias expressions', () {
    test('bare alias still works', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db
            .execute('INSERT INTO t VALUES (1,10),(2,5),(3,20),(4,1)');
        final r = await db
            .execute('SELECT a+b AS s FROM t ORDER BY s');
        expect(r.rows.map((r) => r.first).toList(), [5, 7, 11, 23]);
      } finally {
        await db.close();
      }
    });

    test('alias used inside arithmetic expression', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER, b INTEGER)');
        await db
            .execute('INSERT INTO t VALUES (1,10),(2,5),(3,20),(4,1)');
        final r = await db
            .execute('SELECT a+b AS s FROM t ORDER BY s + 0 DESC');
        expect(r.rows.map((r) => r.first).toList(), [23, 11, 7, 5]);
      } finally {
        await db.close();
      }
    });

    test('alias used in function call', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER)');
        await db.execute('INSERT INTO t VALUES (-3),(1),(-2),(4)');
        final r = await db
            .execute('SELECT a AS x FROM t ORDER BY ABS(x)');
        expect(r.rows.map((r) => r.first).toList(), [1, -2, -3, 4]);
      } finally {
        await db.close();
      }
    });

    test('alias shadowing column resolves to projection', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (a INTEGER)');
        await db.execute('INSERT INTO t VALUES (1),(2),(3)');
        // `a` is also the alias; the alias value (4-a) wins for ORDER BY.
        final r = await db.execute(
            'SELECT 4 - a AS a FROM t ORDER BY a + 0');
        expect(r.rows.map((r) => r.first).toList(), [1, 2, 3]);
      } finally {
        await db.close();
      }
    });
  });
}
