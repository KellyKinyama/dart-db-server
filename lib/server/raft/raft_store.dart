library;

import 'dart:convert';
import 'dart:io';

/// Durable Raft state that must survive restarts: `currentTerm` and `votedFor`
/// (Raft §5). A node must persist these (fsync) before replying to any RPC that
/// relies on them, else a crash+restart could grant a second vote in a term or
/// forget its term and break election safety.
abstract class RaftStore {
  int get currentTerm;
  String? get votedFor;

  /// Durably record [currentTerm] and [votedFor].
  void save(int currentTerm, String? votedFor);
}

/// Non-durable store for tests / single-process use.
class InMemoryRaftStore implements RaftStore {
  @override
  int currentTerm = 0;
  @override
  String? votedFor;

  @override
  void save(int currentTerm, String? votedFor) {
    this.currentTerm = currentTerm;
    this.votedFor = votedFor;
  }
}

/// File-backed store at `<path>` written atomically (temp + fsync + rename).
class FileRaftStore implements RaftStore {
  final String path;
  int _currentTerm = 0;
  String? _votedFor;

  FileRaftStore(this.path) {
    _load();
  }

  @override
  int get currentTerm => _currentTerm;
  @override
  String? get votedFor => _votedFor;

  void _load() {
    try {
      final m = (jsonDecode(File(path).readAsStringSync()) as Map)
          .cast<String, Object?>();
      _currentTerm = (m['current_term'] as num?)?.toInt() ?? 0;
      _votedFor = m['voted_for'] as String?;
    } catch (_) {
      _currentTerm = 0;
      _votedFor = null;
    }
  }

  @override
  void save(int currentTerm, String? votedFor) {
    _currentTerm = currentTerm;
    _votedFor = votedFor;
    final dir = Directory(File(path).parent.path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = '$path.tmp';
    File(tmp).writeAsStringSync(
      jsonEncode({'current_term': currentTerm, 'voted_for': votedFor}),
      flush: true,
    );
    File(tmp).renameSync(path);
  }
}
