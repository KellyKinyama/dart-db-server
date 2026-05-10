import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('B STRICT tables', () {
    test('STRICT INTEGER rejects non-integer string', () async {
      await db.execute('CREATE TABLE s(a INTEGER) STRICT');
      await db.execute('INSERT INTO s VALUES (1)');
      expect(
        () => db.execute("INSERT INTO s VALUES ('hi')"),
        throwsA(isA<FormatException>()),
      );
    });

    test('STRICT TEXT rejects integer', () async {
      await db.execute('CREATE TABLE s(a TEXT) STRICT');
      await db.execute("INSERT INTO s VALUES ('ok')");
      expect(
        () => db.execute('INSERT INTO s VALUES (5)'),
        throwsA(isA<FormatException>()),
      );
    });

    test('Non-strict table still coerces', () async {
      await db.execute('CREATE TABLE s(a INTEGER)');
      await db.execute("INSERT INTO s VALUES ('42')");
      final r = await db.execute('SELECT a FROM s');
      expect(r.rows.first.first, 42);
    });

    test('STRICT rejects unsupported declared types', () async {
      // VARCHAR is not a STRICT-allowed type name in SQLite.
      expect(
        () => db.execute('CREATE TABLE s(a VARCHAR(10)) STRICT'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => db.execute('CREATE TABLE s(a NUMERIC) STRICT'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => db.execute('CREATE TABLE s(a BIGINT) STRICT'),
        throwsA(isA<FormatException>()),
      );
    });

    test('STRICT INT alias is accepted', () async {
      await db.execute('CREATE TABLE s(a INT) STRICT');
      await db.execute('INSERT INTO s VALUES (7)');
      final r = await db.execute('SELECT a FROM s');
      expect(r.rows.first.first, 7);
    });

    test('STRICT ANY accepts anything without coercion', () async {
      await db.execute('CREATE TABLE s(a ANY) STRICT');
      await db.execute('INSERT INTO s VALUES (1)');
      await db.execute("INSERT INTO s VALUES ('hi')");
      await db.execute('INSERT INTO s VALUES (3.14)');
      final r = await db.execute('SELECT a FROM s');
      expect(r.rows.map((r) => r.first).toList(), [1, 'hi', 3.14]);
    });

    test('STRICT INTEGER accepts integer-valued REAL (1.0 -> 1)', () async {
      await db.execute('CREATE TABLE s(a INTEGER) STRICT');
      await db.execute('INSERT INTO s VALUES (1.0)');
      final r = await db.execute('SELECT a FROM s');
      expect(r.rows.first.first, 1);
    });

    test('STRICT REAL rejects strings', () async {
      await db.execute('CREATE TABLE s(a REAL) STRICT');
      expect(
        () => db.execute("INSERT INTO s VALUES ('1.5')"),
        throwsA(isA<FormatException>()),
      );
    });

    test('STRICT BLOB rejects non-blob', () async {
      await db.execute('CREATE TABLE s(a BLOB) STRICT');
      expect(
        () => db.execute("INSERT INTO s VALUES ('abc')"),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('NUMERIC affinity', () {
    test('integer literal stored as INTEGER', () async {
      await db.execute('CREATE TABLE n(a NUMERIC)');
      await db.execute('INSERT INTO n VALUES (5)');
      final r = await db.execute('SELECT a, typeof(a) FROM n');
      expect(r.rows.first[0], 5);
      expect(r.rows.first[1], 'integer');
    });

    test("text '5' becomes integer 5", () async {
      await db.execute('CREATE TABLE n(a NUMERIC)');
      await db.execute("INSERT INTO n VALUES ('5')");
      final r = await db.execute('SELECT a, typeof(a) FROM n');
      expect(r.rows.first[0], 5);
      expect(r.rows.first[1], 'integer');
    });

    test("text '5.5' becomes real 5.5", () async {
      await db.execute('CREATE TABLE n(a NUMERIC)');
      await db.execute("INSERT INTO n VALUES ('5.5')");
      final r = await db.execute('SELECT a, typeof(a) FROM n');
      expect(r.rows.first[0], 5.5);
      expect(r.rows.first[1], 'real');
    });

    test("non-numeric text 'hello' stays text", () async {
      await db.execute('CREATE TABLE n(a NUMERIC)');
      await db.execute("INSERT INTO n VALUES ('hello')");
      final r = await db.execute('SELECT a, typeof(a) FROM n');
      expect(r.rows.first[0], 'hello');
      expect(r.rows.first[1], 'text');
    });

    test('integer-valued REAL collapses to INTEGER (1.0 -> 1)', () async {
      await db.execute('CREATE TABLE n(a NUMERIC)');
      await db.execute('INSERT INTO n VALUES (1.0)');
      final r = await db.execute('SELECT a, typeof(a) FROM n');
      expect(r.rows.first[0], 1);
      expect(r.rows.first[1], 'integer');
    });
  });

  group('SQLite affinity rules', () {
    test('VARCHAR(10) -> TEXT affinity (coerces non-strict)', () async {
      await db.execute('CREATE TABLE t(a VARCHAR(10))');
      await db.execute('INSERT INTO t VALUES (42)');
      final r = await db.execute('SELECT a, typeof(a) FROM t');
      expect(r.rows.first[0], '42');
      expect(r.rows.first[1], 'text');
    });

    test('BIGINT -> INTEGER affinity', () async {
      await db.execute('CREATE TABLE t(a BIGINT)');
      await db.execute("INSERT INTO t VALUES ('99')");
      final r = await db.execute('SELECT a, typeof(a) FROM t');
      expect(r.rows.first[0], 99);
      expect(r.rows.first[1], 'integer');
    });

    test('DOUBLE -> REAL affinity', () async {
      await db.execute('CREATE TABLE t(a DOUBLE)');
      await db.execute("INSERT INTO t VALUES ('2.5')");
      final r = await db.execute('SELECT a, typeof(a) FROM t');
      expect(r.rows.first[0], 2.5);
      expect(r.rows.first[1], 'real');
    });

    test('Unknown declared type -> NUMERIC affinity', () async {
      await db.execute('CREATE TABLE t(a FOOBAR)');
      await db.execute("INSERT INTO t VALUES ('7')");
      final r = await db.execute('SELECT a, typeof(a) FROM t');
      expect(r.rows.first[0], 7);
      expect(r.rows.first[1], 'integer');
    });
  });
}
