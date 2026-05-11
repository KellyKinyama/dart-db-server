/// Views round-trip through JSON persistence: CREATE VIEW, close, reopen,
/// view still works.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

File _tmpJson(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_view_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');

void main() {
  group('View persistence', () {
    test('view survives a save/reload cycle on JSON storage', () async {
      final f = _tmpJson('basic');
      addTearDown(() async {
        if (await f.exists()) await f.delete();
      });
      var db = await Database.open(f.path);
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY, n INTEGER, name TEXT)');
      await db.execute("INSERT INTO t VALUES (1,10,'a'),(2,20,'b'),(3,30,'c')");
      await db.execute('CREATE VIEW big AS SELECT id, n FROM t WHERE n >= 20');
      await db.close();

      // Reopen — the view must come back.
      db = await Database.open(f.path);
      addTearDown(db.close);
      final res = await db.execute('SELECT id, n FROM big ORDER BY id');
      expect(res.rows, [
        [2, 20],
        [3, 30],
      ]);
    });

    test('dropped view is not resurrected on reload', () async {
      final f = _tmpJson('drop');
      addTearDown(() async {
        if (await f.exists()) await f.delete();
      });
      var db = await Database.open(f.path);
      await db.execute('CREATE TABLE t(id INTEGER)');
      await db.execute('CREATE VIEW v AS SELECT id FROM t');
      await db.execute('DROP VIEW v');
      // Touch the file at least once.
      await db.execute('INSERT INTO t VALUES (1)');
      await db.close();

      db = await Database.open(f.path);
      addTearDown(db.close);
      Object? err;
      try {
        await db.execute('SELECT * FROM v');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull, reason: 'view v should not exist after reload');
    });
  });
}
