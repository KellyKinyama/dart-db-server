/// Tests for column `DEFAULT (<expr>)` and DEFAULT CURRENT_* support.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('DEFAULT expression', () {
    test('DEFAULT (<expr>) parses and applies on INSERT', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t ('
            ' id INTEGER PRIMARY KEY,'
            ' a INTEGER DEFAULT (2 + 3),'
            ' b TEXT DEFAULT (UPPER(\'hi\'))'
            ')');
        await db.execute('INSERT INTO t (id) VALUES (1)');
        final r = await db.execute('SELECT a, b FROM t');
        expect(r.rows, [
          [5, 'HI']
        ]);
      } finally {
        await db.close();
      }
    });

    test('user-supplied value overrides expression default', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t ('
            ' id INTEGER PRIMARY KEY,'
            ' a INTEGER DEFAULT (2 + 3)'
            ')');
        await db.execute('INSERT INTO t (id, a) VALUES (1, 99)');
        final r = await db.execute('SELECT a FROM t');
        expect(r.rows, [
          [99]
        ]);
      } finally {
        await db.close();
      }
    });

    test('DEFAULT CURRENT_TIMESTAMP yields an ISO-ish datetime string',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t ('
            ' id INTEGER PRIMARY KEY,'
            ' created TEXT DEFAULT CURRENT_TIMESTAMP'
            ')');
        await db.execute('INSERT INTO t (id) VALUES (1)');
        final r = await db.execute('SELECT created FROM t');
        expect(r.rows.length, 1);
        final v = r.rows.first.first as String;
        // YYYY-MM-DD HH:MM:SS format from SQLite.
        expect(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$').hasMatch(v),
            isTrue,
            reason: 'unexpected value: $v');
      } finally {
        await db.close();
      }
    });

    test('DEFAULT CURRENT_DATE yields a YYYY-MM-DD string', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t ('
            ' id INTEGER PRIMARY KEY,'
            ' d TEXT DEFAULT CURRENT_DATE'
            ')');
        await db.execute('INSERT INTO t (id) VALUES (1)');
        final r = await db.execute('SELECT d FROM t');
        final v = r.rows.first.first as String;
        expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(v), isTrue,
            reason: 'unexpected value: $v');
      } finally {
        await db.close();
      }
    });

    test('ColumnDef round-trips defaultExprSql through JSON', () {
      const c = ColumnDef('a', DataType.integer, defaultExprSql: '2 + 3');
      final rt = ColumnDef.fromJson(c.toJson());
      expect(rt.defaultExprSql, '2 + 3');
      expect(rt.defaultValue, isNull);
    });

    test('literal default still works alongside expression default support',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t ('
            ' id INTEGER PRIMARY KEY,'
            ' a INTEGER DEFAULT 7,'
            ' b INTEGER DEFAULT -3'
            ')');
        await db.execute('INSERT INTO t (id) VALUES (1)');
        final r = await db.execute('SELECT a, b FROM t');
        expect(r.rows, [
          [7, -3]
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
