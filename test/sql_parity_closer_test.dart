/// Closes the SQLite-parity gap: ALTER TABLE column ops, generated-column
/// guards, recursive-trigger depth, PRAGMA optimize / vdbe_listing /
/// max_trigger_depth / wal2_checkpoint, sqlite_stmt / sqlite_dbpage.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('ALTER TABLE column ops', () {
    test('RENAME COLUMN updates schema and queries', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT)');
        await db.execute('INSERT INTO t VALUES(1,2)');
        await db.execute('ALTER TABLE t RENAME COLUMN b TO bb');
        final r = await db.execute('SELECT a, bb FROM t');
        expect(r.rows.first, [1, 2]);
      } finally {
        await db.close();
      }
    });

    test('DROP COLUMN removes data and rejects later reference', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(a INT, b INT, c INT)');
        await db.execute('INSERT INTO t VALUES(1,2,3)');
        await db.execute('ALTER TABLE t DROP COLUMN b');
        final r = await db.execute('SELECT * FROM t');
        expect(r.rows.first, [1, 3]);
        expect(() => db.execute('SELECT b FROM t'), throwsA(anything));
      } finally {
        await db.close();
      }
    });
  });

  group('Generated columns', () {
    test('INSERT cannot supply value for generated column', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t(a INT, b INT GENERATED ALWAYS AS (a+1))');
        await db.execute('INSERT INTO t(a) VALUES(5)');
        final r = await db.execute('SELECT a, b FROM t');
        expect(r.rows.first, [5, 6]);
        expect(() => db.execute('INSERT INTO t(a,b) VALUES(1, 99)'),
            throwsA(anything));
      } finally {
        await db.close();
      }
    });

    test('UPDATE cannot assign to generated column', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t(a INT, b INT GENERATED ALWAYS AS (a+1))');
        await db.execute('INSERT INTO t(a) VALUES(2)');
        expect(() => db.execute('UPDATE t SET b=99'), throwsA(anything));
        await db.execute('UPDATE t SET a=10');
        final r = await db.execute('SELECT a, b FROM t');
        expect(r.rows.first, [10, 11]);
      } finally {
        await db.close();
      }
    });
  });

  group('Recursive trigger depth', () {
    test('runaway recursion is aborted by max_trigger_depth', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(n INT)');
        await db.execute('PRAGMA max_trigger_depth = 8');
        await db.execute(
            'CREATE TRIGGER tr AFTER INSERT ON t BEGIN '
            'INSERT INTO t VALUES(NEW.n + 1); END');
        expect(() => db.execute('INSERT INTO t VALUES(1)'),
            throwsA(anything));
      } finally {
        await db.close();
      }
    });

    test('PRAGMA recursive_triggers = 0 blocks re-entry', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(n INT)');
        await db.execute('PRAGMA recursive_triggers = 0');
        await db.execute(
            'CREATE TRIGGER tr AFTER INSERT ON t BEGIN '
            'INSERT INTO t VALUES(NEW.n + 1); END');
        await db.execute('INSERT INTO t VALUES(1)');
        // Initial row + one trigger insert; no further recursion.
        final r = await db.execute('SELECT count(*) FROM t');
        expect(r.rows.first[0], 2);
      } finally {
        await db.close();
      }
    });
  });

  group('Newly recognised PRAGMAs', () {
    test('optimize completes', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA optimize');
        expect(r.message, contains('optimize'));
      } finally {
        await db.close();
      }
    });

    test('vdbe_listing returns column shape', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA vdbe_listing');
        expect(r.columns, contains('opcode'));
      } finally {
        await db.close();
      }
    });

    test('max_trigger_depth getter and setter', () async {
      final db = await Database.open();
      try {
        await db.execute('PRAGMA max_trigger_depth = 42');
        final r = await db.execute('PRAGMA max_trigger_depth');
        expect(r.rows.first[0], 42);
      } finally {
        await db.close();
      }
    });

    test('wal2_checkpoint returns three-column row', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('PRAGMA wal2_checkpoint');
        expect(r.columns, ['busy', 'log', 'checkpointed']);
        expect(r.rows.first, [0, 0, 0]);
      } finally {
        await db.close();
      }
    });
  });

  group('sqlite_stmt / sqlite_dbpage', () {
    test('sqlite_stmt is queryable and empty', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT count(*) FROM sqlite_stmt');
        expect(r.rows.first[0], 0);
      } finally {
        await db.close();
      }
    });

    test('sqlite_dbpage is queryable', () async {
      final db = await Database.open();
      try {
        final r = await db.execute('SELECT count(*) FROM sqlite_dbpage');
        expect(r.rows.first[0], greaterThanOrEqualTo(0));
      } finally {
        await db.close();
      }
    });
  });
}
