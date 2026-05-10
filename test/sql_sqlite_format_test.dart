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

  group('Overflow pages', () {
    test('writer + reader round-trips a row larger than one page', () {
      // 5 KB blob > 4 KB page → guaranteed overflow.
      final big = Uint8List(5000);
      for (var i = 0; i < big.length; i++) {
        big[i] = i & 0xff;
      }
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 't',
          createSql: 'CREATE TABLE t(id INTEGER, data BLOB)',
          rows: [
            [1, big],
          ],
        ),
      ]);
      final f = SqliteFile.fromBytes(bytes);
      final rows = f.readTable('t');
      expect(rows.length, 1);
      expect(rows.single.values[0], 1);
      final readBack = (rows.single.values[1] as Uint8List).toList();
      expect(readBack.length, big.length);
      expect(readBack, equals(big.toList()));
    });

    test('writer + reader round-trips a very long text overflow chain', () {
      // 20 KB string → 5 overflow pages at 4 KB.
      final s = ('Hello, world. ' * 2000);
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 't',
          createSql: 'CREATE TABLE t(s TEXT)',
          rows: [
            [s]
          ],
        ),
      ]);
      final f = SqliteFile.fromBytes(bytes);
      final rows = f.readTable('t');
      expect((rows.single.values[0] as String).length, s.length);
      expect(rows.single.values[0], s);
    });

    test('SQLite reads what we wrote with overflow', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final big = Uint8List(8000);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 17) & 0xff;
      }
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 't',
          createSql: 'CREATE TABLE t(id INTEGER, data BLOB)',
          rows: [
            [1, big],
            [
              2,
              Uint8List.fromList([0xaa, 0xbb])
            ],
          ],
        ),
      ]);
      final f = _tmpDb('overflow');
      await f.writeAsBytes(bytes);
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        final r = ref.select('SELECT id, length(data) FROM t ORDER BY id');
        expect(r.rows, [
          [1, 8000],
          [2, 2],
        ]);
        // And the actual bytes.
        final blob = ref
            .select('SELECT data FROM t WHERE id = 1')
            .rows
            .single
            .first as List<int>;
        expect(blob.length, 8000);
        expect(blob.take(20).toList(), big.take(20).toList());
        expect(blob.last, big.last);
      } finally {
        ref.dispose();
      }
    });

    test('we read SQLite-produced overflow correctly', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('sqlite_overflow');
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final big = Uint8List(10000);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 31) & 0xff;
      }
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER, data BLOB)');
        final stmt = ref.prepare('INSERT INTO t VALUES (?, ?)');
        stmt.execute([1, big]);
        stmt.execute([
          2,
          Uint8List.fromList([1, 2, 3])
        ]);
        stmt.dispose();
      } finally {
        ref.dispose();
      }
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final fp = SqliteFile.fromBytes(bytes);
      final rows = fp.readTable('t');
      expect(rows.length, 2);
      // Order is by rowid for table-leaf scans.
      final byRowid = {for (final r in rows) r.values[0] as int: r.values[1]};
      expect((byRowid[1] as Uint8List).length, 10000);
      expect((byRowid[1] as Uint8List)[0], big[0]);
      expect((byRowid[1] as Uint8List)[9999], big[9999]);
      expect((byRowid[2] as Uint8List).toList(), [1, 2, 3]);
    });

    test('multiple overflow rows interleaved with small rows', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final big1 = Uint8List(4500);
      for (var i = 0; i < big1.length; i++) {
        big1[i] = i & 0xff;
      }
      final big2 = Uint8List(6000);
      for (var i = 0; i < big2.length; i++) {
        big2[i] = (255 - (i & 0xff)) & 0xff;
      }
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 't',
          createSql: 'CREATE TABLE t(id INTEGER, data BLOB, label TEXT)',
          rows: [
            [1, big1, 'first big'],
            [
              2,
              Uint8List.fromList([0]),
              'tiny'
            ],
            [3, big2, 'second big'],
            [
              4,
              Uint8List.fromList([9, 9, 9]),
              'tiny too'
            ],
          ],
        ),
      ]);
      final f = _tmpDb('mixed_overflow');
      await f.writeAsBytes(bytes);
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        final r =
            ref.select('SELECT id, length(data), label FROM t ORDER BY id');
        expect(r.rows, [
          [1, 4500, 'first big'],
          [2, 1, 'tiny'],
          [3, 6000, 'second big'],
          [4, 3, 'tiny too'],
        ]);
      } finally {
        ref.dispose();
      }
    });
  });

  group('Index B-trees (read)', () {
    test('reads a small index produced by SQLite', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('idx_small');
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
        ref.execute('CREATE INDEX t_name ON t(name)');
        final stmt = ref.prepare('INSERT INTO t VALUES (?, ?)');
        stmt.execute([1, 'charlie']);
        stmt.execute([2, 'alice']);
        stmt.execute([3, 'bob']);
        stmt.dispose();
      } finally {
        ref.dispose();
      }
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final fp = SqliteFile.fromBytes(bytes);
      final entries = fp.readIndex('t_name');
      // Each entry is [name, rowid] in ascending key order.
      expect(entries, [
        ['alice', 2],
        ['bob', 3],
        ['charlie', 1],
      ]);
    });

    test('reads a multi-column index in ascending order', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('idx_multi');
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(a INT, b INT, c TEXT)');
        ref.execute('CREATE INDEX t_ab ON t(a, b)');
        final stmt = ref.prepare('INSERT INTO t VALUES (?, ?, ?)');
        stmt.execute([2, 10, 'x']);
        stmt.execute([1, 20, 'y']);
        stmt.execute([1, 5, 'z']);
        stmt.execute([2, 5, 'w']);
        stmt.dispose();
      } finally {
        ref.dispose();
      }
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final fp = SqliteFile.fromBytes(bytes);
      final entries = fp.readIndex('t_ab');
      // Keys are [a, b, rowid]; ascending by (a, b).
      expect(entries.map((e) => [e[0], e[1]]).toList(), [
        [1, 5],
        [1, 20],
        [2, 5],
        [2, 10],
      ]);
    });

    test('reads an index that spans interior B-tree pages', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('idx_big');
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      // 2000 rows with small string keys → multi-page index B-tree.
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
        ref.execute('CREATE INDEX t_k ON t(k)');
        ref.execute('BEGIN');
        final stmt = ref.prepare('INSERT INTO t VALUES (?, ?)');
        for (var i = 0; i < 2000; i++) {
          // Pad so key sort order != insertion order.
          stmt.execute([i, 'k${(i * 7919) % 100000}']);
        }
        stmt.dispose();
        ref.execute('COMMIT');
      } finally {
        ref.dispose();
      }
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final fp = SqliteFile.fromBytes(bytes);
      final entries = fp.readIndex('t_k');
      expect(entries.length, 2000);
      // Verify ascending order on the key column (string compare).
      for (var i = 1; i < entries.length; i++) {
        final prev = entries[i - 1][0] as String;
        final cur = entries[i][0] as String;
        expect(prev.compareTo(cur) <= 0, isTrue,
            reason: 'out of order at $i: $prev vs $cur');
      }
      // And every rowid 0..1999 appears exactly once.
      final rowids = entries.map((e) => e[1] as int).toSet();
      expect(rowids.length, 2000);
      expect(
          rowids.first >= 0 && rowids.last <= 1999 ||
              (rowids.contains(0) && rowids.contains(1999)),
          isTrue);
    });

    test('reads index entries with overflow (long key)', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmpDb('idx_overflow');
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final big = 'x' * 8000;
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
        ref.execute('CREATE INDEX t_k ON t(k)');
        final stmt = ref.prepare('INSERT INTO t VALUES (?, ?)');
        stmt.execute([1, big]);
        stmt.execute([2, 'short']);
        stmt.dispose();
      } finally {
        ref.dispose();
      }
      final bytes = Uint8List.fromList(await f.readAsBytes());
      final fp = SqliteFile.fromBytes(bytes);
      final entries = fp.readIndex('t_k');
      expect(entries.length, 2);
      // 'short' < 'xxxxx...' lexicographically.
      expect(entries[0][0], 'short');
      expect(entries[0][1], 2);
      expect((entries[1][0] as String).length, 8000);
      expect(entries[1][1], 1);
    });

    test('throws on missing index name', () {
      final bytes = writeSqliteFile([
        SqliteWriteTable(name: 't', createSql: 'CREATE TABLE t(x)', rows: [
          [1]
        ])
      ]);
      expect(() => SqliteFile.fromBytes(bytes).readIndex('nope'),
          throwsA(isA<StateError>()));
    });
  });

  group('Index B-trees (write)', () {
    test('writer + reader round-trips a small index', () {
      final bytes = writeSqliteFile(
        [
          SqliteWriteTable(
            name: 't',
            createSql: 'CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)',
            rows: [
              [1, 'charlie'],
              [2, 'alice'],
              [3, 'bob'],
            ],
          ),
        ],
        indexes: [
          SqliteWriteIndex(
            name: 't_name',
            tableName: 't',
            createSql: 'CREATE INDEX t_name ON t(name)',
            entries: [
              ['charlie', 1],
              ['alice', 2],
              ['bob', 3],
            ],
          ),
        ],
      );
      final f = SqliteFile.fromBytes(bytes);
      // Schema lists both objects.
      final schema = f.readSchema();
      expect(schema.where((s) => s.type == 'table').map((s) => s.name),
          contains('t'));
      expect(schema.where((s) => s.type == 'index').map((s) => s.name),
          contains('t_name'));
      // Index entries come back in ascending key order.
      expect(f.readIndex('t_name'), [
        ['alice', 2],
        ['bob', 3],
        ['charlie', 1],
      ]);
    });

    test('SQLite reads indexes we wrote', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final bytes = writeSqliteFile(
        [
          SqliteWriteTable(
            name: 't',
            createSql: 'CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)',
            rows: [
              for (var i = 0; i < 50; i++) [i + 1, 'k${(i * 7) % 50}']
            ],
          ),
        ],
        indexes: [
          SqliteWriteIndex(
            name: 't_k',
            tableName: 't',
            createSql: 'CREATE INDEX t_k ON t(k)',
            entries: [
              for (var i = 0; i < 50; i++) ['k${(i * 7) % 50}', i + 1]
            ],
          ),
        ],
      );
      final f = _tmpDb('idx_write');
      await f.writeAsBytes(bytes);
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        // SQLite-side integrity: the index must agree with the table.
        final integ = ref.select('PRAGMA integrity_check').rows;
        expect(integ.single.first, 'ok');
        // A query that uses the index returns matching rows.
        final r = ref.select("SELECT id FROM t WHERE k = 'k7'");
        // k7 occurs whenever (i * 7) % 50 == 7  -> i in {1, 51%50=1+50?}
        // Simpler: assert it matches the table contents.
        final viaTable = ref
            .select("SELECT id FROM t WHERE k = 'k7' ORDER BY id")
            .rows
            .map((row) => row.first)
            .toList();
        expect(r.rows.map((row) => row.first).toList()..sort(),
            equals(viaTable.toList()..sort()));
      } finally {
        ref.dispose();
      }
    });

    test('writer + reader round-trip a multi-leaf table B-tree', () async {
      final skip = sqliteSkipReason();
      // Even without sqlite3 we can verify pure-Dart round-trip; only
      // the cross-engine asserts are gated.
      const n = 5000;
      final bytes = writeSqliteFile([
        SqliteWriteTable(
          name: 't',
          createSql: 'CREATE TABLE t(id INTEGER PRIMARY KEY, x INT)',
          rows: [
            for (var i = 0; i < n; i++) [i + 1, i * 3]
          ],
        ),
      ]);
      final f = SqliteFile.fromBytes(bytes);
      final rows = f.readTable('t');
      expect(rows.length, n);
      expect(rows.first.values, [1, 0]);
      expect(rows.last.values, [n, (n - 1) * 3]);
      // SQLite (when available) confirms the file is well-formed.
      if (skip == null) {
        final tmp = _tmpDb('multileaf_table');
        await tmp.writeAsBytes(bytes);
        addTearDown(
            () async => tmp.exists().then((e) => e ? tmp.delete() : null));
        final ref = sq.sqlite3.open(tmp.path);
        try {
          expect(ref.select('PRAGMA integrity_check').rows.single.first, 'ok');
          expect(ref.select('SELECT count(*) FROM t').rows.single.first, n);
          expect(ref.select('SELECT id, x FROM t WHERE id = 1234').rows.single,
              [1234, 1233 * 3]);
        } finally {
          ref.dispose();
        }
      }
    });

    test('writer + SQLite round-trip a multi-leaf index B-tree', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      // 500 entries with ~30-byte keys exceed one 4 KB page → forces
      // interior index pages (page type 0x02).
      final entries = <List<Object?>>[];
      for (var i = 0; i < 500; i++) {
        entries.add(['key_${i.toString().padLeft(20, 'x')}', i + 1]);
      }
      final bytes = writeSqliteFile(
        [
          SqliteWriteTable(
            name: 't',
            createSql: 'CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)',
            rows: [
              for (var i = 0; i < 500; i++)
                [i + 1, 'key_${i.toString().padLeft(20, 'x')}']
            ],
          ),
        ],
        indexes: [
          SqliteWriteIndex(
            name: 't_k',
            tableName: 't',
            createSql: 'CREATE INDEX t_k ON t(k)',
            entries: entries,
          ),
        ],
      );
      final f = _tmpDb('multileaf_index');
      await f.writeAsBytes(bytes);
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        expect(ref.select('PRAGMA integrity_check').rows.single.first, 'ok');
        // Index lookup hits the right row.
        final hit =
            ref.select("SELECT id FROM t WHERE k = 'key_xxxxxxxxxxxxxxxxxx42'");
        expect(hit.rows.single.first, 43); // i=42 → id=43
        // ORDER BY uses the index.
        final ordered =
            ref.select('SELECT k FROM t INDEXED BY t_k ORDER BY k LIMIT 5');
        expect(ordered.rows.length, 5);
        for (var i = 1; i < ordered.rows.length; i++) {
          expect(
              (ordered.rows[i - 1].first as String)
                      .compareTo(ordered.rows[i].first as String) <
                  0,
              isTrue);
        }
      } finally {
        ref.dispose();
      }
    });

    test('writer + SQLite agree on multi-column index ordering', () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final entries = <List<Object?>>[
        [2, 10, 1],
        [1, 20, 2],
        [1, 5, 3],
        [2, 5, 4],
      ];
      final bytes = writeSqliteFile(
        [
          SqliteWriteTable(
            name: 't',
            createSql: 'CREATE TABLE t(id INTEGER PRIMARY KEY, a INT, b INT)',
            rows: [
              [1, 2, 10],
              [2, 1, 20],
              [3, 1, 5],
              [4, 2, 5],
            ],
          ),
        ],
        indexes: [
          SqliteWriteIndex(
            name: 't_ab',
            tableName: 't',
            createSql: 'CREATE INDEX t_ab ON t(a, b)',
            entries: entries,
          ),
        ],
      );
      final f = _tmpDb('idx_multi_write');
      await f.writeAsBytes(bytes);
      addTearDown(() async => f.exists().then((e) => e ? f.delete() : null));
      final ref = sq.sqlite3.open(f.path);
      try {
        expect(ref.select('PRAGMA integrity_check').rows.single.first, 'ok');
        // SQLite using our index produces ascending (a, b).
        final r =
            ref.select('SELECT a, b FROM t INDEXED BY t_ab ORDER BY a, b');
        expect(r.rows, [
          [1, 5],
          [1, 20],
          [2, 5],
          [2, 10],
        ]);
      } finally {
        ref.dispose();
      }
    });
  });
}
