/// Extended STRFTIME specifiers and date modifiers.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('strftime %w / %W / %I / %p / %e', () async {
    final db = await Database.open();
    try {
      final r = await db.execute("SELECT strftime('%w','2024-01-07'),"
          " strftime('%I:%p','2024-01-01 13:05:00'),"
          " strftime('%e','2024-01-09')");
      // 2024-01-07 was Sunday => 0.
      expect(r.rows.first[0], '0');
      expect(r.rows.first[1], '01:PM');
      expect(r.rows.first[2], ' 9');
    } finally {
      await db.close();
    }
  });

  test('strftime %f returns fractional seconds', () async {
    final db = await Database.open();
    try {
      final r =
          await db.execute("SELECT strftime('%f','2024-01-01 12:34:56.500')");
      // SQLite formats as SS.SSS.
      expect(r.rows.first[0].toString().startsWith('56.500'), isTrue);
    } finally {
      await db.close();
    }
  });

  test("date modifier 'start of hour' truncates", () async {
    final db = await Database.open();
    try {
      final r = await db
          .execute("SELECT datetime('2024-06-15 12:34:56','start of hour')");
      expect(r.rows.first[0], '2024-06-15 12:00:00');
    } finally {
      await db.close();
    }
  });

  test("date modifier 'start of minute' truncates", () async {
    final db = await Database.open();
    try {
      final r = await db
          .execute("SELECT datetime('2024-06-15 12:34:56','start of minute')");
      expect(r.rows.first[0], '2024-06-15 12:34:00');
    } finally {
      await db.close();
    }
  });
}
