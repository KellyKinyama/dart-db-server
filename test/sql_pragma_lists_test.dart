/// pragma_function_list / pragma_module_list / pragma_list / pragma_table_list.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('PRAGMA function_list contains common scalars', () async {
    final db = await Database.open();
    try {
      final r = await db.execute('PRAGMA function_list');
      final names = r.rows.map((row) => row[0]).toSet();
      expect(names.contains('coalesce'), isTrue);
      expect(names.contains('iif'), isTrue);
      expect(names.contains('sum'), isTrue);
      expect(names.contains('json_each'), isFalse); // TVF, not function
    } finally {
      await db.close();
    }
  });

  test('PRAGMA module_list lists registered modules', () async {
    final db = await Database.open();
    try {
      final r = await db.execute('PRAGMA module_list');
      final names = r.rows.map((row) => row[0]).toSet();
      expect(names, containsAll(['fts5', 'rtree', 'json_each']));
    } finally {
      await db.close();
    }
  });

  test('PRAGMA pragma_list returns at least common pragmas', () async {
    final db = await Database.open();
    try {
      final r = await db.execute('PRAGMA pragma_list');
      final names = r.rows.map((row) => row[0]).toSet();
      expect(names, containsAll(['table_info', 'foreign_keys', 'journal_mode']));
    } finally {
      await db.close();
    }
  });

  test('PRAGMA table_list lists tables and views', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(a INT)');
      await db.execute('CREATE VIEW v AS SELECT a FROM t');
      final r = await db.execute('PRAGMA table_list');
      expect(r.columns, ['schema', 'name', 'type', 'ncol', 'wr', 'strict']);
      final byName = {for (final row in r.rows) row[1]: row};
      expect(byName.containsKey('t'), isTrue);
      expect(byName['t']![2], 'table');
      expect(byName.containsKey('v'), isTrue);
      expect(byName['v']![2], 'view');
    } finally {
      await db.close();
    }
  });
}
