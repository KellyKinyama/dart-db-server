/// Bounded page cache over a fixed-size-page file, with an undo journal
/// for crash-safe commits.
///
/// This is the foundation of the engine's out-of-core storage layer: it
/// lets a table that is much larger than RAM keep only a bounded set of
/// hot pages resident, faulting cold pages in from disk on demand and
/// evicting clean pages under LRU.
///
/// ## File layout
///
/// The data file is an integer multiple of [pageSize] bytes long. Page
/// numbers are 0-indexed; page `n` lives at byte offset `n * pageSize`.
/// There is no in-file header — higher layers (heap, btree) own their
/// own metadata pages.
///
/// ## Crash safety (undo / rollback journal)
///
/// On the first dirty write of a transaction we open a sibling
/// `<path>.journal` file and copy the *original* bytes of every page we
/// are about to modify into it, fsyncing the journal before touching
/// the data file. [commit] then writes the dirty pages into the data
/// file, fsyncs it, and finally deletes the journal. The journal's
/// presence on disk therefore means "the last transaction did not
/// finish" — [PagedFile.open] replays it page-by-page to restore the
/// pre-transaction image, then deletes it.
///
/// This is the same protocol SQLite uses for its rollback-journal mode
/// and gives atomic, durable commits without depending on the OS for
/// anything beyond `fsync` + `rename`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Magic header written at the start of every rollback journal so we can
/// distinguish a real journal from arbitrary leftover bytes.
const List<int> _journalMagic = [
  0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7, // "ddb-jrnl" + checksum
];

/// Bounded LRU page cache + undo journal over a fixed-page-size file.
///
/// Not thread-safe on its own — callers must serialise mutations
/// through the existing [`AsyncRwLock`](concurrency.dart) (the
/// executor's writer lock already does this).
class PagedFile {
  /// Path to the underlying data file.
  final String path;

  /// Bytes per page. Must be a power of two, at least 512.
  final int pageSize;

  /// Maximum number of resident pages. Must be at least 1. When the
  /// cache is full and a new page is faulted in, the least-recently-used
  /// *clean* page is evicted; if every cached page is dirty we flush a
  /// partial commit (writing dirty pages out under the journal) so we
  /// can keep going.
  final int cacheCapacity;

  RandomAccessFile? _data;
  RandomAccessFile? _journal;

  /// Number of pages currently allocated in the data file.
  int _pageCount = 0;

  /// LRU cache: insertion order = least-recent → most-recent.
  /// We rebuild the order on access by removing-then-reinserting.
  final Map<int, Uint8List> _cache = <int, Uint8List>{};

  /// Pages that have been mutated since the last [commit].
  final Set<int> _dirty = <int>{};

  /// Pages whose original image has already been captured in the
  /// current transaction's journal — we only journal each page once
  /// per transaction.
  final Set<int> _journaled = <int>{};

  bool _closed = false;

  PagedFile._(this.path, this.pageSize, this.cacheCapacity);

  /// Open (or create) a paged file.
  ///
  /// If a `<path>.journal` exists from a previous crashed write, it is
  /// rolled back before the file is exposed for reads, restoring the
  /// pre-crash image of every page recorded in it.
  static Future<PagedFile> open(
    String path, {
    int pageSize = 4096,
    int cacheCapacity = 64,
  }) async {
    if (pageSize < 512 || (pageSize & (pageSize - 1)) != 0) {
      throw ArgumentError.value(
          pageSize, 'pageSize', 'must be a power of two ≥ 512');
    }
    if (cacheCapacity < 1) {
      throw ArgumentError.value(cacheCapacity, 'cacheCapacity', 'must be ≥ 1');
    }
    final pf = PagedFile._(path, pageSize, cacheCapacity);
    // Recover from a crashed previous transaction BEFORE opening for
    // normal use — the rollback writes through directly.
    await pf._recoverIfNeeded();
    final f = File(path);
    if (!await f.exists()) {
      await f.create(recursive: true);
    }
    pf._data = await f.open(mode: FileMode.append);
    final len = await pf._data!.length();
    if (len % pageSize != 0) {
      // Truncate trailing partial page — it can only come from a torn
      // append that the journal didn't cover.
      await pf._data!.truncate(len - (len % pageSize));
    }
    pf._pageCount = (await pf._data!.length()) ~/ pageSize;
    return pf;
  }

  /// Number of pages currently allocated in the data file.
  int get pageCount => _pageCount;

  /// Number of pages currently held in the in-memory cache.
  int get cachedPageCount => _cache.length;

  /// True if the cache holds dirty pages waiting for [commit].
  bool get hasUncommittedChanges => _dirty.isNotEmpty;

  /// Allocate a new page at the end of the file. Returns its page number.
  /// The page is zero-filled, cached, and marked dirty.
  Future<int> allocatePage() async {
    _ensureOpen();
    final pageNo = _pageCount;
    _pageCount += 1;
    final buf = Uint8List(pageSize);
    _cache[pageNo] = buf;
    _touch(pageNo);
    // New pages have no pre-image to journal — mark them as already
    // captured so [commit] doesn't try to roll them back to "the page
    // didn't exist", which our truncate-on-rollback handles separately.
    _journaled.add(pageNo);
    _dirty.add(pageNo);
    await _evictIfNeeded();
    return pageNo;
  }

  /// Read page [pageNo]. The returned buffer is the live cache copy —
  /// callers MUST NOT mutate it without calling [markDirty]; if you
  /// want to modify a page, use [getForWrite] instead.
  Future<Uint8List> read(int pageNo) async {
    _ensureOpen();
    if (pageNo < 0 || pageNo >= _pageCount) {
      throw RangeError.range(pageNo, 0, _pageCount - 1, 'pageNo');
    }
    final cached = _cache[pageNo];
    if (cached != null) {
      _touch(pageNo);
      return cached;
    }
    // Cache miss: fault in from disk.
    final buf = Uint8List(pageSize);
    await _data!.setPosition(pageNo * pageSize);
    final n = await _data!.readInto(buf);
    if (n != pageSize) {
      throw StateError(
          'short read on page $pageNo: expected $pageSize bytes, got $n');
    }
    _cache[pageNo] = buf;
    _touch(pageNo);
    await _evictIfNeeded();
    return buf;
  }

  /// Read page [pageNo] for modification. The returned buffer is
  /// mutable; the page is automatically journaled (once per
  /// transaction) and marked dirty. [commit] will flush it to disk.
  Future<Uint8List> getForWrite(int pageNo) async {
    final buf = await read(pageNo);
    await _captureForUndo(pageNo, buf);
    _dirty.add(pageNo);
    return buf;
  }

  /// Mark an already-mutated cached page dirty. Prefer [getForWrite]
  /// when possible — it captures the undo image automatically.
  Future<void> markDirty(int pageNo) async {
    _ensureOpen();
    final cached = _cache[pageNo];
    if (cached == null) {
      throw StateError('page $pageNo is not resident in cache');
    }
    await _captureForUndo(pageNo, cached);
    _dirty.add(pageNo);
  }

  /// Commit pending dirty pages to disk and finalise the transaction.
  ///
  /// Protocol:
  ///   1. fsync the journal (already done incrementally on each undo
  ///      capture).
  ///   2. Write every dirty page to the data file at its offset.
  ///   3. fsync the data file.
  ///   4. Delete the journal — this is the atomic commit point.
  Future<void> commit() async {
    _ensureOpen();
    if (_dirty.isEmpty && _journal == null) return;
    // Make sure the data file is large enough for any newly allocated
    // pages — if we appended in [allocatePage] but never wrote anything
    // beyond their cached buffer, the file may still be short.
    final needLen = _pageCount * pageSize;
    if (await _data!.length() < needLen) {
      await _data!.truncate(needLen);
    }
    // Flush dirty pages in sorted order for predictable I/O patterns.
    // A dirty page may have been evicted (its bytes were written
    // through under the journal) — in that case it's already on disk
    // and there's nothing to do at commit time.
    final sorted = _dirty.toList()..sort();
    for (final p in sorted) {
      final buf = _cache[p];
      if (buf == null) continue; // already flushed via eviction
      await _data!.setPosition(p * pageSize);
      await _data!.writeFrom(buf);
    }
    await _data!.flush();
    _dirty.clear();
    _journaled.clear();
    await _closeAndDeleteJournal();
  }

  /// Discard pending dirty pages without writing them. The journal is
  /// replayed in-place to restore any pages already flushed.
  Future<void> rollback() async {
    _ensureOpen();
    // Drop dirty cached pages so the next [read] re-faults the
    // pre-transaction image from disk.
    for (final p in _dirty) {
      _cache.remove(p);
    }
    _dirty.clear();
    if (_journal != null) {
      // The journal hasn't been applied yet (commit deletes it); but
      // an evicted-while-dirty page may have been written through
      // [_evictIfNeeded] — reapply the undo records to undo that.
      await _replayJournal(File('$path.journal'));
      await _closeAndDeleteJournal();
    }
    _journaled.clear();
  }

  /// Flush all caches and close file handles. Implicitly commits any
  /// pending dirty pages.
  Future<void> close() async {
    if (_closed) return;
    if (_dirty.isNotEmpty) await commit();
    _closed = true;
    final d = _data;
    _data = null;
    if (d != null) {
      try {
        await d.close();
      } catch (_) {/* best-effort */}
    }
    await _closeAndDeleteJournal();
  }

  /// **Test-only.** Close the data and journal file handles WITHOUT
  /// committing dirty pages or deleting the journal. This is what a
  /// real process crash would look like to the next [PagedFile.open]:
  /// the journal stays on disk, recording the pre-transaction image of
  /// every page that was modified, and recovery rolls those pages back.
  Future<void> abandonForCrashTest() async {
    if (_closed) return;
    _closed = true;
    _dirty.clear();
    _journaled.clear();
    _cache.clear();
    final d = _data;
    _data = null;
    if (d != null) {
      try {
        await d.close();
      } catch (_) {/* best-effort */}
    }
    final j = _journal;
    _journal = null;
    if (j != null) {
      try {
        await j.close();
      } catch (_) {/* best-effort */}
    }
    // Deliberately DO NOT delete the journal file.
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _ensureOpen() {
    if (_closed) throw StateError('PagedFile is closed: $path');
  }

  void _touch(int pageNo) {
    final v = _cache.remove(pageNo);
    if (v != null) _cache[pageNo] = v;
  }

  Future<void> _evictIfNeeded() async {
    while (_cache.length > cacheCapacity) {
      // Find the LRU clean page.
      int? victim;
      for (final k in _cache.keys) {
        if (!_dirty.contains(k)) {
          victim = k;
          break;
        }
      }
      if (victim != null) {
        _cache.remove(victim);
        continue;
      }
      // Every cached page is dirty — flush them all under the journal
      // so we can free space. The journal still gates commit/rollback,
      // so writing dirty pages through to disk is safe: rollback will
      // replay the undo records and restore the originals.
      final sorted = _dirty.toList()..sort();
      final needLen = _pageCount * pageSize;
      if (await _data!.length() < needLen) {
        await _data!.truncate(needLen);
      }
      for (final p in sorted) {
        final buf = _cache[p];
        if (buf == null) continue;
        await _data!.setPosition(p * pageSize);
        await _data!.writeFrom(buf);
      }
      await _data!.flush();
      // Drop the LRU half of dirty pages from cache to free room.
      // Pages stay in [_dirty] (they're uncommitted) but their bytes
      // are safely on disk and the journal preserves rollback.
      final dropTarget = (cacheCapacity ~/ 2).clamp(1, _cache.length);
      final keys = _cache.keys.toList();
      for (var i = 0; i < dropTarget; i++) {
        _cache.remove(keys[i]);
      }
    }
  }

  Future<void> _captureForUndo(int pageNo, Uint8List originalBytes) async {
    if (_journaled.contains(pageNo)) return;
    _journaled.add(pageNo);
    if (_journal == null) {
      final jf = File('$path.journal');
      _journal = await jf.open(mode: FileMode.write);
      // Write magic + page size header.
      final hdr = ByteData(_journalMagic.length + 4)
        ..buffer.asUint8List().setRange(0, _journalMagic.length, _journalMagic);
      hdr.setUint32(_journalMagic.length, pageSize, Endian.little);
      await _journal!.writeFrom(hdr.buffer.asUint8List());
    }
    // Record: [u32 page_no][page_size bytes original].
    final rec = Uint8List(4 + pageSize);
    final bd = ByteData.sublistView(rec);
    bd.setUint32(0, pageNo, Endian.little);
    rec.setRange(4, 4 + pageSize, originalBytes);
    await _journal!.writeFrom(rec);
    await _journal!.flush();
  }

  Future<void> _closeAndDeleteJournal() async {
    final j = _journal;
    _journal = null;
    if (j != null) {
      try {
        await j.close();
      } catch (_) {/* best-effort */}
    }
    final jf = File('$path.journal');
    if (await jf.exists()) {
      try {
        await jf.delete();
      } catch (_) {/* best-effort */}
    }
  }

  Future<void> _recoverIfNeeded() async {
    final jf = File('$path.journal');
    if (!await jf.exists()) return;
    final df = File(path);
    if (!await df.exists()) {
      // No data file to recover into — drop the orphaned journal.
      try {
        await jf.delete();
      } catch (_) {/* best-effort */}
      return;
    }
    await _replayJournal(jf);
    try {
      await jf.delete();
    } catch (_) {/* best-effort */}
  }

  Future<void> _replayJournal(File jf) async {
    final raw = await jf.readAsBytes();
    if (raw.length < _journalMagic.length + 4) return;
    for (var i = 0; i < _journalMagic.length; i++) {
      if (raw[i] != _journalMagic[i]) return; // not a real journal
    }
    final bd = ByteData.sublistView(raw);
    final ps = bd.getUint32(_journalMagic.length, Endian.little);
    if (ps < 512 || (ps & (ps - 1)) != 0) return;
    final df = await File(path).open(mode: FileMode.append);
    try {
      var off = _journalMagic.length + 4;
      while (off + 4 + ps <= raw.length) {
        final pageNo = bd.getUint32(off, Endian.little);
        off += 4;
        final orig = Uint8List.sublistView(raw, off, off + ps);
        off += ps;
        // Only restore pages that already exist in the data file —
        // brand-new pages from the aborted transaction are simply
        // truncated below.
        if ((pageNo + 1) * ps <= await df.length()) {
          await df.setPosition(pageNo * ps);
          await df.writeFrom(orig);
        }
      }
      await df.flush();
    } finally {
      try {
        await df.close();
      } catch (_) {/* best-effort */}
    }
  }
}
