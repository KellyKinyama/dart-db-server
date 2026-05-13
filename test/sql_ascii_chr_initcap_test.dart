/// ASCII, CHR, SPACE, INITCAP scalar functions.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('ASCII / CHR', () {
    test('ASCII basic and round-trip with CHR', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT ASCII('A'), ASCII('a'), CHR(65), CHR(97)");
        expect(r.rows.first, [65, 97, 'A', 'a']);
      } finally {
        await db.close();
      }
    });

    test('ASCII of empty string returns NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT ASCII('')");
        expect(r.rows.first.first, null);
      } finally {
        await db.close();
      }
    });

    test('NULL inputs', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT ASCII(NULL), CHR(NULL)');
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('SPACE', () {
    test('basic', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT SPACE(0), SPACE(1), SPACE(5), SPACE(-3)");
        expect(r.rows.first, ['', ' ', '     ', '']);
      } finally {
        await db.close();
      }
    });
  });

  group('INITCAP', () {
    test('title-cases each word', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT INITCAP('hello world'), INITCAP('FOO BAR'), "
                "       INITCAP('mixed CASE here')");
        expect(r.rows.first, ['Hello World', 'Foo Bar', 'Mixed Case Here']);
      } finally {
        await db.close();
      }
    });

    test('handles tabs and newlines', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT INITCAP('a\tb\nc')");
        expect(r.rows.first.first, 'A\tB\nC');
      } finally {
        await db.close();
      }
    });

    test('NULL / empty', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT INITCAP(NULL), INITCAP('')");
        expect(r.rows.first, [null, '']);
      } finally {
        await db.close();
      }
    });
  });
}
