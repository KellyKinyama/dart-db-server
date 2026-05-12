import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/server/paged_file.dart';
import 'package:test/test.dart';

/// Regressions for the bounded paged-file storage primitive.
///
/// Covers:
///  * basic allocate / read / commit round-trip;
///  * cache eviction works across a working set far larger than
///    [PagedFile.cacheCapacity];
///  * crash before [PagedFile.commit] rolls back to the pre-transaction
///    image via the undo journal;
///  * an orphaned journal file from a previous crash is replayed and
///    deleted on the next [PagedFile.open];
///  * [PagedFile.rollback] discards pending changes in-memory.
void main() {
  String tmpPath(String suffix) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ddb_paged_${stamp}_$suffix';
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

  void fillPattern(Uint8List buf, int seed) {
    for (var i = 0; i < buf.length; i++) {
      buf[i] = (seed + i) & 0xff;
    }
  }

  bool checkPattern(Uint8List buf, int seed) {
    for (var i = 0; i < buf.length; i++) {
      if (buf[i] != ((seed + i) & 0xff)) return false;
    }
    return true;
  }

  group('PagedFile basics', () {
    test('allocate, write, commit, reopen round-trip', () async {
      final p = tmpPath('basic.db');
      addTearDown(() => cleanup(p));

      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      final p0 = await pf.allocatePage();
      final p1 = await pf.allocatePage();
      fillPattern(await pf.getForWrite(p0), 0x10);
      fillPattern(await pf.getForWrite(p1), 0x20);
      await pf.commit();
      await pf.close();

      // Journal must be gone after a clean commit.
      expect(await File('$p.journal').exists(), isFalse);

      final pf2 = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      expect(pf2.pageCount, 2);
      expect(checkPattern(await pf2.read(p0), 0x10), isTrue);
      expect(checkPattern(await pf2.read(p1), 0x20), isTrue);
      await pf2.close();
    });

    test('rejects non-power-of-two page size', () async {
      expect(
        () => PagedFile.open(tmpPath('bad.db'), pageSize: 1000),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('PagedFile cache eviction', () {
    test('working set larger than cache still serves correct bytes', () async {
      final p = tmpPath('evict.db');
      addTearDown(() => cleanup(p));

      const ps = 512;
      const cap = 4;
      const pages = 64; // 16x the cache capacity
      final pf = await PagedFile.open(p, pageSize: ps, cacheCapacity: cap);
      for (var i = 0; i < pages; i++) {
        final pn = await pf.allocatePage();
        expect(pn, i);
        fillPattern(await pf.getForWrite(pn), i + 1);
      }
      await pf.commit();
      // Cache must be bounded.
      expect(pf.cachedPageCount, lessThanOrEqualTo(cap));
      // Read every page back in random-ish order; bytes must still match.
      final order = List<int>.generate(pages, (i) => (i * 17) % pages);
      for (final pn in order) {
        expect(checkPattern(await pf.read(pn), pn + 1), isTrue,
            reason: 'page $pn corrupted after eviction');
      }
      expect(pf.cachedPageCount, lessThanOrEqualTo(cap));
      await pf.close();
    });
  });

  group('PagedFile crash safety', () {
    test('orphan journal is replayed on open and pre-crash bytes win',
        () async {
      final p = tmpPath('crash.db');
      addTearDown(() => cleanup(p));

      // 1. Establish a known baseline of two pages.
      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      await pf.allocatePage();
      await pf.allocatePage();
      fillPattern(await pf.getForWrite(0), 0xAA);
      fillPattern(await pf.getForWrite(1), 0xBB);
      await pf.commit();
      await pf.close();

      // 2. Mutate but do NOT commit — drop the handle to simulate crash.
      //    Because eviction can write dirty pages through to disk, we
      //    force that path by using a tiny cache and dirtying both
      //    pages, then never calling commit/close.
      final pf2 = await PagedFile.open(p, pageSize: 512, cacheCapacity: 1);
      fillPattern(await pf2.getForWrite(0), 0x11);
      fillPattern(await pf2.getForWrite(1), 0x22);
      // Force an eviction-flush by reading a brand-new page.
      await pf2.allocatePage();
      // Journal must exist now (an undo image was captured).
      expect(await File('$p.journal').exists(), isTrue);
      // Simulate crash: close handles without commit, leaving the
      // journal on disk for the next opener to roll back.
      await pf2.abandonForCrashTest();

      // 3. Reopen. Journal must be replayed → pre-crash bytes restored,
      //    journal deleted, and the spuriously allocated page is
      //    truncated by the length-mod-pageSize check.
      final pf3 = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      expect(await File('$p.journal').exists(), isFalse,
          reason: 'journal must be deleted after recovery');
      expect(checkPattern(await pf3.read(0), 0xAA), isTrue,
          reason: 'page 0 must be restored to pre-crash bytes');
      expect(checkPattern(await pf3.read(1), 0xBB), isTrue,
          reason: 'page 1 must be restored to pre-crash bytes');
      await pf3.close();
    });

    test('rollback discards in-memory changes', () async {
      final p = tmpPath('rollback.db');
      addTearDown(() => cleanup(p));

      final pf = await PagedFile.open(p, pageSize: 512, cacheCapacity: 4);
      await pf.allocatePage();
      fillPattern(await pf.getForWrite(0), 0x77);
      await pf.commit();

      // Mutate then rollback.
      fillPattern(await pf.getForWrite(0), 0x99);
      expect(pf.hasUncommittedChanges, isTrue);
      await pf.rollback();
      expect(pf.hasUncommittedChanges, isFalse);

      // Re-read: must see the committed (0x77) image, not the rolled-back
      // (0x99) one.
      expect(checkPattern(await pf.read(0), 0x77), isTrue);
      await pf.close();
    });
  });
}
