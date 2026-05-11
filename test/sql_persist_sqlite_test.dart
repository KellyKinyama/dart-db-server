/// Round-trip persistence: opening a `.sqlite` file then mutating must
/// rewrite the file in SQLite format (not JSON).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_persist_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

void main() {
  final skipReason = sqliteSkipReason();

  group('SQLite persistence round-trip', () {
    test('opening an existing .sqlite file persists back as SQLite', () async {
      final f = _tmp('existing');
      addTearDown(() => _cleanup(f));
      // Seed via the oracle.
      final ora = sq.sqlite3.open(f.path);
      ora.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);');
      ora.execute("INSERT INTO t VALUES (1,'a'),(2,'b');");
      ora.dispose();

      final db = await Database.open(f.path);
      await db.execute("INSERT INTO t VALUES (3,'c')");
      await db.close();

      // The file must still be a SQLite-format file (magic intact),
      // not JSON.
      final raw = await f.readAsBytes();
      expect(raw.length >= 16, isTrue);
      expect(String.fromCharCodes(raw.sublist(0, 15)), 'SQLite format 3');
      expect(raw[15], 0);

      // And SQLite itself can read the new row back.
      final ora2 = sq.sqlite3.open(f.path);
      final rows = ora2.select('SELECT id, v FROM t ORDER BY id');
      ora2.dispose();
      expect(rows.map((r) => [r['id'], r['v']]).toList(), [
        [1, 'a'],
        [2, 'b'],
        [3, 'c'],
      ]);
    }, skip: skipReason);

    test('new file with .sqlite extension is created in SQLite format',
        () async {
      final f = _tmp('new');
      addTearDown(() => _cleanup(f));
      expect(await f.exists(), isFalse);

      final db = await Database.open(f.path);
      await db.execute('CREATE TABLE k(id INTEGER PRIMARY KEY, n INTEGER)');
      await db.execute('INSERT INTO k VALUES (1, 100), (2, 200)');
      await db.close();

      final raw = await f.readAsBytes();
      expect(String.fromCharCodes(raw.sublist(0, 15)), 'SQLite format 3');

      final ora = sq.sqlite3.open(f.path);
      final rows = ora.select('SELECT id, n FROM k ORDER BY id');
      ora.dispose();
      expect(rows.map((r) => [r['id'], r['n']]).toList(), [
        [1, 100],
        [2, 200],
      ]);
    }, skip: skipReason);

    test('.json paths still persist as JSON (no behavioural change)', () async {
      final p = '${Directory.systemTemp.path}/'
          'ddb_persist_json_${DateTime.now().microsecondsSinceEpoch}.json';
      final f = File(p);
      addTearDown(() async {
        if (await f.exists()) await f.delete();
      });
      final db = await Database.open(p);
      await db.execute('CREATE TABLE x(a INTEGER)');
      await db.execute('INSERT INTO x VALUES (1)');
      await db.close();
      // Should be valid UTF-8 JSON, not SQLite magic.
      final raw = await f.readAsBytes();
      expect(raw.length >= 16, isTrue);
      expect(
          String.fromCharCodes(raw.sublist(0, 15)) == 'SQLite format 3', false);
      // First non-whitespace char is `{`.
      final txt = String.fromCharCodes(raw).trimLeft();
      expect(txt.startsWith('{'), isTrue);
    });
  });
}
