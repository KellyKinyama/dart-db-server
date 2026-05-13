/// pragma_table_info / pragma_function_list / pragma_table_list as TVFs.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('pragma_table_info(name) as table-valued function', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INT, n TEXT NOT NULL)');
      final r = await db.execute(
          "SELECT cid, name, notnull FROM pragma_table_info('t') ORDER BY cid");
      expect(r.rows.length, 2);
      expect(r.rows[0][1], 'id');
      expect(r.rows[1][1], 'n');
      expect(r.rows[1][2], 1);
    } finally {
      await db.close();
    }
  });

  test('pragma_function_list() as TVF', () async {
    final db = await Database.open();
    try {
      final r = await db.execute(
          "SELECT count(*) FROM pragma_function_list() WHERE name='coalesce'");
      expect((r.rows.first[0] as num).toInt() >= 1, isTrue);
    } finally {
      await db.close();
    }
  });

  test('pragma_table_list() lists tables', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE foo(a INT)');
      final r = await db.execute(
          "SELECT name FROM pragma_table_list() WHERE type='table'");
      expect(r.rows.map((row) => row[0]).toList(), contains('foo'));
    } finally {
      await db.close();
    }
  });
}
