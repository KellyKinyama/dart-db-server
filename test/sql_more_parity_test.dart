/// More SQLite parity: sqlite_offset, subtype, json_error_position,
/// generate_series TVF.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('introspection scalar stubs', () {
    test('sqlite_offset returns NULL', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT)');
        await db.execute('INSERT INTO t VALUES (1)');
        final r = await db.execute('SELECT sqlite_offset(x) FROM t');
        expect(r.rows.first.first, null);
      } finally {
        await db.close();
      }
    });

    test('subtype returns 0', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT subtype(1), subtype('x'), subtype(NULL)");
        expect(r.rows.first, [0, 0, 0]);
      } finally {
        await db.close();
      }
    });
  });

  group('json_error_position', () {
    test('valid JSON returns 0', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            "SELECT json_error_position('{\"a\":1}'),"
            "       json_error_position('[1,2,3]'),"
            "       json_error_position('null')");
        expect(r.rows.first, [0, 0, 0]);
      } finally {
        await db.close();
      }
    });

    test('invalid JSON returns 1-based error position', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT json_error_position('{not valid')");
        final pos = (r.rows.first.first as num).toInt();
        expect(pos, greaterThan(0));
      } finally {
        await db.close();
      }
    });

    test('NULL input returns NULL', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT json_error_position(NULL)');
        expect(r.rows.first.first, null);
      } finally {
        await db.close();
      }
    });
  });

  group('generate_series TVF', () {
    test('ascending range', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT value FROM generate_series(1, 5)');
        expect(r.rows.map((e) => e.first).toList(), [1, 2, 3, 4, 5]);
      } finally {
        await db.close();
      }
    });

    test('with step', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT value FROM generate_series(0, 10, 2)');
        expect(r.rows.map((e) => e.first).toList(), [0, 2, 4, 6, 8, 10]);
      } finally {
        await db.close();
      }
    });

    test('descending range', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT value FROM generate_series(5, 1, -1)');
        expect(r.rows.map((e) => e.first).toList(), [5, 4, 3, 2, 1]);
      } finally {
        await db.close();
      }
    });

    test('joinable in a query', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            'SELECT sum(value) FROM generate_series(1, 100)');
        expect((r.rows.first.first as num).toInt(), 5050);
      } finally {
        await db.close();
      }
    });

    test('empty range returns no rows', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute('SELECT value FROM generate_series(5, 1)');
        expect(r.rows, isEmpty);
      } finally {
        await db.close();
      }
    });
  });
}
