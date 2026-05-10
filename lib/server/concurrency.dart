/// Concurrency primitives used by [Database]:
///
/// * [AsyncRwLock] — in-process multi-reader / single-writer lock built on
///   completers. Fair: writers don't starve readers and vice-versa.
/// * [DbFileLock] — best-effort cross-process advisory lock on a sidecar
///   `<dbpath>.lock` file using `RandomAccessFile.lock()`.
///
/// These are deliberately tiny and dependency-free. They aren't meant to
/// stand in for a real WAL — they protect the JSON file from
/// double-writers and serialize executor mutations within a single
/// process.
library;

import 'dart:async';
import 'dart:io';

/// Async multi-reader / single-writer lock.
///
/// Writers hold an exclusive lock; readers hold a shared lock. New
/// writers block until all existing readers have released; new readers
/// queued behind a waiting writer also block, which keeps writers from
/// starving.
class AsyncRwLock {
  int _readers = 0;
  bool _writer = false;
  final List<Completer<void>> _readWaiters = [];
  final List<Completer<void>> _writeWaiters = [];

  /// Run [body] under a shared (read) lock. Multiple readers may run
  /// concurrently. The lock is released even if [body] throws.
  Future<T> read<T>(FutureOr<T> Function() body) async {
    await _acquireRead();
    try {
      return await body();
    } finally {
      _releaseRead();
    }
  }

  /// Run [body] under an exclusive (write) lock.
  Future<T> write<T>(FutureOr<T> Function() body) async {
    await _acquireWrite();
    try {
      return await body();
    } finally {
      _releaseWrite();
    }
  }

  Future<void> _acquireRead() {
    if (!_writer && _writeWaiters.isEmpty) {
      _readers++;
      return Future.value();
    }
    final c = Completer<void>();
    _readWaiters.add(c);
    return c.future;
  }

  void _releaseRead() {
    _readers--;
    _drain();
  }

  Future<void> _acquireWrite() {
    if (!_writer && _readers == 0) {
      _writer = true;
      return Future.value();
    }
    final c = Completer<void>();
    _writeWaiters.add(c);
    return c.future;
  }

  void _releaseWrite() {
    _writer = false;
    _drain();
  }

  void _drain() {
    // Prefer waiting writers to avoid starvation.
    if (!_writer && _readers == 0 && _writeWaiters.isNotEmpty) {
      _writer = true;
      _writeWaiters.removeAt(0).complete();
      return;
    }
    if (!_writer && _readWaiters.isNotEmpty) {
      while (_readWaiters.isNotEmpty) {
        _readers++;
        _readWaiters.removeAt(0).complete();
      }
    }
  }

  /// Test-only: returns true if the lock is currently held or contended.
  bool get isBusy =>
      _writer ||
      _readers > 0 ||
      _readWaiters.isNotEmpty ||
      _writeWaiters.isNotEmpty;
}

/// Best-effort cross-process advisory lock on a JSON database file.
///
/// We don't lock the data file directly because Dart's atomic
/// `writeAsString` re-creates the file, which would invalidate any open
/// handle / lock. Instead we lock a sidecar `<path>.lock` file. Any
/// other process that opens the same database via this library will see
/// the lock and either wait or fail, depending on which acquire flavour
/// it uses.
///
/// In addition to the OS-level lock we keep an in-process set of
/// already-held lock paths so a single process opening the same
/// database twice gets a fast `StateError` instead of a deadlock on
/// itself (the OS lock is per-process on most platforms and would
/// otherwise be re-entrant silently).
class DbFileLock {
  static final Set<String> _processHeld = <String>{};

  final String path;
  RandomAccessFile? _raf;

  DbFileLock(this.path);

  /// Lock-file path (sibling of the data file).
  String get lockPath => '$path.lock';

  bool get isHeld => _raf != null;

  /// Acquire a lock, blocking until granted. By default takes an
  /// exclusive lock; pass `exclusive: false` for a shared (reader) lock.
  Future<void> acquire({bool exclusive = true}) async {
    final canon = _canonical(lockPath);
    if (_processHeld.contains(canon)) {
      throw StateError('Database file is already open in this process: $path');
    }
    final raf = await _openLockFile();
    await raf
        .lock(exclusive ? FileLock.blockingExclusive : FileLock.blockingShared);
    _raf = raf;
    _processHeld.add(canon);
  }

  /// Try to acquire without blocking. Returns true on success, false if
  /// another process currently holds it.
  Future<bool> tryAcquire({bool exclusive = true}) async {
    final canon = _canonical(lockPath);
    if (_processHeld.contains(canon)) return false;
    final raf = await _openLockFile();
    try {
      await raf.lock(exclusive ? FileLock.exclusive : FileLock.shared);
      _raf = raf;
      _processHeld.add(canon);
      return true;
    } catch (_) {
      try {
        await raf.close();
      } catch (_) {/* ignore */}
      return false;
    }
  }

  /// Release the lock. Safe to call when nothing was acquired.
  Future<void> release() async {
    final raf = _raf;
    if (raf == null) return;
    _raf = null;
    _processHeld.remove(_canonical(lockPath));
    try {
      await raf.unlock();
    } catch (_) {/* ignore */}
    try {
      await raf.close();
    } catch (_) {/* ignore */}
  }

  String _canonical(String p) {
    try {
      return File(p).absolute.path.toLowerCase();
    } catch (_) {
      return p.toLowerCase();
    }
  }

  Future<RandomAccessFile> _openLockFile() async {
    final f = File(lockPath);
    if (!await f.exists()) {
      try {
        await f.create(recursive: true);
      } on FileSystemException {
        // Race with another process creating it — fine.
      }
    }
    return f.open(mode: FileMode.write);
  }
}
