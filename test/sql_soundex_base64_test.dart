/// SOUNDEX, BASE64 / UNBASE64.
library;

import 'dart:convert';
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('SOUNDEX', () {
    test('classic examples', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT SOUNDEX('Robert'), SOUNDEX('Rupert'), "
            "       SOUNDEX('Ashcraft'), SOUNDEX('Tymczak')");
        expect(r.rows.first, ['R163', 'R163', 'A261', 'T522']);
      } finally {
        await db.close();
      }
    });

    test('empty / NULL returns ?000', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT SOUNDEX(''), SOUNDEX(NULL)");
        expect(r.rows.first, ['?000', '?000']);
      } finally {
        await db.close();
      }
    });

    test('case-insensitive', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT SOUNDEX('robert'), SOUNDEX('ROBERT')");
        expect(r.rows.first, ['R163', 'R163']);
      } finally {
        await db.close();
      }
    });
  });

  group('BASE64 / UNBASE64', () {
    test('round-trip text', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT BASE64('Hello, World!')");
        expect(r.rows.first.first, 'SGVsbG8sIFdvcmxkIQ==');
      } finally {
        await db.close();
      }
    });

    test('UNBASE64 returns blob', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT UNBASE64('SGVsbG8=')");
        final bytes = r.rows.first.first as List<int>;
        expect(utf8.decode(bytes), 'Hello');
      } finally {
        await db.close();
      }
    });

    test('round-trip BASE64(UNBASE64(x)) == x', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT BASE64(UNBASE64('Zm9vYmFy'))");
        expect(r.rows.first.first, 'Zm9vYmFy');
      } finally {
        await db.close();
      }
    });

    test('malformed UNBASE64 returns NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT UNBASE64('!!!not-base64!!!')");
        expect(r.rows.first.first, null);
      } finally {
        await db.close();
      }
    });

    test('NULL inputs', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT BASE64(NULL), UNBASE64(NULL)');
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });
}
