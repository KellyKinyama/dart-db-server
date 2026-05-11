/// SQLite type-affinity behavior for non-STRICT tables.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('type affinity (non-strict)', () {
    test('INTEGER column stores parseable string as int', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
        await db.execute("INSERT INTO t VALUES (1, '42')");
        final r = await db.execute('SELECT n FROM t');
        expect(r.rows, [
          [42]
        ]);
      } finally {
        await db.close();
      }
    });

    test('INTEGER column preserves non-numeric string verbatim', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER)');
        // Per SQLite affinity rules a string that cannot be converted to
        // INTEGER is stored verbatim instead of throwing.
        await db.execute("INSERT INTO t VALUES (1, 'abc')");
        final r = await db.execute('SELECT n FROM t');
        expect(r.rows, [
          ['abc']
        ]);
      } finally {
        await db.close();
      }
    });

    test('BLOB column never converts (string stays string)', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, b BLOB)');
        await db.execute("INSERT INTO t VALUES (1, 'hello')");
        final r = await db.execute('SELECT b FROM t');
        // Previously the engine would utf8-encode the string into bytes;
        // SQLite leaves the value's storage class unchanged for BLOB
        // affinity.
        expect(r.rows, [
          ['hello']
        ]);
      } finally {
        await db.close();
      }
    });

    test('REAL column stores parseable string as double', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, x REAL)');
        await db.execute("INSERT INTO t VALUES (1, '3.5')");
        final r = await db.execute('SELECT x FROM t');
        expect(r.rows, [
          [3.5]
        ]);
      } finally {
        await db.close();
      }
    });

    test('REAL column preserves non-numeric string verbatim', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, x REAL)');
        await db.execute("INSERT INTO t VALUES (1, 'NaNoNaN')");
        final r = await db.execute('SELECT x FROM t');
        expect(r.rows, [
          ['NaNoNaN']
        ]);
      } finally {
        await db.close();
      }
    });

    test('STRICT INTEGER column still rejects non-numeric strings', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t (id INTEGER PRIMARY KEY, n INTEGER) STRICT');
        Object? err;
        try {
          await db.execute("INSERT INTO t VALUES (1, 'abc')");
        } catch (e) {
          err = e;
        }
        expect(err, isNotNull,
            reason: 'STRICT tables must reject affinity fallback');
      } finally {
        await db.close();
      }
    });
  });
}
