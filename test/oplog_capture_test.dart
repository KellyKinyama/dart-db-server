library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oplog.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_oplogcap_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

Future<List<OpLogRecord>> _dump(Database db) =>
    db.opLog!.readFrom(0).toList();

void main() {
  group('op-log capture', () {
    test('disabled by default — no op-log', () async {
      final db = await Database.open(_tmp('off'));
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await db.execute('INSERT INTO t VALUES (1)');
        expect(db.opLog, isNull);
      } finally {
        await db.close();
      }
    });

    test('auto-commit mutations are each appended', () async {
      final db = await Database.open(_tmp('auto'));
      await db.enableOpLog();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT)');
        await db.execute("INSERT INTO t VALUES (1,'a')");
        await db.execute("UPDATE t SET n='b' WHERE id=1");
        await db.execute('SELECT * FROM t'); // read: not logged
        final recs = await _dump(db);
        expect(recs.length, 3);
        expect(recs[0].ops.single, contains('CREATE TABLE'));
        expect(recs[1].ops.single, contains('INSERT INTO t'));
        expect(recs[2].ops.single, contains('UPDATE t'));
        expect(recs.map((r) => r.lsn), [1, 2, 3]);
      } finally {
        await db.close();
      }
    });

    test('an explicit transaction is one record; rollback discards', () async {
      final db = await Database.open(_tmp('txn'));
      await db.enableOpLog();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await db.execute('BEGIN');
        await db.execute('INSERT INTO t VALUES (1)');
        await db.execute('INSERT INTO t VALUES (2)');
        await db.execute('COMMIT');

        await db.execute('BEGIN');
        await db.execute('INSERT INTO t VALUES (3)');
        await db.execute('ROLLBACK');

        final recs = await _dump(db);
        // record 1: CREATE TABLE (auto); record 2: the committed txn (2 ops).
        expect(recs.length, 2);
        expect(recs[1].ops.length, 2);
        expect(recs[1].ops[0], contains('VALUES (1)'));
        expect(recs[1].ops[1], contains('VALUES (2)'));
        // The rolled-back INSERT (3) never reaches the log.
        expect(recs.any((r) => r.ops.any((o) => o.contains('VALUES (3)'))),
            isFalse);
      } finally {
        await db.close();
      }
    });

    test('op-log survives reopen and keeps advancing LSNs', () async {
      final path = _tmp('reopen');
      var db = await Database.open(path);
      await db.enableOpLog();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await db.execute('INSERT INTO t VALUES (1)');
      } finally {
        await db.close();
      }
      db = await Database.open(path);
      await db.enableOpLog();
      try {
        expect(db.opLog!.lastLsn, 2);
        await db.execute('INSERT INTO t VALUES (2)');
        expect(db.opLog!.lastLsn, 3);
        final recs = await _dump(db);
        expect(recs.map((r) => r.lsn), [1, 2, 3]);
      } finally {
        await db.close();
      }
    });
  });
}
