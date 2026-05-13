/// pragma_table_info / index_list / index_info / foreign_key_list parity.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('PRAGMA table_info(t)', () {
    test('returns column rows', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT NOT NULL,'
            " age INTEGER DEFAULT 0)");
        final r = await db.execute('PRAGMA table_info(t)');
        expect(
            r.columns, ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk']);
        expect(r.rows.length, 3);
        expect(r.rows[0][1], 'id');
        expect(r.rows[1][1], 'name');
        expect(r.rows[1][3], 1); // notnull
        expect(r.rows[2][1], 'age');
        expect(r.rows[0][5], 1); // pk
      } finally {
        await db.close();
      }
    });

    test('unknown table returns no rows', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA table_info(nope)');
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });

  group('PRAGMA index_list(t) / index_info(name)', () {
    test('lists named indexes and their columns', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT, c INT)');
        await db.execute('CREATE UNIQUE INDEX ix_ab ON t(a, b)');
        final list = await db.execute('PRAGMA index_list(t)');
        // At least one entry for ix_ab; unique=1.
        final ix =
            list.rows.firstWhere((r) => r[1] == 'ix_ab', orElse: () => []);
        expect(ix, isNotEmpty);
        expect(ix[2], 1);
        final info = await db.execute('PRAGMA index_info(ix_ab)');
        expect(info.rows.length, 2);
        expect(info.rows.map((r) => r[2]).toList(), ['a', 'b']);
      } finally {
        await db.close();
      }
    });
  });

  group('PRAGMA foreign_key_list(t)', () {
    test('lists FK columns', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY)');
        await db.execute('CREATE TABLE c(id INT, pid INT REFERENCES p(id))');
        final r = await db.execute('PRAGMA foreign_key_list(c)');
        expect(r.rows, isNotEmpty);
        final row = r.rows.first;
        expect(row[2], 'p'); // referenced table
        expect(row[3], 'pid'); // from
        expect(row[4], 'id'); // to
      } finally {
        await db.close();
      }
    });
  });
}
