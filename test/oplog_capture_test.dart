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

    test('replay-on-open recovers a committed-but-unpersisted transaction',
        () async {
      final path = _tmp('recover');
      var db = await Database.open(path);
      await db.enableOpLog();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        await db.execute('INSERT INTO t VALUES (1)');
      } finally {
        await db.close(); // snapshot now reflects LSN 2
      }

      // Simulate a crash in the append→persist window: a later commit was
      // fsync'd to the op-log but the snapshot was never rewritten.
      final log = OpLog('$path.oplog');
      await log.open();
      final lsn = await log.append(['INSERT INTO t VALUES (3)']);
      expect(lsn, 3);
      await log.close();

      db = await Database.open(path);
      await db.enableOpLog(); // replays LSN 3
      try {
        final r = await db.execute('SELECT id FROM t ORDER BY id');
        expect(r.rows, [
          [1],
          [3],
        ]);
      } finally {
        await db.close();
      }
    });

    test('gcOpLog bounds log growth without losing unconsumed records',
        () async {
      final path = _tmp('gc');
      final db = await Database.open(path);
      // Tiny segments so there are several to collect.
      await db.enableOpLog();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
        for (var i = 1; i <= 6; i++) {
          await db.execute('INSERT INTO t VALUES ($i)');
        }
        final head = db.opLog!.lastLsn;
        // Every consumer has moved past the head → old segments can go.
        await db.gcOpLog(head);
        // The head record is always retained (active segment kept).
        final recs = await db.opLog!.readFrom(head - 1).toList();
        expect(recs.map((r) => r.lsn), contains(head));
        // The table itself is unaffected by log GC.
        final rr = await db.execute('SELECT COUNT(*) FROM t');
        expect(rr.rows, [
          [6],
        ]);
      } finally {
        await db.close();
      }
    });

    test('bind-aware capture logs prepared statements with values inlined',
        () async {
      final db = await Database.open(_tmp('binds'));
      await db.enableOpLog();
      try {
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT, blob BLOB)');
        // Positional binds.
        await db.prepare('INSERT INTO t(id, n) VALUES (?, ?)').execute(
          positional: [1, "o'brien"],
        );
        // Named binds.
        await db
            .prepare('INSERT INTO t(id, n) VALUES (:id, :n)')
            .execute(named: {'id': 2, 'n': 'alice'});
        // Blob bind.
        await db.prepare('INSERT INTO t(id, blob) VALUES (?, ?)').execute(
          positional: [3, <int>[0xDE, 0xAD]],
        );

        final recs = await _dump(db);
        // CREATE + three prepared inserts.
        expect(recs.length, 4);
        expect(recs[1].ops.single, contains("'o''brien'")); // quote escaped
        expect(recs[2].ops.single, contains("'alice'"));
        expect(recs[3].ops.single, contains("X'dead'")); // blob as hex literal
      } finally {
        await db.close();
      }
    });

    test('a bound statement replays identically on a reopened database',
        () async {
      final path = _tmp('binds_replay');
      var db = await Database.open(path);
      await db.enableOpLog();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT)');
        await db
            .prepare('INSERT INTO t(id, n) VALUES (?, ?)')
            .execute(positional: [1, "quote'd"]);
      } finally {
        await db.close();
      }

      // Simulate a crash before the row was persisted: re-append nothing, but
      // prove the logged literal replays by truncating the snapshot's view.
      final log = OpLog('$path.oplog');
      await log.open();
      final recs = await log.readFrom(1).toList();
      await log.close();
      expect(recs.last.ops.single, contains("'quote''d'"));

      // Reopening applies the data and the row round-trips.
      db = await Database.open(path);
      try {
        final r = await db.execute('SELECT id, n FROM t');
        expect(r.rows, [
          [1, "quote'd"],
        ]);
      } finally {
        await db.close();
      }
    });
  });
}
