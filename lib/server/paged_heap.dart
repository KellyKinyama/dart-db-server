/// Slotted-page row heap built on top of [PagedFile].
///
/// This is the row-storage layer of the out-of-core engine: arbitrary
/// byte payloads ("rows") are inserted into the heap, get back a stable
/// 64-bit [RowId], and can be fetched, replaced, deleted, or
/// full-scanned without ever loading the whole file into memory.
///
/// ## Page layout
///
/// **Page 0 — heap header** (16 bytes used):
///
/// ```
///   offset  field
///   ------  -----
///        0  u32 magic = 'DHP1'
///        4  u32 row count (informational; recomputed on scan)
///        8  u32 next-allocation hint page (or 0)
///       12  u32 reserved
/// ```
///
/// **Page N (N >= 1) — slotted data page**:
///
/// ```
///   offset  field
///   ------  -----
///        0  u8  page kind (1 = data, 2 = overflow)
///        1  u8  reserved
///        2  u16 slot count
///        4  u16 free-space start  (header + slots*4)
///        6  u16 free-space end    (offset of lowest payload byte)
///        8  slot[0..slotCount-1]: u16 payload offset, u16 payload length
///       ..  free space ..
///       ..  payloads (growing from end backward)
/// ```
///
/// A slot whose `length == 0xFFFF` is a **tombstone** — the slot id is
/// retired and may not be reused (so RowIds remain stable across
/// re-opens).
///
/// A slot whose payload begins with `0xFF 0xFF 0xFF 0xFF` followed by
/// `[u32 firstOverflowPage][u32 totalLength][bytes…]` is an **overflow
/// pointer**: the row was too big to fit on a single data page and its
/// real bytes live in a chain of overflow pages, each of which is:
///
/// ```
///   offset  field
///   ------  -----
///        0  u8  page kind = 2
///        1  u8  reserved
///        2  u16 bytes-on-this-page
///        4  u32 next overflow page (0 = end of chain)
///        8  payload bytes (up to pageSize - 8)
/// ```
///
/// ## RowId
///
/// A [RowId] is `(pageNo << 16) | slotIdx`, so we support up to 65536
/// slots per page and 2^48 / pageSize rows in total — vastly more than
/// any in-RAM workload.
///
/// ## Concurrency
///
/// Same model as [PagedFile]: callers must serialise mutations
/// externally (the executor's [`AsyncRwLock`](concurrency.dart) write
/// lock already does this). Reads are safe to run concurrently with
/// other reads on the same handle.
library;

import 'dart:async';
import 'dart:typed_data';

import 'paged_file.dart';

/// Stable 64-bit row identifier. Survives compaction-free updates.
typedef RowId = int;

/// Magic bytes at offset 0 of the heap header page.
const int _heapMagic = 0x44485031; // 'DHP1' big-endian

const int _pageKindData = 1;
const int _pageKindOverflow = 2;

const int _slotEntrySize = 4; // u16 offset + u16 length
const int _dataPageHeaderSize = 8;
const int _overflowPageHeaderSize = 8;
const int _heapHeaderSize = 16;
const int _tombstoneLen = 0xFFFF;

/// Marker prefix indicating the slot payload is an overflow pointer
/// rather than the row itself. Four bytes of 0xFF (an impossible row
/// prefix in our format) followed by the chain head and total length.
const int _overflowMarker = 0xFFFFFFFF;
const int _overflowPointerSize = 12; // 4 marker + 4 firstPage + 4 totalLen

/// Slotted-page row heap.
class PagedHeap {
  final PagedFile file;

  /// Hint: a data page that probably has free space. We update it after
  /// every insert. It's only a hint; we always re-check the page's
  /// actual free space and fall back to allocating a new page if the
  /// hint is stale.
  int _allocHintPage = 0;

  /// Cached row-count for [length]; refreshed lazily.
  int _rowCount = 0;

  PagedHeap._(this.file);

  /// Open (or initialise) a paged heap rooted at the given file.
  static Future<PagedHeap> open(PagedFile file) async {
    final heap = PagedHeap._(file);
    await heap._initIfNeeded();
    return heap;
  }

  /// Number of live rows in the heap (cheap, kept up to date by mutators).
  int get length => _rowCount;

  /// Insert [bytes] and return its [RowId]. The id is stable across
  /// re-opens and compactions; only [delete] retires it.
  Future<RowId> insert(Uint8List bytes) async {
    if (bytes.length + _slotEntrySize > _maxInlineRowSize) {
      return _insertOverflow(bytes);
    }
    // Try the hint page, then scan from page 1 forward.
    final pageNo = await _findFreePage(bytes.length);
    final slotIdx = await _writeIntoPage(pageNo, bytes);
    _rowCount += 1;
    await _bumpRowCount(1);
    return _makeRowId(pageNo, slotIdx);
  }

  /// Fetch the bytes for [rowId], or return null if it was deleted /
  /// never existed.
  Future<Uint8List?> get(RowId rowId) async {
    final pageNo = _pageOf(rowId);
    final slotIdx = _slotOf(rowId);
    if (pageNo < 1 || pageNo >= file.pageCount) return null;
    final buf = await file.read(pageNo);
    if (_byteAt(buf, 0) != _pageKindData) return null;
    final slotCount = _u16(buf, 2);
    if (slotIdx >= slotCount) return null;
    final off = _u16(buf, _dataPageHeaderSize + slotIdx * _slotEntrySize);
    final len =
        _u16(buf, _dataPageHeaderSize + slotIdx * _slotEntrySize + 2);
    if (len == _tombstoneLen) return null;
    final payload = Uint8List.sublistView(buf, off, off + len);
    if (len >= _overflowPointerSize &&
        _u32(payload, 0) == _overflowMarker) {
      return _readOverflowChain(payload);
    }
    // Return a copy so callers can't see future mutations of the cached
    // page through the returned buffer.
    return Uint8List.fromList(payload);
  }

  /// Delete [rowId]. Idempotent. Slot becomes a tombstone (the id is
  /// retired permanently).
  Future<void> delete(RowId rowId) async {
    final pageNo = _pageOf(rowId);
    final slotIdx = _slotOf(rowId);
    if (pageNo < 1 || pageNo >= file.pageCount) return;
    final buf = await file.getForWrite(pageNo);
    if (_byteAt(buf, 0) != _pageKindData) return;
    final slotCount = _u16(buf, 2);
    if (slotIdx >= slotCount) return;
    final slotPos = _dataPageHeaderSize + slotIdx * _slotEntrySize;
    final off = _u16(buf, slotPos);
    final len = _u16(buf, slotPos + 2);
    if (len == _tombstoneLen) return;
    // If overflow, free the chain too.
    if (len >= _overflowPointerSize &&
        _u32(buf, off) == _overflowMarker) {
      final firstOv = _u32(buf, off + 4);
      await _freeOverflowChain(firstOv);
    }
    // Reclaim the payload bytes by sliding everything below it up.
    final freeEnd = _u16(buf, 6);
    if (off > freeEnd) {
      buf.setRange(freeEnd + len, off + len, buf, freeEnd);
      // Adjust every slot whose payload sat *below* the deleted one.
      for (var i = 0; i < slotCount; i++) {
        if (i == slotIdx) continue;
        final sp = _dataPageHeaderSize + i * _slotEntrySize;
        final so = _u16(buf, sp);
        final sl = _u16(buf, sp + 2);
        if (sl == _tombstoneLen) continue;
        if (so < off) _setU16(buf, sp, so + len);
      }
    }
    _setU16(buf, 6, freeEnd + len); // freeEnd moves up
    _setU16(buf, slotPos, 0); // tombstone offset
    _setU16(buf, slotPos + 2, _tombstoneLen);
    _rowCount -= 1;
    await _bumpRowCount(-1);
  }

  /// Replace [rowId] with [bytes]. Equivalent to delete + re-insert if
  /// the new payload doesn't fit in place (RowId stays the same — we
  /// rewrite via overflow if needed).
  Future<void> update(RowId rowId, Uint8List bytes) async {
    final pageNo = _pageOf(rowId);
    final slotIdx = _slotOf(rowId);
    if (pageNo < 1 || pageNo >= file.pageCount) {
      throw StateError('rowId $rowId does not exist');
    }
    final buf = await file.getForWrite(pageNo);
    if (_byteAt(buf, 0) != _pageKindData) {
      throw StateError('rowId $rowId does not exist');
    }
    final slotCount = _u16(buf, 2);
    if (slotIdx >= slotCount) {
      throw StateError('rowId $rowId does not exist');
    }
    final slotPos = _dataPageHeaderSize + slotIdx * _slotEntrySize;
    final off = _u16(buf, slotPos);
    final len = _u16(buf, slotPos + 2);
    if (len == _tombstoneLen) {
      throw StateError('rowId $rowId was deleted');
    }
    // Free any old overflow chain.
    if (len >= _overflowPointerSize &&
        _u32(buf, off) == _overflowMarker) {
      final firstOv = _u32(buf, off + 4);
      await _freeOverflowChain(firstOv);
    }
    // Strategy: tombstone the slot, then write the new payload —
    // possibly to a different page or via overflow — and overwrite the
    // slot's offset/length to point at the new bytes (if same page) or
    // an overflow pointer.
    final freeEnd = _u16(buf, 6);
    if (off > freeEnd) {
      buf.setRange(freeEnd + len, off + len, buf, freeEnd);
      for (var i = 0; i < slotCount; i++) {
        if (i == slotIdx) continue;
        final sp = _dataPageHeaderSize + i * _slotEntrySize;
        final so = _u16(buf, sp);
        final sl = _u16(buf, sp + 2);
        if (sl == _tombstoneLen) continue;
        if (so < off) _setU16(buf, sp, so + len);
      }
    }
    _setU16(buf, 6, freeEnd + len);
    _setU16(buf, slotPos, 0);
    _setU16(buf, slotPos + 2, _tombstoneLen);

    // Now write the new payload.
    if (bytes.length + _slotEntrySize > _maxInlineRowSize) {
      // Overflow: write the chain, then emplace a pointer back into
      // *this* slot (we need a 12-byte payload slot).
      final firstOv = await _writeOverflowChain(bytes);
      final ptr = Uint8List(_overflowPointerSize);
      final pd = ByteData.sublistView(ptr);
      pd.setUint32(0, _overflowMarker, Endian.little);
      pd.setUint32(4, firstOv, Endian.little);
      pd.setUint32(8, bytes.length, Endian.little);
      await _placeIntoExistingSlot(pageNo, slotIdx, ptr);
    } else {
      // Try to put the new bytes back on the same page; if there's no
      // room, fall back to a fresh page and rewrite the slot to point
      // at it via overflow (single-page chain).
      if (_pageHasRoom(buf, bytes.length)) {
        await _placeIntoExistingSlot(pageNo, slotIdx, bytes);
      } else {
        final firstOv = await _writeOverflowChain(bytes);
        final ptr = Uint8List(_overflowPointerSize);
        final pd = ByteData.sublistView(ptr);
        pd.setUint32(0, _overflowMarker, Endian.little);
        pd.setUint32(4, firstOv, Endian.little);
        pd.setUint32(8, bytes.length, Endian.little);
        await _placeIntoExistingSlot(pageNo, slotIdx, ptr);
      }
    }
  }

  /// Iterate every live row in the heap. Cheap on memory: one page
  /// resident at a time.
  Stream<({RowId rowId, Uint8List bytes})> scan() async* {
    for (var pageNo = 1; pageNo < file.pageCount; pageNo++) {
      final buf = await file.read(pageNo);
      if (_byteAt(buf, 0) != _pageKindData) continue;
      final slotCount = _u16(buf, 2);
      for (var i = 0; i < slotCount; i++) {
        final slotPos = _dataPageHeaderSize + i * _slotEntrySize;
        final off = _u16(buf, slotPos);
        final len = _u16(buf, slotPos + 2);
        if (len == _tombstoneLen) continue;
        Uint8List bytes;
        if (len >= _overflowPointerSize &&
            _u32(buf, off) == _overflowMarker) {
          // We need to re-read the page after each overflow walk,
          // because the overflow chain may have evicted it from cache.
          final payload = Uint8List.fromList(
              Uint8List.sublistView(buf, off, off + len));
          bytes = (await _readOverflowChain(payload))!;
        } else {
          bytes = Uint8List.fromList(
              Uint8List.sublistView(buf, off, off + len));
        }
        yield (rowId: _makeRowId(pageNo, i), bytes: bytes);
      }
    }
  }

  /// Persist any pending mutations through the underlying [PagedFile].
  Future<void> commit() => file.commit();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  int get _maxInlineRowSize =>
      file.pageSize - _dataPageHeaderSize - _slotEntrySize;

  int _makeRowId(int pageNo, int slotIdx) => (pageNo << 16) | slotIdx;
  int _pageOf(RowId id) => id >> 16;
  int _slotOf(RowId id) => id & 0xFFFF;

  Future<void> _initIfNeeded() async {
    if (file.pageCount == 0) {
      // Brand new file: write the header page.
      final hdrPage = await file.allocatePage();
      assert(hdrPage == 0);
      final buf = await file.getForWrite(0);
      final bd = ByteData.sublistView(buf);
      bd.setUint32(0, _heapMagic, Endian.big);
      bd.setUint32(4, 0, Endian.little);
      bd.setUint32(8, 0, Endian.little);
      bd.setUint32(12, 0, Endian.little);
      await file.commit();
      _rowCount = 0;
      _allocHintPage = 0;
    } else {
      // Existing file: validate header and load row count + hint.
      final buf = await file.read(0);
      final bd = ByteData.sublistView(buf);
      if (bd.getUint32(0, Endian.big) != _heapMagic) {
        throw StateError(
            'PagedHeap: file does not have a valid heap header at page 0');
      }
      _rowCount = bd.getUint32(4, Endian.little);
      _allocHintPage = bd.getUint32(8, Endian.little);
    }
  }

  Future<void> _bumpRowCount(int delta) async {
    final buf = await file.getForWrite(0);
    final bd = ByteData.sublistView(buf);
    final cur = bd.getUint32(4, Endian.little);
    bd.setUint32(4, (cur + delta) & 0xFFFFFFFF, Endian.little);
    bd.setUint32(8, _allocHintPage, Endian.little);
  }

  /// Find a data page with room for [payloadLen] bytes (plus a slot
  /// entry), allocating a new one if necessary.
  Future<int> _findFreePage(int payloadLen) async {
    bool fits(Uint8List buf) => _pageHasRoom(buf, payloadLen);

    if (_allocHintPage >= 1 && _allocHintPage < file.pageCount) {
      final buf = await file.read(_allocHintPage);
      if (_byteAt(buf, 0) == _pageKindData && fits(buf)) {
        return _allocHintPage;
      }
    }
    // Linear scan; on a full table this hint is updated to the most
    // recently allocated page, so the scan is short in practice.
    for (var p = 1; p < file.pageCount; p++) {
      if (p == _allocHintPage) continue;
      final buf = await file.read(p);
      if (_byteAt(buf, 0) != _pageKindData) continue;
      if (fits(buf)) {
        _allocHintPage = p;
        return p;
      }
    }
    // No room anywhere: allocate a fresh data page.
    final pageNo = await file.allocatePage();
    final buf = await file.getForWrite(pageNo);
    _initDataPage(buf);
    _allocHintPage = pageNo;
    return pageNo;
  }

  void _initDataPage(Uint8List buf) {
    for (var i = 0; i < buf.length; i++) {
      buf[i] = 0;
    }
    buf[0] = _pageKindData;
    buf[1] = 0;
    _setU16(buf, 2, 0); // slot count
    _setU16(buf, 4, _dataPageHeaderSize); // free-start
    _setU16(buf, 6, buf.length); // free-end
  }

  bool _pageHasRoom(Uint8List buf, int payloadLen) {
    final freeStart = _u16(buf, 4);
    final freeEnd = _u16(buf, 6);
    return (freeEnd - freeStart) >= (payloadLen + _slotEntrySize);
  }

  /// Append [payload] to data page [pageNo] and return the new slot id.
  Future<int> _writeIntoPage(int pageNo, Uint8List payload) async {
    final buf = await file.getForWrite(pageNo);
    final slotCount = _u16(buf, 2);
    final freeEnd = _u16(buf, 6);
    final newPayloadOff = freeEnd - payload.length;
    buf.setRange(newPayloadOff, newPayloadOff + payload.length, payload);
    final slotPos = _dataPageHeaderSize + slotCount * _slotEntrySize;
    _setU16(buf, slotPos, newPayloadOff);
    _setU16(buf, slotPos + 2, payload.length);
    _setU16(buf, 2, slotCount + 1);
    _setU16(buf, 4, slotPos + _slotEntrySize);
    _setU16(buf, 6, newPayloadOff);
    return slotCount;
  }

  /// Replace the payload of an existing slot in place. Caller has
  /// already verified that [bytes] fits in the page (or accepts that
  /// the row goes via overflow). The slot must currently be a
  /// tombstone (caller is responsible for tombstoning before calling).
  Future<void> _placeIntoExistingSlot(
      int pageNo, int slotIdx, Uint8List bytes) async {
    final buf = await file.getForWrite(pageNo);
    final freeEnd = _u16(buf, 6);
    final newPayloadOff = freeEnd - bytes.length;
    buf.setRange(newPayloadOff, newPayloadOff + bytes.length, bytes);
    final slotPos = _dataPageHeaderSize + slotIdx * _slotEntrySize;
    _setU16(buf, slotPos, newPayloadOff);
    _setU16(buf, slotPos + 2, bytes.length);
    _setU16(buf, 6, newPayloadOff);
  }

  /// Insert a row larger than a page by writing an overflow chain and
  /// stashing a pointer into a regular slot.
  Future<RowId> _insertOverflow(Uint8List bytes) async {
    final firstOv = await _writeOverflowChain(bytes);
    final ptr = Uint8List(_overflowPointerSize);
    final pd = ByteData.sublistView(ptr);
    pd.setUint32(0, _overflowMarker, Endian.little);
    pd.setUint32(4, firstOv, Endian.little);
    pd.setUint32(8, bytes.length, Endian.little);
    final pageNo = await _findFreePage(ptr.length);
    final slotIdx = await _writeIntoPage(pageNo, ptr);
    _rowCount += 1;
    await _bumpRowCount(1);
    return _makeRowId(pageNo, slotIdx);
  }

  /// Write [bytes] into a chain of overflow pages, returning the
  /// first page number.
  Future<int> _writeOverflowChain(Uint8List bytes) async {
    final perPage = file.pageSize - _overflowPageHeaderSize;
    final pageNos = <int>[];
    for (var off = 0; off < bytes.length; off += perPage) {
      pageNos.add(await file.allocatePage());
    }
    if (bytes.isEmpty) {
      // Edge case: zero-byte row in overflow path. Allocate one page
      // to anchor the chain.
      pageNos.add(await file.allocatePage());
    }
    for (var i = 0; i < pageNos.length; i++) {
      final p = pageNos[i];
      final buf = await file.getForWrite(p);
      for (var j = 0; j < buf.length; j++) {
        buf[j] = 0;
      }
      buf[0] = _pageKindOverflow;
      buf[1] = 0;
      final off = i * perPage;
      final remaining = bytes.length - off;
      final n = remaining < perPage ? remaining : perPage;
      _setU16(buf, 2, n);
      final next = (i == pageNos.length - 1) ? 0 : pageNos[i + 1];
      _setU32(buf, 4, next);
      if (n > 0) {
        buf.setRange(_overflowPageHeaderSize, _overflowPageHeaderSize + n,
            bytes, off);
      }
    }
    return pageNos.first;
  }

  Future<Uint8List?> _readOverflowChain(Uint8List slotPayload) async {
    final pd = ByteData.sublistView(slotPayload);
    var nextPage = pd.getUint32(4, Endian.little);
    final totalLen = pd.getUint32(8, Endian.little);
    final out = Uint8List(totalLen);
    var written = 0;
    while (nextPage != 0 && written < totalLen) {
      if (nextPage >= file.pageCount) return null;
      final buf = await file.read(nextPage);
      if (_byteAt(buf, 0) != _pageKindOverflow) return null;
      final n = _u16(buf, 2);
      final follow = _u32(buf, 4);
      if (n > 0) {
        out.setRange(
            written,
            written + n,
            Uint8List.sublistView(
                buf, _overflowPageHeaderSize, _overflowPageHeaderSize + n));
        written += n;
      }
      nextPage = follow;
    }
    return out;
  }

  /// Mark every page in an overflow chain as recyclable. We don't have
  /// a free-page list yet, so for now we just leave the pages allocated
  /// and zeroed — they'll be ignored by [scan] (kind != data) and the
  /// space is reclaimed only by full vacuum. This keeps the on-disk
  /// format simple; a real free list can be added later without
  /// breaking callers.
  Future<void> _freeOverflowChain(int firstPage) async {
    var p = firstPage;
    while (p != 0 && p < file.pageCount) {
      final buf = await file.getForWrite(p);
      if (_byteAt(buf, 0) != _pageKindOverflow) return;
      final next = _u32(buf, 4);
      for (var i = 0; i < buf.length; i++) {
        buf[i] = 0;
      }
      p = next;
    }
  }

  // ---------------------------------------------------------------------------
  // Byte helpers
  // ---------------------------------------------------------------------------
  static int _byteAt(Uint8List buf, int off) => buf[off];
  static int _u16(Uint8List buf, int off) =>
      buf[off] | (buf[off + 1] << 8);
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
}
