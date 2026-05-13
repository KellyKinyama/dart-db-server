/// Cheap-wins SQLite parity batch:
/// last_insert_rowid / changes / total_changes / sqlite_version,
/// asinh / acosh / atanh, json_pretty.
library;

import 'dart:convert';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('connection-state scalars', () {
    test('last_insert_rowid follows successful inserts', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, x TEXT)');
        var r = await db.execute('SELECT last_insert_rowid()');
        // Before any insert: 0.
        expect((r.rows.first.first as num).toInt(), 0);

        await db.execute("INSERT INTO t(x) VALUES('a')");
        r = await db.execute('SELECT last_insert_rowid()');
        expect((r.rows.first.first as num).toInt(), 1);

        await db.execute("INSERT INTO t(x) VALUES('b')");
        r = await db.execute('SELECT last_insert_rowid()');
        expect((r.rows.first.first as num).toInt(), 2);

        // Explicit id.
        await db.execute("INSERT INTO t(id, x) VALUES(42, 'c')");
        r = await db.execute('SELECT last_insert_rowid()');
        expect((r.rows.first.first as num).toInt(), 42);
      } finally {
        await db.close();
      }
    });

    test('changes() reflects last DML; total_changes() accumulates', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INTEGER)');
        await db.execute('INSERT INTO t(x) VALUES (1),(2),(3)');
        var r = await db.execute('SELECT changes(), total_changes()');
        expect(r.rows.first, [3, 3]);

        await db.execute('UPDATE t SET x = x + 10');
        r = await db.execute('SELECT changes(), total_changes()');
        expect(r.rows.first, [3, 6]);

        await db.execute('DELETE FROM t WHERE x > 11');
        r = await db.execute('SELECT changes(), total_changes()');
        expect(r.rows.first, [2, 8]);
      } finally {
        await db.close();
      }
    });

    test('sqlite_version / sqlite_source_id / compileoption stubs', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT sqlite_version(), sqlite_source_id(), "
                "       sqlite_compileoption_used('FOO'), "
                "       sqlite_compileoption_get(0)");
        final row = r.rows.first;
        expect(row[0], isA<String>());
        expect((row[0] as String), matches(r'^\d+\.\d+\.\d+$'));
        expect(row[1], isA<String>());
        expect(row[2], 0);
        expect(row[3], null);
      } finally {
        await db.close();
      }
    });
  });

  group('hyperbolic inverses', () {
    test('asinh / acosh / atanh basic values', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT asinh(0), acosh(1), atanh(0)');
        expect(r.rows.first, [0.0, 0.0, 0.0]);
      } finally {
        await db.close();
      }
    });

    test('inverse round-trips with sinh/cosh/tanh', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
            'SELECT asinh(sinh(1.5)), acosh(cosh(2.0)), atanh(tanh(0.5))');
        final row = r.rows.first;
        expect((row[0] as num).toDouble(), closeTo(1.5, 1e-12));
        expect((row[1] as num).toDouble(), closeTo(2.0, 1e-12));
        expect((row[2] as num).toDouble(), closeTo(0.5, 1e-12));
      } finally {
        await db.close();
      }
    });

    test('domain errors return NULL', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT acosh(0.5), atanh(1), atanh(-1), asinh(NULL)');
        expect(r.rows.first, [null, null, null, null]);
      } finally {
        await db.close();
      }
    });
  });

  group('json_pretty', () {
    test('default 2-space indent', () async {
      final db = await Database.open();
      try {
        final r =
            await db.execute("SELECT json_pretty('{\"a\":1,\"b\":[2,3]}')");
        final s = r.rows.first.first as String;
        // Re-parse to confirm it's still valid JSON with the same content.
        expect(jsonDecode(s), {
          'a': 1,
          'b': [2, 3]
        });
        // Has a newline -> it really was indented.
        expect(s.contains('\n'), isTrue);
      } finally {
        await db.close();
      }
    });

    test('custom indent string', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT json_pretty('[1,2]', '\t')");
        final s = r.rows.first.first as String;
        expect(s.contains('\t'), isTrue);
        expect(jsonDecode(s), [1, 2]);
      } finally {
        await db.close();
      }
    });

    test('invalid / NULL inputs', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT json_pretty('not json'), json_pretty(NULL)");
        expect(r.rows.first, [null, null]);
      } finally {
        await db.close();
      }
    });
  });
}
