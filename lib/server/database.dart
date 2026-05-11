/// Database engine: tables + views, executes statements (DDL/DML/queries),
/// handles transactions, foreign keys, CHECK constraints, AUTOINCREMENT,
/// aggregates/GROUP BY, subqueries, UNION, etc., and persists to JSON.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'concurrency.dart';
import 'expression.dart';
import 'parser.dart';
import 'prepared.dart';
import 'result.dart';
import 'schema.dart';
import 'sqlite_format.dart';
import 'statement.dart';
import 'table.dart';

/// Outcome of an [AuthorizerCallback] invocation. Mirrors the
/// SQLITE_OK / SQLITE_DENY / SQLITE_IGNORE constants of the C API.
enum AuthorizerResult { allow, deny, ignore }

/// Authorizer callback. Invoked by [Database.executeStmt] for every
/// dispatched statement; the second argument is the primary table the
/// statement targets (or null when there is none, e.g. PRAGMA).
typedef AuthorizerCallback = AuthorizerResult Function(
    Statement action, String? tableName);

class Database {
  final Map<String, Table> _tables = <String, Table>{};
  final Map<String, SelectStmt> _views = <String, SelectStmt>{};

  /// Original SELECT SQL text for each view, keyed by view name.
  /// Used to persist views faithfully through save/reload cycles.
  final Map<String, String> _viewSql = <String, String>{};
  final String? path;

  /// When true, [_persist] writes the database as a real SQLite-format
  /// file (via [exportSqlite]). Set automatically when the on-disk file
  /// has the SQLite magic header or when a fresh file is opened with a
  /// `.sqlite`, `.sqlite3`, or `.db` extension.
  bool _persistAsSqlite = false;

  /// Last full-image bytes written to disk for the SQLite path. Used as
  /// the diff baseline for incremental `-wal` persistence.
  Uint8List? _sqliteBaselineBytes;

  /// Page size used the last time we wrote a full image. Subsequent
  /// incremental WAL writes must use the same page size.
  int _sqlitePageSize = 4096;

  /// User-supplied authorizer callback. When non-null, every dispatched
  /// statement is run past this callback before executing; the callback
  /// can [AuthorizerResult.deny] (throws) or [AuthorizerResult.ignore]
  /// (statement is skipped and a message is returned).
  AuthorizerCallback? authorizer;

  /// Queue of FK checks accumulated while `PRAGMA defer_foreign_keys = 1`
  /// is in effect. Replayed at [_commit] time; failure rolls back.
  final List<_DeferredFk> _deferredFkChecks = <_DeferredFk>[];

  bool get _deferFks => _truthy(_pragmas['defer_foreign_keys']);

  static bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().toLowerCase();
    return s == '1' || s == 'true' || s == 'on' || s == 'yes';
  }

  /// Cross-process advisory lock on the JSON file. Created (and acquired)
  /// by [Database.open] when [path] is non-null.
  DbFileLock? _fileLock;

  /// In-process multi-reader / single-writer lock that wraps every call
  /// to [executeStmt]. Reads (SELECT, EXPLAIN, PRAGMA queries, SHOW,
  /// DESCRIBE) take a shared lock; everything else takes exclusive.
  /// Once a transaction is in flight all further statements run under
  /// the writer arm so the snapshot semantics stay coherent.
  final AsyncRwLock _lock = AsyncRwLock();

  /// Test/diagnostics hook: returns the in-process RW lock so callers
  /// can assert serialization properties.
  AsyncRwLock get rwLock => _lock;

  Map<String, Table>? _snapshot;
  Map<String, SelectStmt>? _viewSnapshot;
  bool get inTransaction => _snapshot != null;

  /// Stashed live state while a snapshot transaction is in progress;
  /// see [beginSnapshot]. Restored to [_tables] / [_views] on commit
  /// or rollback.
  Map<String, Table>? _liveTables;
  Map<String, SelectStmt>? _liveViews;

  /// True when the current transaction was started with `BEGIN DEFERRED`
  /// or via [beginSnapshot] — reads inside it consult [_snapshot] (a
  /// frozen view captured at BEGIN time) so concurrent committed
  /// writers don't perturb the result. Writes inside such a
  /// transaction throw.
  bool _readOnlySnapshot = false;
  bool get inReadOnlySnapshot => _readOnlySnapshot;

  /// Stack of in-scope `WITH` CTE bindings. Each entry maps a CTE name to
  /// its materialized result (columns + rows). The newest binding wins.
  final List<Map<String, _CteRel>> _cteStack = <Map<String, _CteRel>>[];

  /// Currently active trigger context (NEW.col / OLD.col bindings). Null
  /// when no trigger is firing.
  Map<String, Object?>? _triggerScope;

  /// Triggers attached to tables. Stored separately from [_tables] so they
  /// can persist alongside the schema.
  final Map<String, _TriggerSpec> _triggers = <String, _TriggerSpec>{};

  /// Stack of savepoints (name + table snapshot).
  final List<_Savepoint> _savepoints = <_Savepoint>[];

  /// ATTACH DATABASE: alias -> file path. Tables loaded from each attached
  /// database are stored in [_tables] keyed `alias.tablename`.
  final Map<String, String> _attached = <String, String>{};

  /// In-memory PRAGMA state. Provides recognizable values for common
  /// PRAGMAs (read/write); unknown PRAGMAs are accepted as no-ops.
  final Map<String, Object?> _pragmas = <String, Object?>{
    'foreign_keys': 1,
    'journal_mode': 'memory',
    'user_version': 0,
    'synchronous': 'normal',
    'encoding': 'UTF-8',
  };

  /// Optional per-table query-planner statistics, populated by `ANALYZE`.
  /// When a table is missing from this map the planner falls back to
  /// constant heuristics (see [_estimateEqualityHits]).
  final Map<String, _TableStats> _stats = <String, _TableStats>{};

  /// Last plan chosen by the executor for the most recent SELECT. Exposed
  /// to tests via [lastPlanTrace] so we can assert "this query used the
  /// expected index" without parsing EXPLAIN output.
  List<String> _planTrace = const [];
  List<String> get lastPlanTrace => List.unmodifiable(_planTrace);

  /// Cumulative count of index-only (covering) scans the executor has
  /// served. Reset by [resetCounters]. Tests use this to assert that a
  /// query took the covering path.
  int coveringScansUsed = 0;

  /// Reset perf counters (currently just [coveringScansUsed]).
  void resetCounters() {
    coveringScansUsed = 0;
  }

  Database({this.path});

  static Future<Database> open([String? path]) async {
    final db = Database(path: path);
    if (path != null) {
      // Acquire the cross-process file lock before touching the file.
      db._fileLock = DbFileLock(path);
      await db._fileLock!.acquire();
      if (await File(path).exists()) {
        await db._load();
      } else {
        // Fresh file: pick the persist format from the extension.
        final lower = path.toLowerCase();
        if (lower.endsWith('.sqlite') ||
            lower.endsWith('.sqlite3') ||
            lower.endsWith('.db')) {
          db._persistAsSqlite = true;
        }
      }
    }
    return db;
  }

  /// Release the cross-process file lock. Idempotent. Always call this
  /// when you're done with a path-backed database — otherwise the
  /// `<path>.lock` sidecar will keep readers/writers blocked until the
  /// process exits.
  Future<void> close() async {
    final fl = _fileLock;
    _fileLock = null;
    if (fl != null) await fl.release();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------
  Future<QueryResult> execute(String sql) async {
    final stmt = Parser.fromString(sql).parseStatement();
    return executeStmt(stmt);
  }

  Future<List<QueryResult>> executeScript(String sql) async {
    final stmts = Parser.fromString(sql).parseScript();
    final results = <QueryResult>[];
    for (final s in stmts) {
      results.add(await executeStmt(s));
    }
    return results;
  }

  /// Parse [sql] once and return a reusable [PreparedStatement]. Bind
  /// parameters in the SQL (`?`, `?N`, `:name`, `@name`, `$name`) are
  /// substituted at `.execute(...)` time, so the statement can be run
  /// many times with different bindings without re-parsing.
  ///
  /// This is the recommended way to embed user-supplied values in
  /// queries — it eliminates the need for ad-hoc string concatenation
  /// and therefore the entire SQL-injection attack surface.
  PreparedStatement prepare(String sql) {
    final p = Parser.fromString(sql);
    final stmt = p.parseStatement();
    return PreparedStatement.internal(
      db: this,
      stmt: stmt,
      sql: sql,
      positionalCount: p.paramCount,
      namedParams: Set.unmodifiable(p.namedParams),
    );
  }

  /// One-shot convenience: prepare [sql], bind [positional]/[named],
  /// run once, and return the result. Use [prepare] directly if you
  /// want to reuse the statement.
  Future<QueryResult> executeWith(
    String sql, {
    List<Object?> positional = const [],
    Map<String, Object?> named = const {},
  }) {
    return prepare(sql).execute(positional: positional, named: named);
  }

  Future<QueryResult> executeStmt(Statement stmt) async {
    // Statements that span a transaction boundary always need exclusive
    // access; otherwise SELECT-ish statements take the shared arm.
    final wantsWrite = inTransaction ||
        _isMutation(stmt) ||
        stmt is BeginStmt ||
        stmt is CommitStmt ||
        stmt is RollbackStmt ||
        stmt is SavepointStmt ||
        stmt is ReleaseSavepointStmt ||
        stmt is RollbackToSavepointStmt;

    Future<QueryResult> body() async {
      if (_readOnlySnapshot && _isMutation(stmt)) {
        throw StateError(
            'Cannot mutate inside a read-only snapshot transaction');
      }
      final cb = authorizer;
      if (cb != null) {
        final outcome = cb(stmt, _statementTable(stmt));
        if (outcome == AuthorizerResult.deny) {
          throw StateError('not authorized');
        }
        if (outcome == AuthorizerResult.ignore) {
          return QueryResult.message('ignored by authorizer');
        }
      }
      final result = _dispatch(stmt);
      if (stmt is CommitStmt) {
        await _persist();
        return result;
      }
      if (!inTransaction && _isMutation(stmt)) {
        await _persist();
      }
      return result;
    }

    return wantsWrite ? _lock.write(body) : _lock.read(body);
  }

  /// Begin a read-only snapshot transaction. The current state of every
  /// table is cloned and used as the live view for the duration of the
  /// transaction; concurrent writers in the same process block on the
  /// writer arm of [rwLock] until the snapshot is committed/rolled back.
  /// Any mutation inside the snapshot is rejected.
  Future<QueryResult> beginSnapshot() => _lock.write(() async {
        if (inTransaction) {
          throw StateError('Already in a transaction');
        }
        // Stash the live state; install a deep-cloned view as _tables
        // so all read paths transparently see the snapshot.
        _liveTables = Map<String, Table>.from(_tables);
        _liveViews = Map<String, SelectStmt>.from(_views);
        final cloned = {
          for (final e in _tables.entries) e.key: e.value.clone(),
        };
        _snapshot = Map<String, Table>.from(cloned);
        _viewSnapshot = Map<String, SelectStmt>.from(_views);
        _tables
          ..clear()
          ..addAll(cloned);
        _readOnlySnapshot = true;
        return QueryResult.message('Snapshot transaction started');
      });

  /// Snapshot-read primitive: clones the current table set and runs
  /// [body] against the clone. Multiple [snapshotRead] calls can
  /// progress concurrently, and they don't observe writes that happen
  /// after the clone moment. The clone is acquired under the *read*
  /// arm of [rwLock] (so it is consistent with whatever a parallel
  /// writer has just committed) and then released immediately, so the
  /// body itself runs with no locks held.
  ///
  /// This is the closest the engine gets to "real MVCC": readers and
  /// writers don't block each other once the snapshot is taken.
  Future<T> snapshotRead<T>(FutureOr<T> Function(Database snap) body) async {
    final clonedTables = await _lock.read(() => {
          for (final e in _tables.entries) e.key: e.value.clone(),
        });
    final snap = Database();
    snap._tables.addAll(clonedTables);
    snap._views.addAll(_views);
    return body(snap);
  }

  /// Synchronous dispatch \u2014 used directly by trigger bodies (which must run\n  /// in-line with their host INSERT/UPDATE/DELETE).
  QueryResult _dispatch(Statement stmt) {
    QueryResult result;
    if (stmt is CreateTableStmt) {
      result = _createTable(stmt);
    } else if (stmt is DropTableStmt) {
      result = _dropTable(stmt);
    } else if (stmt is TruncateTableStmt) {
      result = _truncate(stmt);
    } else if (stmt is AlterTableAddColumnStmt) {
      result = _alterAddColumn(stmt);
    } else if (stmt is AlterTableDropColumnStmt) {
      result = _alterDropColumn(stmt);
    } else if (stmt is AlterTableRenameColumnStmt) {
      result = _alterRenameColumn(stmt);
    } else if (stmt is AlterTableRenameStmt) {
      result = _alterRenameTable(stmt);
    } else if (stmt is CreateIndexStmt) {
      result = _createIndex(stmt);
    } else if (stmt is DropIndexStmt) {
      result = _dropIndex(stmt);
    } else if (stmt is CreateViewStmt) {
      result = _createView(stmt);
    } else if (stmt is DropViewStmt) {
      result = _dropView(stmt);
    } else if (stmt is InsertStmt) {
      result = _insert(stmt);
    } else if (stmt is SelectStmt) {
      result = _selectTopLevel(stmt);
    } else if (stmt is UpdateStmt) {
      result = _update(stmt);
    } else if (stmt is DeleteStmt) {
      result = _delete(stmt);
    } else if (stmt is BeginStmt) {
      result = _begin();
    } else if (stmt is CommitStmt) {
      result = _commit();
    } else if (stmt is RollbackStmt) {
      result = _rollback();
    } else if (stmt is ShowTablesStmt) {
      result = _showTables();
    } else if (stmt is DescribeStmt) {
      result = _describe(stmt);
    } else if (stmt is ExplainStmt) {
      result = _explain(stmt);
    } else if (stmt is PragmaStmt) {
      result = _pragma(stmt);
    } else if (stmt is CreateTriggerStmt) {
      result = _createTrigger(stmt);
    } else if (stmt is DropTriggerStmt) {
      result = _dropTrigger(stmt);
    } else if (stmt is SavepointStmt) {
      result = _savepoint(stmt);
    } else if (stmt is ReleaseSavepointStmt) {
      result = _releaseSavepoint(stmt);
    } else if (stmt is RollbackToSavepointStmt) {
      result = _rollbackToSavepoint(stmt);
    } else if (stmt is AttachDatabaseStmt) {
      result = _attachDatabase(stmt);
    } else if (stmt is DetachDatabaseStmt) {
      result = _detachDatabase(stmt);
    } else if (stmt is VacuumStmt) {
      result = _vacuum(stmt);
    } else if (stmt is AnalyzeStmt) {
      result = _analyze(stmt);
    } else if (stmt is CreateVirtualTableStmt) {
      result = _createVirtualTable(stmt);
    } else {
      throw StateError('Unknown statement: $stmt');
    }
    return result;
  }

  bool _isMutation(Statement s) =>
      s is CreateTableStmt ||
      s is DropTableStmt ||
      s is TruncateTableStmt ||
      s is AlterTableAddColumnStmt ||
      s is AlterTableDropColumnStmt ||
      s is AlterTableRenameColumnStmt ||
      s is AlterTableRenameStmt ||
      s is CreateIndexStmt ||
      s is DropIndexStmt ||
      s is CreateViewStmt ||
      s is DropViewStmt ||
      s is InsertStmt ||
      s is UpdateStmt ||
      s is DeleteStmt ||
      s is CreateTriggerStmt ||
      s is DropTriggerStmt ||
      s is VacuumStmt ||
      s is AnalyzeStmt ||
      s is CreateVirtualTableStmt;

  /// Best-effort: primary table touched by [s], used to seed the
  /// authorizer callback's `tableName` argument. Returns null when the
  /// statement has no single target (PRAGMA, BEGIN, EXPLAIN, ...).
  String? _statementTable(Statement s) {
    if (s is CreateTableStmt) return s.name;
    if (s is DropTableStmt) return s.name;
    if (s is TruncateTableStmt) return s.name;
    if (s is AlterTableAddColumnStmt) return s.table;
    if (s is AlterTableDropColumnStmt) return s.table;
    if (s is AlterTableRenameColumnStmt) return s.table;
    if (s is AlterTableRenameStmt) return s.oldName;
    if (s is CreateIndexStmt) return s.table;
    if (s is CreateViewStmt) return s.name;
    if (s is DropViewStmt) return s.name;
    if (s is InsertStmt) return s.table;
    if (s is UpdateStmt) return s.table;
    if (s is DeleteStmt) return s.table;
    if (s is SelectStmt) return s.fromTable;
    if (s is CreateTriggerStmt) return s.table;
    return null;
  }

  // ---------------------------------------------------------------------------
  // DDL
  // ---------------------------------------------------------------------------
  QueryResult _createTable(CreateTableStmt s) {
    if (_tables.containsKey(s.name) || _views.containsKey(s.name)) {
      if (s.ifNotExists) {
        return QueryResult.message('Table ${s.name} already exists');
      }
      throw StateError('Table ${s.name} already exists');
    }
    final t = Table(s.name, s.columns,
        constraints: s.constraints,
        strict: s.strict,
        withoutRowid: s.withoutRowid);
    _tables[s.name] = t;
    // Auto-create unique indexes for column-level PK/UNIQUE.
    for (final c in s.columns) {
      if (c.primaryKey || c.unique) {
        t.createIndex(IndexDef('${s.name}__${c.name}', c.name, unique: true));
      }
    }
    return QueryResult.message('Table ${s.name} created');
  }

  QueryResult _dropTable(DropTableStmt s) {
    if (!_tables.containsKey(s.name)) {
      if (s.ifExists) {
        return QueryResult.message('Table ${s.name} did not exist');
      }
      throw StateError('No such table: ${s.name}');
    }
    // Block drop if some other table references this one (unless cascade — not impl).
    for (final other in _tables.values) {
      if (other.name == s.name) continue;
      for (final con in _foreignKeysOf(other)) {
        if (con.references.table == s.name) {
          throw StateError(
              'Cannot drop ${s.name}: referenced by ${other.name}');
        }
      }
    }
    _tables.remove(s.name);
    return QueryResult.message('Table ${s.name} dropped');
  }

  QueryResult _truncate(TruncateTableStmt s) {
    final t = _requireTable(s.name);
    final n = t.rows.length;
    t.rows.clear();
    t.autoInc.clear();
    // Rebuild indexes (now empty).
    final defs = List<IndexDef>.from(t.indexDefs.values);
    for (final d in defs) {
      t.dropIndex(d.name);
      t.createIndex(d);
    }
    return QueryResult.message('Truncated $n row(s) from ${s.name}',
        affected: n);
  }

  QueryResult _alterAddColumn(AlterTableAddColumnStmt s) {
    final t = _requireTable(s.table);
    t.addColumn(s.column);
    if (s.column.primaryKey || s.column.unique) {
      t.createIndex(
          IndexDef('${t.name}__${s.column.name}', s.column.name, unique: true));
    }
    // Backfill GENERATED ALWAYS values for existing rows.
    if (s.column.generatedExprSql != null) {
      _recomputeGenerated(t, s.column);
    }
    return QueryResult.message('Column ${s.column.name} added to ${s.table}');
  }

  QueryResult _alterDropColumn(AlterTableDropColumnStmt s) {
    final t = _requireTable(s.table);
    final idx = t.columnIndex(s.column);
    // Drop any indexes on this column.
    final toDrop = t.indexDefs.values
        .where((d) => d.column.toLowerCase() == s.column.toLowerCase())
        .map((d) => d.name)
        .toList();
    for (final n in toDrop) {
      t.dropIndex(n);
    }
    t.columns.removeAt(idx);
    for (final r in t.rows) {
      r.removeAt(idx);
    }
    return QueryResult.message('Column ${s.column} dropped from ${s.table}');
  }

  QueryResult _alterRenameColumn(AlterTableRenameColumnStmt s) {
    final t = _requireTable(s.table);
    final idx = t.columnIndex(s.oldName);
    final old = t.columns[idx];
    t.columns[idx] = ColumnDef(
      s.newName,
      old.type,
      primaryKey: old.primaryKey,
      notNull: old.notNull,
      unique: old.unique,
      autoIncrement: old.autoIncrement,
      defaultValue: old.defaultValue,
      checkExprSql: old.checkExprSql,
      references: old.references,
      generatedExprSql: old.generatedExprSql,
      generatedStored: old.generatedStored,
    );
    // Rename in autoInc + index defs that reference this column.
    if (t.autoInc.containsKey(s.oldName)) {
      t.autoInc[s.newName] = t.autoInc.remove(s.oldName)!;
    }
    final renamed = <String, IndexDef>{};
    for (final e in t.indexDefs.entries) {
      if (e.value.column.toLowerCase() == s.oldName.toLowerCase()) {
        renamed[e.key] =
            IndexDef(e.value.name, s.newName, unique: e.value.unique);
      }
    }
    renamed.forEach((k, v) {
      t.indexDefs[k] = v;
    });
    return QueryResult.message(
        'Column ${s.oldName} renamed to ${s.newName} in ${s.table}');
  }

  QueryResult _alterRenameTable(AlterTableRenameStmt s) {
    final t = _requireTable(s.oldName);
    if (_tables.containsKey(s.newName) || _views.containsKey(s.newName)) {
      throw StateError('Object ${s.newName} already exists');
    }
    _tables.remove(s.oldName);
    t.name = s.newName;
    _tables[s.newName] = t;
    return QueryResult.message('Table ${s.oldName} renamed to ${s.newName}');
  }

  /// Recompute GENERATED column values for all rows in [t].
  void _recomputeGenerated(Table t, ColumnDef col) {
    final idx = t.columnIndex(col.name);
    final expr = (Parser.fromString('SELECT ${col.generatedExprSql}')
            .parseStatement() as SelectStmt)
        .projection
        .first
        .expr!;
    final bound = _bindExpr(expr);
    for (final r in t.rows) {
      final view = t.rowToMap(r);
      r[idx] = coerce(bound.eval(view), col.type);
    }
  }

  QueryResult _createIndex(CreateIndexStmt s) {
    final t = _requireTable(s.table);
    final hasNonBinary = s.collations.any((c) => c.toUpperCase() != 'BINARY');
    t.createIndex(IndexDef(s.indexName, s.column,
        unique: s.unique,
        whereSql: s.whereSql,
        exprSql: s.exprSql,
        columns: s.columns.length > 1 ? s.columns : null,
        collations: hasNonBinary ? s.collations : null));
    return QueryResult.message('Index ${s.indexName} created');
  }

  QueryResult _dropIndex(DropIndexStmt s) {
    for (final t in _tables.values) {
      if (t.indexDefs.containsKey(s.indexName)) {
        t.dropIndex(s.indexName);
        return QueryResult.message('Index ${s.indexName} dropped');
      }
    }
    throw StateError('No such index: ${s.indexName}');
  }

  QueryResult _createView(CreateViewStmt s) {
    if (_tables.containsKey(s.name) || _views.containsKey(s.name)) {
      if (s.ifNotExists) {
        return QueryResult.message('View ${s.name} already exists');
      }
      throw StateError('Object ${s.name} already exists');
    }
    _views[s.name] = s.select;
    if (s.selectSql.isNotEmpty) _viewSql[s.name] = s.selectSql;
    return QueryResult.message('View ${s.name} created');
  }

  QueryResult _dropView(DropViewStmt s) {
    if (!_views.containsKey(s.name)) {
      if (s.ifExists) {
        return QueryResult.message('View ${s.name} did not exist');
      }
      throw StateError('No such view: ${s.name}');
    }
    _views.remove(s.name);
    _viewSql.remove(s.name);
    return QueryResult.message('View ${s.name} dropped');
  }

  // ---------------------------------------------------------------------------
  // INSERT / REPLACE
  // ---------------------------------------------------------------------------
  QueryResult _insert(InsertStmt s) {
    final pushed = _pushCtes(s.ctes,
        recursive: s.ctesRecursive, columnsOverride: s.cteColumns);
    try {
      return _insertCore(s);
    } finally {
      if (pushed) _cteStack.removeLast();
    }
  }

  QueryResult _insertCore(InsertStmt s) {
    // INSTEAD OF INSERT on a view → run trigger bodies per literal row.
    if (_views.containsKey(s.table) &&
        _triggersFor(s.table, 'INSERT', 'INSTEAD OF').isNotEmpty) {
      return _runInsteadOfInsert(s);
    }
    final t = _requireTable(s.table);

    // Build the list of literal value-rows up front. For INSERT ... SELECT
    // we materialize the inner select first, then convert each result row
    // into a list of LiteralExprs.
    final List<List<Expr>> sourceRows;
    if (s.select != null) {
      final res = _selectTopLevel(s.select!);
      sourceRows = [
        for (final row in res.rows) [for (final v in row) LiteralExpr(v)]
      ];
    } else {
      sourceRows = s.rows ?? const <List<Expr>>[];
    }

    var inserted = 0;
    final returnedRows = <List<Object?>>[];
    final returningExprs = <Expr>[];
    final returningCols = <String>[];
    if (s.returning != null) {
      for (final item in s.returning!) {
        if (item.isStar) {
          for (final c in t.columns) {
            returningCols.add(c.name);
            returningExprs.add(_bindExpr(ColumnExpr(c.name)));
          }
        } else {
          returningCols.add(item.alias ?? _exprLabel(item.expr!));
          returningExprs.add(_bindExpr(item.expr!));
        }
      }
    }

    for (final values in sourceRows) {
      final row = List<Object?>.filled(t.columns.length, null, growable: true);
      // Apply column defaults first.
      for (var i = 0; i < t.columns.length; i++) {
        final c = t.columns[i];
        if (c.defaultValue != null) row[i] = coerce(c.defaultValue, c.type);
      }
      if (s.columns == null) {
        if (values.length != t.columns.length) {
          throw StateError(
              'Expected ${t.columns.length} values, got ${values.length}');
        }
        for (var i = 0; i < values.length; i++) {
          row[i] = coerceForColumn(_evalScalar(values[i]), t.columns[i],
              strict: t.strict);
        }
      } else {
        if (values.length != s.columns!.length) {
          throw StateError('Column/value count mismatch');
        }
        for (var i = 0; i < s.columns!.length; i++) {
          final colIdx = t.columnIndex(s.columns![i]);
          row[colIdx] = coerceForColumn(
              _evalScalar(values[i]), t.columns[colIdx],
              strict: t.strict);
        }
      }
      // AUTOINCREMENT
      for (var i = 0; i < t.columns.length; i++) {
        final c = t.columns[i];
        if (c.autoIncrement && row[i] == null) {
          final next = (t.autoInc[c.name] ?? _maxIntColumn(t, i)) + 1;
          row[i] = next;
          t.autoInc[c.name] = next;
        } else if (c.autoIncrement && row[i] is int) {
          final cur = t.autoInc[c.name] ?? 0;
          if ((row[i] as int) > cur) t.autoInc[c.name] = row[i] as int;
        }
      }
      _evaluateGenerated(t, row);
      _enforceChecks(t, row);
      _enforceForeignKeysOnInsert(t, row);
      _fireTriggers(t.name, 'INSERT', 'BEFORE', newRow: row, sourceTable: t);

      try {
        t.insertRow(row);
        inserted++;
        _fireTriggers(t.name, 'INSERT', 'AFTER', newRow: row, sourceTable: t);
        if (returningExprs.isNotEmpty) {
          final view = t.rowToMap(row);
          returnedRows.add(returningExprs.map((e) => e.eval(view)).toList());
        }
      } on StateError {
        // UPSERT: ON CONFLICT takes precedence over OR REPLACE / OR IGNORE
        // for the rows it matches.
        if (s.onConflict != null) {
          final conflictIdx = _findUniqueConflictsForTarget(
              t, row, s.onConflict!.targetColumns);
          if (conflictIdx.isNotEmpty) {
            if (s.onConflict!.doNothing) {
              continue;
            }
            // ON CONFLICT DO UPDATE: apply assignments to the existing row(s).
            for (final i in conflictIdx) {
              _applyUpsertUpdate(t, i, row, s.onConflict!);
            }
            if (returningExprs.isNotEmpty) {
              for (final i in conflictIdx) {
                final view = t.rowToMap(t.rows[i]);
                returnedRows
                    .add(returningExprs.map((e) => e.eval(view)).toList());
              }
            }
            continue;
          }
        }
        if (s.mode == InsertMode.orIgnore) continue;
        if (s.mode == InsertMode.orReplace) {
          final conflictIdx = _findUniqueConflicts(t, row);
          if (conflictIdx.isNotEmpty) {
            final sorted = conflictIdx.toList()..sort((a, b) => b.compareTo(a));
            for (final i in sorted) {
              _enforceForeignKeysOnDelete(t, t.rows[i]);
              t.rows.removeAt(i);
            }
            _rebuildIndexes(t);
            t.insertRow(row);
            inserted++;
            if (returningExprs.isNotEmpty) {
              final view = t.rowToMap(row);
              returnedRows
                  .add(returningExprs.map((e) => e.eval(view)).toList());
            }
            continue;
          }
        }
        rethrow;
      }
    }
    if (s.returning != null) {
      return QueryResult(
          columns: returningCols, rows: returnedRows, affected: inserted);
    }
    return QueryResult.message('$inserted row(s) inserted', affected: inserted);
  }

  int _maxIntColumn(Table t, int colIdx) {
    var max = 0;
    for (final r in t.rows) {
      final v = r[colIdx];
      if (v is int && v > max) max = v;
    }
    return max;
  }

  Set<int> _findUniqueConflicts(Table t, List<Object?> newRow) {
    final out = <int>{};
    for (var i = 0; i < t.columns.length; i++) {
      final c = t.columns[i];
      if (!(c.primaryKey || c.unique)) continue;
      if (newRow[i] == null) continue;
      for (var ri = 0; ri < t.rows.length; ri++) {
        if (sqlEq(t.rows[ri][i] as Object, newRow[i] as Object)) out.add(ri);
      }
    }
    // Composite PK/UNIQUE
    for (final con in t.constraints) {
      List<String>? cols;
      if (con is PrimaryKeyConstraint) cols = con.columns;
      if (con is UniqueConstraint) cols = con.columns;
      if (cols == null) continue;
      final idxs = cols.map(t.columnIndex).toList();
      final newKey = idxs.map((i) => newRow[i]).toList();
      for (var ri = 0; ri < t.rows.length; ri++) {
        var match = true;
        for (var k = 0; k < idxs.length; k++) {
          final a = t.rows[ri][idxs[k]];
          final b = newKey[k];
          if (a == null || b == null) {
            match = false;
            break;
          }
          if (!sqlEq(a, b)) {
            match = false;
            break;
          }
        }
        if (match) out.add(ri);
      }
    }
    return out;
  }

  void _rebuildIndexes(Table t) {
    final defs = List<IndexDef>.from(t.indexDefs.values);
    for (final d in defs) {
      t.dropIndex(d.name);
    }
    for (final d in defs) {
      t.createIndex(d);
    }
  }

  /// Like [_findUniqueConflicts] but optionally restricted to a specific
  /// `ON CONFLICT (cols)` target. Empty [target] => any unique conflict.
  Set<int> _findUniqueConflictsForTarget(
      Table t, List<Object?> newRow, List<String> target) {
    if (target.isEmpty) return _findUniqueConflicts(t, newRow);
    final idxs = target.map(t.columnIndex).toList();
    final out = <int>{};
    for (var ri = 0; ri < t.rows.length; ri++) {
      var match = true;
      for (final i in idxs) {
        final a = t.rows[ri][i];
        final b = newRow[i];
        if (a == null || b == null) {
          match = false;
          break;
        }
        if (!sqlEq(a, b)) {
          match = false;
          break;
        }
      }
      if (match) out.add(ri);
    }
    return out;
  }

  /// Apply an `ON CONFLICT DO UPDATE` clause to the existing row at index
  /// [rowIdx]. The proposed-insert row [excludedRow] is exposed as
  /// `excluded.col` references inside the assignment expressions.
  void _applyUpsertUpdate(
      Table t, int rowIdx, List<Object?> excludedRow, OnConflictClause c) {
    // Build evaluation context with bare column names from the existing row
    // plus `excluded.col` from the proposed insert.
    final existing = t.rowToMap(t.rows[rowIdx]);
    final ctx = <String, Object?>{...existing};
    for (var i = 0; i < t.columns.length; i++) {
      ctx['excluded.${t.columns[i].name}'] = excludedRow[i];
      ctx['EXCLUDED.${t.columns[i].name}'] = excludedRow[i];
    }
    if (c.where != null && !evalPredicate(_bindExpr(c.where!), ctx)) {
      return;
    }
    // Snapshot OLD row for triggers.
    final oldRow = List<Object?>.from(t.rows[rowIdx]);
    final newRow = List<Object?>.from(t.rows[rowIdx]);
    c.assignments.forEach((col, expr) {
      final ci = t.columnIndex(col);
      newRow[ci] = coerceForColumn(_bindExpr(expr).eval(ctx), t.columns[ci],
          strict: t.strict);
    });
    _evaluateGenerated(t, newRow);
    _enforceChecks(t, newRow);
    _fireTriggers(t.name, 'UPDATE', 'BEFORE',
        newRow: newRow, oldRow: oldRow, sourceTable: t);
    t.rows[rowIdx] = newRow;
    _rebuildIndexes(t);
    _fireTriggers(t.name, 'UPDATE', 'AFTER',
        newRow: newRow, oldRow: oldRow, sourceTable: t);
  }

  // ---------------------------------------------------------------------------
  // UPDATE / DELETE
  // ---------------------------------------------------------------------------
  QueryResult _update(UpdateStmt s) {
    final pushed = _pushCtes(s.ctes,
        recursive: s.ctesRecursive, columnsOverride: s.cteColumns);
    try {
      if (_views.containsKey(s.table) &&
          _triggersFor(s.table, 'UPDATE', 'INSTEAD OF').isNotEmpty) {
        return _runInsteadOfUpdate(s);
      }
      final t = _requireTable(s.table);
      var count = 0;
      final returningExprs = <Expr>[];
      final returningCols = <String>[];
      if (s.returning != null) {
        for (final item in s.returning!) {
          if (item.isStar) {
            for (final c in t.columns) {
              returningCols.add(c.name);
              returningExprs.add(_bindExpr(ColumnExpr(c.name)));
            }
          } else {
            returningCols.add(item.alias ?? _exprLabel(item.expr!));
            returningExprs.add(_bindExpr(item.expr!));
          }
        }
      }
      final returnedRows = <List<Object?>>[];
      for (var ri = 0; ri < t.rows.length; ri++) {
        final row = t.rows[ri];
        final view = t.rowToMap(row);
        if (s.where != null && !evalPredicate(_bindExpr(s.where!), view)) {
          continue;
        }
        final old = List<Object?>.from(row);
        _fireTriggers(t.name, 'UPDATE', 'BEFORE',
            oldRow: old, newRow: row, sourceTable: t);
        s.assignments.forEach((col, expr) {
          final colIdx = t.columnIndex(col);
          row[colIdx] = coerceForColumn(
              _evalScalar(expr, view), t.columns[colIdx],
              strict: t.strict);
        });
        _evaluateGenerated(t, row);
        _enforceChecks(t, row);
        _enforceForeignKeysOnInsert(t, row);
        _cascadeOnUpdate(t, old, row);
        _fireTriggers(t.name, 'UPDATE', 'AFTER',
            oldRow: old, newRow: row, sourceTable: t);
        if (returningExprs.isNotEmpty) {
          final v2 = t.rowToMap(row);
          returnedRows.add(returningExprs.map((e) => e.eval(v2)).toList());
        }
        count++;
      }
      if (count > 0) _rebuildIndexes(t);
      if (s.returning != null) {
        return QueryResult(
            columns: returningCols, rows: returnedRows, affected: count);
      }
      return QueryResult.message('$count row(s) updated', affected: count);
    } finally {
      if (pushed) _cteStack.removeLast();
    }
  }

  QueryResult _delete(DeleteStmt s) {
    final pushed = _pushCtes(s.ctes,
        recursive: s.ctesRecursive, columnsOverride: s.cteColumns);
    try {
      if (_views.containsKey(s.table) &&
          _triggersFor(s.table, 'DELETE', 'INSTEAD OF').isNotEmpty) {
        return _runInsteadOfDelete(s);
      }
      final t = _requireTable(s.table);
      final keep = <List<Object?>>[];
      final deleted = <List<Object?>>[];
      final returningExprs = <Expr>[];
      final returningCols = <String>[];
      if (s.returning != null) {
        for (final item in s.returning!) {
          if (item.isStar) {
            for (final c in t.columns) {
              returningCols.add(c.name);
              returningExprs.add(_bindExpr(ColumnExpr(c.name)));
            }
          } else {
            returningCols.add(item.alias ?? _exprLabel(item.expr!));
            returningExprs.add(_bindExpr(item.expr!));
          }
        }
      }
      final returnedRows = <List<Object?>>[];
      for (final row in t.rows) {
        final view = t.rowToMap(row);
        final shouldDelete =
            s.where == null || evalPredicate(_bindExpr(s.where!), view);
        if (shouldDelete) {
          deleted.add(row);
          if (returningExprs.isNotEmpty) {
            returnedRows.add(returningExprs.map((e) => e.eval(view)).toList());
          }
        } else {
          keep.add(row);
        }
      }
      for (final row in deleted) {
        _fireTriggers(t.name, 'DELETE', 'BEFORE', oldRow: row, sourceTable: t);
        _enforceForeignKeysOnDelete(t, row);
      }
      t.rows
        ..clear()
        ..addAll(keep);
      if (deleted.isNotEmpty) _rebuildIndexes(t);
      for (final row in deleted) {
        _fireTriggers(t.name, 'DELETE', 'AFTER', oldRow: row, sourceTable: t);
      }
      if (s.returning != null) {
        return QueryResult(
            columns: returningCols,
            rows: returnedRows,
            affected: deleted.length);
      }
      return QueryResult.message('${deleted.length} row(s) deleted',
          affected: deleted.length);
    } finally {
      if (pushed) _cteStack.removeLast();
    }
  }

  /// Evaluate any GENERATED ALWAYS columns in [row]; mutates [row] in place.
  void _evaluateGenerated(Table t, List<Object?> row) {
    for (var i = 0; i < t.columns.length; i++) {
      final c = t.columns[i];
      if (c.generatedExprSql == null) continue;
      final expr = (Parser.fromString('SELECT ${c.generatedExprSql}')
              .parseStatement() as SelectStmt)
          .projection
          .first
          .expr!;
      final view = t.rowToMap(row);
      final v = _bindExpr(expr).eval(view);
      row[i] = v == null ? null : coerce(v, c.type);
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints
  // ---------------------------------------------------------------------------
  void _enforceChecks(Table t, List<Object?> row) {
    final view = t.rowToMap(row);
    for (var i = 0; i < t.columns.length; i++) {
      final c = t.columns[i];
      if (c.checkExprSql != null) {
        final e =
            Parser.fromString('SELECT ${c.checkExprSql}').parseStatement();
        // Reuse the parsed projection expr.
        final expr = (e as SelectStmt).projection.first.expr!;
        if (!evalPredicate(_bindExpr(expr), view)) {
          throw StateError('CHECK constraint failed on column ${c.name}');
        }
      }
    }
    for (final con in t.constraints) {
      if (con is CheckConstraint) {
        final e = Parser.fromString('SELECT ${con.sql}').parseStatement();
        final expr = (e as SelectStmt).projection.first.expr!;
        if (!evalPredicate(_bindExpr(expr), view)) {
          throw StateError('CHECK constraint failed: ${con.sql}');
        }
      }
    }
  }

  Iterable<ForeignKeyConstraint> _foreignKeysOf(Table t) sync* {
    for (final c in t.columns) {
      if (c.references != null) {
        yield ForeignKeyConstraint([c.name], c.references!);
      }
    }
    for (final con in t.constraints) {
      if (con is ForeignKeyConstraint) yield con;
    }
  }

  void _enforceForeignKeysOnInsert(Table child, List<Object?> row) {
    if (_deferFks && inTransaction) {
      _deferredFkChecks.add(_DeferredFk(child.name, List<Object?>.from(row)));
      return;
    }
    for (final fk in _foreignKeysOf(child)) {
      final values = fk.columns.map((c) => row[child.columnIndex(c)]).toList();
      if (values.any((v) => v == null)) continue; // SQL: any-null => allowed
      final parent = _tables[fk.references.table];
      if (parent == null) {
        throw StateError('FK references missing table ${fk.references.table}');
      }
      final parentCols = fk.references.column != null
          ? [fk.references.column!]
          : _primaryKeyColumns(parent);
      if (parentCols.length != values.length) {
        throw StateError(
            'FK column arity mismatch (${values.length} -> ${parentCols.length})');
      }
      var found = false;
      for (final r in parent.rows) {
        var match = true;
        for (var i = 0; i < parentCols.length; i++) {
          final pv = r[parent.columnIndex(parentCols[i])];
          if (pv == null || !sqlEq(pv, values[i] as Object)) {
            match = false;
            break;
          }
        }
        if (match) {
          found = true;
          break;
        }
      }
      if (!found) {
        throw StateError('FOREIGN KEY constraint failed: '
            '${child.name}.${fk.columns.join(",")} -> '
            '${parent.name}.${parentCols.join(",")} = $values');
      }
    }
  }

  void _enforceForeignKeysOnDelete(Table parent, List<Object?> parentRow) {
    for (final child in _tables.values) {
      for (final fk in _foreignKeysOf(child)) {
        if (fk.references.table != parent.name) continue;
        final parentCols = fk.references.column != null
            ? [fk.references.column!]
            : _primaryKeyColumns(parent);
        final parentValues =
            parentCols.map((c) => parentRow[parent.columnIndex(c)]).toList();
        // Find matching child rows.
        final matchingChildren = <int>[];
        for (var i = 0; i < child.rows.length; i++) {
          final cr = child.rows[i];
          var match = true;
          for (var k = 0; k < parentCols.length; k++) {
            final cv = cr[child.columnIndex(fk.columns[k])];
            if (cv == null ||
                parentValues[k] == null ||
                !sqlEq(cv, parentValues[k]!)) {
              match = false;
              break;
            }
          }
          if (match) matchingChildren.add(i);
        }
        if (matchingChildren.isEmpty) continue;
        switch (fk.references.onDelete) {
          case 'CASCADE':
            // Recursively delete child rows (with their own FK enforcement).
            final sorted = matchingChildren.toList()
              ..sort((a, b) => b.compareTo(a));
            for (final i in sorted) {
              final delRow = child.rows[i];
              _enforceForeignKeysOnDelete(child, delRow);
              child.rows.removeAt(i);
            }
            _rebuildIndexes(child);
            break;
          case 'SET NULL':
            for (final i in matchingChildren) {
              for (final col in fk.columns) {
                child.rows[i][child.columnIndex(col)] = null;
              }
            }
            _rebuildIndexes(child);
            break;
          case 'NO ACTION':
          case 'RESTRICT':
          default:
            throw StateError('FOREIGN KEY constraint failed: '
                '${child.name} references ${parent.name}');
        }
      }
    }
  }

  void _cascadeOnUpdate(
      Table parent, List<Object?> oldRow, List<Object?> newRow) {
    final pkCols = _primaryKeyColumns(parent);
    if (pkCols.isEmpty) return;
    final oldPk = pkCols.map((c) => oldRow[parent.columnIndex(c)]).toList();
    final newPk = pkCols.map((c) => newRow[parent.columnIndex(c)]).toList();
    var changed = false;
    for (var i = 0; i < oldPk.length; i++) {
      if (oldPk[i] != newPk[i]) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    for (final child in _tables.values) {
      for (final fk in _foreignKeysOf(child)) {
        if (fk.references.table != parent.name) continue;
        final parentCols =
            fk.references.column != null ? [fk.references.column!] : pkCols;
        if (parentCols.length != fk.columns.length) continue;
        for (var ri = 0; ri < child.rows.length; ri++) {
          final cr = child.rows[ri];
          var match = true;
          for (var k = 0; k < parentCols.length; k++) {
            final cv = cr[child.columnIndex(fk.columns[k])];
            if (cv == null || oldPk[k] == null || !sqlEq(cv, oldPk[k]!)) {
              match = false;
              break;
            }
          }
          if (!match) continue;
          switch (fk.references.onUpdate) {
            case 'CASCADE':
              for (var k = 0; k < fk.columns.length; k++) {
                cr[child.columnIndex(fk.columns[k])] = newPk[k];
              }
              break;
            case 'SET NULL':
              for (final col in fk.columns) {
                cr[child.columnIndex(col)] = null;
              }
              break;
            case 'NO ACTION':
            case 'RESTRICT':
            default:
              throw StateError('FOREIGN KEY constraint failed on update: '
                  '${child.name} references ${parent.name}');
          }
        }
      }
    }
  }

  List<String> _primaryKeyColumns(Table t) {
    final cols = <String>[];
    for (final con in t.constraints) {
      if (con is PrimaryKeyConstraint) cols.addAll(con.columns);
    }
    if (cols.isEmpty) {
      for (final c in t.columns) {
        if (c.primaryKey) cols.add(c.name);
      }
    }
    return cols;
  }

  // ---------------------------------------------------------------------------
  // SELECT (top-level entry — handles UNION chaining)
  // ---------------------------------------------------------------------------
  QueryResult _selectTopLevel(SelectStmt s,
      [Map<String, Object?> outer = const {}]) {
    final pushed = _pushCtes(s.ctes,
        recursive: s.ctesRecursive, columnsOverride: s.cteColumns);
    try {
      // Non-compound: nothing special.
      if (s.setOp == null) return _selectInner(s, outer);

      // Compound (UNION / UNION ALL / INTERSECT / EXCEPT). Per SQL
      // semantics ORDER BY / LIMIT / OFFSET on a compound apply to the
      // entire combined result, not to any individual arm. Our parser
      // attaches them to whichever simple-SELECT in the chain spelled
      // them out, so we (a) flatten the chain, (b) detect the arm that
      // owns ORDER BY / LIMIT / OFFSET, (c) evaluate every arm without
      // those clauses, (d) combine, then (e) apply ORDER BY / LIMIT /
      // OFFSET once to the combined result.
      final ops = <String>[]; // length == arms.length - 1
      final arms = <SelectStmt>[s];
      var cur = s;
      while (cur.setOp != null) {
        ops.add(cur.setOp!);
        arms.add(cur.setOpRight!);
        cur = cur.setOpRight!;
      }

      // Pick the last arm that carries ORDER BY / LIMIT / OFFSET (matches
      // SQLite which only accepts those on the trailing simple-SELECT).
      SelectStmt? sortArm;
      for (final a in arms) {
        if (a.orderBy.isNotEmpty || a.limit != null || a.offset != null) {
          sortArm = a;
        }
      }

      // Evaluate each arm with the compound ORDER BY / LIMIT / OFFSET
      // stripped so it doesn't pre-sort or pre-truncate.
      final stripped = arms.map(_stripCompoundClauses).toList();
      var acc = _selectInner(stripped.first, outer);
      for (var i = 1; i < stripped.length; i++) {
        final right = _selectInner(stripped[i], outer);
        acc = _combineSets(ops[i - 1], acc, right);
      }

      if (sortArm != null) {
        acc = _applyCompoundOrderLimit(acc, sortArm);
      }
      return acc;
    } finally {
      if (pushed) _cteStack.removeLast();
    }
  }

  /// Return a shallow copy of [s] with `orderBy`, `limit`, `offset` and the
  /// set-operation continuation removed. Used to evaluate one arm of a
  /// compound SELECT in isolation.
  SelectStmt _stripCompoundClauses(SelectStmt s) {
    return SelectStmt(
      projection: s.projection,
      fromTable: s.fromTable,
      fromSubquery: s.fromSubquery,
      fromAlias: s.fromAlias,
      joins: s.joins,
      where: s.where,
      groupBy: s.groupBy,
      having: s.having,
      orderBy: const [],
      limit: null,
      offset: null,
      distinct: s.distinct,
      // Drop the set-op tail so _selectInner sees a plain SELECT.
      setOp: null,
      setOpRight: null,
      ctes: s.ctes,
      cteColumns: s.cteColumns,
      ctesRecursive: s.ctesRecursive,
      fromFunction: s.fromFunction,
      namedWindows: s.namedWindows,
    );
  }

  /// Apply compound-SELECT ORDER BY / LIMIT / OFFSET to a combined
  /// [QueryResult]. Only references that resolve against the projected
  /// output columns are supported (positional integer literals or column
  /// names matching one of [combined.columns]) — same restriction SQLite
  /// imposes on compound ORDER BY.
  QueryResult _applyCompoundOrderLimit(QueryResult combined, SelectStmt s) {
    var rows = combined.rows;
    final cols = combined.columns;

    if (s.orderBy.isNotEmpty) {
      int resolveIndex(Expr e) {
        if (e is LiteralExpr && e.value is int) {
          final pos = (e.value as int) - 1;
          if (pos < 0 || pos >= cols.length) {
            throw StateError('ORDER BY position out of range');
          }
          return pos;
        }
        if (e is ColumnExpr && e.table == null) {
          final i = cols.indexOf(e.name);
          if (i >= 0) return i;
        }
        throw StateError(
            'Compound ORDER BY only supports projected columns or positions');
      }

      final keys = s.orderBy.map((ob) => (resolveIndex(ob.expr), ob)).toList();
      final sorted = List<List<Object?>>.from(rows);
      sorted.sort((a, b) {
        for (final entry in keys) {
          final idx = entry.$1;
          final ob = entry.$2;
          final av = a[idx];
          final bv = b[idx];
          final nullsFirst = ob.nullsFirst ?? !ob.descending;
          if (av == null && bv == null) continue;
          if (av == null) return nullsFirst ? -1 : 1;
          if (bv == null) return nullsFirst ? 1 : -1;
          final c = sqlCompare(av, bv);
          if (c != 0) return ob.descending ? -c : c;
        }
        return 0;
      });
      rows = sorted;
    }

    final start = (s.offset ?? 0).clamp(0, rows.length);
    var end = rows.length;
    if (s.limit != null) end = (start + s.limit!).clamp(0, rows.length);
    rows = rows.sublist(start, end);

    return QueryResult(columns: cols, rows: rows, affected: rows.length);
  }

  /// Materialize each CTE eagerly and push the bindings on [_cteStack].
  /// Returns true iff a frame was pushed (caller must pop).
  bool _pushCtes(Map<String, SelectStmt> ctes,
      {bool recursive = false,
      Map<String, List<String>> columnsOverride = const {}}) {
    if (ctes.isEmpty) return false;
    final frame = <String, _CteRel>{};
    _cteStack.add(frame);
    // Materialize one at a time so later CTEs can reference earlier ones.
    for (final entry in ctes.entries) {
      final body = entry.value;
      _CteRel rel;
      if (recursive && _isRecursiveCte(entry.key, body)) {
        rel =
            _materializeRecursive(entry.key, body, columnsOverride[entry.key]);
      } else {
        final res = _selectTopLevel(body);
        rel = _CteRel(res.columns, res.rows);
      }
      // Apply explicit column-name override (WITH name(c1, c2) AS ...).
      final override = columnsOverride[entry.key];
      if (override != null && override.length == rel.columns.length) {
        rel = _CteRel(List<String>.from(override), rel.rows);
      }
      frame[entry.key] = rel;
    }
    return true;
  }

  /// True iff the recursive arm of [body] (or [body] itself) references the
  /// CTE [name].
  bool _isRecursiveCte(String name, SelectStmt body) {
    if (body.setOp == null) return false;
    return _selectReferencesName(body.setOpRight!, name);
  }

  bool _selectReferencesName(SelectStmt s, String name) {
    if (s.fromTable == name) return true;
    if (s.fromSubquery != null &&
        _selectReferencesName(s.fromSubquery!, name)) {
      return true;
    }
    for (final j in s.joins) {
      if (j.table == name) return true;
      if (j.subquery != null && _selectReferencesName(j.subquery!, name)) {
        return true;
      }
    }
    if (s.setOpRight != null && _selectReferencesName(s.setOpRight!, name)) {
      return true;
    }
    return false;
  }

  /// Run a recursive CTE: anchor (left arm) seeds the result; each iteration
  /// runs the recursive arm with the CTE bound to the rows added in the
  /// previous step. Stops when no new rows are produced or the safety cap
  /// is hit.
  _CteRel _materializeRecursive(
      String name, SelectStmt body, List<String>? columnNames) {
    final op = body.setOp!; // 'UNION' or 'UNION ALL' typically
    // Anchor: same SelectStmt with setOp stripped.
    final anchor = SelectStmt(
      projection: body.projection,
      fromTable: body.fromTable,
      fromSubquery: body.fromSubquery,
      fromAlias: body.fromAlias,
      joins: body.joins,
      where: body.where,
      groupBy: body.groupBy,
      having: body.having,
      orderBy: body.orderBy,
      limit: body.limit,
      offset: body.offset,
      distinct: body.distinct,
    );
    final anchorRes = _selectTopLevel(anchor);
    final cols =
        (columnNames != null && columnNames.length == anchorRes.columns.length)
            ? List<String>.from(columnNames)
            : anchorRes.columns;
    final all = <List<Object?>>[...anchorRes.rows];
    final seen = <String>{for (final r in all) jsonEncode(r)};
    var queue = <List<Object?>>[...anchorRes.rows];
    final recursiveArm = body.setOpRight!;
    const maxIter = 10000;
    const maxRows = 200000;
    var iter = 0;
    while (queue.isNotEmpty && iter < maxIter && all.length < maxRows) {
      iter++;
      // Push a frame binding [name] to the current queue rows under the
      // (possibly overridden) column names so the recursive arm can
      // reference them by name.
      _cteStack.add({name: _CteRel(cols, queue)});
      List<List<Object?>> step;
      try {
        step = _selectTopLevel(recursiveArm).rows;
      } finally {
        _cteStack.removeLast();
      }
      final next = <List<Object?>>[];
      for (final r in step) {
        final k = jsonEncode(r);
        if (op == 'UNION ALL') {
          next.add(r);
          all.add(r);
        } else {
          if (seen.add(k)) {
            next.add(r);
            all.add(r);
          }
        }
        if (all.length >= maxRows) break;
      }
      queue = next;
    }
    return _CteRel(cols, all);
  }

  _CteRel? _lookupCte(String name) {
    for (var i = _cteStack.length - 1; i >= 0; i--) {
      final r = _cteStack[i][name];
      if (r != null) return r;
    }
    return null;
  }

  QueryResult _combineSets(String op, QueryResult left, QueryResult right) {
    if (left.columns.length != right.columns.length) {
      throw StateError('$op column count mismatch');
    }
    String key(List<Object?> r) => jsonEncode(r);
    switch (op) {
      case 'UNION ALL':
        return QueryResult(
          columns: left.columns,
          rows: [...left.rows, ...right.rows],
          affected: left.rows.length + right.rows.length,
        );
      case 'UNION':
        final seen = <String>{};
        final out = <List<Object?>>[];
        for (final r in [...left.rows, ...right.rows]) {
          if (seen.add(key(r))) out.add(r);
        }
        return QueryResult(
            columns: left.columns, rows: out, affected: out.length);
      case 'INTERSECT':
        final rk = right.rows.map(key).toSet();
        final out = <List<Object?>>[];
        final seen = <String>{};
        for (final r in left.rows) {
          if (rk.contains(key(r)) && seen.add(key(r))) out.add(r);
        }
        return QueryResult(
            columns: left.columns, rows: out, affected: out.length);
      case 'EXCEPT':
        final rk = right.rows.map(key).toSet();
        final out = <List<Object?>>[];
        final seen = <String>{};
        for (final r in left.rows) {
          if (!rk.contains(key(r)) && seen.add(key(r))) out.add(r);
        }
        return QueryResult(
            columns: left.columns, rows: out, affected: out.length);
    }
    throw StateError('Unknown set op: $op');
  }

  // ---- Single SELECT (no set-op) -----------------------------------------
  QueryResult _selectInner(SelectStmt s,
      [Map<String, Object?> outer = const {}]) {
    _planTrace = const [];
    // Index-only / covering-scan fast path. When the SELECT has the
    // shape `SELECT [DISTINCT] <indexed_col> FROM <table> [ORDER BY ... ]
    // [LIMIT ...]`, we can answer entirely from the index without
    // touching the row store.
    final cov = _tryCoveringScan(s);
    if (cov != null) return cov;

    final reordered = _reorderInnerJoins(s);
    final fromRows =
        _planScan(reordered, outer) ?? _resolveFromRows(reordered, outer);

    // WHERE
    var working = s.where == null
        ? fromRows
        : fromRows
            .where((r) => evalPredicate(_bindExpr(s.where!, outer), r))
            .toList();

    // Detect aggregates anywhere in projection or HAVING.
    final hasAggregates = s.groupBy.isNotEmpty ||
        _containsAggregate(s.having) ||
        s.projection.any((p) => p.expr != null && _containsAggregate(p.expr));

    List<List<Object?>> resultRows;
    List<String> outCols;
    List<Map<String, Object?>> orderingMaps;

    if (hasAggregates) {
      final res = _runAggregate(s, working);
      outCols = res.columns;
      resultRows = res.rows;
      orderingMaps = res.orderingMaps;
    } else {
      // Build projection in non-aggregate path.
      final proj = _buildProjection(s);
      outCols = proj.outCols;
      // Detect window functions at the top level of the bound projection.
      final winFns = <FunctionCallExpr>[];
      for (final e in proj.exprs) {
        if (e is FunctionCallExpr && e.isWindow) winFns.add(e);
      }
      if (winFns.isEmpty) {
        resultRows = working
            .map((src) => proj.exprs.map((e) => e.eval(src)).toList())
            .toList();
      } else {
        // Pre-compute window values per-row, indexed by FunctionCallExpr.
        final winValues = <FunctionCallExpr, List<Object?>>{};
        for (final fn in winFns) {
          winValues[fn] = _evalWindowFn(fn, working, s.namedWindows);
        }
        resultRows = List.generate(working.length, (i) {
          final src = working[i];
          return List.generate(proj.exprs.length, (j) {
            final e = proj.exprs[j];
            if (e is FunctionCallExpr && e.isWindow) {
              return winValues[e]![i];
            }
            return e.eval(src);
          });
        });
      }
      orderingMaps = working;
    }

    // ORDER BY
    if (s.orderBy.isNotEmpty) {
      final paired = List.generate(
          resultRows.length, (i) => _Pair(orderingMaps[i], resultRows[i]));
      paired.sort((a, b) {
        for (final ob in s.orderBy) {
          // ORDER BY <integer literal> => 1-based projected column position.
          if (ob.expr is LiteralExpr && (ob.expr as LiteralExpr).value is int) {
            final pos = ((ob.expr as LiteralExpr).value as int) - 1;
            if (pos < 0 || pos >= a.row.length) {
              throw StateError('ORDER BY position out of range');
            }
            final av = a.row[pos];
            final bv = b.row[pos];
            final nullsFirst = ob.nullsFirst ?? !ob.descending;
            if (av == null && bv == null) continue;
            if (av == null) return nullsFirst ? -1 : 1;
            if (bv == null) return nullsFirst ? 1 : -1;
            final c = sqlCompare(av, bv);
            if (c != 0) return ob.descending ? -c : c;
            continue;
          }
          final boundExpr = _bindExpr(ob.expr);
          Object? av;
          Object? bv;
          if (boundExpr is ColumnExpr) {
            final idx = outCols.indexOf(boundExpr.name);
            if (boundExpr.table == null && idx >= 0) {
              av = a.row[idx];
              bv = b.row[idx];
            } else {
              av = boundExpr.eval(a.src);
              bv = boundExpr.eval(b.src);
            }
          } else {
            try {
              av = boundExpr.eval(a.src);
              bv = boundExpr.eval(b.src);
            } catch (_) {
              // Fall back to projected column lookup if expression refers
              // only to a projected alias.
              if (ob.expr is ColumnExpr) {
                final idx = outCols.indexOf((ob.expr as ColumnExpr).name);
                if (idx >= 0) {
                  av = a.row[idx];
                  bv = b.row[idx];
                }
              }
            }
          }
          final nullsFirst = ob.nullsFirst ?? !ob.descending;
          if (av == null && bv == null) continue;
          if (av == null) return nullsFirst ? -1 : 1;
          if (bv == null) return nullsFirst ? 1 : -1;
          final c = sqlCompare(av, bv);
          if (c != 0) return ob.descending ? -c : c;
        }
        return 0;
      });
      resultRows = paired.map((p) => p.row).toList();
    }

    // DISTINCT
    if (s.distinct) {
      final seen = <String>{};
      resultRows = resultRows.where((r) => seen.add(jsonEncode(r))).toList();
    }

    // LIMIT / OFFSET
    final start = (s.offset ?? 0).clamp(0, resultRows.length);
    var end = resultRows.length;
    if (s.limit != null) end = (start + s.limit!).clamp(0, resultRows.length);
    resultRows = resultRows.sublist(start, end);

    return QueryResult(
        columns: outCols, rows: resultRows, affected: resultRows.length);
  }

  // Build initial row maps from FROM table (real or view) and JOINs.
  /// Index-only / covering-scan fast path.
  ///
  /// Recognises the shape:
  ///
  ///   SELECT [DISTINCT] <col> [AS alias] FROM <table>
  ///     [ORDER BY <col> [ASC|DESC]]
  ///     [LIMIT n] [OFFSET n]
  ///
  /// where `<col>` has a non-partial, non-expression index. In that case
  /// we walk the index entries directly and synthesise the result without
  /// hydrating any base-table row.
  ///
  /// Returns null when any condition fails.
  QueryResult? _tryCoveringScan(SelectStmt s) {
    if (s.fromTable == null) return null;
    if (s.joins.isNotEmpty) return null;
    if (s.fromSubquery != null || s.fromFunction != null) return null;
    if (s.where != null) return null;
    if (s.groupBy.isNotEmpty || s.having != null) return null;
    if (s.setOp != null) return null;
    if (s.projection.length != 1) return null;
    final p = s.projection.first;
    if (p.isStar) return null;
    if (p.expr is! ColumnExpr) return null;
    final colExpr = p.expr as ColumnExpr;
    final t = _tables[s.fromTable!];
    if (t == null) return null;
    final idx = _findIndexForColumn(t, colExpr.name);
    if (idx == null) return null;
    final indexMap = t.indexes[idx.name];
    if (indexMap == null) return null;

    // Honour ORDER BY only if it's on the same column. Anything else
    // requires re-sorting, which defeats the optimisation.
    var descending = false;
    if (s.orderBy.isNotEmpty) {
      if (s.orderBy.length != 1) return null;
      final ob = s.orderBy.first;
      if (ob.expr is! ColumnExpr) return null;
      if ((ob.expr as ColumnExpr).name.toLowerCase() !=
          colExpr.name.toLowerCase()) {
        return null;
      }
      descending = ob.descending;
    }

    // Iterate the index in sorted (asc) order and emit one row per
    // posting (or one per distinct key when DISTINCT).
    final outName = p.alias ?? colExpr.name;
    final out = <List<Object?>>[];
    Iterable<MapEntry<Object, List<int>>> entries = indexMap.entries;
    if (descending) entries = entries.toList().reversed;
    for (final e in entries) {
      if (s.distinct) {
        out.add([e.key]);
      } else {
        for (var i = 0; i < e.value.length; i++) {
          out.add([e.key]);
        }
      }
    }

    // LIMIT / OFFSET
    var rows = out;
    final start = (s.offset ?? 0).clamp(0, rows.length);
    var end = rows.length;
    if (s.limit != null) end = (start + s.limit!).clamp(0, rows.length);
    rows = rows.sublist(start, end);

    coveringScansUsed++;
    _planTrace = [
      'COVERING SCAN ${t.name} USING INDEX ${idx.name} '
          '(${colExpr.name}${descending ? " DESC" : ""})',
    ];
    return QueryResult(columns: [outName], rows: rows, affected: rows.length);
  }

  /// Greedy join reorderer.
  ///
  /// When every join in the SELECT is INNER (with optional CROSS), and
  /// each relation is a base table or subquery (no table-valued
  /// functions), pick the cheapest start relation and grow the chain by
  /// repeatedly adding the cheapest relation whose ON-condition becomes
  /// satisfied. Returns the original [s] unchanged when reordering would
  /// be unsafe (any OUTER/FULL join, table-function, NATURAL/USING) or
  /// would not produce a valid order.
  ///
  /// This is purely a performance optimisation: we re-evaluate every ON
  /// against the combined row map, so the join-order doesn't change the
  /// result set, only how big the intermediate working set gets.
  SelectStmt _reorderInnerJoins(SelectStmt s) {
    if (s.joins.isEmpty) return s;
    if (s.fromTable == null) return s; // subquery/function FROM: skip
    // Reorder only when EVERY relation is a real base table we can size
    // and column-list. CTEs / views / unknown names: bail out.
    if (!_tables.containsKey(s.fromTable)) return s;
    for (final j in s.joins) {
      if (j.type != 'INNER' && j.type != 'CROSS') return s;
      if (j.subquery != null) return s; // subquery RHS: skip for safety
      if (j.table == null) return s;
      if (j.natural || j.using != null) return s;
      if (!_tables.containsKey(j.table)) return s;
    }

    // Build relation slots: id 0 is the FROM, then each join.
    final slots = <_JoinSlot>[];
    slots.add(_JoinSlot(
      tableName: s.fromTable!,
      alias: s.fromAlias,
      on: null,
      rowCount: _tableRowCountEstimate(s.fromTable!),
    ));
    for (final j in s.joins) {
      slots.add(_JoinSlot(
        tableName: j.table!,
        alias: j.alias,
        on: j.on,
        rowCount: _tableRowCountEstimate(j.table!),
      ));
    }
    // Compute provided column-keys for each slot. We over-approximate by
    // using both the bare column name and the qualified `alias.column`
    // / `table.column` form, mirroring `Table.rowToMap`.
    for (final slot in slots) {
      slot.provides = _providedKeys(slot.tableName, slot.alias);
    }
    // Compute required keys for each ON expression.
    final pending = <_PendingOn>[];
    for (var i = 1; i < slots.length; i++) {
      final on = slots[i].on;
      if (on == null) continue;
      pending.add(_PendingOn(on, _columnsReferenced(on), {i}));
    }
    // Some ONs reference *both* sides; their required-slot set should
    // include any slot whose `provides` contains those keys.
    for (final p in pending) {
      for (var i = 0; i < slots.length; i++) {
        if (p.requiredKeys
            .any((k) => slots[i].provides.contains(k.toLowerCase()))) {
          p.requiredSlots.add(i);
        }
      }
    }

    // Greedy: pick the smallest slot first, then iteratively pick the
    // smallest slot whose addition makes some pending ON satisfiable
    // (or, lacking such a slot, the smallest remaining slot).
    final order = <int>[];
    final remaining = <int>{for (var i = 0; i < slots.length; i++) i};
    int pickStart() {
      var best = remaining.first;
      for (final i in remaining) {
        if (slots[i].rowCount < slots[best].rowCount) best = i;
      }
      return best;
    }

    final start = pickStart();
    order.add(start);
    remaining.remove(start);
    final available = <int>{start};

    while (remaining.isNotEmpty) {
      // Prefer a slot that completes a pending ON (so the join becomes
      // a real equi-join rather than a Cartesian step).
      int? chosen;
      var chosenCost = 1 << 62;
      for (final i in remaining) {
        // Hypothetically add slot i.
        final hypothetical = {...available, i};
        // Cost = our row count, but if some pending ON becomes satisfied
        // (i.e., requires a subset of {hypothetical}), the per-row
        // selectivity of that ON divides our cost. We approximate by
        // dividing the joined-relation cost by the number of ONs it
        // newly satisfies (>=1 if any).
        var newlySatisfied = 0;
        for (final p in pending) {
          if (p.satisfied) continue;
          if (p.requiredSlots.every(hypothetical.contains)) {
            newlySatisfied++;
          }
        }
        final cost = newlySatisfied > 0
            ? slots[i].rowCount ~/ (newlySatisfied + 1)
            : slots[i].rowCount * 4; // penalty for Cartesian step
        if (cost < chosenCost) {
          chosenCost = cost;
          chosen = i;
        }
      }
      chosen ??= remaining.first;
      order.add(chosen);
      remaining.remove(chosen);
      available.add(chosen);
      // Mark satisfied ONs so the next round doesn't double-count.
      for (final p in pending) {
        if (!p.satisfied && p.requiredSlots.every(available.contains)) {
          p.satisfied = true;
        }
      }
    }

    // No-op if the greedy order matches the source order.
    var same = true;
    for (var i = 0; i < order.length; i++) {
      if (order[i] != i) {
        same = false;
        break;
      }
    }
    if (same) return s;

    // Re-emit the SELECT with reordered FROM + joins. The first slot
    // becomes the FROM; remaining slots become INNER joins. ON
    // expressions get attached to the slot that completes them (i.e.
    // the *latest* slot in `order` among `requiredSlots`).
    final firstId = order.first;
    final firstSlot = slots[firstId];
    final newJoins = <JoinClause>[];
    for (var k = 1; k < order.length; k++) {
      final id = order[k];
      final slot = slots[id];
      // Find ON expressions whose latest required slot is `id`.
      Expr? mergedOn;
      for (final p in pending) {
        if (p.requiredSlots.isEmpty) continue;
        var latest = -1;
        for (final r in p.requiredSlots) {
          final pos = order.indexOf(r);
          if (pos > latest) latest = pos;
        }
        if (order[latest] != id) continue;
        mergedOn =
            mergedOn == null ? p.expr : BinaryExpr('AND', mergedOn, p.expr);
      }
      newJoins.add(JoinClause('INNER', slot.tableName, slot.alias, mergedOn));
    }

    return SelectStmt(
      projection: s.projection,
      fromTable: firstSlot.tableName,
      fromAlias: firstSlot.alias,
      joins: newJoins,
      where: s.where,
      groupBy: s.groupBy,
      having: s.having,
      orderBy: s.orderBy,
      limit: s.limit,
      offset: s.offset,
      distinct: s.distinct,
      ctes: s.ctes,
      cteColumns: s.cteColumns,
      ctesRecursive: s.ctesRecursive,
      namedWindows: s.namedWindows,
    );
  }

  int _tableRowCountEstimate(String tableName) {
    final t = _tables[tableName];
    if (t != null) return t.rows.length;
    // Unknown (CTE / view alias not in _tables): assume 100.
    return 100;
  }

  /// Lower-cased keys a relation contributes to a row map: bare column
  /// name plus `alias.column` / `table.column` qualifiers.
  Set<String> _providedKeys(String tableName, String? alias) {
    final out = <String>{};
    final t = _tables[tableName];
    if (t == null) return out;
    for (final c in t.columns) {
      final n = c.name.toLowerCase();
      out.add(n);
      out.add('${tableName.toLowerCase()}.$n');
      if (alias != null) out.add('${alias.toLowerCase()}.$n');
    }
    return out;
  }

  /// All ColumnExpr nodes referenced anywhere in [e]. Returns lower-cased
  /// strings: `name` or `qualifier.name`.
  Set<String> _columnsReferenced(Expr e) {
    final out = <String>{};
    void walk(Expr x) {
      if (x is ColumnExpr) {
        out.add(x.table == null
            ? x.name.toLowerCase()
            : '${x.table!.toLowerCase()}.${x.name.toLowerCase()}');
        return;
      }
      if (x is UnaryExpr) {
        walk(x.operand);
        return;
      }
      if (x is BinaryExpr) {
        walk(x.left);
        walk(x.right);
        return;
      }
      if (x is BetweenExpr) {
        walk(x.value);
        walk(x.low);
        walk(x.high);
        return;
      }
      if (x is InExpr) {
        walk(x.value);
        x.values.forEach(walk);
        return;
      }
      // Other Expr subclasses (CASE, function calls, subqueries, ...) are
      // either rare in ON clauses or safe to treat as "depends on
      // everything available" (we just won't be able to defer them); we
      // leave their references unrecorded, which means they get attached
      // to the first join that completes their other dependencies.
    }

    walk(e);
    return out;
  }

  /// Cost-based single-table planner.
  ///
  /// Looks at the SELECT's WHERE clause (decomposed into AND-conjuncts),
  /// finds the cheapest indexable predicate on the FROM table, and
  /// returns the resulting candidate rows already wrapped as
  /// `Map<String, Object?>` row-views. Returns null when no plan beats
  /// a full table scan.
  ///
  /// The full WHERE clause is *re-evaluated* on each returned row by the
  /// caller, so this is always semantically safe — at worst we miss an
  /// optimisation and fall back to scanning everything.
  List<Map<String, Object?>>? _planScan(
      SelectStmt s, Map<String, Object?> outer) {
    if (s.fromTable == null) return null;
    if (s.joins.isNotEmpty) return null;
    if (s.fromFunction != null || s.fromSubquery != null) return null;
    if (s.where == null) return null;
    final t = _tables[s.fromTable!];
    if (t == null) return null;

    final conjuncts = _splitAndConjuncts(s.where!);
    final candidates = <_IndexPlan>[];
    for (final c in conjuncts) {
      final p = _classifyConjunct(t, c);
      if (p != null) candidates.add(p);
    }
    // Multi-column index plans: when a contiguous prefix of a multi-column
    // index has every column equality-constrained, build a single composite
    // probe (full match) or prefix scan (partial match). These are added on
    // top of the per-conjunct candidates and almost always win.
    candidates.addAll(_classifyMultiColumnPlans(t, conjuncts));
    if (candidates.isEmpty) return null;

    // Pick the candidate with the lowest estimated hits. Tie-break on
    // equality-over-range so a unique probe wins over a half-open scan.
    candidates.sort((a, b) {
      final c = a.estHits.compareTo(b.estHits);
      if (c != 0) return c;
      return (a.equalityKeys != null ? 0 : 1) -
          (b.equalityKeys != null ? 0 : 1);
    });
    final best = candidates.first;

    // If the cheapest plan still touches more than ~80% of the table, just
    // scan — random-access via the index would cost more than a sequential
    // sweep.
    if (best.estHits >= (t.rows.length * 0.8).ceil()) return null;

    _planTrace = [best.describe()];
    final rowIds = _executeIndexPlan(t, best);
    return [
      for (final ri in rowIds)
        {...outer, ...t.rowToMap(t.rows[ri], alias: s.fromAlias)},
    ];
  }

  /// Flatten an `a AND b AND c` chain into `[a, b, c]`. Other expressions
  /// pass through unchanged.
  List<Expr> _splitAndConjuncts(Expr e) {
    final out = <Expr>[];
    void visit(Expr x) {
      if (x is BinaryExpr && x.op == 'AND') {
        visit(x.left);
        visit(x.right);
      } else {
        out.add(x);
      }
    }

    visit(e);
    return out;
  }

  /// Build composite-key plans for multi-column indexes. Walks every
  /// non-expression, non-partial multi-column index on [t]; for each,
  /// scans [conjuncts] for `col = literal` predicates that constrain a
  /// contiguous leading prefix of the index. When the entire index is
  /// equality-bound, emits a full composite probe; when only a leading
  /// prefix is bound, emits a [_IndexPlan.prefix] scan.
  List<_IndexPlan> _classifyMultiColumnPlans(Table t, List<Expr> conjuncts) {
    final out = <_IndexPlan>[];
    // Map column-name (lowercase) -> equality literal value, taking the
    // first one we see per column.
    final eqByCol = <String, Object>{};
    for (final c in conjuncts) {
      if (c is! BinaryExpr || c.op != '=') continue;
      final (col, key, _) = _columnLiteralPair(c);
      if (col == null || key == null) continue;
      eqByCol.putIfAbsent(col.toLowerCase(), () => key);
    }
    if (eqByCol.isEmpty) return out;

    for (final def in t.indexDefs.values) {
      if (def.exprSql != null || def.whereSql != null) continue;
      if (def.columns.length < 2) continue;
      // Determine the longest leading prefix of def.columns that's
      // entirely equality-bound.
      final parts = <Object>[];
      for (final cn in def.columns) {
        final v = eqByCol[cn.toLowerCase()];
        if (v == null) break;
        parts.add(v);
      }
      if (parts.isEmpty) continue;
      // Cardinality estimate: use ANALYZE stats if present, else assume
      // sqrt(N) per equality column (more selective the longer the prefix).
      final perCol = _estimateEqualityHits(t, def.columns.first);
      final divisor = math.pow(2, parts.length - 1).toInt();
      final est = (perCol / divisor).ceil().clamp(1, t.rows.length);
      if (parts.length == def.columns.length) {
        // Full key probe \u2014 single composite key into the SplayTreeMap.
        out.add(_IndexPlan.equality(
          table: t.name,
          index: def.name,
          column: def.columns.join(','),
          equalityKey: CompositeIndexKey(parts),
          estHits: est,
        ));
      } else {
        out.add(_IndexPlan.prefix(
          table: t.name,
          index: def.name,
          column: def.columns.take(parts.length).join(','),
          prefixKey: parts,
          estHits: est,
        ));
      }
    }
    return out;
  }

  /// Try to interpret [conjunct] as `<indexed_column> <op> <constant>` and
  /// return an [_IndexPlan]. Returns null when the conjunct can't be
  /// rewritten as an index probe/range against [t].
  _IndexPlan? _classifyConjunct(Table t, Expr conjunct) {
    // Equality / range against an indexed column.
    if (conjunct is BinaryExpr) {
      final op = conjunct.op;
      if (op == '=' || op == '<' || op == '<=' || op == '>' || op == '>=') {
        final (col, key, flipped) = _columnLiteralPair(conjunct);
        if (col == null) return null;
        final idx = _findIndexForColumn(t, col);
        if (idx == null) return null;
        // Multi-column indexes need a composite key; per-conjunct
        // classification can't build one. Defer to the multi-column
        // planner pass instead of emitting a wrong single-key plan.
        if (idx.columns.length > 1) return null;
        if (key == null) return null;
        final effOp = flipped ? _flipComparison(op) : op;
        if (effOp == '=') {
          return _IndexPlan.equality(
            table: t.name,
            index: idx.name,
            column: col,
            equalityKey: key,
            estHits: _estimateEqualityHits(t, col),
          );
        }
        // Range
        final estHits = _estimateRangeHits(t);
        switch (effOp) {
          case '<':
            return _IndexPlan.range(
                table: t.name,
                index: idx.name,
                column: col,
                lo: null,
                hi: key,
                loInclusive: false,
                hiInclusive: false,
                estHits: estHits);
          case '<=':
            return _IndexPlan.range(
                table: t.name,
                index: idx.name,
                column: col,
                lo: null,
                hi: key,
                loInclusive: false,
                hiInclusive: true,
                estHits: estHits);
          case '>':
            return _IndexPlan.range(
                table: t.name,
                index: idx.name,
                column: col,
                lo: key,
                hi: null,
                loInclusive: false,
                hiInclusive: false,
                estHits: estHits);
          case '>=':
            return _IndexPlan.range(
                table: t.name,
                index: idx.name,
                column: col,
                lo: key,
                hi: null,
                loInclusive: true,
                hiInclusive: false,
                estHits: estHits);
        }
      }
    }
    // BETWEEN: closed range on both sides.
    if (conjunct is BetweenExpr && !conjunct.negated) {
      if (conjunct.value is! ColumnExpr) return null;
      final col = (conjunct.value as ColumnExpr).name;
      final idx = _findIndexForColumn(t, col);
      if (idx == null) return null;
      if (idx.columns.length > 1) return null;
      final lo = _evalConst(conjunct.low);
      final hi = _evalConst(conjunct.high);
      if (lo == null || hi == null) return null;
      return _IndexPlan.range(
          table: t.name,
          index: idx.name,
          column: col,
          lo: lo,
          hi: hi,
          loInclusive: true,
          hiInclusive: true,
          estHits: _estimateRangeHits(t));
    }
    // IN (literal-list): probe each key. Cost = perKey * list length, but
    // bounded by the table size (and crucially, lower bound 1 so a tiny
    // IN list still beats a full scan when stats are missing).
    if (conjunct is InExpr && !conjunct.negated) {
      if (conjunct.value is! ColumnExpr) return null;
      final col = (conjunct.value as ColumnExpr).name;
      final idx = _findIndexForColumn(t, col);
      if (idx == null) return null;
      if (idx.columns.length > 1) return null;
      final keys = <Object>[];
      for (final v in conjunct.values) {
        if (!_isConstExpr(v)) return null;
        final k = _evalConst(v);
        if (k == null) continue; // NULL never equals anything
        keys.add(k);
      }
      if (keys.isEmpty) return null;
      final perKey = _estimateEqualityHits(t, col);
      final est = (perKey * keys.length).clamp(1, t.rows.length);
      return _IndexPlan.equalityList(
        table: t.name,
        index: idx.name,
        column: col,
        equalityKeys: keys,
        estHits: est,
      );
    }
    return null;
  }

  /// If [b] is `column op literal` or `literal op column`, return the
  /// column name and constant value. The third element is `true` when the
  /// literal was on the *left* (so range operators must be flipped).
  (String?, Object?, bool) _columnLiteralPair(BinaryExpr b) {
    if (b.left is ColumnExpr && _isConstExpr(b.right)) {
      return ((b.left as ColumnExpr).name, _evalConst(b.right), false);
    }
    if (b.right is ColumnExpr && _isConstExpr(b.left)) {
      return ((b.right as ColumnExpr).name, _evalConst(b.left), true);
    }
    return (null, null, false);
  }

  bool _isConstExpr(Expr e) => e is LiteralExpr;
  Object? _evalConst(Expr e) => e.eval(const {});

  String _flipComparison(String op) => switch (op) {
        '<' => '>',
        '<=' => '>=',
        '>' => '<',
        '>=' => '<=',
        _ => op,
      };

  IndexDef? _findIndexForColumn(Table t, String column) {
    final lc = column.toLowerCase();
    // Single-column indexes are the cheapest and unambiguous match.
    for (final d in t.indexDefs.values) {
      if (d.exprSql == null &&
          d.whereSql == null &&
          d.columns.length == 1 &&
          d.column.toLowerCase() == lc) {
        return d;
      }
    }
    // Fallback: a multi-column index whose LEADING column matches. The
    // executor handles this via a prefix scan over the composite-key
    // SplayTreeMap (see [_executeIndexPlan]).
    for (final d in t.indexDefs.values) {
      if (d.exprSql == null &&
          d.whereSql == null &&
          d.columns.length > 1 &&
          d.columns.first.toLowerCase() == lc) {
        return d;
      }
    }
    return null;
  }

  /// Average rows per equal-key on [column], using ANALYZE stats when
  /// available. Falls back to `sqrt(rowCount)` otherwise — better than
  /// assuming uniqueness, worse than full scan.
  int _estimateEqualityHits(Table t, String column) {
    final stats = _stats[t.name];
    if (stats != null) {
      final dc = stats.distinctByColumn[column.toLowerCase()];
      if (dc != null && dc > 0) {
        return (stats.rowCount / dc).ceil();
      }
    }
    if (t.rows.isEmpty) return 0;
    final n = t.rows.length;
    final est = n <= 4 ? 1 : (n / math.sqrt(n.toDouble())).ceil();
    return est.clamp(1, n);
  }

  /// Half the table — coarse but matches SQLite's default heuristic when
  /// no stat-1 row tells us better.
  int _estimateRangeHits(Table t) =>
      t.rows.isEmpty ? 0 : (t.rows.length / 2).ceil().clamp(1, t.rows.length);

  /// Enumerate the row ids selected by [plan]. Equality plans hit one
  /// posting list per key; range plans walk the SplayTreeMap from `lo` to
  /// `hi`. Output preserves index order within a single key but does NOT
  /// guarantee global order across keys/ranges — callers that need
  /// ordering must sort.
  List<int> _executeIndexPlan(Table t, _IndexPlan plan) {
    final idx = t.indexes[plan.index];
    if (idx == null) return const [];
    final def = t.indexDefs[plan.index];
    // Apply per-column collations to probe values so they match the
    // normalized form that `_buildIndexKey` stored.
    Object? coll0(Object? v) => def == null ? v : def.collate(0, v);
    // Prefix scan over a composite-key (multi-column) index: collect
    // every entry whose key shares the requested leading components.
    if (plan.prefixKey != null) {
      final prefixRaw = plan.prefixKey!;
      final prefix = <Object?>[
        for (var i = 0; i < prefixRaw.length; i++)
          def == null ? prefixRaw[i] : def.collate(i, prefixRaw[i])
      ];
      final out = <int>[];
      for (final entry in idx.entries) {
        final k = entry.key;
        if (k is! CompositeIndexKey) continue;
        if (k.parts.length < prefix.length) continue;
        var match = true;
        for (var i = 0; i < prefix.length; i++) {
          if (CompositeIndexKey.compareValues(k.parts[i], prefix[i]) != 0) {
            match = false;
            break;
          }
        }
        if (match) out.addAll(entry.value);
      }
      return out;
    }
    if (plan.equalityKeys != null) {
      final out = <int>[];
      for (final k in plan.equalityKeys!) {
        final ck = coll0(k);
        if (ck == null) continue;
        final hits = idx[ck];
        if (hits != null) out.addAll(hits);
      }
      return out;
    }
    // Single-key equality is encoded as range with lo==hi; check upstream.
    final lo = plan.lo == null ? null : coll0(plan.lo);
    final hi = plan.hi == null ? null : coll0(plan.hi);
    final out = <int>[];
    for (final entry in idx.entries) {
      final k = entry.key;
      if (lo != null) {
        final c = sqlCompare(k, lo);
        if (plan.loInclusive ? c < 0 : c <= 0) continue;
      }
      if (hi != null) {
        final c = sqlCompare(k, hi);
        if (plan.hiInclusive ? c > 0 : c >= 0) break;
      }
      out.addAll(entry.value);
    }
    return out;
  }

  List<Map<String, Object?>> _resolveFromRows(SelectStmt s,
      [Map<String, Object?> outer = const {}]) {
    if (s.fromTable == null &&
        s.fromSubquery == null &&
        s.fromFunction == null) {
      // SELECT-without-FROM: a single empty row, with outer scope visible.
      return [Map<String, Object?>.from(outer)];
    }
    final List<Map<String, Object?>> left;
    if (s.fromFunction != null) {
      left = _materializeTableFunction(s.fromFunction!, s.fromAlias);
    } else if (s.fromSubquery != null) {
      left = _materializeSubquery(s.fromSubquery!, s.fromAlias, outer);
    } else {
      left = _materializeRelation(s.fromTable!, s.fromAlias, outer);
    }
    var working = left;
    for (final j in s.joins) {
      final right = j.subquery != null
          ? _materializeSubquery(j.subquery!, j.alias, outer)
          : _materializeRelation(j.table!, j.alias, outer);

      // Resolve the effective ON expression for NATURAL / USING joins.
      Expr? onExpr = j.on;
      if (j.natural) {
        final lcols = _columnsOfWorking(working, s);
        final rcols = j.subquery != null
            ? _selectTopLevel(j.subquery!).columns
            : _materializeColumns(j.table!);
        final common = lcols.where(rcols.contains).toList();
        onExpr = _equiJoinExpr(common, s, j);
      } else if (j.using != null) {
        onExpr = _equiJoinExpr(j.using!, s, j);
      }

      final next = <Map<String, Object?>>[];
      switch (j.type) {
        case 'CROSS':
          for (final l in working) {
            for (final r in right) {
              next.add({...l, ...r});
            }
          }
          break;
        case 'RIGHT':
          for (final r in right) {
            var matched = false;
            for (final l in working) {
              final combined = {...l, ...r};
              if (onExpr != null &&
                  evalPredicate(_bindExpr(onExpr), combined)) {
                next.add(combined);
                matched = true;
              }
            }
            if (!matched) {
              final nulls = _nullSideOf(_keyTableName(s, working));
              next.add({...nulls, ...r});
            }
          }
          break;
        case 'FULL':
          // LEFT side
          final matchedRightIdx = <int>{};
          for (final l in working) {
            var matched = false;
            for (var ri = 0; ri < right.length; ri++) {
              final combined = {...l, ...right[ri]};
              if (onExpr != null &&
                  evalPredicate(_bindExpr(onExpr), combined)) {
                next.add(combined);
                matched = true;
                matchedRightIdx.add(ri);
              }
            }
            if (!matched) {
              next.add({...l, ..._nullsForJoin(j)});
            }
          }
          // Unmatched right rows
          final leftNulls = _nullSideOf(_keyTableName(s, working));
          for (var ri = 0; ri < right.length; ri++) {
            if (!matchedRightIdx.contains(ri)) {
              next.add({...leftNulls, ...right[ri]});
            }
          }
          break;
        case 'LEFT':
          for (final l in working) {
            var matched = false;
            for (final r in right) {
              final combined = {...l, ...r};
              if (onExpr != null &&
                  evalPredicate(_bindExpr(onExpr), combined)) {
                next.add(combined);
                matched = true;
              }
            }
            if (!matched) {
              next.add({...l, ..._nullsForJoin(j)});
            }
          }
          break;
        case 'INNER':
        default:
          for (final l in working) {
            for (final r in right) {
              final combined = {...l, ...r};
              if (onExpr != null &&
                  evalPredicate(_bindExpr(onExpr), combined)) {
                next.add(combined);
              }
            }
          }
      }
      working = next;
    }
    return working;
  }

  /// Approximate the unqualified column list of the current working set.
  /// Used by NATURAL JOIN to discover common columns.
  List<String> _columnsOfWorking(
      List<Map<String, Object?>> working, SelectStmt s) {
    if (working.isEmpty) {
      // Fall back to the FROM source's columns.
      if (s.fromTable != null) return _materializeColumns(s.fromTable!);
      if (s.fromSubquery != null) {
        return _selectTopLevel(s.fromSubquery!).columns;
      }
      return const [];
    }
    return working.first.keys.where((k) => !k.contains('.')).toList();
  }

  /// Build `(a.c = b.c) AND ...` over [cols] using the left source from [s]
  /// and the right side from [j].
  Expr? _equiJoinExpr(List<String> cols, SelectStmt s, JoinClause j) {
    if (cols.isEmpty) return null;
    final leftQ = s.fromAlias ?? s.fromTable;
    final rightQ = j.alias ?? j.table;
    Expr? out;
    for (final c in cols) {
      final eq = BinaryExpr(
          '=', ColumnExpr(c, table: leftQ), ColumnExpr(c, table: rightQ));
      out = out == null ? eq : BinaryExpr('AND', out, eq);
    }
    return out;
  }

  /// Materialize a derived-table subquery into row maps (with bare and
  /// aliased keys).
  List<Map<String, Object?>> _materializeSubquery(
      SelectStmt s, String? alias, Map<String, Object?> outer) {
    final res = _selectTopLevel(s, outer);
    final out = <Map<String, Object?>>[];
    for (final row in res.rows) {
      final m = <String, Object?>{...outer};
      for (var i = 0; i < res.columns.length; i++) {
        m[res.columns[i]] = row[i];
        if (alias != null) m['$alias.${res.columns[i]}'] = row[i];
      }
      out.add(m);
    }
    return out;
  }

  /// Build a null-row for an unmatched outer join right side, keyed for
  /// either a base relation or a derived-table subquery.
  Map<String, Object?> _nullsForJoin(JoinClause j) {
    if (j.subquery != null) {
      // Run the subquery with no outer to learn its columns; rows are not
      // needed — only the column names. (Cheap because executor returns
      // QueryResult quickly even with empty input — for simple subqueries.)
      final res = _selectTopLevel(j.subquery!);
      final out = <String, Object?>{};
      for (final c in res.columns) {
        out[c] = null;
        if (j.alias != null) out['${j.alias}.$c'] = null;
      }
      return out;
    }
    return _nullsForRelation(j.table!, j.alias);
  }

  /// Materialize a "relation" — either a base table or a view — into
  /// row maps with bare and qualified keys. Each row is merged with the
  /// optional [outer] scope so correlated subqueries can resolve outer
  /// column references.
  List<Map<String, Object?>> _materializeRelation(String name, String? alias,
      [Map<String, Object?> outer = const {}]) {
    // CTE bindings shadow tables and views.
    final cte = _lookupCte(name);
    if (cte != null) {
      final out = <Map<String, Object?>>[];
      for (final row in cte.rows) {
        final m = <String, Object?>{...outer};
        for (var i = 0; i < cte.columns.length; i++) {
          m[cte.columns[i]] = row[i];
          m['$name.${cte.columns[i]}'] = row[i];
          if (alias != null) m['$alias.${cte.columns[i]}'] = row[i];
        }
        out.add(m);
      }
      return out;
    }
    if (_tables.containsKey(name)) {
      final t = _tables[name]!;
      return [
        for (final r in t.rows) {...outer, ...t.rowToMap(r, alias: alias)}
      ];
    }
    if (_views.containsKey(name)) {
      final res = _selectTopLevel(_views[name]!, outer);
      final out = <Map<String, Object?>>[];
      for (final row in res.rows) {
        final m = <String, Object?>{...outer};
        for (var i = 0; i < res.columns.length; i++) {
          m[res.columns[i]] = row[i];
          m['$name.${res.columns[i]}'] = row[i];
          if (alias != null) m['$alias.${res.columns[i]}'] = row[i];
        }
        out.add(m);
      }
      return out;
    }
    throw StateError('No such table or view: $name');
  }

  /// Materialize a table-valued function call (e.g. `json_each(...)`) into
  /// a relation. Result column names follow SQLite conventions: each
  /// supported function exposes a fixed schema.
  List<Map<String, Object?>> _materializeTableFunction(
      FunctionCallExpr fn, String? alias) {
    final upper = fn.name.toUpperCase();
    final args = fn.args.map((e) => _bindExpr(e).eval(const {})).toList();
    final qual = alias ?? fn.name.toLowerCase();
    List<Map<String, Object?>> rows;
    switch (upper) {
      case 'JSON_EACH':
        rows = _jsonEachRows(args, recursive: false);
        break;
      case 'JSON_TREE':
        rows = _jsonEachRows(args, recursive: true);
        break;
      default:
        throw StateError('Unknown table-valued function: ${fn.name}');
    }
    return rows
        .map((r) => <String, Object?>{
              ...r,
              for (final e in r.entries) '$qual.${e.key}': e.value,
            })
        .toList();
  }

  /// Implementation of `json_each` / `json_tree`. Returns rows with the
  /// SQLite-standard columns `key, value, type, atom, id, parent, fullkey,
  /// path`. [recursive] = true visits descendants too (json_tree).
  List<Map<String, Object?>> _jsonEachRows(List<Object?> args,
      {required bool recursive}) {
    if (args.isEmpty || args[0] == null) return const [];
    Object? root;
    try {
      root = jsonDecode(args[0].toString());
    } catch (_) {
      return const [];
    }
    if (args.length >= 2 && args[1] != null) {
      root = jsonPathLookup(root, args[1].toString());
    }
    final out = <Map<String, Object?>>[];
    var nextId = 0;
    void emit(
        Object? key, Object? value, int? parent, String fullkey, String path) {
      final id = nextId++;
      final type = _jsonTypeName(value);
      final atom =
          (value is num || value is bool || value is String) ? value : null;
      final outVal =
          (value is List || value is Map) ? jsonEncode(value) : value;
      out.add({
        'key': key,
        'value': outVal,
        'type': type,
        'atom': atom,
        'id': id,
        'parent': parent,
        'fullkey': fullkey,
        'path': path,
      });
      if (recursive) {
        if (value is Map) {
          value.forEach((k, v) {
            emit(k, v, id, '$fullkey.$k', fullkey);
          });
        } else if (value is List) {
          for (var i = 0; i < value.length; i++) {
            emit(i, value[i], id, '$fullkey[$i]', fullkey);
          }
        }
      }
    }

    if (root is List) {
      for (var i = 0; i < root.length; i++) {
        emit(i, root[i], null, '\$[$i]', '\$');
      }
    } else if (root is Map) {
      root.forEach((k, v) {
        emit(k, v, null, '\$.$k', '\$');
      });
    } else {
      emit(null, root, null, '\$', '\$');
    }
    return out;
  }

  String _jsonTypeName(Object? v) {
    if (v == null) return 'null';
    if (v is bool) return v ? 'true' : 'false';
    if (v is int) return 'integer';
    if (v is double) return 'real';
    if (v is String) return 'text';
    if (v is List) return 'array';
    if (v is Map) return 'object';
    return 'null';
  }

  Map<String, Object?> _nullsForRelation(String name, String? alias) {
    final out = <String, Object?>{};
    if (_tables.containsKey(name)) {
      for (final c in _tables[name]!.columns) {
        out[c.name] = null;
        out['$name.${c.name}'] = null;
        if (alias != null) out['$alias.${c.name}'] = null;
      }
    }
    return out;
  }

  Map<String, Object?> _nullSideOf(String tableName) {
    if (!_tables.containsKey(tableName)) return const {};
    final t = _tables[tableName]!;
    final out = <String, Object?>{};
    for (final c in t.columns) {
      out[c.name] = null;
      out['${t.name}.${c.name}'] = null;
    }
    return out;
  }

  String _keyTableName(SelectStmt s, List<Map<String, Object?>> working) {
    return s.fromAlias ?? s.fromTable ?? '';
  }

  _Projection _buildProjection(SelectStmt s) {
    final outCols = <String>[];
    final exprs = <Expr>[];
    for (final item in s.projection) {
      if (item.isStar) {
        if (item.starTable != null) {
          final src = _materializeColumns(item.starTable!);
          for (final c in src) {
            outCols.add(c);
            exprs.add(_bindExpr(ColumnExpr(c, table: item.starTable)));
          }
        } else if (s.fromTable != null) {
          final tCols = _materializeColumns(s.fromTable!);
          for (final c in tCols) {
            outCols.add(c);
            exprs.add(
                _bindExpr(ColumnExpr(c, table: s.fromAlias ?? s.fromTable!)));
          }
          for (final j in s.joins) {
            final List<String> src;
            if (j.subquery != null) {
              src = _selectTopLevel(j.subquery!).columns;
            } else {
              src = _materializeColumns(j.table!);
            }
            final qual = j.alias ?? j.table ?? '';
            // For NATURAL / USING joins, omit columns already projected
            // from the left side (de-duplicate join columns).
            final skip = <String>{};
            if (j.using != null) {
              skip.addAll(j.using!);
            } else if (j.natural) {
              skip.addAll(src.where(outCols.contains));
            }
            for (final c in src) {
              if (skip.contains(c)) continue;
              outCols.add(c);
              exprs.add(_bindExpr(ColumnExpr(c, table: qual)));
            }
          }
        } else if (s.fromSubquery != null) {
          final src = _selectTopLevel(s.fromSubquery!).columns;
          final qual = s.fromAlias ?? '';
          for (final c in src) {
            outCols.add(c);
            exprs.add(_bindExpr(
                qual.isEmpty ? ColumnExpr(c) : ColumnExpr(c, table: qual)));
          }
        }
      } else {
        outCols.add(item.alias ?? _exprLabel(item.expr!));
        exprs.add(_bindExpr(item.expr!));
      }
    }
    return _Projection(outCols, exprs);
  }

  List<String> _materializeColumns(String name) {
    final cte = _lookupCte(name);
    if (cte != null) return cte.columns;
    if (_tables.containsKey(name)) {
      return _tables[name]!.columns.map((c) => c.name).toList();
    }
    if (_views.containsKey(name)) {
      // Materialize once (small; cached by caller's structure).
      final res = _selectTopLevel(_views[name]!);
      return res.columns;
    }
    throw StateError('No such table or view: $name');
  }

  String _exprLabel(Expr e) {
    if (e is ColumnExpr) {
      return e.table == null ? e.name : '${e.table}.${e.name}';
    }
    if (e is FunctionCallExpr) {
      if (e.isStarArg) return '${e.name.toLowerCase()}(*)';
      return '${e.name.toLowerCase()}(${e.args.map(_exprLabel).join(", ")})';
    }
    if (e is LiteralExpr) {
      return e.value?.toString() ?? 'NULL';
    }
    return '?column?';
  }

  // ---- Aggregate execution -----------------------------------------------
  _AggResult _runAggregate(SelectStmt s, List<Map<String, Object?>> rows) {
    // Group rows by GROUP BY key (empty group-by => single group).
    final groups = <String, List<Map<String, Object?>>>{};
    final groupKeys = <String, List<Object?>>{};
    final groupOrder = <String>[];
    for (final r in rows) {
      final keyVals = s.groupBy.map((g) => _bindExpr(g).eval(r)).toList();
      final key = jsonEncode(keyVals);
      if (!groups.containsKey(key)) {
        groups[key] = <Map<String, Object?>>[];
        groupKeys[key] = keyVals;
        groupOrder.add(key);
      }
      groups[key]!.add(r);
    }
    if (groupOrder.isEmpty && s.groupBy.isEmpty) {
      // SELECT COUNT(*) FROM t WHERE ... with no rows still returns one row.
      groups[''] = const [];
      groupKeys[''] = const [];
      groupOrder.add('');
    }

    final outCols = <String>[];
    final projExprs = <Expr>[];
    for (final item in s.projection) {
      if (item.isStar) {
        // Expanding * with aggregates is unusual; do the non-aggregate cols.
        if (item.starTable != null) {
          for (final c in _materializeColumns(item.starTable!)) {
            outCols.add(c);
            projExprs.add(_bindExpr(ColumnExpr(c, table: item.starTable)));
          }
        } else if (s.fromTable != null) {
          for (final c in _materializeColumns(s.fromTable!)) {
            outCols.add(c);
            projExprs.add(
                _bindExpr(ColumnExpr(c, table: s.fromAlias ?? s.fromTable!)));
          }
        }
      } else {
        outCols.add(item.alias ?? _exprLabel(item.expr!));
        projExprs.add(_bindExpr(item.expr!));
      }
    }

    final outRows = <List<Object?>>[];
    final orderingMaps = <Map<String, Object?>>[];
    for (final key in groupOrder) {
      final grpRows = groups[key]!;
      // Group context map: columns of an arbitrary row (used by non-aggregate
      // projected columns), plus the GROUP BY values reachable by their text.
      final ctx = grpRows.isEmpty
          ? <String, Object?>{}
          : Map<String, Object?>.from(grpRows.first);
      // Make GROUP BY exprs available by source label too.
      for (var gi = 0; gi < s.groupBy.length; gi++) {
        ctx['__group$gi'] = groupKeys[key]![gi];
      }

      // HAVING
      if (s.having != null) {
        if (!_evalHaving(s.having!, grpRows, ctx)) continue;
      }

      final row = <Object?>[];
      for (final e in projExprs) {
        row.add(_evalProjectedWithAggregates(e, grpRows, ctx));
      }
      outRows.add(row);
      orderingMaps.add(ctx);
    }
    return _AggResult(outCols, outRows, orderingMaps);
  }

  bool _containsAggregate(Expr? e) {
    if (e == null) return false;
    if (e is FunctionCallExpr && e.isAggregate && !e.isWindow) return true;
    if (e is BinaryExpr) {
      return _containsAggregate(e.left) || _containsAggregate(e.right);
    }
    if (e is UnaryExpr) return _containsAggregate(e.operand);
    if (e is BetweenExpr) {
      return _containsAggregate(e.value) ||
          _containsAggregate(e.low) ||
          _containsAggregate(e.high);
    }
    if (e is InExpr) {
      return _containsAggregate(e.value) || e.values.any(_containsAggregate);
    }
    if (e is CaseExpr) {
      return e.whens.any(_containsAggregate) ||
          e.thens.any(_containsAggregate) ||
          _containsAggregate(e.elseExpr);
    }
    if (e is CastExpr) return _containsAggregate(e.expr);
    if (e is FunctionCallExpr) return e.args.any(_containsAggregate);
    return false;
  }

  Object? _evalProjectedWithAggregates(
      Expr e, List<Map<String, Object?>> grp, Map<String, Object?> ctx) {
    if (e is FunctionCallExpr && e.isAggregate) {
      return _aggregateValue(e, grp);
    }
    if (e is BinaryExpr) {
      final l = _evalProjectedWithAggregates(e.left, grp, ctx);
      final r = _evalProjectedWithAggregates(e.right, grp, ctx);
      // Re-run BinaryExpr semantics with the resolved values.
      return BinaryExpr(e.op, LiteralExpr(l), LiteralExpr(r)).eval(ctx);
    }
    if (e is UnaryExpr) {
      final v = _evalProjectedWithAggregates(e.operand, grp, ctx);
      return UnaryExpr(e.op, LiteralExpr(v)).eval(ctx);
    }
    if (e is CaseExpr) {
      for (var i = 0; i < e.whens.length; i++) {
        final cond = _evalProjectedWithAggregates(e.whens[i], grp, ctx);
        if (sqlTruthy(cond)) {
          return _evalProjectedWithAggregates(e.thens[i], grp, ctx);
        }
      }
      if (e.elseExpr != null) {
        return _evalProjectedWithAggregates(e.elseExpr!, grp, ctx);
      }
      return null;
    }
    if (e is FunctionCallExpr) {
      final args =
          e.args.map((a) => _evalProjectedWithAggregates(a, grp, ctx)).toList();
      return FunctionCallExpr(
              e.name, args.map((v) => LiteralExpr(v) as Expr).toList())
          .eval(ctx);
    }
    if (e is CastExpr) {
      final v = _evalProjectedWithAggregates(e.expr, grp, ctx);
      return CastExpr(LiteralExpr(v), e.targetType).eval(ctx);
    }
    return e.eval(ctx);
  }

  bool _evalHaving(
      Expr e, List<Map<String, Object?>> grp, Map<String, Object?> ctx) {
    final v = _evalProjectedWithAggregates(e, grp, ctx);
    return v is bool && v;
  }

  Object? _aggregateValue(FunctionCallExpr e, List<Map<String, Object?>> grp) {
    if (e.filterExpr != null) {
      grp = grp.where((r) {
        final v = e.filterExpr!.eval(r);
        return v == true || (v is num && v != 0);
      }).toList();
    }
    switch (e.name) {
      case 'COUNT':
        if (e.isStarArg) return grp.length;
        if (e.args.isEmpty) return grp.length;
        final values = grp
            .map((r) => _bindExpr(e.args.first).eval(r))
            .where((v) => v != null);
        if (e.distinct) return values.map((v) => jsonEncode(v)).toSet().length;
        return values.length;
      case 'SUM':
        {
          var acc = 0.0;
          var any = false;
          var allInt = true;
          final iter = _aggValues(e, grp);
          for (final v in iter) {
            if (v == null) continue;
            any = true;
            if (v is! num) {
              throw StateError('SUM requires numeric, got ${v.runtimeType}');
            }
            if (v is! int) allInt = false;
            acc += v.toDouble();
          }
          if (!any) return null;
          return allInt ? acc.toInt() : acc;
        }
      case 'AVG':
        {
          var acc = 0.0;
          var n = 0;
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (v is! num) {
              throw StateError('AVG requires numeric');
            }
            acc += v.toDouble();
            n++;
          }
          if (n == 0) return null;
          return acc / n;
        }
      case 'MIN':
        {
          Object? best;
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (best == null || sqlCompare(v, best) < 0) best = v;
          }
          return best;
        }
      case 'MAX':
        {
          Object? best;
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (best == null || sqlCompare(v, best) > 0) best = v;
          }
          return best;
        }
      case 'JSON_GROUP_ARRAY':
        {
          final out = <Object?>[];
          for (final v in _aggValues(e, grp)) {
            // Strings that already look like JSON nest as values; otherwise
            // include the raw value.
            if (v is String) {
              final t = v.trim();
              if (t.startsWith('{') || t.startsWith('[')) {
                try {
                  out.add(jsonDecode(v));
                  continue;
                } catch (_) {}
              }
            }
            out.add(v);
          }
          return jsonEncode(out);
        }
      case 'JSON_GROUP_OBJECT':
        {
          if (e.args.length != 2) {
            throw StateError('json_group_object requires (key, value)');
          }
          final keyExpr = _bindExpr(e.args[0]);
          final valExpr = _bindExpr(e.args[1]);
          final m = <String, Object?>{};
          for (final r in grp) {
            final k = keyExpr.eval(r);
            if (k == null) continue;
            final v = valExpr.eval(r);
            Object? out = v;
            if (v is String) {
              final t = v.trim();
              if (t.startsWith('{') || t.startsWith('[')) {
                try {
                  out = jsonDecode(v);
                } catch (_) {}
              }
            }
            m[k.toString()] = out;
          }
          return jsonEncode(m);
        }
    }
    throw StateError('Unknown aggregate: ${e.name}');
  }

  Iterable<Object?> _aggValues(
      FunctionCallExpr e, List<Map<String, Object?>> grp) sync* {
    if (e.args.isEmpty) {
      for (final _ in grp) {
        yield null;
      }
      return;
    }
    final arg = _bindExpr(e.args.first);
    if (e.distinct) {
      final seen = <String>{};
      for (final r in grp) {
        final v = arg.eval(r);
        if (v == null) continue;
        if (seen.add(jsonEncode(v))) yield v;
      }
    } else {
      for (final r in grp) {
        yield arg.eval(r);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Window functions
  // ---------------------------------------------------------------------------

  /// Evaluate a window function across [rows] and return a list of values
  /// indexed by the original row position. Supported functions:
  ///   ROW_NUMBER(), RANK(), DENSE_RANK(),
  ///   LAG(expr [, offset [, default]]), LEAD(expr [, offset [, default]]),
  ///   COUNT(*|expr), SUM/AVG/MIN/MAX(expr) — computed over the partition.
  List<Object?> _evalWindowFn(
      FunctionCallExpr fn, List<Map<String, Object?>> rows,
      [Map<String, WindowSpec> namedWindows = const {}]) {
    final spec = _resolveWindowSpec(fn.window!, namedWindows);
    final n = rows.length;
    final out = List<Object?>.filled(n, null);

    // Group row indices by partition key.
    final partitions = <String, List<int>>{};
    for (var i = 0; i < n; i++) {
      final key = spec.partitionBy.isEmpty
          ? ''
          : jsonEncode(spec.partitionBy.map((e) => e.eval(rows[i])).toList());
      partitions.putIfAbsent(key, () => <int>[]).add(i);
    }

    int orderCmp(int a, int b) {
      for (final ob in spec.orderBy) {
        final av = ob.expr.eval(rows[a]);
        final bv = ob.expr.eval(rows[b]);
        final nullsFirst = ob.nullsFirst ?? !ob.descending;
        if (av == null && bv == null) continue;
        if (av == null) return nullsFirst ? -1 : 1;
        if (bv == null) return nullsFirst ? 1 : -1;
        final c = sqlCompare(av, bv);
        if (c != 0) return ob.descending ? -c : c;
      }
      return 0;
    }

    bool sameOrderKey(int a, int b) {
      if (spec.orderBy.isEmpty) return true;
      return orderCmp(a, b) == 0;
    }

    bool passesFilter(Map<String, Object?> r) {
      if (fn.filterExpr == null) return true;
      final v = fn.filterExpr!.eval(r);
      return v == true || (v is num && v != 0);
    }

    // Frame defaults follow SQL: when ORDER BY is present, RANGE
    // UNBOUNDED PRECEDING TO CURRENT ROW; otherwise the entire partition.
    final frame = spec.frame;

    for (final part in partitions.values) {
      final ordered = List<int>.from(part)..sort(orderCmp);
      final partRows = ordered.map((i) => rows[i]).toList();

      // Helper: compute frame bounds for index k in `ordered` (k is the
      // current-row position). Returns inclusive [lo, hi].
      List<int> frameRange(int k) {
        if (frame == null) {
          if (spec.orderBy.isEmpty) return [0, ordered.length - 1];
          // default RANGE UNBOUNDED PRECEDING TO CURRENT ROW with peers
          var hi = k;
          while (hi + 1 < ordered.length &&
              sameOrderKey(ordered[k], ordered[hi + 1])) {
            hi++;
          }
          return [0, hi];
        }
        int lo;
        int hi;
        if (frame.mode == FrameMode.rows) {
          int boundLo(FrameBound b) {
            switch (b.kind) {
              case FrameBoundKind.unboundedPreceding:
                return 0;
              case FrameBoundKind.preceding:
                final off = (b.offset!.eval(const {}) as num).toInt();
                return (k - off).clamp(0, ordered.length - 1);
              case FrameBoundKind.currentRow:
                return k;
              case FrameBoundKind.following:
                final off = (b.offset!.eval(const {}) as num).toInt();
                return (k + off).clamp(0, ordered.length - 1);
              case FrameBoundKind.unboundedFollowing:
                return ordered.length - 1;
            }
          }

          int boundHi(FrameBound b) => boundLo(b);
          lo = boundLo(frame.start);
          hi = boundHi(frame.end);
        } else {
          // RANGE / GROUPS: tie-aware default behaviour.
          // For RANGE on a numeric ORDER BY, n PRECEDING/FOLLOWING look at
          // value differences. For simplicity we treat RANGE n
          // PRECEDING/FOLLOWING the same as ROWS when no ORDER BY tie groups
          // matter, and use peer expansion for CURRENT ROW boundaries.
          int peerStart(int idx) {
            var i = idx;
            while (i > 0 && sameOrderKey(ordered[i - 1], ordered[idx])) {
              i--;
            }
            return i;
          }

          int peerEnd(int idx) {
            var i = idx;
            while (i + 1 < ordered.length &&
                sameOrderKey(ordered[i + 1], ordered[idx])) {
              i++;
            }
            return i;
          }

          int boundFor(FrameBound b, {required bool isStart}) {
            switch (b.kind) {
              case FrameBoundKind.unboundedPreceding:
                return 0;
              case FrameBoundKind.preceding:
                final off = (b.offset!.eval(const {}) as num).toInt();
                final t = (k - off).clamp(0, ordered.length - 1);
                return isStart ? peerStart(t) : peerEnd(t);
              case FrameBoundKind.currentRow:
                return isStart ? peerStart(k) : peerEnd(k);
              case FrameBoundKind.following:
                final off = (b.offset!.eval(const {}) as num).toInt();
                final t = (k + off).clamp(0, ordered.length - 1);
                return isStart ? peerStart(t) : peerEnd(t);
              case FrameBoundKind.unboundedFollowing:
                return ordered.length - 1;
            }
          }

          lo = boundFor(frame.start, isStart: true);
          hi = boundFor(frame.end, isStart: false);
        }
        if (lo > hi) {
          // empty frame
          return [0, -1];
        }
        return [lo, hi];
      }

      List<Map<String, Object?>> frameRows(int k,
          {bool excludeCurrent = false}) {
        final r = frameRange(k);
        if (r[1] < r[0]) return const [];
        final result = <Map<String, Object?>>[];
        for (var i = r[0]; i <= r[1]; i++) {
          if (excludeCurrent && i == k) continue;
          // EXCLUDE handling
          switch (frame?.exclude ?? FrameExclude.noOthers) {
            case FrameExclude.noOthers:
              break;
            case FrameExclude.currentRow:
              if (i == k) continue;
              break;
            case FrameExclude.group:
              if (sameOrderKey(ordered[i], ordered[k])) continue;
              break;
            case FrameExclude.ties:
              if (i != k && sameOrderKey(ordered[i], ordered[k])) continue;
              break;
          }
          if (!passesFilter(partRows[i])) continue;
          result.add(partRows[i]);
        }
        return result;
      }

      switch (fn.name) {
        case 'ROW_NUMBER':
          for (var k = 0; k < ordered.length; k++) {
            out[ordered[k]] = k + 1;
          }
          break;
        case 'RANK':
          {
            var rank = 1;
            for (var k = 0; k < ordered.length; k++) {
              if (k > 0 && !sameOrderKey(ordered[k - 1], ordered[k])) {
                rank = k + 1;
              }
              out[ordered[k]] = rank;
            }
          }
          break;
        case 'DENSE_RANK':
          {
            var rank = 1;
            for (var k = 0; k < ordered.length; k++) {
              if (k > 0 && !sameOrderKey(ordered[k - 1], ordered[k])) {
                rank++;
              }
              out[ordered[k]] = rank;
            }
          }
          break;
        case 'PERCENT_RANK':
          {
            // (rank - 1) / (N - 1)
            final m = ordered.length;
            var rank = 1;
            for (var k = 0; k < m; k++) {
              if (k > 0 && !sameOrderKey(ordered[k - 1], ordered[k])) {
                rank = k + 1;
              }
              out[ordered[k]] = m <= 1 ? 0.0 : (rank - 1) / (m - 1);
            }
          }
          break;
        case 'CUME_DIST':
          {
            // Number of rows <= current peer / N
            final m = ordered.length;
            for (var k = 0; k < m; k++) {
              var hi = k;
              while (hi + 1 < m && sameOrderKey(ordered[k], ordered[hi + 1])) {
                hi++;
              }
              final v = (hi + 1) / m;
              for (var j = k; j <= hi; j++) {
                out[ordered[j]] = v;
              }
              k = hi;
            }
          }
          break;
        case 'NTILE':
          {
            final buckets = (fn.args.first.eval(const {}) as num).toInt();
            final m = ordered.length;
            // Distribute extras into the first (m % buckets) tiles.
            final base = m ~/ buckets;
            final extra = m % buckets;
            var idx = 0;
            for (var b = 1; b <= buckets; b++) {
              final size = base + (b <= extra ? 1 : 0);
              for (var j = 0; j < size && idx < m; j++) {
                out[ordered[idx]] = b;
                idx++;
              }
            }
          }
          break;
        case 'LAG':
        case 'LEAD':
          {
            final dir = fn.name == 'LAG' ? -1 : 1;
            final offset = fn.args.length >= 2
                ? (fn.args[1].eval(const {}) as num).toInt()
                : 1;
            final defaultVal =
                fn.args.length >= 3 ? fn.args[2].eval(const {}) : null;
            for (var k = 0; k < ordered.length; k++) {
              final target = k + dir * offset;
              if (target < 0 || target >= ordered.length) {
                out[ordered[k]] = defaultVal;
              } else {
                out[ordered[k]] = fn.args.isEmpty
                    ? null
                    : fn.args.first.eval(rows[ordered[target]]);
              }
            }
          }
          break;
        case 'FIRST_VALUE':
          for (var k = 0; k < ordered.length; k++) {
            final fr = frameRows(k);
            out[ordered[k]] = fr.isEmpty ? null : fn.args.first.eval(fr.first);
          }
          break;
        case 'LAST_VALUE':
          for (var k = 0; k < ordered.length; k++) {
            final fr = frameRows(k);
            out[ordered[k]] = fr.isEmpty ? null : fn.args.first.eval(fr.last);
          }
          break;
        case 'NTH_VALUE':
          {
            final nth = (fn.args[1].eval(const {}) as num).toInt();
            for (var k = 0; k < ordered.length; k++) {
              final fr = frameRows(k);
              out[ordered[k]] = (nth < 1 || nth > fr.length)
                  ? null
                  : fn.args.first.eval(fr[nth - 1]);
            }
          }
          break;
        case 'COUNT':
        case 'SUM':
        case 'AVG':
        case 'MIN':
        case 'MAX':
        case 'TOTAL':
        case 'GROUP_CONCAT':
        case 'JSON_GROUP_ARRAY':
        case 'JSON_GROUP_OBJECT':
          {
            for (var k = 0; k < ordered.length; k++) {
              final slice = frameRows(k);
              out[ordered[k]] = _aggregateValue(fn, slice);
            }
          }
          break;
        default:
          throw StateError('Unsupported window function: ${fn.name}');
      }
    }
    return out;
  }

  /// Resolves a `WindowSpec` whose `baseName` references a named window
  /// in the SELECT's WINDOW clause. The inline spec extends/overrides the
  /// named one (partition/order can be inherited; frame can be added).
  WindowSpec _resolveWindowSpec(
      WindowSpec spec, Map<String, WindowSpec> namedWindows) {
    if (spec.baseName == null) return spec;
    final base = namedWindows[spec.baseName!];
    if (base == null) {
      throw StateError('Unknown window: ${spec.baseName}');
    }
    return WindowSpec(
      partitionBy:
          spec.partitionBy.isNotEmpty ? spec.partitionBy : base.partitionBy,
      orderBy: spec.orderBy.isNotEmpty ? spec.orderBy : base.orderBy,
      frame: spec.frame ?? base.frame,
    );
  }

  // ---------------------------------------------------------------------------
  // Subquery binding
  // ---------------------------------------------------------------------------

  /// Walk the expression tree, replacing any Subquery* placeholders with
  /// concrete versions whose closures invoke the database executor.
  /// [outerScope] (optional) is merged into the *outer* row at evaluation
  /// time before being passed as outer scope to the inner SELECT — this is
  /// what enables correlated subqueries.
  Expr _bindExpr(Expr e, [Map<String, Object?> outerScope = const {}]) {
    // Fold NEW.col / OLD.col references inside trigger bodies into literals
    // so they survive evaluation against unrelated row maps.
    if (e is ColumnExpr && _triggerScope != null) {
      final tbl = e.table?.toUpperCase();
      if (tbl == 'NEW' || tbl == 'OLD') {
        final key = '$tbl.${e.name}';
        return LiteralExpr(_triggerScope![key]);
      }
    }
    if (e is SubquerySelectExpr) {
      return ScalarSubqueryExpr((row) {
        final r = _selectTopLevel(e.select, {...outerScope, ...row});
        if (r.rows.isEmpty) return null;
        if (r.rows.first.isEmpty) return null;
        return r.rows.first.first;
      });
    }
    if (e is SubqueryInExpr) {
      return InSubqueryExpr(_bindExpr(e.value, outerScope), (row) {
        final r = _selectTopLevel(e.select, {...outerScope, ...row});
        return r.rows.map((row) => row.isEmpty ? null : row.first).toList();
      }, negated: e.negated);
    }
    if (e is SubqueryExistsExpr) {
      return ExistsExpr((row) {
        final r = _selectTopLevel(e.select, {...outerScope, ...row});
        return r.rows.isNotEmpty;
      }, negated: e.negated);
    }
    if (e is BinaryExpr) {
      return BinaryExpr(
          e.op, _bindExpr(e.left, outerScope), _bindExpr(e.right, outerScope));
    }
    if (e is UnaryExpr)
      return UnaryExpr(e.op, _bindExpr(e.operand, outerScope));
    if (e is BetweenExpr) {
      return BetweenExpr(_bindExpr(e.value, outerScope),
          _bindExpr(e.low, outerScope), _bindExpr(e.high, outerScope),
          negated: e.negated);
    }
    if (e is InExpr) {
      return InExpr(_bindExpr(e.value, outerScope),
          e.values.map((x) => _bindExpr(x, outerScope)).toList(),
          negated: e.negated);
    }
    if (e is CaseExpr) {
      return CaseExpr(
          e.whens.map((x) => _bindExpr(x, outerScope)).toList(),
          e.thens.map((x) => _bindExpr(x, outerScope)).toList(),
          e.elseExpr == null ? null : _bindExpr(e.elseExpr!, outerScope));
    }
    if (e is CastExpr)
      return CastExpr(_bindExpr(e.expr, outerScope), e.targetType);
    if (e is FunctionCallExpr) {
      // Window arguments are evaluated in their own pass, but we still
      // need to bind subqueries / nested exprs in their args.
      WindowSpec? boundWindow;
      if (e.window != null) {
        boundWindow = WindowSpec(
          partitionBy: e.window!.partitionBy
              .map((x) => _bindExpr(x, outerScope))
              .toList(),
          orderBy: e.window!.orderBy
              .map((o) => WindowOrderItem(_bindExpr(o.expr, outerScope),
                  descending: o.descending, nullsFirst: o.nullsFirst))
              .toList(),
          frame: e.window!.frame,
          baseName: e.window!.baseName,
        );
      }
      return FunctionCallExpr(
          e.name, e.args.map((x) => _bindExpr(x, outerScope)).toList(),
          isStarArg: e.isStarArg,
          distinct: e.distinct,
          window: boundWindow,
          filterExpr: e.filterExpr == null
              ? null
              : _bindExpr(e.filterExpr!, outerScope));
    }
    return e;
  }

  Object? _evalScalar(Expr e, [Map<String, Object?> row = const {}]) {
    return _bindExpr(e).eval(row);
  }

  // ---------------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------------
  QueryResult _begin() {
    if (inTransaction) throw StateError('Already in a transaction');
    _snapshot = {for (final e in _tables.entries) e.key: e.value.clone()};
    _viewSnapshot = Map<String, SelectStmt>.from(_views);
    return QueryResult.message('Transaction started');
  }

  QueryResult _commit() {
    if (!inTransaction) throw StateError('No transaction in progress');
    // Replay any deferred FK checks now. Failure rolls the txn back
    // and throws with a deferred-prefixed message.
    if (_deferredFkChecks.isNotEmpty && !_readOnlySnapshot) {
      final queued = List<_DeferredFk>.from(_deferredFkChecks);
      _deferredFkChecks.clear();
      for (final d in queued) {
        final t = _tables[d.childTable];
        if (t == null) continue;
        try {
          // Re-check synchronously; bypass the deferral path.
          for (final fk in _foreignKeysOf(t)) {
            final values =
                fk.columns.map((c) => d.row[t.columnIndex(c)]).toList();
            if (values.any((v) => v == null)) continue;
            final parent = _tables[fk.references.table];
            if (parent == null) {
              throw StateError(
                  'FK references missing table ${fk.references.table}');
            }
            final parentCols = fk.references.column != null
                ? [fk.references.column!]
                : _primaryKeyColumns(parent);
            var found = false;
            for (final r in parent.rows) {
              var match = true;
              for (var i = 0; i < parentCols.length; i++) {
                final pv = r[parent.columnIndex(parentCols[i])];
                if (pv == null || !sqlEq(pv, values[i] as Object)) {
                  match = false;
                  break;
                }
              }
              if (match) {
                found = true;
                break;
              }
            }
            if (!found) {
              throw StateError('FOREIGN KEY constraint failed: '
                  '${t.name}.${fk.columns.join(",")} -> '
                  '${parent.name}.${parentCols.join(",")} = $values');
            }
          }
        } catch (e) {
          _rollback();
          throw StateError('DEFERRED FOREIGN KEY check failed on commit: $e');
        }
      }
    }
    if (_readOnlySnapshot) {
      // Discard the snapshot view; restore the live (unchanged) state.
      _tables
        ..clear()
        ..addAll(_liveTables!);
      _views
        ..clear()
        ..addAll(_liveViews!);
      _liveTables = null;
      _liveViews = null;
      _readOnlySnapshot = false;
    }
    _snapshot = null;
    _viewSnapshot = null;
    return QueryResult.message('Transaction committed');
  }

  QueryResult _rollback() {
    if (!inTransaction) throw StateError('No transaction in progress');
    _deferredFkChecks.clear();
    if (_readOnlySnapshot) {
      _tables
        ..clear()
        ..addAll(_liveTables!);
      _views
        ..clear()
        ..addAll(_liveViews!);
      _liveTables = null;
      _liveViews = null;
      _readOnlySnapshot = false;
    } else {
      _tables
        ..clear()
        ..addAll(_snapshot!);
      _views
        ..clear()
        ..addAll(_viewSnapshot!);
    }
    _snapshot = null;
    _viewSnapshot = null;
    return QueryResult.message('Transaction rolled back');
  }

  // ---------------------------------------------------------------------------
  // Introspection
  // ---------------------------------------------------------------------------
  QueryResult _showTables() => QueryResult(
        columns: const ['name', 'kind'],
        rows: [
          ..._tables.keys.map((n) => <Object?>[n, 'TABLE']),
          ..._views.keys.map((n) => <Object?>[n, 'VIEW']),
        ],
        affected: _tables.length + _views.length,
      );

  QueryResult _describe(DescribeStmt s) {
    if (_views.containsKey(s.table)) {
      final res = _selectTopLevel(_views[s.table]!);
      return QueryResult(
        columns: const ['name', 'type'],
        rows: res.columns.map((c) => <Object?>[c, 'VIEW']).toList(),
        affected: res.columns.length,
      );
    }
    final t = _requireTable(s.table);
    return QueryResult(
      columns: const [
        'name',
        'type',
        'notNull',
        'primaryKey',
        'unique',
        'autoIncrement',
        'default'
      ],
      rows: t.columns
          .map((c) => <Object?>[
                c.name,
                dataTypeName(c.type),
                c.notNull,
                c.primaryKey,
                c.unique,
                c.autoIncrement,
                c.defaultValue,
              ])
          .toList(),
      affected: t.columns.length,
    );
  }

  QueryResult _explain(ExplainStmt s) {
    return QueryResult(
      columns: const ['plan'],
      rows: _planLines(s.target).map((l) => <Object?>[l]).toList(),
    );
  }

  // ---------------------------------------------------------------------------
  // PRAGMA
  // ---------------------------------------------------------------------------
  QueryResult _pragma(PragmaStmt s) {
    final name = s.name.toLowerCase();
    // Setter form: PRAGMA name = value  /  PRAGMA name(value)
    if (s.value != null) {
      _pragmas[name] = s.value;
      return QueryResult.message('PRAGMA $name = ${s.value}');
    }
    // Special introspection PRAGMAs.
    switch (name) {
      case 'table_info':
      case 'table_xinfo':
        return QueryResult(columns: const [
          'cid',
          'name',
          'type',
          'notnull',
          'dflt_value',
          'pk'
        ], rows: const []);
      case 'database_list':
        return QueryResult(columns: const [
          'seq',
          'name',
          'file'
        ], rows: [
          [0, 'main', path ?? ''],
          for (final e in _attached.entries.toList().asMap().entries)
            [e.key + 1, e.value.key, e.value.value],
        ]);
      case 'index_list':
        return QueryResult(
            columns: const ['seq', 'name', 'unique'], rows: const []);
      case 'index_info':
      case 'index_xinfo':
        return QueryResult(
            columns: const ['seqno', 'cid', 'name'], rows: const []);
      case 'foreign_key_list':
        return QueryResult(columns: const [
          'id',
          'seq',
          'table',
          'from',
          'to',
          'on_update',
          'on_delete',
          'match'
        ], rows: const []);
      case 'integrity_check':
      case 'quick_check':
        return QueryResult(columns: const [
          'integrity_check'
        ], rows: const [
          ['ok']
        ]);
      case 'compile_options':
        return QueryResult(columns: const [
          'compile_options'
        ], rows: const [
          ['ENABLE_JSON1'],
          ['ENABLE_WINDOW_FUNCTIONS'],
          ['ENABLE_FTS5'],
          ['ENABLE_RTREE'],
          ['ENABLE_UPDATE_DELETE_LIMIT'],
        ]);
      case 'collation_list':
        return QueryResult(columns: const [
          'seq',
          'name'
        ], rows: const [
          [0, 'BINARY'],
          [1, 'NOCASE'],
          [2, 'RTRIM'],
        ]);
      case 'function_list':
      case 'module_list':
      case 'pragma_list':
        return QueryResult(columns: const ['name'], rows: const []);
    }
    // Recognised PRAGMA names with sensible default return values when no
    // explicit value has been set. Matches the SQLite list closely enough
    // for client compatibility; values are no-ops in this engine.
    const defaults = <String, Object?>{
      'cache_size': -2000,
      'page_size': 4096,
      'page_count': 0,
      'max_page_count': 1073741823,
      'journal_mode': 'memory',
      'synchronous': 1,
      'foreign_keys': 1,
      'locking_mode': 'normal',
      'mmap_size': 0,
      'temp_store': 0,
      'encoding': 'UTF-8',
      'user_version': 0,
      'application_id': 0,
      'schema_version': 1,
      'busy_timeout': 0,
      'wal_autocheckpoint': 1000,
      'automatic_index': 1,
      'recursive_triggers': 1,
      'defer_foreign_keys': 0,
      'ignore_check_constraints': 0,
      'read_uncommitted': 0,
      'reverse_unordered_selects': 0,
      'secure_delete': 0,
      'soft_heap_limit': 0,
      'threads': 0,
      'trusted_schema': 1,
      'cell_size_check': 0,
      'auto_vacuum': 0,
      'fullfsync': 0,
      'checkpoint_fullfsync': 0,
      'cache_spill': 0,
      'count_changes': 0,
      'data_version': 1,
      'legacy_alter_table': 0,
      'legacy_file_format': 0,
      'optimize': 0,
      'query_only': 0,
      'short_column_names': 1,
      'wal_checkpoint': 0,
    };
    final v = _pragmas.containsKey(name) ? _pragmas[name] : defaults[name];
    return QueryResult(columns: [
      name
    ], rows: [
      <Object?>[v]
    ], affected: v == null ? 0 : 1);
  }

  // ---------------------------------------------------------------------------
  // Triggers
  // ---------------------------------------------------------------------------
  QueryResult _createTrigger(CreateTriggerStmt s) {
    if (_triggers.containsKey(s.name)) {
      if (s.ifNotExists) {
        return QueryResult.message('Trigger ${s.name} already exists');
      }
      throw StateError('Trigger ${s.name} already exists');
    }
    if (s.timing == 'INSTEAD OF') {
      if (!_views.containsKey(s.table)) {
        throw StateError(
            'INSTEAD OF trigger requires a view target: ${s.table}');
      }
    } else {
      _requireTable(s.table);
    }
    _triggers[s.name] =
        _TriggerSpec(s.name, s.timing, s.event, s.table, s.when, s.body);
    return QueryResult.message('Trigger ${s.name} created');
  }

  QueryResult _dropTrigger(DropTriggerStmt s) {
    if (!_triggers.containsKey(s.name)) {
      if (s.ifExists) {
        return QueryResult.message('Trigger ${s.name} did not exist');
      }
      throw StateError('No such trigger: ${s.name}');
    }
    _triggers.remove(s.name);
    return QueryResult.message('Trigger ${s.name} dropped');
  }

  Iterable<_TriggerSpec> _triggersFor(
      String table, String event, String timing) sync* {
    for (final t in _triggers.values) {
      if (t.table == table && t.event == event && t.timing == timing) yield t;
    }
  }

  QueryResult _runInsteadOfInsert(InsertStmt s) {
    final view = _views[s.table]!;
    final viewCols = _selectTopLevel(view).columns;
    // Determine target columns: explicit list or full view column set.
    final targetCols = s.columns ?? viewCols;
    final List<List<Object?>> sourceRows;
    if (s.select != null) {
      sourceRows = _selectTopLevel(s.select!).rows;
    } else {
      sourceRows = (s.rows ?? const <List<Expr>>[])
          .map((r) => r.map((e) => _evalScalar(e)).toList())
          .toList();
    }
    var count = 0;
    for (final r in sourceRows) {
      // Build a NEW row aligned with view column order.
      final newRow = List<Object?>.filled(viewCols.length, null);
      for (var i = 0; i < targetCols.length && i < r.length; i++) {
        final idx = viewCols.indexOf(targetCols[i]);
        if (idx >= 0) newRow[idx] = r[i];
      }
      _fireTriggers(s.table, 'INSERT', 'INSTEAD OF',
          newRow: newRow, columnNames: viewCols);
      count++;
    }
    return QueryResult.message('$count row(s) inserted', affected: count);
  }

  QueryResult _runInsteadOfUpdate(UpdateStmt s) {
    final view = _views[s.table]!;
    final res = _selectTopLevel(view);
    final viewCols = res.columns;
    var count = 0;
    for (final row in res.rows) {
      final view2 = <String, Object?>{
        for (var i = 0; i < viewCols.length; i++) viewCols[i]: row[i],
      };
      if (s.where != null && !evalPredicate(_bindExpr(s.where!), view2)) {
        continue;
      }
      final newRow = List<Object?>.from(row);
      s.assignments.forEach((col, expr) {
        final idx = viewCols.indexOf(col);
        if (idx >= 0) newRow[idx] = _evalScalar(expr, view2);
      });
      _fireTriggers(s.table, 'UPDATE', 'INSTEAD OF',
          oldRow: row, newRow: newRow, columnNames: viewCols);
      count++;
    }
    return QueryResult.message('$count row(s) updated', affected: count);
  }

  QueryResult _runInsteadOfDelete(DeleteStmt s) {
    final view = _views[s.table]!;
    final res = _selectTopLevel(view);
    final viewCols = res.columns;
    var count = 0;
    for (final row in res.rows) {
      final view2 = <String, Object?>{
        for (var i = 0; i < viewCols.length; i++) viewCols[i]: row[i],
      };
      if (s.where != null && !evalPredicate(_bindExpr(s.where!), view2)) {
        continue;
      }
      _fireTriggers(s.table, 'DELETE', 'INSTEAD OF',
          oldRow: row, columnNames: viewCols);
      count++;
    }
    return QueryResult.message('$count row(s) deleted', affected: count);
  }

  /// Run all triggers matching ([table], [event], [timing]) once with the
  /// supplied NEW / OLD bindings. Either map may be null when not relevant.
  void _fireTriggers(String table, String event, String timing,
      {List<Object?>? newRow,
      List<Object?>? oldRow,
      Table? sourceTable,
      List<String>? columnNames}) {
    final fired = _triggersFor(table, event, timing).toList();
    if (fired.isEmpty) return;
    final names = columnNames ??
        (sourceTable == null
            ? const <String>[]
            : sourceTable.columns.map((c) => c.name).toList());
    final scope = <String, Object?>{};
    for (var i = 0; i < names.length; i++) {
      final c = names[i];
      if (newRow != null && i < newRow.length) scope['NEW.$c'] = newRow[i];
      if (oldRow != null && i < oldRow.length) scope['OLD.$c'] = oldRow[i];
    }
    final saved = _triggerScope;
    _triggerScope = {...?saved, ...scope};
    try {
      for (final tr in fired) {
        if (tr.when != null && !evalPredicate(_bindExpr(tr.when!), const {})) {
          continue;
        }
        try {
          for (final stmt in tr.body) {
            _dispatch(stmt);
          }
        } on RaiseException catch (e) {
          switch (e.action) {
            case 'IGNORE':
              return; // silently abandon the host operation
            case 'ROLLBACK':
              if (inTransaction) _rollback();
              throw StateError(
                  'RAISE(ROLLBACK${e.message.isEmpty ? '' : ", '${e.message}'"})');
            default: // ABORT / FAIL
              throw StateError(
                  'RAISE(${e.action}${e.message.isEmpty ? '' : ", '${e.message}'"})');
          }
        }
      }
    } finally {
      _triggerScope = saved;
    }
  }

  // ---------------------------------------------------------------------------
  // Savepoints
  // ---------------------------------------------------------------------------
  QueryResult _savepoint(SavepointStmt s) {
    final tablesSnap = {
      for (final e in _tables.entries) e.key: e.value.clone()
    };
    final viewsSnap = Map<String, SelectStmt>.from(_views);
    _savepoints.add(_Savepoint(s.name, tablesSnap, viewsSnap));
    return QueryResult.message('Savepoint ${s.name} created');
  }

  QueryResult _releaseSavepoint(ReleaseSavepointStmt s) {
    final i = _savepoints.lastIndexWhere((sp) => sp.name == s.name);
    if (i < 0) throw StateError('No such savepoint: ${s.name}');
    // Release this savepoint and any nested ones above it.
    _savepoints.removeRange(i, _savepoints.length);
    return QueryResult.message('Savepoint ${s.name} released');
  }

  QueryResult _rollbackToSavepoint(RollbackToSavepointStmt s) {
    final i = _savepoints.lastIndexWhere((sp) => sp.name == s.name);
    if (i < 0) throw StateError('No such savepoint: ${s.name}');
    final sp = _savepoints[i];
    _tables
      ..clear()
      ..addAll(sp.tables);
    _views
      ..clear()
      ..addAll(sp.views);
    // Discard nested savepoints above this one (the savepoint itself remains).
    _savepoints.removeRange(i + 1, _savepoints.length);
    return QueryResult.message('Rolled back to savepoint ${s.name}');
  }

  // ---------------------------------------------------------------------------
  // ATTACH DATABASE
  // ---------------------------------------------------------------------------

  /// Load tables from the database at [s.path] into this database,
  /// namespacing each table as `alias.tablename`. The file may be either
  /// our JSON format or a SQLite-format binary file (auto-detected by
  /// the 16-byte magic header).
  QueryResult _attachDatabase(AttachDatabaseStmt s) {
    if (_attached.containsKey(s.alias)) {
      throw StateError('Database "${s.alias}" is already attached');
    }
    _attached[s.alias] = s.path;
    final f = File(s.path);
    if (f.existsSync() && f.lengthSync() > 0) {
      final bytes = f.readAsBytesSync();
      const magic = [
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, // 'SQLite f'
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00, // 'ormat 3\0'
      ];
      var isSqlite = bytes.length >= 16;
      if (isSqlite) {
        for (var i = 0; i < 16; i++) {
          if (bytes[i] != magic[i]) {
            isSqlite = false;
            break;
          }
        }
      }
      if (isSqlite) {
        _attachSqliteFile(s.alias, s.path, bytes);
      } else {
        final raw = String.fromCharCodes(bytes).trim();
        if (raw.isNotEmpty) {
          final data = jsonDecode(raw);
          Map<String, Object?> tables;
          if (data is Map && data['__schema__'] == 2) {
            tables = (data['tables'] as Map).cast<String, Object?>();
          } else {
            tables = (data as Map).cast<String, Object?>();
          }
          tables.forEach((tname, tjson) {
            final m = (tjson as Map).cast<String, Object?>();
            m['name'] ??= tname;
            final t = Table.fromJson(m);
            t.name = '${s.alias}.${t.name}';
            _tables[t.name] = t;
          });
        }
      }
    }
    return QueryResult.message('Database "${s.alias}" attached');
  }

  /// Load every user table from a SQLite-format file under the namespace
  /// `alias.tablename`. Tables are read into in-memory `Table` objects;
  /// writes through SQL go to memory only (no propagation back to the
  /// SQLite file), matching the read-only semantics of attaching.
  void _attachSqliteFile(String alias, String path, Uint8List bytes) {
    final walFile = File('$path-wal');
    final walBytes = walFile.existsSync() ? walFile.readAsBytesSync() : null;
    final fmt = walBytes != null
        ? SqliteFile.fromBytesWithWal(bytes, walBytes)
        : SqliteFile.fromBytes(bytes);
    final schema = fmt.readSchema();
    final tableSchemas = schema.where((s) => s.type == 'table').toList();
    for (final ts in tableSchemas) {
      if (ts.sql == null) continue;
      if (ts.name == 'sqlite_sequence' || ts.name == 'sqlite_stat1') continue;
      // Parse the CREATE TABLE in isolation so we can build a Table
      // without touching the local namespace, then rename it under
      // `alias.`.
      Table tbl;
      try {
        final stmt = Parser.fromString(ts.sql!).parseStatement();
        if (stmt is! CreateTableStmt) continue;
        tbl = Table(stmt.name, stmt.columns,
            constraints: stmt.constraints,
            strict: stmt.strict,
            withoutRowid: stmt.withoutRowid);
      } catch (_) {
        continue;
      }
      // Restore rows, applying the WITHOUT ROWID column-order remap.
      final isWor = fmt.isWithoutRowid(ts.name);
      final pkIdx = tbl.columns
          .indexWhere((c) => c.primaryKey && c.type == DataType.integer);
      List<int>? onDiskToDeclared;
      if (isWor) {
        final pkCols = <int>[];
        for (var i = 0; i < tbl.columns.length; i++) {
          if (tbl.columns[i].primaryKey) pkCols.add(i);
        }
        if (pkCols.isEmpty) {
          for (final con in tbl.constraints) {
            if (con is PrimaryKeyConstraint) {
              for (final n in con.columns) {
                final idx = tbl.columns
                    .indexWhere((c) => c.name.toLowerCase() == n.toLowerCase());
                if (idx >= 0) pkCols.add(idx);
              }
              break;
            }
          }
        }
        final pkSet = pkCols.toSet();
        onDiskToDeclared = <int>[
          ...pkCols,
          for (var i = 0; i < tbl.columns.length; i++)
            if (!pkSet.contains(i)) i,
        ];
      }
      for (final row in fmt.readTable(ts.name)) {
        var src = row.values;
        if (onDiskToDeclared != null && src.length == tbl.columns.length) {
          final remapped = List<Object?>.filled(tbl.columns.length, null);
          for (var k = 0; k < src.length; k++) {
            remapped[onDiskToDeclared[k]] = src[k];
          }
          src = remapped;
        }
        final values = List<Object?>.from(src);
        while (values.length < tbl.columns.length) {
          values.add(null);
        }
        if (values.length > tbl.columns.length) {
          values.removeRange(tbl.columns.length, values.length);
        }
        if (!isWor && pkIdx >= 0 && values[pkIdx] == null) {
          values[pkIdx] = row.rowid;
        }
        tbl.rows.add(values);
      }
      _rebuildIndexes(tbl);
      tbl.name = '$alias.${tbl.name}';
      _tables[tbl.name] = tbl;
    }
  }

  QueryResult _detachDatabase(DetachDatabaseStmt s) {
    if (!_attached.containsKey(s.alias)) {
      throw StateError('No such attached database: ${s.alias}');
    }
    _attached.remove(s.alias);
    _tables.removeWhere((k, _) => k.startsWith('${s.alias}.'));
    return QueryResult.message('Database "${s.alias}" detached');
  }

  /// VACUUM: in this engine, persistence already serialises the entire
  /// database on every mutation, so VACUUM has no internal work to do
  /// beyond signalling that a fresh on-disk image should be written.
  /// (Returning is enough — the dispatcher persists after mutations.)
  QueryResult _vacuum(VacuumStmt s) {
    return QueryResult.message('VACUUM ok');
  }

  /// Create a "virtual" table. We don't have a true virtual-table API; the
  /// supported toy modules (`fts5`, `rtree`) just create a regular table
  /// with a sensible column list inferred from the module arguments.
  QueryResult _createVirtualTable(CreateVirtualTableStmt s) {
    if (_tables.containsKey(s.name)) {
      if (s.ifNotExists) {
        return QueryResult.message('Table ${s.name} already exists');
      }
      throw StateError('Table ${s.name} already exists');
    }
    final module = s.module.toLowerCase();
    List<ColumnDef> cols;
    switch (module) {
      case 'fts5':
        // Each arg is a column name (extra options like `tokenize=...` are
        // skipped).
        cols = [
          for (final a in s.args)
            if (!a.contains('=')) ColumnDef(a, DataType.text),
        ];
        if (cols.isEmpty) {
          throw FormatException('fts5 requires at least one column');
        }
        break;
      case 'rtree':
        // First arg is rowid name; remaining args are min/max numeric pairs.
        cols = [
          for (final a in s.args) ColumnDef(a, DataType.real),
        ];
        if (cols.isEmpty) {
          throw FormatException('rtree requires at least one column');
        }
        // Promote the first column to INTEGER PRIMARY KEY (the rowid).
        cols[0] = ColumnDef(cols[0].name, DataType.integer, primaryKey: true);
        break;
      default:
        throw StateError('Unsupported virtual-table module: $module');
    }
    _tables[s.name] = Table(s.name, cols);
    return QueryResult.message(
        'Virtual table ${s.name} (USING $module) created');
  }

  /// ANALYZE: populate (or refresh) a synthetic `sqlite_stat1` table with
  /// `(tbl, idx, stat)` rows where `stat` is the row count of `tbl`. Only
  /// tables in the local namespace are analysed.
  QueryResult _analyze(AnalyzeStmt s) {
    final stat = _tables.putIfAbsent(
      'sqlite_stat1',
      () => Table(
        'sqlite_stat1',
        const [
          ColumnDef('tbl', DataType.text),
          ColumnDef('idx', DataType.text),
          ColumnDef('stat', DataType.text),
        ],
      ),
    );
    Iterable<MapEntry<String, Table>> targets;
    if (s.target == null) {
      targets = _tables.entries.where((e) => e.key != 'sqlite_stat1');
    } else {
      final t = _tables[s.target];
      if (t == null) throw StateError('No such table: ${s.target}');
      targets = [MapEntry(s.target!, t)];
    }
    // Remove any prior rows for these tables.
    final names = targets.map((e) => e.key).toSet();
    stat.rows.removeWhere((r) => names.contains(r[0]));
    for (final e in targets) {
      final tbl = e.value;
      stat.rows.add([e.key, null, tbl.rows.length.toString()]);

      // Identify the auto-created INTEGER-PRIMARY-KEY shadow index so we
      // can skip it: SQLite has no real on-disk index for that case.
      final pkIntCol = tbl.columns.firstWhere(
          (c) => c.primaryKey && c.type == DataType.integer,
          orElse: () => const ColumnDef('', DataType.any));
      final pkShadowName =
          pkIntCol.name.isEmpty ? null : '${e.key}__${pkIntCol.name}';

      // Sample per-index distinct counts.
      final distinct = <String, int>{};
      for (final idxDef in tbl.indexDefs.values) {
        if (idxDef.exprSql != null || idxDef.whereSql != null) continue;
        if (idxDef.name == pkShadowName) continue;
        final col = idxDef.column;
        final keys = <Object>{};
        final colIdx = tbl.columns
            .indexWhere((c) => c.name.toLowerCase() == col.toLowerCase());
        if (colIdx < 0) continue;
        for (final r in tbl.rows) {
          final v = r[colIdx];
          if (v != null) keys.add(v);
        }
        distinct[col.toLowerCase()] = keys.length;
        // Mirror per-index stat into sqlite_stat1 in the SQLite-style
        // 'rowCount avgRowsPerKey' format.
        final avg = keys.isEmpty
            ? tbl.rows.length
            : (tbl.rows.length / keys.length).ceil();
        stat.rows.add([e.key, idxDef.name, '${tbl.rows.length} $avg']);
      }
      _stats[e.key] = _TableStats(tbl.rows.length, distinct);
    }
    _rebuildIndexes(stat);
    return QueryResult.message('ANALYZE ok');
  }

  List<String> _planLines(Statement stmt) {
    if (stmt is SelectStmt) {
      final lines = <String>[];
      lines.add('SCAN ${stmt.fromTable}'
          '${stmt.fromAlias != null ? " AS ${stmt.fromAlias}" : ""}');
      for (final j in stmt.joins) {
        lines.add('  ${j.type} JOIN ${j.table}'
            '${j.alias != null ? " AS ${j.alias}" : ""}'
            '${j.on != null ? " ON ..." : ""}');
      }
      if (stmt.where != null) lines.add('  FILTER WHERE');
      if (stmt.groupBy.isNotEmpty) {
        lines.add('  GROUP BY ${stmt.groupBy.length} key(s)');
      }
      if (stmt.having != null) lines.add('  HAVING');
      if (stmt.orderBy.isNotEmpty)
        lines.add('  ORDER BY ${stmt.orderBy.length} key(s)');
      if (stmt.limit != null) lines.add('  LIMIT ${stmt.limit}');
      if (stmt.offset != null) lines.add('  OFFSET ${stmt.offset}');
      if (stmt.setOp != null) {
        lines.add(stmt.setOp!);
        lines.addAll(_planLines(stmt.setOpRight!).map((l) => '  $l'));
      }
      return lines;
    }
    return [stmt.runtimeType.toString()];
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------
  Future<void> _persist() async {
    if (path == null) return;
    if (_persistAsSqlite) {
      await _persistSqlite();
      return;
    }
    final out = <String, Object?>{
      '__schema__': 2,
      'tables': {for (final e in _tables.entries) e.key: e.value.toJson()},
      'views': {for (final e in _viewSql.entries) e.key: e.value},
    };
    await File(path!).writeAsString(jsonEncode(out));
  }

  /// Maximum fraction of pages that may change before we abandon the
  /// incremental `-wal` and rewrite the whole main file. 0.75 mirrors
  /// the threshold the SQLite library uses for auto-checkpointing.
  static const double _walAutoCheckpointThreshold = 0.75;

  /// SQLite-format persist. First call (or any call where the change
  /// ratio exceeds [_walAutoCheckpointThreshold], or where the file
  /// shrinks) writes the main file in full and snapshots it as the diff
  /// baseline. Subsequent calls write a fresh `<path>-wal` companion
  /// containing only the pages that differ from the baseline, leaving
  /// the main file untouched.
  Future<void> _persistSqlite() async {
    final current = _buildSqliteBytes(pageSize: _sqlitePageSize);
    final baseline = _sqliteBaselineBytes;
    final walPath = '${path!}-wal';
    final ps = _sqlitePageSize;
    final canDiff = baseline != null &&
        baseline.length % ps == 0 &&
        current.length % ps == 0 &&
        current.length >= baseline.length;
    if (!canDiff) {
      // Full rewrite path.
      await File(path!).writeAsBytes(current);
      _sqliteBaselineBytes = Uint8List.fromList(current);
      final wf = File(walPath);
      if (await wf.exists()) await wf.delete();
      return;
    }
    final pages = current.length ~/ ps;
    final basePages = baseline.length ~/ ps;
    final overrides = <int, Uint8List>{};
    for (var i = 0; i < pages; i++) {
      final off = i * ps;
      final cur = Uint8List.sublistView(current, off, off + ps);
      if (i < basePages) {
        final bp = Uint8List.sublistView(baseline, off, off + ps);
        if (_bytesEqual(bp, cur)) continue;
      }
      overrides[i + 1] = Uint8List.fromList(cur);
    }
    if (overrides.isEmpty) {
      // No-op commit; drop any stale WAL.
      final wf = File(walPath);
      if (await wf.exists()) await wf.delete();
      return;
    }
    final ratio = overrides.length / pages;
    if (ratio >= _walAutoCheckpointThreshold) {
      // Too churny: rewrite the main file and reset baseline.
      await File(path!).writeAsBytes(current);
      _sqliteBaselineBytes = Uint8List.fromList(current);
      final wf = File(walPath);
      if (await wf.exists()) await wf.delete();
      return;
    }
    final wal = buildWal(
      pageSize: ps,
      pageOverrides: overrides,
      dbSizeAfterCommit: pages,
    );
    await File(walPath).writeAsBytes(wal);
    // Baseline stays at the on-disk main image; we do NOT update it
    // here, so subsequent incremental writes keep diffing against the
    // last full snapshot.
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Flush any pending `-wal` content into the main SQLite file and
  /// delete the WAL. After this returns the on-disk main file is the
  /// canonical image and the diff baseline is reset.
  Future<void> checkpointSqlite() async {
    if (path == null || !_persistAsSqlite) return;
    final bytes = _buildSqliteBytes(pageSize: _sqlitePageSize);
    await File(path!).writeAsBytes(bytes);
    _sqliteBaselineBytes = Uint8List.fromList(bytes);
    final wf = File('${path!}-wal');
    if (await wf.exists()) await wf.delete();
  }

  String _serializeSelect(SelectStmt s) {
    // We don't have a SQL pretty-printer — serialize the source by
    // re-roundtripping through identifiers we know about. As a pragmatic
    // shortcut we just store the original projection labels and inputs.
    // Views are reparsed on load from this representation via PRAGMA-like
    // marshaling: persist as JSON-blob-of-AST.
    return jsonEncode(_selectToJson(s));
  }

  Map<String, Object?> _selectToJson(SelectStmt s) => {
        'from': s.fromTable,
        if (s.fromAlias != null) 'fromAlias': s.fromAlias,
        'projection': s.projection.map((p) {
          if (p.isStar)
            return {
              'star': true,
              if (p.starTable != null) 'table': p.starTable
            };
          return {
            'expr': _exprLabel(p.expr!),
            if (p.alias != null) 'alias': p.alias
          };
        }).toList(),
        // Note: full AST round-tripping for views is non-trivial. For now we
        // store the original SQL by re-rendering minimal projections; this is
        // best-effort and views may be lost on reload. See README.
      };

  Future<void> _load() async {
    // Sniff the first 16 bytes: a real SQLite file starts with the
    // literal "SQLite format 3\x00" magic. If we see it, hand off to
    // importSqlite (which also picks up a `-wal` companion).
    final raw = await File(path!).readAsBytes();
    if (raw.isEmpty) return;
    if (raw.length >= 16) {
      const magic = 'SQLite format 3';
      var isSqlite = raw[15] == 0;
      for (var i = 0; isSqlite && i < magic.length; i++) {
        if (raw[i] != magic.codeUnitAt(i)) isSqlite = false;
      }
      if (isSqlite) {
        // Capture page size + baseline BEFORE calling importSqlite,
        // because importSqlite re-issues DDL/DML through executeStmt,
        // which would otherwise persist as JSON.
        if (raw.length >= 18) {
          var ps = (raw[16] << 8) | raw[17];
          if (ps == 1) ps = 65536;
          if (ps >= 512 && (ps & (ps - 1)) == 0) {
            _sqlitePageSize = ps;
          }
        }
        _sqliteBaselineBytes = Uint8List.fromList(raw);
        _persistAsSqlite = true;
        await importSqlite(path!);
        // The reissued CREATE/INSERTs above will have produced one or
        // more incremental WAL writes against our baseline. Drop any
        // stale WAL — the in-memory state already equals "baseline +
        // its original WAL", so the baseline alone is canonical.
        final wf = File('${path!}-wal');
        if (await wf.exists()) await wf.delete();
        return;
      }
    }
    final text = String.fromCharCodes(raw);
    if (text.trim().isEmpty) return;
    final data = jsonDecode(text);
    if (data is Map && data['__schema__'] == 2) {
      final tables = (data['tables'] as Map).cast<String, Object?>();
      for (final e in tables.entries) {
        final t = Table.fromJson((e.value as Map).cast<String, Object?>());
        _tables[t.name] = t;
      }
      final views = (data['views'] as Map?)?.cast<String, Object?>();
      if (views != null) {
        for (final ve in views.entries) {
          final sql = ve.value;
          if (sql is! String || sql.isEmpty) continue;
          try {
            final stmt = Parser.fromString(sql).parseStatement();
            if (stmt is SelectStmt) {
              _views[ve.key] = stmt;
              _viewSql[ve.key] = sql;
            }
          } catch (_) {
            // Best-effort: skip views we can no longer parse.
          }
        }
      }
      return;
    }
    // Legacy v1 format: bare {tableName: {columns:..., rows:...}}.
    final dataMap = (data as Map).cast<String, Object?>();
    for (final entry in dataMap.entries) {
      final tableJson = (entry.value as Map).cast<String, Object?>();
      tableJson['name'] ??= entry.key;
      final t = Table.fromJson(tableJson);
      _tables[t.name] = t;
    }
  }

  Future<void> flush() => _persist();

  // ---------------------------------------------------------------------------
  // SQLite file-format import/export
  // ---------------------------------------------------------------------------

  /// Write every local table (excluding `sqlite_*` shadow tables) to a real
  /// SQLite-format database file at [path]. The resulting file is readable
  /// by `package:sqlite3` and the official `sqlite3` CLI, including all
  /// rows and any non-expression, non-partial single-column indexes.
  ///
  /// Columns whose declared type is `BLOB` keep their bytes; everything
  /// else is stored using SQLite's natural serial types (INT / REAL / TEXT
  /// / NULL). Booleans are stored as 0/1 integers.
  Future<void> exportSqlite(String path,
      {int pageSize = 4096, bool includeIndexes = true}) async {
    final bytes =
        _buildSqliteBytes(pageSize: pageSize, includeIndexes: includeIndexes);
    await File(path).writeAsBytes(bytes);
  }

  /// Build the SQLite-format byte image for the current in-memory state.
  /// Pure: no I/O. See [exportSqlite] for the disk-writing wrapper.
  Uint8List _buildSqliteBytes(
      {int pageSize = 4096, bool includeIndexes = true}) {
    final tables = <SqliteWriteTable>[];
    final indexes = <SqliteWriteIndex>[];
    for (final entry in _tables.entries) {
      final name = entry.key;
      // Skip namespaced (attached) and shadow tables.
      if (name.contains('.')) continue;
      final t = entry.value;
      // WITHOUT ROWID tables are stored as INDEX B-trees keyed by the
      // PK record. We need on-disk column order: PK columns (in their
      // declared PK order) first, then the remaining columns in declared
      // order. Row values get permuted to match, and we sidestep all the
      // INTEGER-PRIMARY-KEY rowid-promotion logic.
      if (t.withoutRowid) {
        final pkOrder = _withoutRowidColumnOrder(t);
        if (pkOrder == null) {
          throw StateError(
              'Cannot export WITHOUT ROWID table ${t.name}: no PRIMARY KEY');
        }
        final reorderedRows = <List<Object?>>[
          for (final r in t.rows)
            [for (final ci in pkOrder) _toSqliteValue(r[ci])]
        ];
        tables.add(SqliteWriteTable(
          name: name,
          createSql: _renderCreateTable(t),
          rows: reorderedRows,
          withoutRowid: true,
        ));
        if (!includeIndexes) continue;
        // Secondary indexes on a WITHOUT ROWID table: each entry is
        // (indexed-col values..., PK-col values...). Per SQLite, PK
        // columns already present in the index key are NOT appended
        // again. The auto-created PK shadow index is the table itself,
        // so skip any IndexDef whose columns exactly match the PK.
        final pkCols = pkOrder; // already PK-first
        final pkColCount = _pkColumnCount(t);
        final pkColIdxs = pkCols.take(pkColCount).toList();
        final pkColNamesLower =
            pkColIdxs.map((i) => t.columns[i].name.toLowerCase()).toSet();
        for (final ix in t.indexDefs.values) {
          // Expression-index branch (WITHOUT ROWID): single-key entry is
          // [exprValue, ...PK columns].
          if (ix.exprSql != null) {
            final exprFn = _compileIndexExpression(ix.exprSql!);
            final partialPred = _compilePartialPredicate(ix.whereSql);
            final entries = <List<Object?>>[];
            for (final r in t.rows) {
              if (partialPred != null && !partialPred(t, r)) continue;
              entries.add([
                _toSqliteValue(exprFn(t, r)),
                for (final ci in pkColIdxs) _toSqliteValue(r[ci]),
              ]);
            }
            final whereTail =
                ix.whereSql == null ? '' : ' WHERE ${ix.whereSql}';
            indexes.add(SqliteWriteIndex(
              name: ix.name,
              tableName: name,
              createSql: 'CREATE ${ix.unique ? "UNIQUE " : ""}INDEX ${ix.name} '
                  'ON $name(${ix.exprSql})$whereTail',
              entries: entries,
            ));
            continue;
          }
          // Resolve indexed columns to row indices.
          final keyIdxs = <int>[];
          final keyNamesLower = <String>{};
          var ok = true;
          for (final cn in ix.columns) {
            final i = t.columns
                .indexWhere((c) => c.name.toLowerCase() == cn.toLowerCase());
            if (i < 0) {
              ok = false;
              break;
            }
            keyIdxs.add(i);
            keyNamesLower.add(cn.toLowerCase());
          }
          if (!ok) continue;
          // Skip the auto-PK shadow index (matches PK exactly).
          if (keyNamesLower.length == pkColNamesLower.length &&
              keyNamesLower.containsAll(pkColNamesLower)) {
            continue;
          }
          // Append PK columns NOT already in the index key.
          final trailingPkIdxs = [
            for (final pi in pkColIdxs)
              if (!keyNamesLower.contains(t.columns[pi].name.toLowerCase())) pi
          ];
          final partialPred = _compilePartialPredicate(ix.whereSql);
          final entries = <List<Object?>>[];
          for (final r in t.rows) {
            if (partialPred != null && !partialPred(t, r)) continue;
            entries.add([
              for (final ci in keyIdxs) _toSqliteValue(r[ci]),
              for (final ci in trailingPkIdxs) _toSqliteValue(r[ci]),
            ]);
          }
          final colList = _renderIndexColumnList(ix);
          final whereTail = ix.whereSql == null ? '' : ' WHERE ${ix.whereSql}';
          indexes.add(SqliteWriteIndex(
            name: ix.name,
            tableName: name,
            createSql: 'CREATE ${ix.unique ? "UNIQUE " : ""}INDEX ${ix.name} '
                'ON $name($colList)$whereTail',
            entries: entries,
          ));
        }
        continue;
      }
      // SQLite's INTEGER PRIMARY KEY is an alias for the rowid: the
      // column value MUST be stored as the rowid (and as NULL in the
      // record) or the engine reads rowid back as the id and disagrees
      // with the stored value, breaking integrity.
      final pkIdx = t.columns
          .indexWhere((c) => c.primaryKey && c.type == DataType.integer);
      List<int>? finalRowids;
      if (pkIdx >= 0 &&
          t.rows.every((r) => r[pkIdx] is int && (r[pkIdx] as int) > 0)) {
        finalRowids = [for (final r in t.rows) r[pkIdx] as int];
      }
      List<List<Object?>> exportRows;
      if (finalRowids != null) {
        exportRows = [
          for (final r in t.rows)
            [
              for (var i = 0; i < r.length; i++)
                if (i == pkIdx) null else _toSqliteValue(r[i])
            ]
        ];
      } else {
        exportRows = [
          for (final r in t.rows) [for (final v in r) _toSqliteValue(v)]
        ];
      }
      tables.add(SqliteWriteTable(
        name: name,
        createSql: _renderCreateTable(t),
        rows: exportRows,
        rowids: finalRowids,
      ));
      if (!includeIndexes) continue;
      for (final ix in t.indexDefs.values) {
        // Expression-index branch: evaluate the expression per row and
        // emit a single-key index entry per surviving row.
        if (ix.exprSql != null) {
          final exprFn = _compileIndexExpression(ix.exprSql!);
          final partialPred = _compilePartialPredicate(ix.whereSql);
          final entries = <List<Object?>>[];
          for (var r = 0; r < t.rows.length; r++) {
            final row = t.rows[r];
            if (partialPred != null && !partialPred(t, row)) continue;
            final rowid = finalRowids != null ? finalRowids[r] : r + 1;
            entries.add([_toSqliteValue(exprFn(t, row)), rowid]);
          }
          final whereTail = ix.whereSql == null ? '' : ' WHERE ${ix.whereSql}';
          indexes.add(SqliteWriteIndex(
            name: ix.name,
            tableName: name,
            createSql: 'CREATE ${ix.unique ? "UNIQUE " : ""}INDEX ${ix.name} '
                'ON $name(${ix.exprSql})$whereTail',
            entries: entries,
          ));
          continue;
        }
        // Skip the auto-created INTEGER-PRIMARY-KEY shadow index: SQLite
        // never stores one (the rowid B-tree IS the index).
        if (pkIdx >= 0 &&
            ix.columns.length == 1 &&
            ix.columns.first.toLowerCase() ==
                t.columns[pkIdx].name.toLowerCase()) {
          continue;
        }
        // Resolve every key column to its row-array index. Skip the
        // index entirely if any column is unknown.
        final colIdxs = <int>[];
        var ok = true;
        for (final cn in ix.columns) {
          final i = t.columns
              .indexWhere((c) => c.name.toLowerCase() == cn.toLowerCase());
          if (i < 0) {
            ok = false;
            break;
          }
          colIdxs.add(i);
        }
        if (!ok) continue;
        final partialPred = _compilePartialPredicate(ix.whereSql);
        final entries = <List<Object?>>[];
        for (var r = 0; r < t.rows.length; r++) {
          final row = t.rows[r];
          if (partialPred != null && !partialPred(t, row)) continue;
          final rowid = finalRowids != null ? finalRowids[r] : r + 1;
          entries.add([
            for (final ci in colIdxs) _toSqliteValue(row[ci]),
            rowid,
          ]);
        }
        final colList = _renderIndexColumnList(ix);
        final whereTail = ix.whereSql == null ? '' : ' WHERE ${ix.whereSql}';
        indexes.add(SqliteWriteIndex(
          name: ix.name,
          tableName: name,
          createSql: 'CREATE ${ix.unique ? "UNIQUE " : ""}INDEX ${ix.name} '
              'ON $name($colList)$whereTail',
          entries: entries,
        ));
      }
    }
    // Synthesize SQLite's `sqlite_sequence` table from per-table autoInc
    // counters so AUTOINCREMENT state survives the round-trip. SQLite
    // owns this table internally; the canonical CREATE TABLE statement
    // is exactly `CREATE TABLE sqlite_sequence(name,seq)`.
    final seqRows = <List<Object?>>[];
    for (final entry in _tables.entries) {
      final t = entry.value;
      // Only INTEGER PRIMARY KEY AUTOINCREMENT participates.
      final hasAutoInc = t.columns.any((c) => c.autoIncrement);
      if (!hasAutoInc) continue;
      // SQLite's seq value is the largest assigned rowid. Use the max
      // counter across any AUTOINCREMENT columns (always 1 in practice).
      var seq = 0;
      for (final c in t.columns) {
        if (c.autoIncrement) {
          final v = t.autoInc[c.name];
          if (v != null && v > seq) seq = v;
        }
      }
      if (seq > 0) seqRows.add([entry.key, seq]);
    }
    if (seqRows.isNotEmpty) {
      tables.add(SqliteWriteTable(
        name: 'sqlite_sequence',
        createSql: 'CREATE TABLE sqlite_sequence(name,seq)',
        rows: seqRows,
      ));
    }
    final bytes = writeSqliteFile(tables, pageSize: pageSize, indexes: indexes);
    return bytes;
  }

  /// Replace the contents of this database with the tables found in the
  /// SQLite file at [path]. The file's `CREATE TABLE` statements are
  /// re-executed against this engine, then rows are bulk-inserted. Indexes
  /// stored in the file are recreated by re-executing their `CREATE INDEX`
  /// statements (any indexes the local parser doesn't accept are skipped
  /// with a warning row in the returned message).
  ///
  /// Returns a human-readable summary string describing what was loaded.
  Future<String> importSqlite(String path) async {
    final bytes = await File(path).readAsBytes();
    // If the database is in WAL mode, the companion `<path>-wal` file
    // may hold newer page versions. Load and overlay it transparently.
    final walFile = File('$path-wal');
    Uint8List? walBytes;
    if (await walFile.exists()) {
      walBytes = await walFile.readAsBytes();
    }
    final f = walBytes != null
        ? SqliteFile.fromBytesWithWal(bytes, walBytes)
        : SqliteFile.fromBytes(bytes);
    _tables.clear();
    _views.clear();
    final schema = f.readSchema();
    final tableSchemas = schema.where((s) => s.type == 'table').toList();
    final indexSchemas = schema.where((s) => s.type == 'index').toList();
    var tablesLoaded = 0;
    var rowsLoaded = 0;
    var indexesLoaded = 0;
    final skipped = <String>[];
    for (final ts in tableSchemas) {
      if (ts.sql == null) continue;
      // SQLite's internal sqlite_sequence is handled below; never try to
      // re-execute its CREATE TABLE (the parser rejects sqlite_*).
      if (ts.name == 'sqlite_sequence') continue;
      // sqlite_stat1 is similarly synthesized below from raw rows.
      if (ts.name == 'sqlite_stat1') continue;
      // SQLite includes auto-created indexes for INTEGER PRIMARY KEY etc.
      // with names like `sqlite_autoindex_*`; their entries live with the
      // table B-tree, no separate root.
      try {
        await execute(ts.sql!);
      } catch (_) {
        skipped.add('table ${ts.name}');
        continue;
      }
      final t = _tables[ts.name];
      if (t == null) {
        skipped.add('table ${ts.name}');
        continue;
      }
      tablesLoaded++;
      final pkIdx = t.columns
          .indexWhere((c) => c.primaryKey && c.type == DataType.integer);
      // For WITHOUT ROWID tables, SQLite physically stores PK columns
      // first in the record, then the remaining columns in declared
      // order. Build a mapping from on-disk position back to declared
      // position so we can restore the user's column order.
      final isWor = f.isWithoutRowid(ts.name);
      List<int>? onDiskToDeclared;
      if (isWor) {
        final pkCols = <int>[];
        for (var i = 0; i < t.columns.length; i++) {
          if (t.columns[i].primaryKey) pkCols.add(i);
        }
        // Table-level PRIMARY KEY constraint, if any (preserves order).
        if (pkCols.isEmpty) {
          for (final con in t.constraints) {
            if (con is PrimaryKeyConstraint) {
              for (final n in con.columns) {
                final idx = t.columns
                    .indexWhere((c) => c.name.toLowerCase() == n.toLowerCase());
                if (idx >= 0) pkCols.add(idx);
              }
              break;
            }
          }
        }
        // On-disk order = [pkCols..., other declared columns in order].
        final pkSet = pkCols.toSet();
        final onDisk = <int>[
          ...pkCols,
          for (var i = 0; i < t.columns.length; i++)
            if (!pkSet.contains(i)) i,
        ];
        // Map: onDisk[k] = declared index. We want, for each declared
        // index d, the on-disk index k such that onDisk[k] == d.
        onDiskToDeclared = onDisk;
      }
      for (final row in f.readTable(ts.name)) {
        var src = row.values;
        if (onDiskToDeclared != null && src.length == t.columns.length) {
          final remapped = List<Object?>.filled(t.columns.length, null);
          for (var k = 0; k < src.length; k++) {
            remapped[onDiskToDeclared[k]] = src[k];
          }
          src = remapped;
        }
        // Pad/truncate to column count and store values as-is.
        final values = List<Object?>.from(src);
        while (values.length < t.columns.length) {
          values.add(null);
        }
        if (values.length > t.columns.length) {
          values.removeRange(t.columns.length, values.length);
        }
        // SQLite's INTEGER PRIMARY KEY column is stored as NULL in the
        // record (the rowid IS the value). Repair that on read.
        // (WITHOUT ROWID tables don't have this trick — values are real.)
        if (!isWor && pkIdx >= 0 && values[pkIdx] == null) {
          values[pkIdx] = row.rowid;
        }
        t.rows.add(values);
        rowsLoaded++;
      }
      _rebuildIndexes(t);
    }
    for (final ixs in indexSchemas) {
      if (ixs.sql == null) continue;
      if (ixs.name.startsWith('sqlite_autoindex_')) continue;
      try {
        await execute(ixs.sql!);
        indexesLoaded++;
      } catch (_) {
        skipped.add('index ${ixs.name}');
      }
    }
    // Restore AUTOINCREMENT counters from sqlite_sequence, if present.
    final hasSeq = tableSchemas.any((s) => s.name == 'sqlite_sequence');
    if (hasSeq) {
      try {
        for (final row in f.readTable('sqlite_sequence')) {
          final vals = row.values;
          if (vals.length < 2) continue;
          final tname = vals[0]?.toString();
          final seq = vals[1];
          if (tname == null || seq is! int) continue;
          final tt = _tables[tname];
          if (tt == null) continue;
          for (final c in tt.columns) {
            if (c.autoIncrement) tt.autoInc[c.name] = seq;
          }
        }
      } catch (_) {
        // Non-fatal: leave counters at default.
      }
    }
    // Restore ANALYZE planner stats from sqlite_stat1, if present.
    final hasStat = tableSchemas.any((s) => s.name == 'sqlite_stat1');
    if (hasStat) {
      final stat = Table(
        'sqlite_stat1',
        const [
          ColumnDef('tbl', DataType.text),
          ColumnDef('idx', DataType.text),
          ColumnDef('stat', DataType.text),
        ],
      );
      try {
        for (final row in f.readTable('sqlite_stat1')) {
          final vals = List<Object?>.from(row.values);
          while (vals.length < 3) {
            vals.add(null);
          }
          stat.rows.add(vals.sublist(0, 3));
        }
      } catch (_) {
        // Non-fatal.
      }
      _tables['sqlite_stat1'] = stat;
      // Repopulate the planner's _stats map from the loaded rows. SQLite
      // emits per-index rows where `stat` is `<rowCount> <avgRowsPerKey>`;
      // the first integer doubles as the table row count.
      final tableCounts = <String, int>{};
      for (final r in stat.rows) {
        final tname = r[0]?.toString();
        final statStr = r[2]?.toString();
        if (tname == null || statStr == null) continue;
        final n = int.tryParse(statStr.split(' ').first);
        if (n == null) continue;
        // Prefer the largest count seen across rows for this table.
        final cur = tableCounts[tname] ?? 0;
        if (n > cur) tableCounts[tname] = n;
      }
      tableCounts.forEach((tname, n) {
        if (_tables[tname] != null) {
          _stats[tname] = _TableStats(n, <String, int>{});
        }
      });
    }
    final msg = StringBuffer('Loaded $tablesLoaded table(s), '
        '$rowsLoaded row(s), $indexesLoaded index(es) from $path');
    if (skipped.isNotEmpty) {
      msg.write(' (skipped: ${skipped.join(", ")})');
    }
    return msg.toString();
  }

  String _renderCreateTable(Table t) {
    String sqlType(DataType d) {
      switch (d) {
        case DataType.integer:
          return 'INTEGER';
        case DataType.real:
          return 'REAL';
        case DataType.text:
          return 'TEXT';
        case DataType.boolean:
          return 'INTEGER';
        case DataType.blob:
          return 'BLOB';
        case DataType.numeric:
          return 'NUMERIC';
        case DataType.any:
          return '';
      }
    }

    final cols = <String>[];
    for (final c in t.columns) {
      final pieces = <String>[c.name];
      final ty = sqlType(c.type);
      if (ty.isNotEmpty) pieces.add(ty);
      if (c.primaryKey) pieces.add('PRIMARY KEY');
      if (c.autoIncrement) pieces.add('AUTOINCREMENT');
      if (c.notNull) pieces.add('NOT NULL');
      if (c.unique && !c.primaryKey) pieces.add('UNIQUE');
      cols.add(pieces.join(' '));
    }
    // Emit table-level PRIMARY KEY(a, b, ...) when no column-level PK
    // marker is present. Required for composite WITHOUT ROWID tables.
    final hasColumnPk = t.columns.any((c) => c.primaryKey);
    if (!hasColumnPk) {
      for (final con in t.constraints) {
        if (con is PrimaryKeyConstraint) {
          cols.add('PRIMARY KEY(${con.columns.join(", ")})');
          break;
        }
      }
    }
    final trailer = <String>[];
    if (t.withoutRowid) trailer.add('WITHOUT ROWID');
    if (t.strict) trailer.add('STRICT');
    final tail = trailer.isEmpty ? '' : ' ${trailer.join(", ")}';
    return 'CREATE TABLE ${t.name}(${cols.join(", ")})$tail';
  }

  /// Render an index column list with per-column COLLATE qualifiers,
  /// e.g. `name COLLATE NOCASE, age`.
  String _renderIndexColumnList(IndexDef ix) {
    final out = StringBuffer();
    for (var i = 0; i < ix.columns.length; i++) {
      if (i > 0) out.write(', ');
      out.write(ix.columns[i]);
      if (i < ix.collations.length &&
          ix.collations[i].toUpperCase() != 'BINARY') {
        out.write(' COLLATE ${ix.collations[i]}');
      }
    }
    return out.toString();
  }

  /// Compile a partial-index `WHERE` clause into a row predicate.
  /// Returns null when [whereSql] is null. The returned function takes the
  /// owning table (for column-name resolution) and a row, and returns true
  /// when the row should be included in the index.
  bool Function(Table, List<Object?>)? _compilePartialPredicate(
      String? whereSql) {
    if (whereSql == null) return null;
    final stmt =
        Parser.fromString('SELECT $whereSql').parseStatement() as SelectStmt;
    final expr = stmt.projection.first.expr!;
    final bound = _bindExpr(expr);
    return (t, row) => evalPredicate(bound, t.rowToMap(row));
  }

  /// Compile an expression-index expression into a per-row evaluator.
  /// Returns the raw evaluated value, which the exporter writes as the
  /// index key (subject to [_toSqliteValue] coercion at the call site).
  Object? Function(Table, List<Object?>) _compileIndexExpression(
      String exprSql) {
    final stmt =
        Parser.fromString('SELECT $exprSql').parseStatement() as SelectStmt;
    final expr = stmt.projection.first.expr!;
    final bound = _bindExpr(expr);
    return (t, row) => bound.eval(t.rowToMap(row));
  }

  /// Number of PK columns in [t] — column-level PK markers if any,
  /// otherwise the table-level PRIMARY KEY constraint.
  int _pkColumnCount(Table t) {
    var n = 0;
    for (final c in t.columns) {
      if (c.primaryKey) n++;
    }
    if (n > 0) return n;
    for (final con in t.constraints) {
      if (con is PrimaryKeyConstraint) return con.columns.length;
    }
    return 0;
  }

  /// Compute the on-disk column order for a WITHOUT ROWID table: PK
  /// columns first (in declared PK order), then non-PK columns in
  /// declared order. Returns null if the table has no PK.
  List<int>? _withoutRowidColumnOrder(Table t) {
    final pkIdxs = <int>[];
    // Column-level PK markers come first, in declared order.
    for (var i = 0; i < t.columns.length; i++) {
      if (t.columns[i].primaryKey) pkIdxs.add(i);
    }
    // Table-level PRIMARY KEY(a, b, ...) wins if there's no column-level
    // PK.
    if (pkIdxs.isEmpty) {
      for (final c in t.constraints) {
        if (c is PrimaryKeyConstraint) {
          for (final cn in c.columns) {
            final i = t.columns
                .indexWhere((cd) => cd.name.toLowerCase() == cn.toLowerCase());
            if (i >= 0) pkIdxs.add(i);
          }
          break;
        }
      }
    }
    if (pkIdxs.isEmpty) return null;
    final pkSet = pkIdxs.toSet();
    final order = <int>[...pkIdxs];
    for (var i = 0; i < t.columns.length; i++) {
      if (!pkSet.contains(i)) order.add(i);
    }
    return order;
  }

  Object? _toSqliteValue(Object? v) {
    if (v is bool) return v ? 1 : 0;
    return v; // null, num, String, Uint8List/List<int> all pass through.
  }

  Iterable<String> get tableNames => _tables.keys;
  Iterable<String> get viewNames => _views.keys;
  Table? table(String name) => _tables[name];

  Table _requireTable(String name) {
    final t = _tables[name];
    if (t == null) throw StateError('No such table: $name');
    return t;
  }
}

class _Pair {
  final Map<String, Object?> src;
  final List<Object?> row;
  _Pair(this.src, this.row);
}

class _Projection {
  final List<String> outCols;
  final List<Expr> exprs;
  _Projection(this.outCols, this.exprs);
}

class _AggResult {
  final List<String> columns;
  final List<List<Object?>> rows;
  final List<Map<String, Object?>> orderingMaps;
  _AggResult(this.columns, this.rows, this.orderingMaps);
}

/// A `WITH` (CTE) binding's materialized contents.
class _CteRel {
  final List<String> columns;
  final List<List<Object?>> rows;
  _CteRel(this.columns, this.rows);
}

class _TriggerSpec {
  final String name;
  final String timing; // BEFORE | AFTER
  final String event; // INSERT | UPDATE | DELETE
  final String table;
  final Expr? when;
  final List<Statement> body;
  _TriggerSpec(
      this.name, this.timing, this.event, this.table, this.when, this.body);
}

class _Savepoint {
  final String name;
  final Map<String, Table> tables;
  final Map<String, SelectStmt> views;
  _Savepoint(this.name, this.tables, this.views);
}

/// Per-table planner statistics. Populated by `ANALYZE`.
///
/// `distinctByColumn[col]` is the number of distinct (non-null) values
/// observed in column `col`. We only sample columns that have an index,
/// since they're the only ones the planner can act on today.
class _TableStats {
  int rowCount;
  final Map<String, int> distinctByColumn;
  _TableStats(this.rowCount, this.distinctByColumn);
}

/// One relation in a join chain being considered by [_reorderInnerJoins].
class _JoinSlot {
  final String tableName;
  final String? alias;
  final Expr? on;
  final int rowCount;
  Set<String> provides = const <String>{};
  _JoinSlot({
    required this.tableName,
    required this.alias,
    required this.on,
    required this.rowCount,
  });
}

/// One pending ON predicate while greedy join reordering is in progress.
class _PendingOn {
  final Expr expr;
  final Set<String> requiredKeys; // lower-cased column references
  final Set<int> requiredSlots; // slot ids that must be present
  bool satisfied = false;
  _PendingOn(this.expr, this.requiredKeys, this.requiredSlots);
}

/// A planner candidate: an index + a contiguous slice of its key space.
///
/// `equalityKeys != null` => one or more single-key probes (cheapest plan,
/// used both for `col = lit` and `col IN (lit, lit, ...)`).
/// `prefixKey != null` => prefix scan over a composite-key (multi-column)
/// index when only the leading K of N columns are equality-constrained.
/// Otherwise (`lo`, `hi`, `loInclusive`, `hiInclusive`) define an open or
/// closed range. Either bound may be null for half-open ranges.
class _IndexPlan {
  final String table;
  final String index;
  final String column;
  final List<Object>? equalityKeys;
  final List<Object?>? prefixKey;
  final Object? lo;
  final Object? hi;
  final bool loInclusive;
  final bool hiInclusive;

  /// Estimated number of rows produced by this plan.
  final int estHits;

  _IndexPlan.equality({
    required this.table,
    required this.index,
    required this.column,
    required Object equalityKey,
    required this.estHits,
  })  : equalityKeys = [equalityKey],
        prefixKey = null,
        lo = null,
        hi = null,
        loInclusive = false,
        hiInclusive = false;

  _IndexPlan.equalityList({
    required this.table,
    required this.index,
    required this.column,
    required this.equalityKeys,
    required this.estHits,
  })  : prefixKey = null,
        lo = null,
        hi = null,
        loInclusive = false,
        hiInclusive = false;

  _IndexPlan.range({
    required this.table,
    required this.index,
    required this.column,
    required this.lo,
    required this.hi,
    required this.loInclusive,
    required this.hiInclusive,
    required this.estHits,
  })  : equalityKeys = null,
        prefixKey = null;

  _IndexPlan.prefix({
    required this.table,
    required this.index,
    required this.column,
    required this.prefixKey,
    required this.estHits,
  })  : equalityKeys = null,
        lo = null,
        hi = null,
        loInclusive = false,
        hiInclusive = false;

  String describe() {
    if (prefixKey != null) {
      return 'SEARCH $table USING INDEX $index '
          '($column PREFIX ${prefixKey!.length}=?) ~$estHits';
    }
    if (equalityKeys != null) {
      if (equalityKeys!.length == 1) {
        return 'SEARCH $table USING INDEX $index ($column=?) ~$estHits';
      }
      return 'SEARCH $table USING INDEX $index '
          '($column IN ?${equalityKeys!.length}) ~$estHits';
    }
    final loS = lo == null ? '' : '${loInclusive ? ">=" : ">"} $lo';
    final hiS = hi == null ? '' : '${hiInclusive ? "<=" : "<"} $hi';
    final cond = [loS, hiS].where((s) => s.isNotEmpty).join(' AND ');
    return 'SEARCH $table USING INDEX $index ($column $cond) ~$estHits';
  }
}

/// Pending FK constraint check accumulated during a deferred-FK txn.
class _DeferredFk {
  final String childTable;
  final List<Object?> row;
  _DeferredFk(this.childTable, this.row);
}
