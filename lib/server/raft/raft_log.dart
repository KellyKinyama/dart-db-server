library;

import 'rpc.dart';

/// Raft's replicated log, indexed from 1. In v1 this is an in-memory list; R5
/// backs it with the engine's on-disk `OpLog` (index == LSN). Entries are kept
/// contiguous, so `_entries[i]` holds index `i + 1`.
class RaftLog {
  final List<RaftEntry> _entries = [];

  /// Index of the last entry (0 when empty).
  int get lastIndex => _entries.isEmpty ? 0 : _entries.last.index;

  /// Term of the last entry (0 when empty).
  int get lastTerm => _entries.isEmpty ? 0 : _entries.last.term;

  int get length => _entries.length;

  /// Term of the entry at [index] (0 for index 0 / out of range).
  int termAt(int index) {
    if (index <= 0 || index > _entries.length) return 0;
    return _entries[index - 1].term;
  }

  /// The entry at [index], or null when out of range.
  RaftEntry? at(int index) {
    if (index <= 0 || index > _entries.length) return null;
    return _entries[index - 1];
  }

  /// Append [entry]; its index must be exactly `lastIndex + 1`.
  void append(RaftEntry entry) {
    assert(entry.index == lastIndex + 1, 'non-contiguous append');
    _entries.add(entry);
  }

  /// Entries with index > [afterIndex], in order (for AppendEntries).
  List<RaftEntry> entriesAfter(int afterIndex) =>
      afterIndex >= _entries.length
          ? const []
          : _entries.sublist(afterIndex);

  /// Delete every entry with index > [index] (conflict resolution).
  void truncateAfter(int index) {
    if (index < 0) index = 0;
    if (index < _entries.length) {
      _entries.removeRange(index, _entries.length);
    }
  }
}
