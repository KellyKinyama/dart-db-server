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

    // F55: an INTEGER PRIMARY KEY is a rowid alias — it must hold an integer,
    // and SQLite raises "datatype mismatch" for a non-integer value (unlike a
    // regular INTEGER column's loose affinity).
    test('INTEGER PRIMARY KEY rejects a non-integer text value', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
        await expectLater(db.execute("INSERT INTO t VALUES ('x', 1)"),
            throwsA(isA<FormatException>()));
      } finally {
        await db.close();
      }
    });

    test('INTEGER PRIMARY KEY rejects a non-integer float value', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
        await expectLater(db.execute('INSERT INTO t VALUES (1.5, 1)'),
            throwsA(isA<FormatException>()));
      } finally {
        await db.close();
      }
    });

    test('INTEGER PRIMARY KEY still accepts an integer-valued string/float',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
        await db.execute("INSERT INTO t VALUES ('7', 1)"); // '7' -> 7
        await db.execute('INSERT INTO t VALUES (8.0, 2)'); // 8.0 -> 8
        final r = await db.execute('SELECT id FROM t ORDER BY id');
        expect(r.rows, [
          [7],
          [8]
        ]);
      } finally {
        await db.close();
      }
    });

    test('WITHOUT ROWID INTEGER PRIMARY KEY keeps loose affinity', () async {
      final db = await Database.open();
      try {
        // Not a rowid alias, so the non-integer value is stored verbatim.
        await db.execute(
            'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER) WITHOUT ROWID');
        await db.execute("INSERT INTO t VALUES ('x', 1)");
        final r = await db.execute('SELECT id FROM t');
        expect(r.rows, [
          ['x']
        ]);
      } finally {
        await db.close();
      }
    });

    // F56: a plain INTEGER PRIMARY KEY is a rowid alias and auto-assigns the
    // id when omitted/NULL, like SQLite — even without the AUTOINCREMENT keyword.
    test('plain INTEGER PRIMARY KEY auto-assigns the rowid when omitted',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
        await db.execute('INSERT INTO t (v) VALUES (10)');
        await db.execute('INSERT INTO t (v) VALUES (20)');
        await db.execute('INSERT INTO t (id, v) VALUES (5, 30)'); // explicit
        await db.execute('INSERT INTO t (v) VALUES (40)'); // max(5)+1 -> 6
        final r = await db.execute('SELECT id, v FROM t ORDER BY v');
        expect(r.rows, [
          [1, 10],
          [2, 20],
          [5, 30],
          [6, 40]
        ]);
      } finally {
        await db.close();
      }
    });

    // F57: the rowid pseudo-column (and aliases _rowid_/oid) resolves to the
    // INTEGER PRIMARY KEY on a rowid table, in both the SELECT list and WHERE.
    test('rowid / _rowid_ / oid resolve to the INTEGER PRIMARY KEY', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
        await db.execute('INSERT INTO t VALUES (5, 50)');
        expect((await db.execute('SELECT rowid FROM t')).rows, [
          [5]
        ]);
        expect((await db.execute('SELECT _rowid_ FROM t')).rows, [
          [5]
        ]);
        expect((await db.execute('SELECT oid FROM t')).rows, [
          [5]
        ]);
        expect((await db.execute('SELECT v FROM t WHERE rowid = 5')).rows, [
          [50]
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
