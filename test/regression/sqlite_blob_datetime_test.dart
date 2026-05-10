/// Cross-engine parity tests for BLOB and DATE/TIME against `package:sqlite3`.
///
/// Skipped automatically when the native sqlite3 shared library isn't
/// available on the host.
library;

import 'package:test/test.dart';

import 'sqlite_oracle.dart';

void main() {
  final skip = sqliteSkipReason();

  group('SQLite parity (BLOB)', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
    });
    tearDown(() => o.close());

    test('X\'..\' literal stores and reads as identical bytes', () async {
      await o.exec('CREATE TABLE b (id INTEGER, data BLOB)');
      await o.exec("INSERT INTO b VALUES (1, X'cafebabe'), (2, X'00ff7f80')");
      await o.expectSameRows('SELECT id, data FROM b ORDER BY id');
    });

    test('LENGTH(blob) returns byte count on both engines', () async {
      await o.exec('CREATE TABLE b (data BLOB)');
      await o.exec("INSERT INTO b VALUES (X''), (X'cafe'), (X'01020304')");
      await o
          .expectSameRows('SELECT LENGTH(data) FROM b ORDER BY LENGTH(data)');
    });

    test('TYPEOF reports "blob" on both engines', () async {
      await o.expectSameResult("SELECT TYPEOF(X'00ff') AS t");
    });
  }, skip: skip);

  group('SQLite parity (DATE/TIME)', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
    });
    tearDown(() => o.close());

    test('DATE / TIME / DATETIME on a literal', () async {
      await o.expectSameResult("SELECT DATE('2024-03-15 10:20:30') AS d, "
          "TIME('2024-03-15 10:20:30') AS t, "
          "DATETIME('2024-03-15 10:20:30') AS dt");
    });

    test('STRFTIME basic format codes', () async {
      await o.expectSameResult(
          "SELECT STRFTIME('%Y/%m/%d %H:%M:%S', '2024-03-15 10:20:30') AS s");
    });

    test('JULIANDAY of the Unix epoch', () async {
      await o.expectSameResult("SELECT JULIANDAY('1970-01-01 00:00:00') AS j");
    });

    test('UNIXEPOCH of the Unix epoch', () async {
      await o.expectSameResult("SELECT UNIXEPOCH('1970-01-01 00:00:00') AS u");
    });

    test('Modifier: +N days', () async {
      await o.expectSameResult("SELECT DATE('2024-03-15', '+10 days') AS d1, "
          "DATE('2024-03-15', '-15 days') AS d2");
    });

    test('Modifier: start of month / start of year', () async {
      await o
          .expectSameResult("SELECT DATE('2024-03-15', 'start of month') AS m, "
              "DATE('2024-03-15', 'start of year') AS y");
    });

    test('Modifier: +N months wraps year', () async {
      await o.expectSameResult("SELECT DATE('2024-11-15', '+3 months') AS d");
    });

    test('unixepoch modifier on a numeric arg', () async {
      await o.expectSameResult("SELECT DATETIME(0, 'unixepoch') AS dt");
    });

    test('DATE/TIME stored in TEXT columns and ordered chronologically',
        () async {
      await o.exec('CREATE TABLE evt (id INTEGER, ts TEXT)');
      await o.exec("INSERT INTO evt VALUES "
          "(1, '2024-03-15 10:00:00'), "
          "(2, '2024-03-15 09:00:00'), "
          "(3, '2024-03-14 23:59:59')");
      await o.expectSameRows('SELECT id FROM evt ORDER BY ts');
      await o.expectSameRows(
          "SELECT id FROM evt WHERE ts < '2024-03-15 10:00:00' ORDER BY id");
    });
  }, skip: skip);
}
