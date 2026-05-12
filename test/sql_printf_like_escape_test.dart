/// LIKE ESCAPE clause and PRINTF / FORMAT scalar functions.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('LIKE ESCAPE', () {
    test('Escapes literal % via custom escape char', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute(
            "INSERT INTO t VALUES ('100%'), ('abc'), ('50%_off'), ('100x')");
        final r = await db.execute(
            "SELECT s FROM t WHERE s LIKE '100!%' ESCAPE '!' ORDER BY s");
        expect(r.rows.map((r) => r.first).toList(), ['100%']);
      } finally {
        await db.close();
      }
    });

    test('Escapes literal _ via custom char', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('a_b'), ('axb'), ('a__b')");
        final r = await db.execute(
            "SELECT s FROM t WHERE s LIKE 'a!_b' ESCAPE '!' ORDER BY s");
        expect(r.rows.map((r) => r.first).toList(), ['a_b']);
      } finally {
        await db.close();
      }
    });

    test('Non-escaped wildcards still match', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('100%'), ('200%'), ('abc')");
        final r = await db.execute(
            "SELECT s FROM t WHERE s LIKE '%!%' ESCAPE '!' ORDER BY s");
        expect(r.rows.map((r) => r.first).toList(), ['100%', '200%']);
      } finally {
        await db.close();
      }
    });

    test('NOT LIKE ... ESCAPE inverts the match', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (s TEXT)');
        await db.execute("INSERT INTO t VALUES ('100%'), ('abc')");
        final r = await db
            .execute("SELECT s FROM t WHERE s NOT LIKE '100!%' ESCAPE '!'");
        expect(r.rows.map((r) => r.first).toList(), ['abc']);
      } finally {
        await db.close();
      }
    });

    test('NULL pattern / value / escape return NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT 'abc' LIKE NULL ESCAPE '!', "
            "       NULL LIKE 'abc' ESCAPE '!', "
            "       'abc' LIKE 'abc' ESCAPE NULL");
        expect(r.rows.first, [null, null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('PRINTF / FORMAT', () {
    test('plain text and literal %%', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT PRINTF('100%%')");
        expect(r.rows.first.first, '100%');
      } finally {
        await db.close();
      }
    });

    test('%d basic integer', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT PRINTF('%d / %d / %d', 1, -42, 0)");
        expect(r.rows.first.first, '1 / -42 / 0');
      } finally {
        await db.close();
      }
    });

    test('width and zero-padding', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT PRINTF('%5d', 42), PRINTF('%05d', 42), PRINTF('%-5d|', 42)");
        expect(r.rows.first, ['   42', '00042', '42   |']);
      } finally {
        await db.close();
      }
    });

    test('hex / octal conversion', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT PRINTF('%x %X %o', 255, 255, 8)");
        expect(r.rows.first.first, 'ff FF 10');
      } finally {
        await db.close();
      }
    });

    test('%s with width / precision', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT PRINTF('|%10s|', 'hi'), PRINTF('|%.3s|', 'hello')");
        expect(r.rows.first, ['|        hi|', '|hel|']);
      } finally {
        await db.close();
      }
    });

    test('%f / %e / %g precision', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT PRINTF('%.2f', 3.14159), PRINTF('%.3e', 1234.5)");
        expect(r.rows.first[0], '3.14');
        expect(r.rows.first[1], '1.235e+3');
      } finally {
        await db.close();
      }
    });

    test('%q escapes single quotes; %Q wraps in single quotes', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT PRINTF('%q', 'O''Brien'), PRINTF('%Q', 'O''Brien'), "
            "       PRINTF('%Q', NULL)");
        expect(r.rows.first, ["O''Brien", "'O''Brien'", 'NULL']);
      } finally {
        await db.close();
      }
    });

    test('FORMAT is an alias for PRINTF', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT FORMAT('%d-%s', 7, 'x')");
        expect(r.rows.first.first, '7-x');
      } finally {
        await db.close();
      }
    });

    test('NULL format returns NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT PRINTF(NULL, 1, 2)');
        expect(r.rows.first.first, isNull);
      } finally {
        await db.close();
      }
    });
  });
}
