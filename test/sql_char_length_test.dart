/// CHAR_LENGTH / CHARACTER_LENGTH aliases for LENGTH.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('CHAR_LENGTH and CHARACTER_LENGTH alias LENGTH', () async {
    final db = await Database.open();
    try {
      final r = await db
          .execute("SELECT CHAR_LENGTH('abc'), CHARACTER_LENGTH('hello'),"
              " CHAR_LENGTH(NULL)");
      expect(r.rows.first, [3, 5, null]);
    } finally {
      await db.close();
    }
  });
}
