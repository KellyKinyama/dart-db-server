/// LEAST, GREATEST, OCTET_LENGTH, BIT_LENGTH, TIMEDIFF.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('LEAST / GREATEST', () {
    test('basic numeric', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT LEAST(3, 1, 2), GREATEST(3, 1, 2)');
        expect(r.rows.first, [1, 3]);
      } finally {
        await db.close();
      }
    });

    test('skips NULL values', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            'SELECT LEAST(NULL, 5, 2, NULL), GREATEST(NULL, 5, 2, NULL)');
        expect(r.rows.first, [2, 5]);
      } finally {
        await db.close();
      }
    });

    test('all NULL returns NULL', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT LEAST(NULL, NULL), GREATEST(NULL, NULL)');
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });

    test('strings use SQL comparison', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT LEAST('c', 'a', 'b'), GREATEST('c', 'a', 'b')");
        expect(r.rows.first, ['a', 'c']);
      } finally {
        await db.close();
      }
    });
  });

  group('OCTET_LENGTH / BIT_LENGTH', () {
    test('ASCII string', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT OCTET_LENGTH('hello'), BIT_LENGTH('hello')");
        expect(r.rows.first, [5, 40]);
      } finally {
        await db.close();
      }
    });

    test('multi-byte UTF-8', () async {
      final db = await Database.open();
      try {
        // 'é' = 2 bytes in UTF-8, 'a' = 1 byte.
        final r =
            await db.execute("SELECT OCTET_LENGTH('aé'), LENGTH('aé')");
        expect(r.rows.first, [3, 2]);
      } finally {
        await db.close();
      }
    });

    test('NULL input', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT OCTET_LENGTH(NULL), BIT_LENGTH(NULL)');
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('TIMEDIFF', () {
    test('positive difference', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT TIMEDIFF('2025-01-02 12:30:45', '2025-01-01 12:00:00')");
        expect(r.rows.first.first, '+0000-00-01 00:30:45.000');
      } finally {
        await db.close();
      }
    });

    test('negative difference', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT TIMEDIFF('2025-01-01 12:00:00', '2025-01-01 13:30:15')");
        expect(r.rows.first.first, '-0000-00-00 01:30:15.000');
      } finally {
        await db.close();
      }
    });

    test('NULL input', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT TIMEDIFF(NULL, '2025-01-01'), TIMEDIFF('2025-01-01', NULL)");
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });
}
