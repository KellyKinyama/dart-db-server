/// Session / changeset extension — analogous to SQLite's session module
/// (`sqlite3session_create`, `sqlite3changeset_apply`).
///
/// A [Session] records every INSERT/UPDATE/DELETE that lands on the
/// tables it watches while it is enabled. The recorded changes can be
/// serialized into a portable JSON byte blob via [Session.changeset]
/// and replayed on another [Database] (or the same one) with
/// [Database.applyChangeset].
///
/// The format is a UTF-8 JSON document. Not byte-compatible with
/// SQLite's binary `.changeset` format, but round-trips faithfully
/// across this engine and is trivial to inspect.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One captured row-level change.
class Change {
  /// `'INSERT'`, `'UPDATE'`, or `'DELETE'`.
  final String op;
  final String table;

  /// Column names, in table order at recording time.
  final List<String> columns;

  /// Pre-mutation row values. Null for INSERT.
  final List<Object?>? oldValues;

  /// Post-mutation row values. Null for DELETE.
  final List<Object?>? newValues;

  /// Names of the columns that uniquely identify the row (used to
  /// locate the target row when replaying UPDATE/DELETE). Empty when
  /// the source table has no primary key — in that case replay falls
  /// back to whole-row matching.
  final List<String> pkColumns;

  Change({
    required this.op,
    required this.table,
    required this.columns,
    required this.pkColumns,
    this.oldValues,
    this.newValues,
  });

  Map<String, Object?> toJson() => {
        'op': op,
        'table': table,
        'columns': columns,
        'pk': pkColumns,
        if (oldValues != null) 'old': _encodeValues(oldValues!),
        if (newValues != null) 'new': _encodeValues(newValues!),
      };

  factory Change.fromJson(Map<String, Object?> j) => Change(
        op: j['op'] as String,
        table: j['table'] as String,
        columns: (j['columns'] as List).cast<String>(),
        pkColumns: (j['pk'] as List).cast<String>(),
        oldValues: j.containsKey('old')
            ? _decodeValues((j['old'] as List).cast<Object?>())
            : null,
        newValues: j.containsKey('new')
            ? _decodeValues((j['new'] as List).cast<Object?>())
            : null,
      );

  /// JSON cannot represent Uint8List directly; encode BLOBs as a tagged
  /// object `{"__blob__": "<base64>"}`. Other values pass through.
  static List<Object?> _encodeValues(List<Object?> vs) {
    return [
      for (final v in vs)
        if (v is Uint8List)
          {'__blob__': base64.encode(v)}
        else if (v is List<int>)
          {'__blob__': base64.encode(v)}
        else
          v
    ];
  }

  static List<Object?> _decodeValues(List<Object?> vs) {
    return [
      for (final v in vs)
        if (v is Map && v.containsKey('__blob__'))
          Uint8List.fromList(base64.decode(v['__blob__'] as String))
        else
          v
    ];
  }
}

/// Conflict outcomes returned by an [ChangesetConflictHandler].
enum ConflictResolution {
  /// Skip this change and continue with the next one.
  skip,

  /// Replace the conflicting row with the change's new values
  /// (UPDATE/INSERT only).
  replace,

  /// Abort the whole apply, rolling back any changes already applied
  /// in this call.
  abort,
}

/// Reasons a change might fail to apply cleanly.
enum ConflictKind {
  /// INSERT: a row with the same PK already exists.
  notUnique,

  /// UPDATE / DELETE: no row matched the recorded PK.
  notFound,

  /// UPDATE: the matched row's current values disagree with the
  /// recorded `oldValues`. (We're permissive by default — only
  /// surfaced when [Database.applyChangeset] is given a handler.)
  data,
}

typedef ChangesetConflictHandler = ConflictResolution Function(
    Change change, ConflictKind kind);

/// A live recording of mutations against a [Database]. Construct via
/// [Database.beginSession]. Sessions stay attached and recording until
/// [close] is called.
class Session {
  /// Tables the session watches. Empty means "every table".
  final Set<String> _tables = <String>{};

  final List<Change> _changes = [];
  bool _enabled = true;
  bool _closed = false;

  /// Internal hook called by the Database when a mutation lands. Not
  /// part of the public API but kept package-visible for the engine.
  void recordInternal(Change c) {
    if (_closed || !_enabled) return;
    if (_tables.isNotEmpty && !_tables.contains(c.table.toLowerCase())) {
      return;
    }
    _changes.add(c);
  }

  /// Attach a specific table to the session. If never called, the
  /// session records mutations on every table (the default).
  void attach(String table) {
    _tables.add(table.toLowerCase());
  }

  /// Pause recording without losing already-captured changes.
  void disable() => _enabled = false;

  /// Resume recording.
  void enable() => _enabled = true;

  /// Whether the session is currently capturing changes.
  bool get isEnabled => _enabled && !_closed;

  /// Drop everything captured so far.
  void clear() => _changes.clear();

  /// Snapshot of captured changes in order.
  List<Change> get changes => List.unmodifiable(_changes);

  /// True after [close]. Closed sessions ignore further mutations and
  /// still let callers read [changes] / produce a [changeset].
  bool get isClosed => _closed;

  /// Stop recording. Idempotent.
  void close() {
    _closed = true;
  }

  /// Serialize captured changes to a portable byte blob suitable for
  /// passing to [Database.applyChangeset].
  Uint8List changeset() {
    final doc = {
      '__ddbs_changeset__': 1,
      'changes': [for (final c in _changes) c.toJson()],
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(doc)));
  }

  /// Decode a changeset blob into its [Change] list.
  static List<Change> decode(Uint8List bytes) {
    final doc = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    if (doc['__ddbs_changeset__'] != 1) {
      throw FormatException('not a dart_db_server changeset');
    }
    return [
      for (final c in (doc['changes'] as List).cast<Map<String, Object?>>())
        Change.fromJson(c)
    ];
  }
}
