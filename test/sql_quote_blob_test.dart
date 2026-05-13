/// QUOTE, ZEROBLOB, RANDOMBLOB, LIKELY/UNLIKELY/LIKELIHOOD.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('QUOTE', () {
    test('strings get single-quoted with escaping', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT QUOTE('abc'), QUOTE('O''Brien'), QUOTE(NULL)");
        expect(r.rows.first, ["'abc'", "'O''Brien'", 'NULL']);
      } finally {
        await db.close();
      }
    });

    test('numbers stringified bare', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT QUOTE(42), QUOTE(3.14)');
        expect(r.rows.first, ['42', '3.14']);
      } finally {
        await db.close();
      }
    });

    test('blob becomes X-prefixed hex literal', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT QUOTE(X'deadbeef')");
        expect(r.rows.first.first, "X'DEADBEEF'");
      } finally {
        await db.close();
      }
    });
  });

  group('ZEROBLOB / RANDOMBLOB', () {
    test('ZEROBLOB returns N zero bytes', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT LENGTH(ZEROBLOB(8))');
        expect(r.rows.first.first, 8);
        final r2 = await db.execute('SELECT HEX(ZEROBLOB(4))');
        expect(r2.rows.first.first, '00000000');
      } finally {
        await db.close();
      }
    });

    test('ZEROBLOB(0) and negative N', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT LENGTH(ZEROBLOB(0)), LENGTH(ZEROBLOB(-3))');
        expect(r.rows.first, [0, 0]);
      } finally {
        await db.close();
      }
    });

    test('RANDOMBLOB returns N bytes', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT LENGTH(RANDOMBLOB(16))');
        expect(r.rows.first.first, 16);
      } finally {
        await db.close();
      }
    });

    test('NULL input returns NULL', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute('SELECT ZEROBLOB(NULL), RANDOMBLOB(NULL), QUOTE(NULL)');
        expect(r.rows.first, [null, null, 'NULL']);
      } finally {
        await db.close();
      }
    });
  });

  group('LIKELY / UNLIKELY / LIKELIHOOD', () {
    test('return their first argument unchanged', () async {
      final db = await Database.open();
      try {
        final r = await db
            .execute("SELECT LIKELY(5), UNLIKELY('x'), LIKELIHOOD(42, 0.0625)");
        expect(r.rows.first, [5, 'x', 42]);
      } finally {
        await db.close();
      }
    });

    test('usable in WHERE without changing semantics', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t (x INTEGER)');
        await db.execute('INSERT INTO t VALUES (1),(2),(3),(4)');
        final r =
            await db.execute('SELECT x FROM t WHERE LIKELY(x > 2) ORDER BY x');
        expect(r.rows.map((r) => r.first).toList(), [3, 4]);
      } finally {
        await db.close();
      }
    });
  });
}
