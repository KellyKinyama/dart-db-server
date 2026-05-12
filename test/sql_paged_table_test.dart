import 'dart:io';

import 'package:dart_db_server/server/paged_table.dart';
import 'package:test/test.dart';

/// Regressions for the self-contained out-of-core typed table.
///
/// Covers create / open / openOrCreate, insert / get / update / delete,
/// duplicate-PK rejection, scan and range in PK order across types,
/// rows that exceed a page (NULL-tolerant text columns), and
/// persistence across close / reopen with mixed types.
///
/// Crash safety is exercised at the heap and btree layers in their own
/// suites; here we cover the API contract on top.
void main() {
  String tmpBase(String suffix) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ddb_paged_table_${stamp}_$suffix';
  }

  Future<void> cleanup(String base) async {
    for (final s in [
      '$base.heap',
      '$base.heap.journal',
      '$base.idx',
      '$base.idx.journal',
      '$base.meta.json',
      '$base.meta.json.tmp',
    ]) {
      final f = File(s);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {/* best-effort */}
      }
    }
  }

  group('PagedTable basics', () {
    test('create / insert / get / scan round-trip with mixed types', () async {
      final base = tmpBase('mixed');
      addTearDown(() => cleanup(base));

      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('name', PagedColumnType.textType),
          PagedColumn('score', PagedColumnType.realType),
          PagedColumn('active', PagedColumnType.boolType),
        ],
        primaryKey: 'id',
        pageSize: 512,
        cacheCapacity: 4,
      );
      try {
        await t
            .insert({'id': 1, 'name': 'alpha', 'score': 1.5, 'active': true});
        await t
            .insert({'id': 2, 'name': 'beta', 'score': 2.5, 'active': false});
        await t
            .insert({'id': 3, 'name': 'gamma', 'score': null, 'active': true});
        await t.commit();

        expect(t.length, 3);
        final r1 = await t.get(1);
        expect(r1, isNotNull);
        expect(r1!['name'], 'alpha');
        expect(r1['score'], 1.5);
        expect(r1['active'], true);
        expect(await t.get(99), isNull);

        // Scan must come back in PK order even though we didn't insert
        // sorted (we did, but: spot-check that order matches PK ints).
        final ids = <int>[];
        await for (final r in t.scan()) {
          ids.add(r['id'] as int);
        }
        expect(ids, [1, 2, 3]);
      } finally {
        await t.close();
      }
    });

    test('duplicate primary key is rejected', () async {
      final base = tmpBase('dup');
      addTearDown(() => cleanup(base));

      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('v', PagedColumnType.textType),
        ],
        primaryKey: 'id',
        pageSize: 512,
        cacheCapacity: 4,
      );
      try {
        await t.insert({'id': 7, 'v': 'first'});
        // Must use expectLater here — expect(...) doesn't await the
        // future, which would otherwise overlap with the next get(7)
        // and trip RandomAccessFile's "async operation pending" guard.
        await expectLater(
          t.insert({'id': 7, 'v': 'second'}),
          throwsA(isA<StateError>()),
        );
        // The first insert is still there.
        expect((await t.get(7))!['v'], 'first');
      } finally {
        await t.close();
      }
    });

    test('update in-place keeps PK and rewrites the row', () async {
      final base = tmpBase('update');
      addTearDown(() => cleanup(base));

      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('v', PagedColumnType.textType),
        ],
        primaryKey: 'id',
        pageSize: 512,
        cacheCapacity: 4,
      );
      try {
        await t.insert({'id': 1, 'v': 'before'});
        await t.update(1, {'id': 1, 'v': 'after'});
        expect((await t.get(1))!['v'], 'after');

        // Trying to rewrite the PK value is rejected.
        await expectLater(
          t.update(1, {'id': 2, 'v': 'nope'}),
          throwsA(isA<ArgumentError>()),
        );
      } finally {
        await t.close();
      }
    });

    test('delete removes the row and the index entry', () async {
      final base = tmpBase('del');
      addTearDown(() => cleanup(base));

      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('v', PagedColumnType.textType),
        ],
        primaryKey: 'id',
        pageSize: 512,
        cacheCapacity: 4,
      );
      try {
        for (var i = 0; i < 5; i++) {
          await t.insert({'id': i, 'v': 'row$i'});
        }
        expect(await t.delete(2), isTrue);
        expect(await t.delete(2), isFalse);
        expect(await t.get(2), isNull);
        expect(t.length, 4);

        final ids = <int>[];
        await for (final r in t.scan()) {
          ids.add(r['id'] as int);
        }
        expect(ids, [0, 1, 3, 4]);
      } finally {
        await t.close();
      }
    });
  });

  group('PagedTable PK order and range', () {
    test('integer PKs sort numerically including negatives', () async {
      final base = tmpBase('int-order');
      addTearDown(() => cleanup(base));

      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('k', PagedColumnType.intType),
          PagedColumn('v', PagedColumnType.intType),
        ],
        primaryKey: 'k',
        pageSize: 512,
        cacheCapacity: 4,
      );
      try {
        for (final n in [3, -10, 0, 100, -1, 2, -50]) {
          await t.insert({'k': n, 'v': n * 10});
        }
        final order = <int>[];
        await for (final r in t.scan()) {
          order.add(r['k'] as int);
        }
        expect(order, [-50, -10, -1, 0, 2, 3, 100]);

        // Range scan: keys in [-1, 100) ascending.
        final rng = <int>[];
        await for (final r in t.range(lower: -1, upper: 100)) {
          rng.add(r['k'] as int);
        }
        expect(rng, [-1, 0, 2, 3]);
      } finally {
        await t.close();
      }
    });

    test('text PKs sort by UTF-8 byte order', () async {
      final base = tmpBase('text-order');
      addTearDown(() => cleanup(base));

      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('k', PagedColumnType.textType),
          PagedColumn('v', PagedColumnType.intType),
        ],
        primaryKey: 'k',
        pageSize: 512,
        cacheCapacity: 4,
      );
      try {
        for (final s in ['delta', 'alpha', 'gamma', 'beta', 'epsilon']) {
          await t.insert({'k': s, 'v': s.length});
        }
        final order = <String>[];
        await for (final r in t.scan()) {
          order.add(r['k'] as String);
        }
        expect(order, ['alpha', 'beta', 'delta', 'epsilon', 'gamma']);

        // Bounded range, exclusive upper.
        final mid = <String>[];
        await for (final r
            in t.range(lower: 'beta', upper: 'gamma', upperInclusive: false)) {
          mid.add(r['k'] as String);
        }
        expect(mid, ['beta', 'delta', 'epsilon']);
      } finally {
        await t.close();
      }
    });
  });

  group('PagedTable persistence', () {
    test('close + openOrCreate preserves rows and schema', () async {
      final base = tmpBase('reopen');
      addTearDown(() => cleanup(base));

      const cols = [
        PagedColumn('id', PagedColumnType.intType),
        PagedColumn('name', PagedColumnType.textType),
      ];

      {
        final t = await PagedTable.create(
          base,
          columns: cols,
          primaryKey: 'id',
          pageSize: 512,
          cacheCapacity: 4,
        );
        for (var i = 0; i < 100; i++) {
          await t.insert({'id': i, 'name': 'r$i'});
        }
        expect(t.length, 100, reason: 'in-memory length after 100 inserts');
        await t.commit();
        expect(t.length, 100, reason: 'length after commit');
        await t.close();
      }
      {
        final t = await PagedTable.openOrCreate(
          base,
          columns: cols,
          primaryKey: 'id',
          pageSize: 512,
          cacheCapacity: 4,
        );
        expect(t.length, 100, reason: 'index entry count must persist');
        expect((await t.get(0))!['name'], 'r0');
        expect((await t.get(99))!['name'], 'r99');
        // Confirm scan still ascending.
        final ids = <int>[];
        await for (final r in t.scan()) {
          ids.add(r['id'] as int);
        }
        expect(ids.first, 0);
        expect(ids.last, 99);
        expect(ids.length, 100);
        await t.close();
      }
    });

    test('rows much larger than a page round-trip', () async {
      final base = tmpBase('big-row');
      addTearDown(() => cleanup(base));

      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('blob', PagedColumnType.textType),
        ],
        primaryKey: 'id',
        pageSize: 512,
        cacheCapacity: 4,
      );
      try {
        final huge = 'x' * 5000; // way bigger than 512
        await t.insert({'id': 1, 'blob': huge});
        await t.commit();
        final got = await t.get(1);
        expect(got, isNotNull);
        expect(got!['blob'], huge);
      } finally {
        await t.close();
      }
    });

    test('out-of-core: working set far larger than cache stays correct',
        () async {
      final base = tmpBase('outofcore');
      addTearDown(() => cleanup(base));

      // 2000 rows on 512-byte pages ≈ 330 data pages plus B-tree
      // pages — the working set is ~40x the configured cache, which
      // is what "out-of-core" means here.
      final t = await PagedTable.create(
        base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('v', PagedColumnType.intType),
        ],
        primaryKey: 'id',
        pageSize: 512,
        cacheCapacity: 16,
      );
      try {
        const n = 2000;
        for (var i = 0; i < n; i++) {
          await t.insert({'id': i, 'v': i * 2});
        }
        await t.commit();
        expect(t.length, n);

        // Spot-check.
        for (final i in [0, 1, 7, 999, 1999]) {
          final r = await t.get(i);
          expect(r, isNotNull, reason: 'missing id=$i');
          expect(r!['v'], i * 2);
        }

        // Full scan must be in order and complete.
        var prev = -1;
        var seen = 0;
        await for (final r in t.scan()) {
          final id = r['id'] as int;
          expect(id, greaterThan(prev));
          prev = id;
          seen++;
        }
        expect(seen, n);
      } finally {
        await t.close();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
