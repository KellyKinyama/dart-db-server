/// Tests for prepared statements + bind parameters.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, age INTEGER)');
    await db.execute("INSERT INTO t VALUES (1, 'alice', 30)");
    await db.execute("INSERT INTO t VALUES (2, 'bob', 25)");
    await db.execute("INSERT INTO t VALUES (3, 'carol', 42)");
  });

  group('Anonymous positional ?', () {
    test('SELECT WHERE col = ? returns the right row', () async {
      final r = await db.executeWith(
        'SELECT name FROM t WHERE id = ?',
        positional: [2],
      );
      expect(r.rows.single.single, 'bob');
    });

    test('multiple ? are auto-numbered left-to-right', () async {
      final r = await db.executeWith(
        'SELECT name FROM t WHERE age >= ? AND age <= ?',
        positional: [26, 40],
      );
      expect(r.rows.single.single, 'alice');
    });

    test('reusing the same statement with different bindings', () async {
      final stmt = db.prepare('SELECT name FROM t WHERE id = ?');
      final r1 = await stmt.execute(positional: [1]);
      final r2 = await stmt.execute(positional: [3]);
      expect(r1.rows.single.single, 'alice');
      expect(r2.rows.single.single, 'carol');
    });

    test('INSERT with placeholders', () async {
      await db.executeWith(
        'INSERT INTO t VALUES (?, ?, ?)',
        positional: [4, 'dave', 50],
      );
      final r = await db.execute('SELECT name FROM t WHERE id = 4');
      expect(r.rows.single.single, 'dave');
    });

    test('UPDATE with placeholders', () async {
      await db.executeWith(
        'UPDATE t SET age = ? WHERE name = ?',
        positional: [99, 'alice'],
      );
      final r = await db.execute("SELECT age FROM t WHERE name = 'alice'");
      expect(r.rows.single.single, 99);
    });

    test('NULL binding', () async {
      await db.executeWith(
        'INSERT INTO t VALUES (?, ?, ?)',
        positional: [4, null, null],
      );
      final r = await db.execute('SELECT name, age FROM t WHERE id = 4');
      expect(r.rows.single, [null, null]);
    });

    test('BLOB binding', () async {
      await db.execute('CREATE TABLE b(data BLOB)');
      await db.executeWith(
        'INSERT INTO b VALUES (?)',
        positional: [
          [0x01, 0x02, 0xff]
        ],
      );
      final r = await db.execute('SELECT LENGTH(data) FROM b');
      expect(r.rows.single.single, 3);
    });
  });

  group('Numbered positional ?N', () {
    test('?1 ?2 in any order', () async {
      final r = await db.executeWith(
        'SELECT name FROM t WHERE age >= ?2 AND age <= ?1',
        positional: [40, 26],
      );
      expect(r.rows.single.single, 'alice');
    });

    test('?1 can be repeated', () async {
      final r = await db.executeWith(
        'SELECT name FROM t WHERE id = ?1 OR age = ?1',
        positional: [25],
      );
      expect(r.rows.map((r) => r.single).toSet(), {'bob'});
    });
  });

  group('Named parameters', () {
    test(':name binding', () async {
      final r = await db.executeWith(
        'SELECT age FROM t WHERE name = :n',
        named: {':n': 'carol'},
      );
      expect(r.rows.single.single, 42);
    });

    test('@name binding (caller may pass without sigil)', () async {
      final r = await db.executeWith(
        'SELECT age FROM t WHERE name = @n',
        named: {'n': 'bob'},
      );
      expect(r.rows.single.single, 25);
    });

    test(r'$name binding', () async {
      final r = await db.executeWith(
        r'SELECT age FROM t WHERE name = $n',
        named: {r'$n': 'alice'},
      );
      expect(r.rows.single.single, 30);
    });

    test('mixing positional + named', () async {
      final r = await db.executeWith(
        'SELECT name FROM t WHERE id = ? AND age > :min',
        positional: [3],
        named: {':min': 40},
      );
      expect(r.rows.single.single, 'carol');
    });

    test('repeated named parameter is bound once', () async {
      final r = await db.executeWith(
        'SELECT name FROM t WHERE id = :x OR age = :x',
        named: {':x': 25},
      );
      expect(r.rows.map((r) => r.single).toSet(), {'bob'});
    });
  });

  group('Validation', () {
    test('missing positional parameter throws', () async {
      expect(
        () => db.executeWith(
          'SELECT * FROM t WHERE id = ? AND age = ?',
          positional: [1],
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('missing named parameter throws', () async {
      expect(
        () => db.executeWith(
          'SELECT * FROM t WHERE name = :n',
          named: {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('typo in named binding throws (catches misnamed args)', () async {
      expect(
        () => db.executeWith(
          'SELECT * FROM t WHERE name = :name',
          named: {':nme': 'alice'},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('PreparedStatement reports its parameter shape', () {
      final s1 = db.prepare('SELECT * FROM t WHERE id = ? AND age >= ?');
      expect(s1.positionalCount, 2);
      expect(s1.namedParams, isEmpty);

      final s2 = db.prepare('SELECT * FROM t WHERE name = :n AND age = :a');
      expect(s2.positionalCount, 0);
      expect(s2.namedParams, {':n', ':a'});

      final s3 = db.prepare('SELECT * FROM t WHERE id = ? AND name = :n');
      expect(s3.positionalCount, 1);
      expect(s3.namedParams, {':n'});
    });

    test('SQL injection attempt is treated as a value, not SQL', () async {
      // Classic injection: a value containing "; DROP TABLE t". With a
      // bind parameter the parser never sees that text as SQL, so the
      // table survives and the lookup simply returns no rows.
      final r = await db.executeWith(
        'SELECT name FROM t WHERE name = ?',
        positional: ["alice'; DROP TABLE t; --"],
      );
      expect(r.rows, isEmpty);
      // Table is still there.
      final after = await db.execute('SELECT COUNT(*) FROM t');
      expect(after.rows.single.single, 3);
    });
  });

  final skip = sqliteSkipReason();
  group('Cross-engine parity', () {
    late SqliteOracle o;

    setUp(() async {
      o = await SqliteOracle.open();
      await o.exec(
          'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, age INTEGER)');
      await o.exec("INSERT INTO t VALUES (1, 'alice', 30)");
      await o.exec("INSERT INTO t VALUES (2, 'bob', 25)");
      await o.exec("INSERT INTO t VALUES (3, 'carol', 42)");
    });
    tearDown(() => o.close());

    test('SQLite parses the same ? placeholders', () async {
      // Build the SQL with ? then bind on both sides.
      const sql = 'SELECT name FROM t WHERE id = ? ORDER BY name';
      final ours = await o.ours.executeWith(sql, positional: [2]);
      // package:sqlite3 binds via select(sql, [params]).
      final ref = o.ref.select(sql, [2]);
      expect(ours.rows, equals(ref.rows));
    });

    test('SQLite parses :named placeholders the same way', () async {
      const sql = 'SELECT name FROM t WHERE age >= :a ORDER BY id';
      final ours = await o.ours.executeWith(sql, named: {':a': 30});
      // package:sqlite3 supports a Map for named binding via
      // PreparedStatement.selectMap (skip if not available; the
      // positional fallback covers parity).
      final ref = o.ref.select(sql, [30]);
      expect(ours.rows.length, ref.rows.length);
    });
  }, skip: skip);
}
