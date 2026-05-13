/// EXPLAIN now emits SQLite-shaped 8-column VDBE rows; EXPLAIN QUERY PLAN
/// emits the (id, parent, notused, detail) tree; PRAGMA vdbe_listing
/// surfaces the most recently EXPLAIN'd bytecode.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('EXPLAIN bytecode', () {
    test('SELECT yields Init/OpenRead/.../Halt rows', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT)');
        final r = await db.execute('EXPLAIN SELECT * FROM t');
        expect(r.columns,
            ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment']);
        final opcodes = r.rows.map((row) => row[1] as String).toList();
        expect(opcodes.first, 'Init');
        expect(opcodes, contains('OpenRead'));
        expect(opcodes, contains('Rewind'));
        expect(opcodes, contains('Column'));
        expect(opcodes, contains('ResultRow'));
        expect(opcodes, contains('Next'));
        expect(opcodes, contains('Halt'));
      } finally {
        await db.close();
      }
    });

    test('INSERT yields write-side opcodes', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT)');
        final r = await db.execute('EXPLAIN INSERT INTO t VALUES(1)');
        final opcodes = r.rows.map((row) => row[1] as String).toList();
        expect(opcodes, contains('OpenWrite'));
        expect(opcodes, contains('Insert'));
      } finally {
        await db.close();
      }
    });

    test('DELETE yields Delete opcode', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT)');
        final r = await db.execute('EXPLAIN DELETE FROM t');
        final opcodes = r.rows.map((row) => row[1] as String).toList();
        expect(opcodes, contains('Delete'));
      } finally {
        await db.close();
      }
    });
  });

  group('EXPLAIN QUERY PLAN', () {
    test('SELECT returns id/parent/notused/detail rows', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT)');
        final r = await db.execute('EXPLAIN QUERY PLAN SELECT * FROM t');
        expect(r.columns, ['id', 'parent', 'notused', 'detail']);
        expect(r.rows.length, greaterThan(0));
        expect(r.rows.first[3].toString(), contains('SCAN t'));
      } finally {
        await db.close();
      }
    });

    test('uses SEARCH...USING INDEX when an equality index matches',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT)');
        await db.execute('CREATE INDEX ix_a ON t(a)');
        final r = await db
            .execute('EXPLAIN QUERY PLAN SELECT * FROM t WHERE a = 5');
        final detail = r.rows.first[3].toString();
        expect(detail, contains('SEARCH t USING INDEX ix_a'));
      } finally {
        await db.close();
      }
    });

    test('JOIN adds child rows under the driving SCAN', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE a(id INT)');
        await db.execute('CREATE TABLE b(id INT)');
        final r = await db.execute(
            'EXPLAIN QUERY PLAN SELECT * FROM a INNER JOIN b ON a.id=b.id');
        final details = r.rows.map((row) => row[3].toString()).toList();
        expect(details.any((d) => d.contains('SCAN a')), isTrue);
        expect(details.any((d) => d.contains('JOIN b')), isTrue);
      } finally {
        await db.close();
      }
    });
  });

  group('PRAGMA vdbe_listing buffer', () {
    test('returns rows from the previous EXPLAIN', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT)');
        await db.execute('EXPLAIN SELECT * FROM t');
        final r = await db.execute('PRAGMA vdbe_listing');
        expect(r.columns,
            ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment']);
        expect(r.rows.length, greaterThan(0));
        expect(r.rows.first[1], 'Init');
      } finally {
        await db.close();
      }
    });

    test('EXPLAIN QUERY PLAN clears the bytecode buffer', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT)');
        await db.execute('EXPLAIN SELECT * FROM t');
        await db.execute('EXPLAIN QUERY PLAN SELECT * FROM t');
        final r = await db.execute('PRAGMA vdbe_listing');
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
