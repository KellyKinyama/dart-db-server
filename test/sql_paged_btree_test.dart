import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/server/paged_btree.dart';
import 'package:dart_db_server/server/paged_file.dart';
import 'package:test/test.dart';

/// Regressions for the out-of-core B+-tree index.
///
/// Covers point lookup / put / replace / delete, ordered range scan
/// (full and bounded), tree growth via splits well past one page,
/// persistence across reopen, and crash-then-recover via the inherited
/// PagedFile undo journal.
void main() {
  String tmpPath(String suffix) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ddb_btree_${stamp}_$suffix';
  }

  Future<void> cleanup(String p) async {
    for (final s in [p, '$p.journal']) {
      final f = File(s);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {/* best-effort */}
      }
    }
  }

  Uint8List k(String s) => Uint8List.fromList(s.codeUnits);
  // Fixed-width zero-padded integer key so lex order == numeric order.
  Uint8List kInt(int n) =>
      Uint8List.fromList(n.toString().padLeft(8, '0').codeUnits);

  group('PagedBTree basics', () {
    test('put / get / replace / delete on a single leaf', () async {
      final p = tmpPath('basic.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final t = await PagedBTree.open(pf);

      expect(await t.put(k('alpha'), 1), isTrue);
      expect(await t.put(k('beta'), 2), isTrue);
      expect(await t.put(k('gamma'), 3), isTrue);
      expect(t.length, 3);

      expect(await t.get(k('alpha')), 1);
      expect(await t.get(k('beta')), 2);
      expect(await t.get(k('gamma')), 3);
      expect(await t.get(k('missing')), isNull);

      // Replace.
      expect(await t.put(k('beta'), 200), isFalse);
      expect(await t.get(k('beta')), 200);
      expect(t.length, 3);

      // Delete.
      expect(await t.remove(k('beta')), isTrue);
      expect(await t.get(k('beta')), isNull);
      expect(await t.remove(k('beta')), isFalse);
      expect(t.length, 2);
      await pf.close();
    });

    test('ordered scan returns keys in ascending byte order', () async {
      final p = tmpPath('order.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final t = await PagedBTree.open(pf);

      for (final s in ['gamma', 'alpha', 'epsilon', 'beta', 'delta']) {
        await t.put(k(s), s.length);
      }
      final got = <String>[];
      await for (final e in t.scan()) {
        got.add(String.fromCharCodes(e.key));
      }
      expect(got, ['alpha', 'beta', 'delta', 'epsilon', 'gamma']);
      await pf.close();
    });
  });

  group('PagedBTree growth and splits', () {
    test('inserts that overflow many pages stay correct', () async {
      final p = tmpPath('grow.db');
      addTearDown(() => cleanup(p));
      // Small page = forces splits quickly.
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 8);
      final t = await PagedBTree.open(pf);

      const n = 1000;
      // Insert in non-monotonic order to exercise the routing logic.
      for (var i = 0; i < n; i++) {
        final key = ((i * 2654435761) & 0x7fffffff) % n;
        await t.put(kInt(key), key * 10);
      }
      // Distinct keys may collide (mod n), so the final length is the
      // number of unique residues we hit.
      final expected = <int>{
        for (var i = 0; i < n; i++) ((i * 2654435761) & 0x7fffffff) % n,
      };
      expect(t.length, expected.length);

      // Spot-check a handful of expected keys.
      for (final key in expected.take(20)) {
        expect(await t.get(kInt(key)), key * 10);
      }

      // Full scan must produce sorted, unique keys.
      var prev = -1;
      var seen = 0;
      await for (final e in t.scan()) {
        final n = int.parse(String.fromCharCodes(e.key));
        expect(n, greaterThan(prev));
        prev = n;
        seen++;
      }
      expect(seen, expected.length);

      // The tree must have grown beyond a single root leaf.
      expect(pf.pageCount, greaterThan(2),
          reason: 'expected splits to allocate additional pages');
      await pf.close();
    });

    test('range scan honours inclusive / exclusive bounds', () async {
      final p = tmpPath('range.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 8);
      final t = await PagedBTree.open(pf);

      for (var i = 0; i < 200; i++) {
        await t.put(kInt(i), i);
      }
      final inRange = <int>[];
      await for (final e in t.range(
          lower: kInt(50),
          lowerInclusive: true,
          upper: kInt(60),
          upperInclusive: false)) {
        inRange.add(int.parse(String.fromCharCodes(e.key)));
      }
      expect(inRange, [50, 51, 52, 53, 54, 55, 56, 57, 58, 59]);

      // Open lower bound.
      final firstFew = <int>[];
      await for (final e in t.range(upper: kInt(3))) {
        firstFew.add(int.parse(String.fromCharCodes(e.key)));
      }
      expect(firstFew, [0, 1, 2]);

      // Open upper bound.
      final tail = <int>[];
      await for (final e in t.range(lower: kInt(197), lowerInclusive: false)) {
        tail.add(int.parse(String.fromCharCodes(e.key)));
      }
      expect(tail, [198, 199]);
      await pf.close();
    });
  });

  group('PagedBTree persistence', () {
    test('survives close/reopen with all data intact', () async {
      final p = tmpPath('persist.db');
      addTearDown(() => cleanup(p));

      const n = 500;
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final t = await PagedBTree.open(pf);
        for (var i = 0; i < n; i++) {
          await t.put(kInt(i), i * 3);
        }
        await t.commit();
        await pf.close();
      }
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final t = await PagedBTree.open(pf);
        expect(t.length, n);
        for (var i = 0; i < n; i++) {
          expect(await t.get(kInt(i)), i * 3);
        }
        await pf.close();
      }
    });
  });

  group('PagedBTree crash safety', () {
    test('uncommitted inserts are rolled back on reopen', () async {
      final p = tmpPath('crash.db');
      addTearDown(() => cleanup(p));

      // Commit a baseline.
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final t = await PagedBTree.open(pf);
        for (var i = 0; i < 50; i++) {
          await t.put(kInt(i), i);
        }
        await t.commit();
        await pf.close();
      }
      // Insert more under a tiny cache (forces eviction-write-through),
      // then crash.
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 1);
        final t = await PagedBTree.open(pf);
        for (var i = 50; i < 200; i++) {
          await t.put(kInt(i), i);
        }
        await pf.abandonForCrashTest();
      }
      // Reopen: only the original 50 must survive.
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final t = await PagedBTree.open(pf);
        expect(t.length, 50);
        for (var i = 0; i < 50; i++) {
          expect(await t.get(kInt(i)), i);
        }
        for (var i = 50; i < 60; i++) {
          expect(await t.get(kInt(i)), isNull);
        }
        await pf.close();
      }
    });
  });
}
