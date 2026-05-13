/// Parser parity: TEMP/TEMPORARY tables; INSERT OR ABORT/FAIL/ROLLBACK.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('CREATE TEMP[ORARY] TABLE', () {
    test('TEMP modifier accepted', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TEMP TABLE t(x INT)');
        await db.execute('INSERT INTO t VALUES (1)');
        final r = await db.execute('SELECT x FROM t');
        expect(r.rows.first.first, 1);
      } finally {
        await db.close();
      }
    });

    test('TEMPORARY modifier accepted', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TEMPORARY TABLE t(x INT)');
        await db.execute('INSERT INTO t VALUES (2)');
        final r = await db.execute('SELECT x FROM t');
        expect(r.rows.first.first, 2);
      } finally {
        await db.close();
      }
    });
  });

  group('INSERT OR ABORT|FAIL|ROLLBACK', () {
    test('ABORT/FAIL/ROLLBACK parse and behave as default', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(x INT UNIQUE)');
        await db.execute('INSERT OR ABORT INTO t VALUES (1)');
        await db.execute('INSERT OR FAIL INTO t VALUES (2)');
        await db.execute('INSERT OR ROLLBACK INTO t VALUES (3)');
        final r = await db.execute('SELECT count(*) FROM t');
        expect((r.rows.first.first as num).toInt(), 3);
        // Conflict on UNIQUE still throws (same as plain INSERT).
        expect(() => db.execute('INSERT OR ABORT INTO t VALUES (1)'),
            throwsA(isA<StateError>()));
      } finally {
        await db.close();
      }
    });
  });
}
