/// Tests for the pure-Dart SQLite file-format reader/writer.
///
/// Two layers:
///   * Pure-Dart unit tests on the reader/writer that round-trip values
///     without involving any native SQLite library.
///   * Cross-engine tests that hand the writer's output to
///     `package:sqlite3` (the real engine) and assert the rows come back
///     unchanged, and conversely read fixtures produced by SQLite.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmpDb(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_fmt_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

void main() {
  group('SqliteFile round-trip (pure Dart)', () {
    test('writer + reader preserves a small table', () {
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 't',
          createSql: 'CREATE TABLE t(a INTEGER, b TEXT, c REAL, d BLOB)',
          rows: [
            [
              1,
              'hello',
              3.14,
              Uint8List.fromList([0x01, 0x02, 0xff])
            ],
            [
              2,
              'world',
              2.71,
              Uint8List.fromList([0xca, 0xfe, 0xba, 0xbe])
            ],
            [-1234567890, 'neg', -1.5, null],
            [null, null, null, null],
          ],
        ),
      ]);
      final f = SqliteFile.fromBytes(bytes);
      expect(f.header.pageSize, 4096);
      expect(f.header.textEncoding, 1);
      final schema = f.readSchema();
      expect(schema.length, 1);
      expect(schema.first.type, 'table');
      expect(schema.first.name, 't');
      expect(schema.first.rootPage, 2);
      final rows = f.readTable('t');
      expect(rows.length, 4);
      expect(rows[0].rowid, 1);
      expect(rows[0].values[0], 1);
      expect(rows[0].values[1], 'hello');
      expect(rows[0].values[2], closeTo(3.14, 1e-9));
      expect((rows[0].values[3] as Uint8List).toList(), [0x01, 0x02, 0xff]);
      expect(rows[3].values, [null, null, null, null]);
    });

    test('writer + reader handles two tables', () {
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 'a',
          createSql: 'CREATE TABLE a(x INTEGER)',
          rows: [
            [10],
            [20]
          ],
        ),
        SqliteWriteTable(
          name: 'b',
          createSql: 'CREATE TABLE b(name TEXT)',
          rows: [
            ['alice'],
            ['bob'],
            ['carol']
          ],
        ),
      ]);
      final f = SqliteFile.fromBytes(bytes);
      expect(f.readTable('a').map((r) => r.values[0]).toList(), [10, 20]);
      expect(
        f.readTable('b').map((r) => r.values[0]).toList(),
        ['alice', 'bob', 'carol'],
      );
    });

    test('rejects non-SQLite input', () {
      expect(
        () => SqliteFile.fromBytes(Uint8List(200)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SqliteFile <-> package:sqlite3 parity', () {
    final skip = sqliteSkipReason();

    test('SQLite can read what we wrote', () async {
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 'people',
          createSql: 'CREATE TABLE people(id INTEGER, name TEXT, age INTEGER)',
          rows: [
            [1, 'alice', 30],
            [2, 'bob', 25],
            [3, 'carol', 42],
          ],
        ),
      ]);
      final f = _tmpDb('written');
      await f.writeAsBytes(bytes);
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        final r = ref.select('SELECT id, name, age FROM people ORDER BY id');
        expect(r.rows, [
          [1, 'alice', 30],
          [2, 'bob', 25],
          [3, 'carol', 42],
        ]);
      } finally {
        ref.dispose();
      }
    }, skip: skip);

    test('SQLite can read a multi-table file we wrote', () async {
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 'a',
          createSql: 'CREATE TABLE a(x INTEGER, y REAL)',
          rows: [
            [1, 1.5],
            [2, 2.5]
          ],
        ),
        SqliteWriteTable(
          name: 'b',
          createSql: 'CREATE TABLE b(s TEXT)',
          rows: [
            ['one'],
            ['two'],
            ['three']
          ],
        ),
      ]);
      final f = _tmpDb('multi');
      await f.writeAsBytes(bytes);
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        expect(
          ref.select('SELECT x, y FROM a ORDER BY x').rows,
          [
            [1, 1.5],
            [2, 2.5]
          ],
        );
        expect(
          ref.select('SELECT s FROM b ORDER BY rowid').rows.map((r) => r[0]),
          ['one', 'two', 'three'],
        );
      } finally {
        ref.dispose();
      }
    }, skip: skip);

    test('we can read what SQLite wrote', () async {
      final f = _tmpDb('readback');
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(a INTEGER, b TEXT, c REAL)');
        ref.execute("INSERT INTO t VALUES (1, 'hi', 1.5)");
        ref.execute("INSERT INTO t VALUES (2, 'bye', 2.5)");
        ref.execute("INSERT INTO t VALUES (-100, NULL, -3.14)");
      } finally {
        ref.dispose();
      }
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final fp = SqliteFile.fromBytes(bytes);
      final rows = fp.readTable('t');
      expect(rows.length, 3);
      expect(rows[0].values, [1, 'hi', 1.5]);
      expect(rows[1].values, [2, 'bye', 2.5]);
      expect(rows[2].values[0], -100);
      expect(rows[2].values[1], isNull);
      expect(rows[2].values[2], closeTo(-3.14, 1e-9));
    }, skip: skip);

    test('we can read SQLite schema rows', () async {
      final f = _tmpDb('schema');
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE foo(a INTEGER)');
        ref.execute('CREATE TABLE bar(b TEXT)');
        ref.execute("INSERT INTO foo VALUES (1)");
        ref.execute("INSERT INTO bar VALUES ('x')");
      } finally {
        ref.dispose();
      }
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final fp = SqliteFile.fromBytes(bytes);
      final names = fp
          .readSchema()
          .where((r) => r.type == 'table')
          .map((r) => r.name)
          .toList();
      expect(names, containsAll(['foo', 'bar']));
    }, skip: skip);
  });
}
