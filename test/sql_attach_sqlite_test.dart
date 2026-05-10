/// ATTACH DATABASE pointed at a real SQLite file (auto-detected).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmpSqlite(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_attach_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

File _tmpJson(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_attach_host_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');

void main() {
  final skipReason = sqliteSkipReason();

  group('ATTACH SQLite file', () {
    test('attach reads tables from a real SQLite file under the alias',
        () async {
      final src = _tmpSqlite('basic');
      addTearDown(() async {
        for (final ext in ['', '-wal', '-shm', '-journal']) {
          final ff = File('${src.path}$ext');
          if (await ff.exists()) await ff.delete();
        }
      });
      // Build a real SQLite file via the oracle.
      final ora = sq.sqlite3.open(src.path);
      ora.execute('CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT);');
      ora.execute("INSERT INTO people VALUES (1,'a'),(2,'b'),(3,'c');");
      ora.execute(
          'CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT NOT NULL);');
      ora.execute("INSERT INTO notes VALUES (10,'hi'),(20,'there');");
      ora.dispose();

      final host = _tmpJson('basic');
      addTearDown(() async {
        if (await host.exists()) await host.delete();
      });
      final db = await Database.open(host.path);
      addTearDown(db.close);
      await db.execute("ATTACH DATABASE '${src.path}' AS ext");
      final r1 =
          await db.execute('SELECT id, name FROM ext.people ORDER BY id');
      expect(r1.rows, [
        [1, 'a'],
        [2, 'b'],
        [3, 'c'],
      ]);
      final r2 = await db.execute('SELECT body FROM ext.notes ORDER BY id');
      expect(r2.rows, [
        ['hi'],
        ['there'],
      ]);
    }, skip: skipReason);

    test('detach removes namespaced tables', () async {
      final src = _tmpSqlite('detach');
      addTearDown(() async {
        for (final ext in ['', '-wal', '-shm', '-journal']) {
          final ff = File('${src.path}$ext');
          if (await ff.exists()) await ff.delete();
        }
      });
      final ora = sq.sqlite3.open(src.path);
      ora.execute('CREATE TABLE k(v INTEGER);');
      ora.execute('INSERT INTO k VALUES (7);');
      ora.dispose();

      final host = _tmpJson('detach');
      addTearDown(() async {
        if (await host.exists()) await host.delete();
      });
      final db = await Database.open(host.path);
      addTearDown(db.close);
      await db.execute("ATTACH DATABASE '${src.path}' AS x");
      var r = await db.execute('SELECT v FROM x.k');
      expect(r.rows, [
        [7]
      ]);
      await db.execute('DETACH DATABASE x');
      // After detaching, the table must be gone.
      Object? err;
      try {
        await db.execute('SELECT v FROM x.k');
      } catch (e) {
        err = e;
      }
      expect(err, isNotNull);
    }, skip: skipReason);
  });
}
