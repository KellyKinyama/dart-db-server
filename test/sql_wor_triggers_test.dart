/// Triggers fire correctly on WITHOUT ROWID tables.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

Future<Database> _newDb(String tag) async {
  final f = File('${Directory.systemTemp.path}/'
      'ddb_wortrig_${tag}_${DateTime.now().microsecondsSinceEpoch}.json');
  addTearDown(() async {
    if (await f.exists()) await f.delete();
  });
  return Database.open(f.path);
}

void main() {
  group('triggers on WITHOUT ROWID', () {
    test('AFTER INSERT trigger fires and sees NEW', () async {
      final db = await _newDb('ains');
      await db.execute('CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) '
          'WITHOUT ROWID');
      await db.execute('CREATE TABLE log(k TEXT, v INTEGER)');
      await db.execute('CREATE TRIGGER tr_ai AFTER INSERT ON t '
          'FOR EACH ROW BEGIN INSERT INTO log VALUES (NEW.k, NEW.v); END');
      await db.execute("INSERT INTO t VALUES ('a',1),('b',2)");
      final r = await db.execute('SELECT k, v FROM log ORDER BY k');
      expect(r.rows, [
        ['a', 1],
        ['b', 2],
      ]);
    });

    test('AFTER UPDATE trigger sees OLD and NEW', () async {
      final db = await _newDb('aupd');
      await db.execute('CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) '
          'WITHOUT ROWID');
      await db.execute('CREATE TABLE log(k TEXT, oldv INTEGER, newv INTEGER)');
      await db.execute('CREATE TRIGGER tr_au AFTER UPDATE ON t '
          'FOR EACH ROW BEGIN INSERT INTO log VALUES (NEW.k, OLD.v, NEW.v); END');
      await db.execute("INSERT INTO t VALUES ('a',10),('b',20)");
      await db.execute("UPDATE t SET v=v*10 WHERE k='b'");
      final r = await db.execute('SELECT k, oldv, newv FROM log');
      expect(r.rows, [
        ['b', 20, 200],
      ]);
    });

    test('AFTER DELETE trigger sees OLD', () async {
      final db = await _newDb('adel');
      await db.execute('CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) '
          'WITHOUT ROWID');
      await db.execute('CREATE TABLE log(k TEXT, v INTEGER)');
      await db.execute('CREATE TRIGGER tr_ad AFTER DELETE ON t '
          'FOR EACH ROW BEGIN INSERT INTO log VALUES (OLD.k, OLD.v); END');
      await db.execute("INSERT INTO t VALUES ('a',1),('b',2),('c',3)");
      await db.execute("DELETE FROM t WHERE v >= 2");
      final r = await db.execute('SELECT k, v FROM log ORDER BY k');
      expect(r.rows, [
        ['b', 2],
        ['c', 3],
      ]);
    });

    test('BEFORE INSERT trigger with RAISE(ABORT) blocks insert', () async {
      final db = await _newDb('bins');
      await db.execute('CREATE TABLE t(k TEXT PRIMARY KEY, v INTEGER) '
          'WITHOUT ROWID');
      await db.execute('CREATE TRIGGER guard BEFORE INSERT ON t '
          "FOR EACH ROW WHEN NEW.v < 0 "
          "BEGIN SELECT RAISE(ABORT, 'negative not allowed'); END");
      expect(() async => await db.execute("INSERT INTO t VALUES ('a',-1)"),
          throwsA(anything));
      final r = await db.execute('SELECT COUNT(*) FROM t');
      expect(r.rows.first.first, 0);
    });

    test('Composite-PK WITHOUT ROWID trigger sees full key', () async {
      final db = await _newDb('comp');
      await db.execute('CREATE TABLE t(a INTEGER, b TEXT, v INTEGER, '
          'PRIMARY KEY(a,b)) WITHOUT ROWID');
      await db.execute('CREATE TABLE log(a INTEGER, b TEXT, v INTEGER)');
      await db.execute('CREATE TRIGGER tr_ai AFTER INSERT ON t '
          'FOR EACH ROW BEGIN INSERT INTO log VALUES (NEW.a, NEW.b, NEW.v); END');
      await db.execute("INSERT INTO t VALUES (1,'x',10),(2,'y',20)");
      final r = await db.execute('SELECT a,b,v FROM log ORDER BY a');
      expect(r.rows, [
        [1, 'x', 10],
        [2, 'y', 20],
      ]);
    });
  });
}
