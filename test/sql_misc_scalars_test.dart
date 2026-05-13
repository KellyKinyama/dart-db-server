/// Misc scalars: BIT_COUNT, LOAD_EXTENSION, SQLITE_LOG, DATABASE, SCHEMA.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('BIT_COUNT counts set bits', () async {
    final db = await Database.open();
    try {
      final r = await db.execute(
          'SELECT BIT_COUNT(0), BIT_COUNT(7), BIT_COUNT(255), BIT_COUNT(NULL)');
      expect(r.rows.first, [0, 3, 8, null]);
    } finally {
      await db.close();
    }
  });

  test('LOAD_EXTENSION and SQLITE_LOG are no-op NULL', () async {
    final db = await Database.open();
    try {
      final r = await db.execute(
          "SELECT LOAD_EXTENSION('foo'), SQLITE_LOG(1,'hi')");
      expect(r.rows.first, [null, null]);
    } finally {
      await db.close();
    }
  });

  test('DATABASE / SCHEMA return main', () async {
    final db = await Database.open();
    try {
      final r = await db.execute('SELECT DATABASE(), SCHEMA()');
      expect(r.rows.first, ['main', 'main']);
    } finally {
      await db.close();
    }
  });
}
