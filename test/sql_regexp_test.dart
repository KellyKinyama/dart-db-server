/// REGEXP operator and REGEXP_* scalar functions.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('REGEXP operator', () {
    test('basic match', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            r"SELECT 'hello world' REGEXP '^hello', 'foo' REGEXP '^bar'");
        expect(r.rows.first, [true, false]);
      } finally {
        await db.close();
      }
    });

    test('NOT REGEXP inverts', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute(
            "INSERT INTO t VALUES ('abc123'), ('only-letters'), ('999')");
        final r = await db
            .execute(r"SELECT s FROM t WHERE s NOT REGEXP '[0-9]' ORDER BY s");
        expect(r.rows.map((r) => r.first).toList(), ['only-letters']);
      } finally {
        await db.close();
      }
    });

    test('NULL operands return NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT NULL REGEXP 'x', 'x' REGEXP NULL");
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });

    test('character class and anchors', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute(
            "INSERT INTO t VALUES ('a1b'), ('abc'), ('123'), ('A99Z')");
        final r = await db
            .execute(r"SELECT s FROM t WHERE s REGEXP '^[A-Z].*[0-9]+[A-Z]$'");
        expect(r.rows.map((r) => r.first).toList(), ['A99Z']);
      } finally {
        await db.close();
      }
    });
  });

  group('REGEXP_* functions', () {
    test('REGEXP_LIKE', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            r"SELECT REGEXP_LIKE('abc123', '[0-9]+'), REGEXP_LIKE('abc', '^z')");
        expect(r.rows.first, [true, false]);
      } finally {
        await db.close();
      }
    });

    test('REGEXP_SUBSTR returns first match or NULL', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute(r"SELECT REGEXP_SUBSTR('foo-123-bar', '[0-9]+'), "
                r"       REGEXP_SUBSTR('foo', '[0-9]+')");
        expect(r.rows.first, ['123', null]);
      } finally {
        await db.close();
      }
    });

    test('REGEXP_REPLACE replaces all matches', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute(r"SELECT REGEXP_REPLACE('a1b2c3', '[0-9]', 'X')");
        expect(r.rows.first.first, 'aXbXcX');
      } finally {
        await db.close();
      }
    });
  });
}
