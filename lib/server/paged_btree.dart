/// Order-preserving B+-tree index built on [PagedFile].
///
/// Maps **binary keys** (compared lexicographically via unsigned-byte
/// order) to **64-bit values** (typically [RowId]s from a
/// [`PagedHeap`](paged_heap.dart)). Supports point lookup, ordered
/// range scan, insert, and delete — all out-of-core, with one page
/// resident per descent step.
///
/// ## Page layout
///
/// **Page 0 — header** (16 bytes used):
///
/// ```
///   offset  field
///   ------  -----
///        0  u32 magic 'DBT1'
///        4  u32 root page number
///        8  u32 entry count (informational)
///       12  u32 reserved
/// ```
///
/// **Leaf page** (kind = 1):
///
/// ```
///   offset  field
///   ------  -----
///        0  u8  kind = 1
///        1  u8  reserved
///        2  u16 entry count
///        4  u32 next-leaf page (0 = end)
///        8  packed entries:
///             u16 keyLen
///             u16 reserved
///             u64 value
///             keyLen bytes key
/// ```
///
/// **Internal page** (kind = 2):
///
/// ```
///   offset  field
///   ------  -----
///        0  u8  kind = 2
///        1  u8  reserved
///        2  u16 entry count
///        4  u32 leftmost child page
///        8  packed entries:
///             u16 keyLen
///             u16 reserved
///             u32 right child page
///             keyLen bytes key
/// ```
///
/// Routing: a key `k` descends to the right child of the largest entry
/// whose key is `<= k`; if `k <` first entry key, descend to
/// `leftmostChild`.
///
/// ## Concurrency
///
/// Same as [PagedFile] / [PagedHeap]: callers serialise mutators
/// externally. Reads can run concurrently with other reads.
library;

import 'dart:async';
import 'dart:typed_data';

import 'paged_file.dart';

const int _btreeMagic = 0x44425431; // 'DBT1'

const int _kindLeaf = 1;
const int _kindInternal = 2;

const int _leafHeaderSize = 8;
const int _internalHeaderSize = 8;

class _SplitResult {
  final int newRightPage;
  final Uint8List separatorKey;
  _SplitResult(this.newRightPage, this.separatorKey);
}

/// Out-of-core B+-tree index.
class PagedBTree {
  final PagedFile file;
  int _rootPage = 0;
  int _entryCount = 0;

  PagedBTree._(this.file);

  static Future<PagedBTree> open(PagedFile file) async {
    final t = PagedBTree._(file);
    await t._initIfNeeded();
    return t;
  }

  /// Number of entries in the tree.
  int get length => _entryCount;

  /// Look up [key]. Returns its value, or `null` if absent.
  Future<int?> get(Uint8List key) async {
    var pageNo = _rootPage;
    while (true) {
      final buf = await file.read(pageNo);
      final kind = buf[0];
      if (kind == _kindLeaf) {
        return _leafLookup(buf, key);
      } else if (kind == _kindInternal) {
        pageNo = _internalChildFor(buf, key);
      } else {
        throw StateError('PagedBTree: bad page kind $kind on page $pageNo');
      }
    }
  }

  /// Insert (or replace) a `(key, value)` pair. Returns true if a new
  /// entry was added, false if an existing one was updated in place.
  Future<bool> put(Uint8List key, int value) async {
    final stack = <int>[]; // pages from root to leaf, exclusive of leaf
    var pageNo = _rootPage;
    while (true) {
      final buf = await file.read(pageNo);
      if (buf[0] == _kindLeaf) break;
      stack.add(pageNo);
      pageNo = _internalChildFor(buf, key);
    }
    // Try to update in place first.
    final updated = await _leafReplace(pageNo, key, value);
    if (updated) return false;
    final split = await _leafInsert(pageNo, key, value);
    _entryCount += 1;
    await _bumpEntryCount(1);
    if (split == null) return true;
    await _propagateSplit(stack, split);
    return true;
  }

  /// Delete [key]. Returns true if it existed.
  Future<bool> remove(Uint8List key) async {
    var pageNo = _rootPage;
    while (true) {
      final buf = await file.read(pageNo);
      if (buf[0] == _kindLeaf) break;
      pageNo = _internalChildFor(buf, key);
    }
    final removed = await _leafDelete(pageNo, key);
    if (removed) {
      _entryCount -= 1;
      await _bumpEntryCount(-1);
    }
    return removed;
  }

  /// Yield every `(key, value)` entry whose key falls in
  /// `[lower?, upper?)`. Either bound may be null for an open side.
  /// Order is ascending by key.
  Stream<({Uint8List key, int value})> range({
    Uint8List? lower,
    bool lowerInclusive = true,
    Uint8List? upper,
    bool upperInclusive = false,
  }) async* {
    // Descend to the leaf containing [lower] (or the leftmost leaf if
    // null), then walk the next-leaf chain.
    var leafPage =
        lower == null ? await _leftmostLeaf() : await _findLeaf(lower);
    while (leafPage != 0) {
      final buf = await file.read(leafPage);
      final entries = _readLeafEntries(buf);
      for (final e in entries) {
        if (lower != null) {
          final c = _compareKeys(e.key, lower);
          if (c < 0) continue;
          if (c == 0 && !lowerInclusive) continue;
        }
        if (upper != null) {
          final c = _compareKeys(e.key, upper);
          if (c > 0) return;
          if (c == 0 && !upperInclusive) return;
        }
        yield (key: e.key, value: e.value);
      }
      leafPage = _u32(buf, 4);
    }
  }

  /// Yield every `(key, value)` in ascending key order. Streaming.
  Stream<({Uint8List key, int value})> scan() => range();

  /// Persist pending mutations.
  Future<void> commit() => file.commit();

  /// Discard pending mutations on the underlying file and reload the
  /// in-memory header fields ([_rootPage], [_entryCount]) from the
  /// (now-restored) header page. Safe to call when there is nothing
  /// to roll back.
  Future<void> rollback() async {
    await file.rollback();
    if (file.pageCount == 0) {
      _rootPage = 0;
      _entryCount = 0;
      return;
    }
    final hdr = await file.read(0);
    final bd = ByteData.sublistView(hdr);
    _rootPage = bd.getUint32(4, Endian.little);
    _entryCount = bd.getUint32(8, Endian.little);
  }

  // ---------------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------------
  Future<void> _initIfNeeded() async {
    if (file.pageCount == 0) {
      // Header page (0).
      final hdrPage = await file.allocatePage();
      assert(hdrPage == 0);
      // Root leaf page (1).
      final root = await file.allocatePage();
      final rootBuf = await file.getForWrite(root);
      _initLeaf(rootBuf);
      _rootPage = root;
      _entryCount = 0;
      final hdr = await file.getForWrite(0);
      final bd = ByteData.sublistView(hdr);
      bd.setUint32(0, _btreeMagic, Endian.big);
      bd.setUint32(4, root, Endian.little);
      bd.setUint32(8, 0, Endian.little);
      bd.setUint32(12, 0, Endian.little);
      await file.commit();
    } else {
      final hdr = await file.read(0);
      final bd = ByteData.sublistView(hdr);
      if (bd.getUint32(0, Endian.big) != _btreeMagic) {
        throw StateError(
            'PagedBTree: file does not have a valid btree header at page 0');
      }
      _rootPage = bd.getUint32(4, Endian.little);
      _entryCount = bd.getUint32(8, Endian.little);
    }
  }

  Future<void> _bumpEntryCount(int delta) async {
    final hdr = await file.getForWrite(0);
    final bd = ByteData.sublistView(hdr);
    final cur = bd.getUint32(8, Endian.little);
    bd.setUint32(8, (cur + delta) & 0xFFFFFFFF, Endian.little);
    bd.setUint32(4, _rootPage, Endian.little);
  }

  // ---------------------------------------------------------------------------
  // Leaf operations
  // ---------------------------------------------------------------------------
  void _initLeaf(Uint8List buf) {
    for (var i = 0; i < buf.length; i++) {
      buf[i] = 0;
    }
    buf[0] = _kindLeaf;
    _setU16(buf, 2, 0);
    _setU32(buf, 4, 0);
  }

  /// Read every entry in a leaf page in stored (sorted) order. Each
  /// returned key is a fresh copy.
  List<({Uint8List key, int value, int entryStart, int entryLen})>
      _readLeafEntries(Uint8List buf) {
    final entries =
        <({Uint8List key, int value, int entryStart, int entryLen})>[];
    final count = _u16(buf, 2);
    var off = _leafHeaderSize;
    for (var i = 0; i < count; i++) {
      final keyLen = _u16(buf, off);
      final value = _u64(buf, off + 4);
      final keyOff = off + 12;
      final key = Uint8List.fromList(
          Uint8List.sublistView(buf, keyOff, keyOff + keyLen));
      entries.add((
        key: key,
        value: value,
        entryStart: off,
        entryLen: 12 + keyLen,
      ));
      off += 12 + keyLen;
    }
    return entries;
  }

  int? _leafLookup(Uint8List buf, Uint8List key) {
    final entries = _readLeafEntries(buf);
    // Linear scan; binary-search not worth it for typical leaf sizes.
    for (final e in entries) {
      final c = _compareKeys(e.key, key);
      if (c == 0) return e.value;
      if (c > 0) return null;
    }
    return null;
  }

  Future<bool> _leafReplace(int pageNo, Uint8List key, int value) async {
    // Cheap pre-check first to avoid CoW-ing the page on a no-op.
    final ro = await file.read(pageNo);
    final entries = _readLeafEntries(ro);
    int? hitIdx;
    for (var i = 0; i < entries.length; i++) {
      final c = _compareKeys(entries[i].key, key);
      if (c == 0) {
        hitIdx = i;
        break;
      }
      if (c > 0) break;
    }
    if (hitIdx == null) return false;
    final buf = await file.getForWrite(pageNo);
    final entry = entries[hitIdx];
    _setU64(buf, entry.entryStart + 4, value);
    return true;
  }

  /// Returns null if no split, else the split result.
  Future<_SplitResult?> _leafInsert(
      int pageNo, Uint8List key, int value) async {
    final buf = await file.getForWrite(pageNo);
    final entries = _readLeafEntries(buf);

    // Find sorted insert position.
    var insertAt = entries.length;
    for (var i = 0; i < entries.length; i++) {
      if (_compareKeys(entries[i].key, key) > 0) {
        insertAt = i;
        break;
      }
    }

    final newEntryLen = 12 + key.length;
    final usedBytes = entries.fold<int>(0, (a, e) => a + e.entryLen);
    final freeBytes = file.pageSize - _leafHeaderSize - usedBytes;
    if (newEntryLen <= freeBytes) {
      _writeLeafEntries(buf, [
        ...entries.sublist(0, insertAt),
        (
          key: key,
          value: value,
          entryStart: 0,
          entryLen: newEntryLen,
        ),
        ...entries.sublist(insertAt),
      ]);
      return null;
    }

    // Split: build the full sorted list including the new entry, then
    // partition by byte-size into two roughly equal halves.
    final all = <({Uint8List key, int value})>[
      for (final e in entries.sublist(0, insertAt))
        (key: e.key, value: e.value),
      (key: key, value: value),
      for (final e in entries.sublist(insertAt)) (key: e.key, value: e.value),
    ];
    final totalBytes = all.fold<int>(0, (a, e) => a + 12 + e.key.length);
    var leftBytes = 0;
    var splitIdx = 0;
    for (var i = 0; i < all.length; i++) {
      leftBytes += 12 + all[i].key.length;
      if (leftBytes >= totalBytes ~/ 2 && i + 1 < all.length) {
        splitIdx = i + 1;
        break;
      }
    }
    if (splitIdx == 0) splitIdx = all.length ~/ 2;
    final leftEntries = all.sublist(0, splitIdx);
    final rightEntries = all.sublist(splitIdx);

    // Write left half back into the existing page.
    _writeLeafEntries(buf, [
      for (final e in leftEntries)
        (
          key: e.key,
          value: e.value,
          entryStart: 0,
          entryLen: 12 + e.key.length
        ),
    ]);

    // Allocate the new right page and write the right half.
    final rightPage = await file.allocatePage();
    final rightBuf = await file.getForWrite(rightPage);
    _initLeaf(rightBuf);
    _writeLeafEntries(rightBuf, [
      for (final e in rightEntries)
        (
          key: e.key,
          value: e.value,
          entryStart: 0,
          entryLen: 12 + e.key.length
        ),
    ]);

    // Stitch the leaf chain: right.next = oldNext; left.next = rightPage.
    // We must re-fetch BOTH buffers via getForWrite — under cache
    // pressure either may have been evicted by the operations above.
    // Mutating an evicted buffer is silently lost because it is no
    // longer linked into the page cache.
    final buf2 = await file.getForWrite(pageNo);
    final oldNext = _u32(buf2, 4);
    _setU32(buf2, 4, rightPage);
    final rightBuf2 = await file.getForWrite(rightPage);
    _setU32(rightBuf2, 4, oldNext);

    return _SplitResult(rightPage, rightEntries.first.key);
  }

  Future<bool> _leafDelete(int pageNo, Uint8List key) async {
    final ro = await file.read(pageNo);
    final entries = _readLeafEntries(ro);
    int? hitIdx;
    for (var i = 0; i < entries.length; i++) {
      final c = _compareKeys(entries[i].key, key);
      if (c == 0) {
        hitIdx = i;
        break;
      }
      if (c > 0) break;
    }
    if (hitIdx == null) return false;
    final buf = await file.getForWrite(pageNo);
    final kept = [
      for (var i = 0; i < entries.length; i++)
        if (i != hitIdx) entries[i],
    ];
    _writeLeafEntries(buf, kept);
    return true;
  }

  void _writeLeafEntries(
      Uint8List buf,
      List<({Uint8List key, int value, int entryStart, int entryLen})>
          entries) {
    // Zero out the entry region first to avoid leaving stale bytes.
    for (var i = _leafHeaderSize; i < buf.length; i++) {
      buf[i] = 0;
    }
    var off = _leafHeaderSize;
    for (final e in entries) {
      _setU16(buf, off, e.key.length);
      _setU16(buf, off + 2, 0);
      _setU64(buf, off + 4, e.value);
      buf.setRange(off + 12, off + 12 + e.key.length, e.key);
      off += 12 + e.key.length;
    }
    _setU16(buf, 2, entries.length);
  }

  // ---------------------------------------------------------------------------
  // Internal page operations
  // ---------------------------------------------------------------------------
  void _initInternal(Uint8List buf, int leftmostChild) {
    for (var i = 0; i < buf.length; i++) {
      buf[i] = 0;
    }
    buf[0] = _kindInternal;
    _setU16(buf, 2, 0);
    _setU32(buf, 4, leftmostChild);
  }

  /// Decide which child page a key descends into.
  int _internalChildFor(Uint8List buf, Uint8List key) {
    final entries = _readInternalEntries(buf);
    final leftmost = _u32(buf, 4);
    var child = leftmost;
    for (final e in entries) {
      if (_compareKeys(key, e.key) < 0) break;
      child = e.child;
    }
    return child;
  }

  List<({Uint8List key, int child, int entryStart, int entryLen})>
      _readInternalEntries(Uint8List buf) {
    final entries =
        <({Uint8List key, int child, int entryStart, int entryLen})>[];
    final count = _u16(buf, 2);
    var off = _internalHeaderSize;
    for (var i = 0; i < count; i++) {
      final keyLen = _u16(buf, off);
      final child = _u32(buf, off + 4);
      final keyOff = off + 8;
      final key = Uint8List.fromList(
          Uint8List.sublistView(buf, keyOff, keyOff + keyLen));
      entries.add((
        key: key,
        child: child,
        entryStart: off,
        entryLen: 8 + keyLen,
      ));
      off += 8 + keyLen;
    }
    return entries;
  }

  void _writeInternalEntries(
      Uint8List buf,
      int leftmostChild,
      List<({Uint8List key, int child, int entryStart, int entryLen})>
          entries) {
    for (var i = _internalHeaderSize; i < buf.length; i++) {
      buf[i] = 0;
    }
    _setU32(buf, 4, leftmostChild);
    var off = _internalHeaderSize;
    for (final e in entries) {
      _setU16(buf, off, e.key.length);
      _setU16(buf, off + 2, 0);
      _setU32(buf, off + 4, e.child);
      buf.setRange(off + 8, off + 8 + e.key.length, e.key);
      off += 8 + e.key.length;
    }
    _setU16(buf, 2, entries.length);
  }

  Future<_SplitResult?> _internalInsert(
      int pageNo, Uint8List key, int rightChild) async {
    final buf = await file.getForWrite(pageNo);
    final entries = _readInternalEntries(buf);
    final leftmost = _u32(buf, 4);
    var insertAt = entries.length;
    for (var i = 0; i < entries.length; i++) {
      if (_compareKeys(entries[i].key, key) > 0) {
        insertAt = i;
        break;
      }
    }
    final newEntryLen = 8 + key.length;
    final usedBytes = entries.fold<int>(0, (a, e) => a + e.entryLen);
    final freeBytes = file.pageSize - _internalHeaderSize - usedBytes;
    if (newEntryLen <= freeBytes) {
      _writeInternalEntries(buf, leftmost, [
        ...entries.sublist(0, insertAt),
        (
          key: key,
          child: rightChild,
          entryStart: 0,
          entryLen: newEntryLen,
        ),
        ...entries.sublist(insertAt),
      ]);
      return null;
    }

    // Split internal node. Promote the median key (it disappears from
    // both halves and becomes the new separator in the parent).
    final all = <({Uint8List key, int child})>[
      for (final e in entries.sublist(0, insertAt))
        (key: e.key, child: e.child),
      (key: key, child: rightChild),
      for (final e in entries.sublist(insertAt)) (key: e.key, child: e.child),
    ];
    final mid = all.length ~/ 2;
    final promoted = all[mid];
    final leftEntries = all.sublist(0, mid);
    final rightEntries = all.sublist(mid + 1);

    _writeInternalEntries(buf, leftmost, [
      for (final e in leftEntries)
        (key: e.key, child: e.child, entryStart: 0, entryLen: 8 + e.key.length),
    ]);

    final rightPage = await file.allocatePage();
    final rightBuf = await file.getForWrite(rightPage);
    _initInternal(rightBuf, promoted.child);
    _writeInternalEntries(rightBuf, promoted.child, [
      for (final e in rightEntries)
        (key: e.key, child: e.child, entryStart: 0, entryLen: 8 + e.key.length),
    ]);

    return _SplitResult(rightPage, promoted.key);
  }

  // ---------------------------------------------------------------------------
  // Split propagation
  // ---------------------------------------------------------------------------
  Future<void> _propagateSplit(List<int> stack, _SplitResult split) async {
    var current = split;
    while (stack.isNotEmpty) {
      final parent = stack.removeLast();
      final next = await _internalInsert(
          parent, current.separatorKey, current.newRightPage);
      if (next == null) return;
      current = next;
    }
    // Stack exhausted → root split. Allocate a new root.
    final oldRoot = _rootPage;
    final newRoot = await file.allocatePage();
    final buf = await file.getForWrite(newRoot);
    _initInternal(buf, oldRoot);
    _writeInternalEntries(buf, oldRoot, [
      (
        key: current.separatorKey,
        child: current.newRightPage,
        entryStart: 0,
        entryLen: 8 + current.separatorKey.length,
      ),
    ]);
    _rootPage = newRoot;
    final hdr = await file.getForWrite(0);
    final bd = ByteData.sublistView(hdr);
    bd.setUint32(4, newRoot, Endian.little);
  }

  // ---------------------------------------------------------------------------
  // Range scan helpers
  // ---------------------------------------------------------------------------
  Future<int> _leftmostLeaf() async {
    var pageNo = _rootPage;
    while (true) {
      final buf = await file.read(pageNo);
      if (buf[0] == _kindLeaf) return pageNo;
      pageNo = _u32(buf, 4); // leftmost child
    }
  }

  Future<int> _findLeaf(Uint8List key) async {
    var pageNo = _rootPage;
    while (true) {
      final buf = await file.read(pageNo);
      if (buf[0] == _kindLeaf) return pageNo;
      pageNo = _internalChildFor(buf, key);
    }
  }

  // ---------------------------------------------------------------------------
  // Bytes
  // ---------------------------------------------------------------------------
  static int _compareKeys(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }

  static int _u16(Uint8List buf, int off) => buf[off] | (buf[off + 1] << 8);
  static void _setU16(Uint8List buf, int off, int v) {
    buf[off] = v & 0xff;
    buf[off + 1] = (v >> 8) & 0xff;
  }

  static int _u32(Uint8List buf, int off) =>
      buf[off] |
      (buf[off + 1] << 8) |
      (buf[off + 2] << 16) |
      (buf[off + 3] << 24);
  static void _setU32(Uint8List buf, int off, int v) {
    buf[off] = v & 0xff;
    buf[off + 1] = (v >> 8) & 0xff;
    buf[off + 2] = (v >> 16) & 0xff;
    buf[off + 3] = (v >> 24) & 0xff;
  }

  static int _u64(Uint8List buf, int off) {
    final lo = _u32(buf, off);
    final hi = _u32(buf, off + 4);
    return (hi << 32) | (lo & 0xFFFFFFFF);
  }

  static void _setU64(Uint8List buf, int off, int v) {
    _setU32(buf, off, v & 0xFFFFFFFF);
    _setU32(buf, off + 4, (v >> 32) & 0xFFFFFFFF);
  }
}
