import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/server/paged_file.dart';
import 'package:dart_db_server/server/paged_heap.dart';
import 'package:test/test.dart';

/// Regressions for the slotted-page row heap.
///
/// Covers:
///  * insert / get / scan round-trip;
///  * RowIds remain stable after delete (no slot reuse);
///  * delete reclaims free space, and a fresh insert reuses it;
///  * update in place when the new row fits, and via overflow when it
///    doesn't;
///  * rows larger than a page transparently use overflow chains;
///  * persistence across close/reopen;
///  * crash before commit leaves the heap in its pre-transaction state
///    (PagedHeap inherits this from PagedFile's undo journal).
void main() {
  String tmpPath(String suffix) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ddb_heap_${stamp}_$suffix';
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

  Uint8List bytesOf(String s) => Uint8List.fromList(s.codeUnits);
  String stringOf(Uint8List b) => String.fromCharCodes(b);

  group('PagedHeap basics', () {
    test('insert + get + scan round-trip', () async {
      final p = tmpPath('basic.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final heap = await PagedHeap.open(pf);

      final ids = <int>[];
      for (final s in ['alpha', 'beta', 'gamma', 'delta']) {
        ids.add(await heap.insert(bytesOf(s)));
      }
      await heap.commit();

      expect(heap.length, 4);
      expect(stringOf((await heap.get(ids[0]))!), 'alpha');
      expect(stringOf((await heap.get(ids[3]))!), 'delta');

      final seen = <String>[];
      await for (final r in heap.scan()) {
        seen.add(stringOf(r.bytes));
      }
      expect(seen.toSet(), {'alpha', 'beta', 'gamma', 'delta'});
      await pf.close();
    });

    test('persists across reopen', () async {
      final p = tmpPath('reopen.db');
      addTearDown(() => cleanup(p));

      int idA, idB;
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final heap = await PagedHeap.open(pf);
        idA = await heap.insert(bytesOf('one'));
        idB = await heap.insert(bytesOf('two'));
        await heap.commit();
        await pf.close();
      }
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final heap = await PagedHeap.open(pf);
        expect(heap.length, 2);
        expect(stringOf((await heap.get(idA))!), 'one');
        expect(stringOf((await heap.get(idB))!), 'two');
        await pf.close();
      }
    });
  });

  group('PagedHeap delete and update', () {
    test('delete tombstones the slot; get returns null', () async {
      final p = tmpPath('del.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final heap = await PagedHeap.open(pf);

      final id = await heap.insert(bytesOf('vanish'));
      expect((await heap.get(id)) != null, isTrue);
      await heap.delete(id);
      expect(await heap.get(id), isNull);
      expect(heap.length, 0);

      // Scan must skip the tombstone.
      var count = 0;
      await for (final _ in heap.scan()) {
        count++;
      }
      expect(count, 0);
      await pf.close();
    });

    test('delete reclaims space; subsequent insert succeeds', () async {
      final p = tmpPath('reclaim.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final heap = await PagedHeap.open(pf);

      // Pack a page with strings that nearly fill it, then delete one
      // and re-insert a same-sized one. The new insert must succeed
      // without allocating a brand new page.
      final pageCountBefore = pf.pageCount;
      final ids = <int>[];
      for (var i = 0; i < 5; i++) {
        ids.add(await heap.insert(Uint8List(80)));
      }
      final pagesAfterFill = pf.pageCount;
      await heap.delete(ids[2]);
      await heap.insert(Uint8List(80));
      expect(pf.pageCount, pagesAfterFill,
          reason: 'reclaimed slot/space should be reused');
      expect(pf.pageCount, greaterThan(pageCountBefore));
      await heap.commit();
      await pf.close();
    });

    test('update in-place: same-size row keeps RowId', () async {
      final p = tmpPath('upd-inplace.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final heap = await PagedHeap.open(pf);

      final id = await heap.insert(bytesOf('hello'));
      await heap.update(id, bytesOf('world'));
      expect(stringOf((await heap.get(id))!), 'world');
      await pf.close();
    });

    test('update grows the row beyond a page → overflow', () async {
      final p = tmpPath('upd-overflow.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final heap = await PagedHeap.open(pf);

      final id = await heap.insert(bytesOf('small'));
      final big = Uint8List(2000); // >> 512 byte page
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 7) & 0xff;
      }
      await heap.update(id, big);
      final got = await heap.get(id);
      expect(got, isNotNull);
      expect(got!.length, 2000);
      for (var i = 0; i < got.length; i++) {
        expect(got[i], (i * 7) & 0xff);
      }
      await pf.close();
    });
  });

  group('PagedHeap overflow', () {
    test('insert of row larger than a page round-trips', () async {
      final p = tmpPath('big.db');
      addTearDown(() => cleanup(p));
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final heap = await PagedHeap.open(pf);

      final big = Uint8List(5000);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i + 1) & 0xff;
      }
      final id = await heap.insert(big);
      await heap.commit();
      final got = await heap.get(id);
      expect(got, isNotNull);
      expect(got!.length, 5000);
      for (var i = 0; i < big.length; i++) {
        expect(got[i], big[i]);
      }
      await pf.close();
    });

    test('overflow row survives reopen', () async {
      final p = tmpPath('big-reopen.db');
      addTearDown(() => cleanup(p));

      final big = Uint8List(3000);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i ^ 0xA5) & 0xff;
      }

      int id;
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 2);
        final heap = await PagedHeap.open(pf);
        id = await heap.insert(big);
        await heap.commit();
        await pf.close();
      }
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 2);
        final heap = await PagedHeap.open(pf);
        final got = await heap.get(id);
        expect(got, isNotNull);
        expect(got!, equals(big));
        await pf.close();
      }
    });
  });

  group('PagedHeap crash safety', () {
    test('crash before commit: heap is unchanged on reopen', () async {
      final p = tmpPath('crash.db');
      addTearDown(() => cleanup(p));

      int idCommitted;
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final heap = await PagedHeap.open(pf);
        idCommitted = await heap.insert(bytesOf('committed'));
        await heap.commit();
        await pf.close();
      }
      {
        // Mutate but don't commit; abandon the file as if the process
        // crashed. The undo journal must roll back to "committed only".
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 1);
        final heap = await PagedHeap.open(pf);
        await heap.insert(bytesOf('uncommitted-1'));
        await heap.insert(bytesOf('uncommitted-2'));
        // Force eviction-write-through by opening a tiny cache and
        // doing more inserts.
        for (var i = 0; i < 10; i++) {
          await heap.insert(bytesOf('uncommitted-$i'));
        }
        await pf.abandonForCrashTest();
      }
      {
        final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
        final heap = await PagedHeap.open(pf);
        expect(heap.length, 1,
            reason: 'only the committed row must survive');
        expect(stringOf((await heap.get(idCommitted))!), 'committed');
        await pf.close();
      }
    });
  });
}
