/// Cross-engine parity tests for STRICT tables and NUMERIC affinity.
///
/// Each test runs the same SQL on dart-db-server and on `package:sqlite3`
/// (via [SqliteOracle]), then asserts that the result rows are equal
/// after normalisation. Skipped automatically when the native sqlite3
/// shared library isn't loadable.
library;

import 'package:test/test.dart';

import 'sqlite_oracle.dart';

void main() {
  final skip = sqliteSkipReason();

  group('NUMERIC affinity vs SQLite', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
    });
    tearDown(() => o.close());

    test('text round-trip: integer-looking, real-looking, garbage', () async {
      await o.exec('CREATE TABLE n(a NUMERIC)');
      await o.exec("INSERT INTO n VALUES ('5'), ('5.5'), ('hello')");
      await o.expectSameRows('SELECT a, typeof(a) FROM n ORDER BY a');
    });

    test('integer literals stay integer', () async {
      await o.exec('CREATE TABLE n(a NUMERIC)');
      await o.exec('INSERT INTO n VALUES (1), (2), (3)');
      await o.expectSameRows('SELECT a, typeof(a) FROM n ORDER BY a');
    });

    test('1.0 collapses to integer', () async {
      await o.exec('CREATE TABLE n(a NUMERIC)');
      await o.exec('INSERT INTO n VALUES (1.0), (2.5)');
      await o.expectSameRows('SELECT a, typeof(a) FROM n ORDER BY a');
    });
  }, skip: skip);

  group('Affinity rules vs SQLite', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
    });
    tearDown(() => o.close());

    test('VARCHAR(10) coerces 42 -> "42"', () async {
      await o.exec('CREATE TABLE t(a VARCHAR(10))');
      await o.exec('INSERT INTO t VALUES (42)');
      await o.expectSameRows('SELECT a, typeof(a) FROM t');
    });

    test('BIGINT coerces "99" -> 99', () async {
      await o.exec('CREATE TABLE t(a BIGINT)');
      await o.exec("INSERT INTO t VALUES ('99')");
      await o.expectSameRows('SELECT a, typeof(a) FROM t');
    });

    test('DOUBLE coerces "2.5" -> 2.5', () async {
      await o.exec('CREATE TABLE t(a DOUBLE)');
      await o.exec("INSERT INTO t VALUES ('2.5')");
      await o.expectSameRows('SELECT a, typeof(a) FROM t');
    });
  }, skip: skip);

  group('STRICT tables vs SQLite', () {
    late SqliteOracle o;
    setUp(() async {
      o = await SqliteOracle.open();
    });
    tearDown(() => o.close());

    test('STRICT INTEGER accepts 1 and 1.0', () async {
      await o.exec('CREATE TABLE s(a INTEGER) STRICT');
      await o.exec('INSERT INTO s VALUES (1)');
      await o.exec('INSERT INTO s VALUES (1.0)');
      await o.expectSameRows('SELECT a, typeof(a) FROM s ORDER BY a');
    });

    test('STRICT TEXT accepts text values', () async {
      await o.exec('CREATE TABLE s(a TEXT) STRICT');
      await o.exec("INSERT INTO s VALUES ('ok')");
      await o.exec("INSERT INTO s VALUES ('hello')");
      await o.expectSameRows('SELECT a, typeof(a) FROM s ORDER BY a');
    });

    test('STRICT ANY column stores values verbatim', () async {
      await o.exec('CREATE TABLE s(a ANY) STRICT');
      await o.exec('INSERT INTO s VALUES (1)');
      await o.exec("INSERT INTO s VALUES ('hi')");
      await o.exec('INSERT INTO s VALUES (3.14)');
      await o
          .expectSameRows('SELECT a, typeof(a) FROM s ORDER BY typeof(a), a');
    });

    test('STRICT rejects VARCHAR/NUMERIC/BIGINT at CREATE TABLE', () async {
      // Both engines must reject these.
      await o.exec('CREATE TABLE s1(a VARCHAR(10)) STRICT');
      await o.exec('CREATE TABLE s2(a NUMERIC) STRICT');
      await o.exec('CREATE TABLE s3(a BIGINT) STRICT');
    });
  }, skip: skip);
}
