/// Unit tests for the `REINDEX` statement.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('REINDEX', () {
    test('no target: rebuilds all indexes, lookups still work', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
        await db.execute('CREATE INDEX t_k ON t(k)');
        await db.execute("INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')");
        final r = await db.execute('REINDEX');
        expect(r.message, contains('REINDEX'));
        final q = await db.execute("SELECT id FROM t WHERE k = 'b'");
        expect(q.rows, [
          [2]
        ]);
      } finally {
        await db.close();
      }
    });

    test('table target: rebuilds only that table\'s indexes', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
        await db.execute('CREATE INDEX t_k ON t(k)');
        await db.execute("INSERT INTO t VALUES (1,'a'),(2,'b')");
        final r = await db.execute('REINDEX t');
        expect(r.message, contains('t'));
      } finally {
        await db.close();
      }
    });

    test('index target: rebuilds the named index', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
        await db.execute('CREATE INDEX t_k ON t(k)');
        await db.execute("INSERT INTO t VALUES (1,'x'),(2,'y')");
        final r = await db.execute('REINDEX t_k');
        expect(r.message, contains('t_k'));
      } finally {
        await db.close();
      }
    });

    test('unknown name is treated as a no-op (like a collation name)',
        () async {
      final db = await Database.open();
      try {
        final r = await db.execute('REINDEX NOCASE');
        expect(r.message, contains('REINDEX'));
      } finally {
        await db.close();
      }
    });

    test('UNIQUE constraints remain enforced after REINDEX', () async {
      final db = await Database.open();
      try {
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT UNIQUE)');
        await db.execute("INSERT INTO t VALUES (1,'a'),(2,'b')");
        await db.execute('REINDEX t');
        expect(
          () => db.execute("INSERT INTO t VALUES (3,'a')"),
          throwsA(isA<Object>()),
        );
      } finally {
        await db.close();
      }
    });
  });
}
