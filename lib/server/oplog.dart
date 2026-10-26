library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One committed transaction in the logical op-log: a monotonic [lsn], a
/// wall-clock [timestampMs], and the ordered SQL [ops] that were applied.
class OpLogRecord {
  final int lsn;
  final int timestampMs;
  final List<String> ops;
  OpLogRecord(this.lsn, this.timestampMs, this.ops);

  Map<String, Object?> toJson() =>
      {'lsn': lsn, 'ts': timestampMs, 'ops': ops};

  factory OpLogRecord.fromJson(Map<String, Object?> j) => OpLogRecord(
        (j['lsn'] as num).toInt(),
        (j['ts'] as num).toInt(),
        (j['ops'] as List).cast<String>(),
      );
}

/// CRC32 (IEEE 802.3, reflected, polynomial 0xEDB88320). Lazily-built table.
int opLogCrc32(List<int> bytes) {
  _crcTable ??= _buildCrcTable();
  final table = _crcTable!;
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = (crc >> 8) ^ table[(crc ^ b) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int>? _crcTable;
List<int> _buildCrcTable() {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c & 0xFFFFFFFF;
  }
  return t;
}

/// In-memory index of one on-disk segment file.
class _Segment {
  final String file;
  int firstLsn; // 0 when the segment holds no records yet
  int lastLsn; // 0 when empty
  int validBytes; // byte length of the intact (CRC-verified) prefix
  _Segment(this.file, this.firstLsn, this.lastLsn, this.validBytes);
}

/// An append-only, crash-safe **logical change log**. Each committed
/// transaction is one length-prefixed, CRC32-checked frame:
/// `[u32 payloadLen][u32 crc32][payload]`, where `payload` is UTF-8 JSON of an
/// [OpLogRecord]. Segments rotate once they exceed [segmentBytes]; on [open]
/// the log scans every segment, truncating any torn tail frame left by a crash
/// mid-append, and recomputes the authoritative [lastLsn].
///
/// This is the replication source of truth and the redo stream for
/// transaction-level recovery (see `doc/high-availability-plan.md`, Phase 1).
class OpLog {
  /// Directory holding the segment files (e.g. `<dbpath>.oplog/`).
  final String dir;

  /// Soft cap on a segment's size; a new segment opens once appending would
  /// exceed it (a single oversized record still goes into its own segment).
  final int segmentBytes;

  final List<_Segment> _segments = [];
  RandomAccessFile? _active;
  int _lastLsn = 0;
  bool _open = false;

  OpLog(this.dir, {this.segmentBytes = 8 * 1024 * 1024});

  /// The highest LSN durably appended, or 0 when the log is empty.
  int get lastLsn => _lastLsn;

  static String _segName(int seq) => '${seq.toString().padLeft(6, '0')}.log';

  int _seqOf(String file) {
    final base = file.split(Platform.pathSeparator).last;
    return int.tryParse(base.replaceAll('.log', '')) ?? 0;
  }

  /// Open (creating [dir] if needed), rebuild the segment index by scanning
  /// every segment, truncate a torn final frame, and ready the newest segment
  /// for appends.
  Future<void> open() async {
    if (_open) return;
    final d = Directory(dir);
    if (!await d.exists()) await d.create(recursive: true);

    final files = <String>[
      for (final e in d.listSync())
        if (e is File && e.path.endsWith('.log')) e.path,
    ]..sort((a, b) => _seqOf(a).compareTo(_seqOf(b)));

    for (final f in files) {
      final seg = await _scanSegment(f);
      _segments.add(seg);
      if (seg.lastLsn > _lastLsn) _lastLsn = seg.lastLsn;
    }

    if (_segments.isEmpty) {
      final first = '$dir${Platform.pathSeparator}${_segName(1)}';
      _segments.add(_Segment(first, 0, 0, 0));
    }

    final last = _segments.last;
    // Truncate any torn tail so the next append starts on a frame boundary.
    // Open in append mode (which never clobbers existing content) and trim to
    // the verified byte length before taking it as the active writer.
    final lf = File(last.file);
    final raf = await lf.open(mode: FileMode.append);
    if (lf.lengthSync() != last.validBytes) {
      await raf.truncate(last.validBytes);
    }
    _active = raf;
    _open = true;
  }

  /// Append one committed transaction and return its assigned LSN. The frame
  /// is fsync-requested (`flush`) before returning, so the LSN is durable.
  Future<int> append(List<String> ops, {int? timestampMs}) async {
    if (!_open) throw StateError('OpLog.append before open()');
    final lsn = _lastLsn + 1;
    final rec = OpLogRecord(
      lsn,
      timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      ops,
    );
    final payload = utf8.encode(jsonEncode(rec.toJson()));
    final header = ByteData(8)
      ..setUint32(0, payload.length, Endian.little)
      ..setUint32(4, opLogCrc32(payload), Endian.little);
    final frameLen = 8 + payload.length;

    final seg = _segments.last;
    if (seg.validBytes > 0 && seg.validBytes + frameLen > segmentBytes) {
      await _rotate();
    }
    final active = _active!;
    await active.writeFrom(header.buffer.asUint8List());
    await active.writeFrom(payload);
    await active.flush(); // request fsync

    final cur = _segments.last;
    if (cur.firstLsn == 0) cur.firstLsn = lsn;
    cur.lastLsn = lsn;
    cur.validBytes += frameLen;
    _lastLsn = lsn;
    return lsn;
  }

  Future<void> _rotate() async {
    await _active?.close();
    final nextSeq = _seqOf(_segments.last.file) + 1;
    final file = '$dir${Platform.pathSeparator}${_segName(nextSeq)}';
    _segments.add(_Segment(file, 0, 0, 0));
    _active = await File(file).open(mode: FileMode.append);
  }

  /// Replay every record with `lsn > afterLsn`, in LSN order.
  Stream<OpLogRecord> readFrom(int afterLsn) async* {
    for (final seg in _segments) {
      if (seg.lastLsn <= afterLsn) continue;
      for (final rec in await _readSegment(seg.file, seg.validBytes)) {
        if (rec.lsn > afterLsn) yield rec;
      }
    }
  }

  /// Drop whole segments whose every record is below [minLsn] (e.g. already
  /// persisted in a snapshot and consumed by the slowest replica). The active
  /// segment is never removed.
  Future<void> truncateBelow(int minLsn) async {
    final keep = <_Segment>[];
    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final isActive = i == _segments.length - 1;
      if (!isActive && seg.lastLsn != 0 && seg.lastLsn < minLsn) {
        final f = File(seg.file);
        if (await f.exists()) await f.delete();
      } else {
        keep.add(seg);
      }
    }
    _segments
      ..clear()
      ..addAll(keep);
  }

  Future<void> close() async {
    await _active?.close();
    _active = null;
    _open = false;
  }

  /// Read a segment's intact frames up to [limitBytes].
  Future<List<OpLogRecord>> _readSegment(String file, int limitBytes) async {
    final f = File(file);
    if (!await f.exists()) return const [];
    final bytes = await f.readAsBytes();
    final out = <OpLogRecord>[];
    var off = 0;
    final end = limitBytes < bytes.length ? limitBytes : bytes.length;
    while (off + 8 <= end) {
      final bd = ByteData.sublistView(bytes, off, off + 8);
      final len = bd.getUint32(0, Endian.little);
      final crc = bd.getUint32(4, Endian.little);
      if (off + 8 + len > end) break;
      final payload = bytes.sublist(off + 8, off + 8 + len);
      if (opLogCrc32(payload) != crc) break;
      out.add(OpLogRecord.fromJson(
          (jsonDecode(utf8.decode(payload)) as Map).cast<String, Object?>()));
      off += 8 + len;
    }
    return out;
  }

  /// Scan a segment file to its first torn/corrupt frame, returning its index.
  Future<_Segment> _scanSegment(String file) async {
    final bytes = await File(file).readAsBytes();
    var off = 0;
    var firstLsn = 0;
    var lastLsn = 0;
    while (off + 8 <= bytes.length) {
      final bd = ByteData.sublistView(bytes, off, off + 8);
      final len = bd.getUint32(0, Endian.little);
      final crc = bd.getUint32(4, Endian.little);
      if (off + 8 + len > bytes.length) break;
      final payload = bytes.sublist(off + 8, off + 8 + len);
      if (opLogCrc32(payload) != crc) break;
      final rec = OpLogRecord.fromJson(
          (jsonDecode(utf8.decode(payload)) as Map).cast<String, Object?>());
      if (firstLsn == 0) firstLsn = rec.lsn;
      lastLsn = rec.lsn;
      off += 8 + len;
    }
    return _Segment(file, firstLsn, lastLsn, off);
  }
}
