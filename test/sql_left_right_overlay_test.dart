/// LEFT, RIGHT, POSITION, OVERLAY, REVERSE, REPEAT.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('LEFT / RIGHT', () {
    test('basic', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT LEFT('hello', 3), RIGHT('hello', 2)");
        expect(r.rows.first, ['hel', 'lo']);
      } finally {
        await db.close();
      }
    });

    test('n >= length returns whole string; n <= 0 returns empty', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT LEFT('abc', 99), RIGHT('abc', 0), LEFT('abc', -1)");
        expect(r.rows.first, ['abc', '', '']);
      } finally {
        await db.close();
      }
    });

    test('NULL input', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT LEFT(NULL, 3), RIGHT(NULL, 3)');
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('POSITION', () {
    test('1-based index, 0 when not found', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT POSITION('lo', 'hello'), POSITION('zz', 'hello')");
        expect(r.rows.first, [4, 0]);
      } finally {
        await db.close();
      }
    });

    test('empty needle returns 1', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT POSITION('', 'abc')");
        expect(r.rows.first.first, 1);
      } finally {
        await db.close();
      }
    });

    test('NULL input', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT POSITION(NULL, 'abc'), POSITION('a', NULL)");
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('OVERLAY', () {
    test('replace using default length', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT OVERLAY('abcdef', 'XY', 3)");
        expect(r.rows.first.first, 'abXYef');
      } finally {
        await db.close();
      }
    });

    test('explicit length', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT OVERLAY('abcdef', 'X', 2, 3)");
        expect(r.rows.first.first, 'aXef');
      } finally {
        await db.close();
      }
    });

    test('insert past end', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT OVERLAY('ab', 'CDE', 5)");
        expect(r.rows.first.first, 'abCDE');
      } finally {
        await db.close();
      }
    });
  });

  group('REVERSE / REPEAT', () {
    test('REVERSE basic', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT REVERSE('hello'), REVERSE('')");
        expect(r.rows.first, ['olleh', '']);
      } finally {
        await db.close();
      }
    });

    test('REPEAT basic', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT REPEAT('ab', 3), REPEAT('x', 0), REPEAT('y', -2)");
        expect(r.rows.first, ['ababab', '', '']);
      } finally {
        await db.close();
      }
    });

    test('NULL input', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT REVERSE(NULL), REPEAT(NULL, 3), REPEAT('x', NULL)");
        expect(r.rows.first, [null, null, null]);
      } finally {
        await db.close();
      }
    });
  });
}
