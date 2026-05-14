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
import 'blob.dart';
import 'expression.dart';
import 'fts5.dart';
import 'parser.dart';
import 'prepared.dart';
import 'result.dart';
import 'rtree.dart';
import 'schema.dart';
import 'session.dart';
import 'sqlite_format.dart';
import 'statement.dart';
import 'table.dart';
import 'paged_table.dart';
import 'table_backend.dart';

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

  /// Cache of parsed expressions keyed by source SQL. Used to avoid
  /// re-parsing per-row CHECK / DEFAULT / GENERATED / partial-index
  /// expressions on every row. Bounded by the schema, not by the row
  /// count, so it does not need eviction.
  final Map<String, Expr> _exprCache = <String, Expr>{};

  Expr _parseSelectExprCached(String sql) {
    final cached = _exprCache[sql];
    if (cached != null) return cached;
    final parsed =
        (Parser.fromString('SELECT $sql').parseStatement() as SelectStmt)
            .projection
            .first
            .expr!;
    _exprCache[sql] = parsed;
    return parsed;
  }

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

  /// True when journal_mode = wal2: we maintain two alternating WAL
  /// companion files (`-wal` and `-wal2`). Each commit goes to whichever
  /// is "live"; the other holds the previous commit's overrides until
  /// the next checkpoint, giving us a torn-write fallback.
  bool _persistAsWal2 = false;

  /// Monotonic counter for picking the live WAL slot in wal2 mode.
  /// Even values write to `-wal2`, odd values write to `-wal`.
  int _wal2Counter = 0;

  /// User-supplied authorizer callback. When non-null, every dispatched
  /// statement is run past this callback before executing; the callback
  /// can [AuthorizerResult.deny] (throws) or [AuthorizerResult.ignore]
  /// (statement is skipped and a message is returned).
  AuthorizerCallback? authorizer;

  /// Queue of FK checks accumulated while `PRAGMA defer_foreign_keys = 1`
  /// is in effect. Replayed at [_commit] time; failure rolls back.
  final List<_DeferredFk> _deferredFkChecks = <_DeferredFk>[];

  /// Queue of CHECK validations accumulated while `PRAGMA defer_checks = 1`
  /// is in effect. Stores only the *names* of tables that had at least one
  /// mutating operation; at commit time every row of each such table is
  /// re-validated against its CHECK constraints. This sidesteps the
  /// problem of stale intermediate row images when a row is mutated
  /// repeatedly inside a single transaction.
  final Set<String> _deferredCheckTables = <String>{};

  bool get _deferFks => _truthy(_pragmas['defer_foreign_keys']);
  bool get _deferChecks => _truthy(_pragmas['defer_checks']);

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

  /// Out-of-core paged-table registry. A `CREATE TABLE … USING paged`
  /// statement creates an entry here instead of in [_tables]; statements
  /// targeting these names are routed through the async PagedTable API
  /// in [_executePagedStmt] rather than the in-memory dispatch path.
  final Map<String, PagedTable> _pagedTables = {};

  /// Maps a paged secondary-index name back to the table it lives on,
  /// so `DROP INDEX <name>` can route to the right [PagedTable]. The
  /// index name is the user-visible name from `CREATE INDEX`.
  final Map<String, String> _pagedIndexOwners = {};

  /// Directory where each paged table's `.heap` / `.idx` / `.meta.json`
  /// sidecar files live. Derived from [path] (e.g. `mydb.json` →
  /// `mydb.paged/`). `null` for in-memory databases — those refuse
  /// `USING paged`.
  String? _pagedDir;

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

  /// Current recursive-trigger depth. Incremented when [_fireTriggers]
  /// re-enters itself (a trigger body that fires another trigger).
  /// Compared against the SQLite default cap of 1000 levels and the
  /// PRAGMA `max_trigger_depth` value to abort runaway recursion.
  int _triggerDepth = 0;

  /// Triggers attached to tables. Stored separately from [_tables] so they
  /// can persist alongside the schema.
  final Map<String, _TriggerSpec> _triggers = <String, _TriggerSpec>{};

  /// Stack of savepoints (name + table snapshot).
  final List<_Savepoint> _savepoints = <_Savepoint>[];

  /// Paged tables that have been mutated by the currently active
  /// transaction. Used by [_commit] / [_rollback] to flush or undo all
  /// of them at the transaction boundary; individual DML statements
  /// skip calling [PagedTable.commit] while [inTransaction] is true
  /// and instead register themselves here.
  final Set<PagedTable> _pagedDirty = <PagedTable>{};

  /// Drained by [executeStmt] right after [_dispatch] returns: tables
  /// in [_pendingPagedCommit] get [PagedTable.commit] awaited; tables
  /// in [_pendingPagedRollback] get [PagedTable.rollback] awaited.
  /// They exist because [_commit] / [_rollback] are sync (they're
  /// invoked from the sync trigger dispatch path) but the underlying
  /// paged-file work is async.
  final List<PagedTable> _pendingPagedCommit = <PagedTable>[];
  final List<PagedTable> _pendingPagedRollback = <PagedTable>[];

  /// ATTACH DATABASE: alias -> file path. Tables loaded from each attached
  /// database are stored in [_tables] keyed `alias.tablename`.
  final Map<String, String> _attached = <String, String>{};

  /// Per-connection counters surfaced by `last_insert_rowid()`,
  /// `changes()` and `total_changes()`. [_lastInsertRowid] is updated
  /// inside [_insert]; [_changesCount] / [_totalChangesCount] are
  /// updated in [executeStmt] right after dispatch.
  int _lastInsertRowid = 0;
  int _changesCount = 0;
  int _totalChangesCount = 0;

  /// In-memory PRAGMA state. Provides recognizable values for common
  /// PRAGMAs (read/write); unknown PRAGMAs are accepted as no-ops.
  final Map<String, Object?> _pragmas = <String, Object?>{
    'foreign_keys': 1,
    'journal_mode': 'memory',
    'user_version': 0,
    'synchronous': 'normal',
    'encoding': 'UTF-8',
    // Phase 0.2: opt-in default backend for new CREATE TABLE statements
    // on path-backed databases. Accepted values: 'memory' (default) and
    // 'paged'. When set to 'paged' and the table shape is compatible
    // (single-column PK, no STRICT / WITHOUT ROWID, _pagedDir != null),
    // bare `CREATE TABLE` routes to the paged backend just as if the
    // user had written `... USING paged`. Incompatible shapes fall
    // through to the in-memory backend silently so existing schemas
    // keep working.
    'default_table_kind': 'memory',
  };

  /// Optional per-table query-planner statistics, populated by `ANALYZE`.
  /// When a table is missing from this map the planner falls back to
  /// constant heuristics (see [_estimateEqualityHits]).
  final Map<String, _TableStats> _stats = <String, _TableStats>{};

  /// Lazy cache of corpus-aware FTS5 indexes, keyed by
  /// `'<table>:<column>'` (lower-cased). Built on first access via
  /// [fts5IndexFor] and invalidated when the underlying table is
  /// mutated.
  final Map<String, Fts5Index> _fts5IndexCache = <String, Fts5Index>{};

  /// Stack of [Database] instances currently mid-`executeStmt`. The
  /// FTS5 ranking scalar functions (`BM25_CORPUS`) consult
  /// [Database.current] to discover the active corpus.
  static final List<Database> _executionStack = <Database>[];

  /// The innermost [Database] whose `executeStmt` is currently on the
  /// call stack, or null when none is. Used by context-sensitive
  /// scalar functions.
  static Database? get current =>
      _executionStack.isEmpty ? null : _executionStack.last;

  /// Return (and lazily build) the corpus-aware FTS5 index for
  /// [tableName].[columnName]. The index is rebuilt automatically
  /// after any mutation of [tableName].
  Fts5Index fts5IndexFor(String tableName, String columnName) {
    final key = '${tableName.toLowerCase()}:${columnName.toLowerCase()}';
    final cached = _fts5IndexCache[key];
    if (cached != null) return cached;
    final t = _tables[tableName];
    if (t == null) {
      throw StateError('No such table: $tableName');
    }
    final colIdx = t.columns
        .indexWhere((c) => c.name.toLowerCase() == columnName.toLowerCase());
    if (colIdx < 0) {
      throw StateError('No such column: $tableName.$columnName');
    }
    final docs = <String>[
      for (final row in t.rows) (row[colIdx] ?? '').toString(),
    ];
    final idx = Fts5Index.build(docs);
    _fts5IndexCache[key] = idx;
    return idx;
  }

  /// Invalidate the cached FTS5 index for [tableName] (any column).
  /// Called whenever the table's row set may have changed.
  void _invalidateFts5(String tableName) {
    final prefix = '${tableName.toLowerCase()}:';
    _fts5IndexCache.removeWhere((k, _) => k.startsWith(prefix));
  }

  /// Names (lowercased) of tables created via `CREATE VIRTUAL TABLE ... USING rtree`
  /// in the current session. Used to enable bbox-aware planning. Reloaded
  /// tables don't gain this set bit, so range queries on them fall back to
  /// scans — still correct.
  final Set<String> _rtreeTables = <String>{};

  /// Lazy cache of in-memory [RTreeIndex]es keyed by lower-cased table
  /// name. Built on first planner access and dropped on any mutation of
  /// the underlying table.
  final Map<String, RTreeIndex> _rtreeIndexCache = <String, RTreeIndex>{};

  /// Build (or return cached) [RTreeIndex] for [t], which must be an
  /// rtree virtual table (column 0 is the rowid; remaining columns come
  /// in min/max pairs per axis).
  RTreeIndex _rtreeIndexFor(Table t) {
    final key = t.name.toLowerCase();
    final cached = _rtreeIndexCache[key];
    if (cached != null) return cached;
    final dims = (t.columns.length - 1) ~/ 2;
    final items = <MapEntry<int, BBox>>[];
    for (var ri = 0; ri < t.rows.length; ri++) {
      final row = t.rows[ri];
      final rowid = (row[0] as num).toInt();
      final mins = <double>[];
      final maxs = <double>[];
      for (var d = 0; d < dims; d++) {
        final a = (row[1 + d * 2] as num).toDouble();
        final b = (row[2 + d * 2] as num).toDouble();
        mins.add(math.min(a, b));
        maxs.add(math.max(a, b));
      }
      items.add(MapEntry(rowid, BBox.fromMinMax(mins, maxs)));
    }
    final idx = RTreeIndex.bulkLoad(dims, items);
    _rtreeIndexCache[key] = idx;
    return idx;
  }

  void _invalidateRtree(String tableName) {
    _rtreeIndexCache.remove(tableName.toLowerCase());
  }

  /// Cached, parsed partial-index `WHERE` predicate AST per index name.
  /// Built lazily on first planner access and cleared when a partial
  /// index is created or dropped.
  final Map<String, Expr> _partialIndexAstCache = <String, Expr>{};

  /// Drop and rebuild every partial / expression index attached to
  /// [t] so that its entries reflect the current row set. Called from
  /// the `executeStmt` mutation hook and from [_createIndex] when the
  /// new index is partial or expression-based.
  void _refreshPartialIndexes(Table t) {
    for (final def in t.indexDefs.values) {
      if (def.whereSql == null && def.exprSql == null) continue;
      final pred =
          def.whereSql == null ? null : _compilePartialPredicate(def.whereSql);
      final exprFn =
          def.exprSql == null ? null : _compileIndexExpression(def.exprSql!);
      final tree = t.indexes[def.name];
      if (tree == null) continue;
      tree.clear();
      for (var i = 0; i < t.rows.length; i++) {
        final row = t.rows[i];
        if (pred != null && !pred(t, row)) continue;
        Object? key;
        if (exprFn != null) {
          final v = exprFn(t, row);
          if (v == null) continue;
          key = v;
        } else {
          key = t.buildIndexKey(def, row);
          if (key == null) continue;
        }
        final list = tree.putIfAbsent(key, () => <int>[]);
        if (def.unique && list.isNotEmpty) {
          throw StateError(
              'UNIQUE index ${def.name} violation while refreshing '
              'partial index: $key');
        }
        list.add(i);
      }
    }
  }

  /// Conjuncts of the WHERE clause currently being planned. Set at the
  /// top of [_planScan] and consulted by [_partialIndexUsable] to decide
  /// whether a partial index's predicate is implied by the query.
  List<Expr> _currentScanConjuncts = const [];

  /// Returns true when [def] is non-partial OR when the query currently
  /// being planned has a conjunct that structurally matches the index's
  /// `WHERE` predicate (i.e. the query is provably narrower than the
  /// partial index's filter). When false, the planner must skip the
  /// index — using it would miss rows.
  bool _partialIndexUsable(IndexDef def) {
    if (def.whereSql == null) return true;
    final ast = _partialIndexAstCache.putIfAbsent(def.name, () {
      final stmt = Parser.fromString('SELECT ${def.whereSql}').parseStatement()
          as SelectStmt;
      return stmt.projection.first.expr!;
    });
    for (final c in _currentScanConjuncts) {
      if (_exprStructEq(c, ast)) return true;
    }
    return false;
  }

  /// Structural equality on the subset of Expr shapes that commonly
  /// appear in partial-index predicates: column refs, literals,
  /// `IS NULL` / `IS NOT NULL`, comparisons against literals, and
  /// AND/OR combinations of the above. Returns false for any AST it
  /// doesn't recognise (safe: the planner just falls back to a scan).
  bool _exprStructEq(Expr a, Expr b) {
    if (identical(a, b)) return true;
    if (a is LiteralExpr && b is LiteralExpr) return a.value == b.value;
    if (a is ColumnExpr && b is ColumnExpr) {
      return a.name.toLowerCase() == b.name.toLowerCase() &&
          (a.table?.toLowerCase() ?? '') == (b.table?.toLowerCase() ?? '');
    }
    if (a is UnaryExpr && b is UnaryExpr) {
      return a.op == b.op && _exprStructEq(a.operand, b.operand);
    }
    if (a is BinaryExpr && b is BinaryExpr) {
      if (a.op != b.op) return false;
      if (_exprStructEq(a.left, b.left) && _exprStructEq(a.right, b.right)) {
        return true;
      }
      const commutative = {'=', '!=', '<>', 'AND', 'OR', '+', '*'};
      if (commutative.contains(a.op)) {
        return _exprStructEq(a.left, b.right) && _exprStructEq(a.right, b.left);
      }
      return false;
    }
    if (a is FunctionCallExpr && b is FunctionCallExpr) {
      if (a.name.toUpperCase() != b.name.toUpperCase()) return false;
      if (a.args.length != b.args.length) return false;
      for (var i = 0; i < a.args.length; i++) {
        if (!_exprStructEq(a.args[i], b.args[i])) return false;
      }
      return true;
    }
    return false;
  }

  /// Last plan chosen by the executor for the most recent SELECT. Exposed
  /// to tests via [lastPlanTrace] so we can assert "this query used the
  /// expected index" without parsing EXPLAIN output.
  List<String> _planTrace = const [];
  List<String> get lastPlanTrace => List.unmodifiable(_planTrace);

  /// Last per-CTE materialization decision the dispatcher saw. Entries
  /// are `name` -> `true` for `MATERIALIZED`, `false` for
  /// `NOT MATERIALIZED`, or absent when no hint was given (default).
  /// Exposed for test introspection.
  Map<String, bool> _lastCteHints = const {};
  Map<String, bool> get lastCteHints => Map.unmodifiable(_lastCteHints);

  /// Cumulative count of index-only (covering) scans the executor has
  /// served. Reset by [resetCounters]. Tests use this to assert that a
  /// query took the covering path.
  int coveringScansUsed = 0;

  /// Reset perf counters (currently just [coveringScansUsed]).
  void resetCounters() {
    coveringScansUsed = 0;
  }

  Database({this.path}) {
    // Install the corpus-lookup hook for FTS5 ranking functions. The
    // hook routes through [Database.current] so all live databases
    // share a single installation.
    fts5CorpusLookup ??= (table, column) {
      final db = Database.current;
      if (db == null) return null;
      try {
        return db.fts5IndexFor(table, column);
      } catch (_) {
        return null;
      }
    };
  }

  static Future<Database> open([String? path]) async {
    final db = Database(path: path);
    if (path != null) {
      // Acquire the cross-process file lock before touching the file.
      db._fileLock = DbFileLock(path);
      await db._fileLock!.acquire();
      // Reap any half-written temp files left behind by a crashed
      // writer (sibling `<path>.tmp` / `<path>-wal.tmp`).
      await db._reapStaleTempFiles();
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
      // Compute paged-table directory: strip a single known extension.
      db._pagedDir = _derivePagedDir(path);
      await db._restorePagedTables();
    }
    return db;
  }

  /// Derive the sibling directory that hosts every `USING paged` table's
  /// `.heap` / `.idx` / `.meta.json` files. `mydb.json` →
  /// `mydb.paged/`; `mydb.sqlite` → `mydb.paged/`; bare `mydb` →
  /// `mydb.paged/`.
  static String _derivePagedDir(String path) {
    final lower = path.toLowerCase();
    for (final ext in const [
      '.json',
      '.sqlite3',
      '.sqlite',
      '.db',
    ]) {
      if (lower.endsWith(ext)) {
        return '${path.substring(0, path.length - ext.length)}.paged';
      }
    }
    return '$path.paged';
  }

  /// Re-open every paged table found under [_pagedDir]. Called once at
  /// [open] time. Missing dir is fine (no paged tables yet).
  Future<void> _restorePagedTables() async {
    final dir = _pagedDir;
    if (dir == null) return;
    final d = Directory(dir);
    if (!await d.exists()) return;
    await for (final ent in d.list(followLinks: false)) {
      if (ent is! File) continue;
      final name = ent.uri.pathSegments.last;
      if (!name.endsWith('.meta.json')) continue;
      final tableName = name.substring(0, name.length - '.meta.json'.length);
      final base = '$dir/$tableName';
      try {
        final ps = _pragmaPageSize();
        final cc = _pragmaCacheCapacity(ps);
        final pt = await PagedTable.open(base, pageSize: ps, cacheCapacity: cc);
        pt.tableName = tableName;
        _pagedTables[tableName] = pt;
        // Re-register every secondary index this table owns so
        // `DROP INDEX <name>` can route to the right paged table.
        for (final idxName in pt.secondaryIndexNames) {
          _pagedIndexOwners[idxName] = tableName;
        }
      } catch (e) {
        // Don't take the whole DB down for one corrupt sidecar — but do
        // surface it so the operator notices.
        stderr.writeln('paged table $tableName at $base failed to open: $e');
      }
    }
  }

  /// Release the cross-process file lock. Idempotent. Always call this
  /// when you're done with a path-backed database — otherwise the
  /// `<path>.lock` sidecar will keep readers/writers blocked until the
  /// process exits.
  Future<void> close() async {
    // Flush + close every paged table first; their journals must be
    // gone before we drop the file lock so a subsequent open sees a
    // clean state.
    for (final pt in _pagedTables.values) {
      try {
        await pt.commit();
      } catch (_) {}
      try {
        await pt.close();
      } catch (_) {}
    }
    _pagedTables.clear();
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
      _executionStack.add(this);
      final prevConnState = connStateLookup;
      connStateLookup = (which) {
        switch (which) {
          case 'last_insert_rowid':
            return _lastInsertRowid;
          case 'changes':
            return _changesCount;
          case 'total_changes':
            return _totalChangesCount;
          default:
            return 0;
        }
      };
      QueryResult result;
      try {
        // Paged-table fast path: a `CREATE TABLE … USING paged` lives
        // in [_pagedTables] rather than [_tables], and statements that
        // target one of those names use the async PagedTable API. Both
        // need to run before the synchronous [_dispatch] so they can
        // await disk I/O.
        final paged = await _maybeRunPagedStmt(stmt);
        if (paged != null) {
          result = paged;
        } else {
          result = _dispatch(stmt);
        }
      } finally {
        _executionStack.removeLast();
        connStateLookup = prevConnState;
        // Drain any paged commit/rollback queued by a sync _commit /
        // _rollback. Rollbacks always run before commits — and run
        // unconditionally, including on the exception path — so a
        // deferred-FK-failed COMMIT (which calls _rollback internally
        // and rethrows) still undoes the paged side.
        if (_pendingPagedRollback.isNotEmpty) {
          final pending = List<PagedTable>.from(_pendingPagedRollback);
          _pendingPagedRollback.clear();
          for (final pt in pending) {
            try {
              await pt.rollback();
            } catch (_) {/* best-effort */}
          }
        }
        if (_pendingPagedCommit.isNotEmpty) {
          final pending = List<PagedTable>.from(_pendingPagedCommit);
          _pendingPagedCommit.clear();
          for (final pt in pending) {
            await pt.commit();
          }
        }
      }
      if (_isMutation(stmt)) {
        // Track changes()/total_changes() at the SQL function layer.
        if (stmt is InsertStmt || stmt is UpdateStmt || stmt is DeleteStmt) {
          _changesCount = result.affected;
          _totalChangesCount += result.affected;
        }
        // Conservatively drop FTS5 caches for the statement's target
        // table; the next ranking call will rebuild on demand.
        final tname = _statementTable(stmt);
        if (tname != null) {
          _invalidateFts5(tname);
          _invalidateRtree(tname);
          final t = _tables[tname];
          if (t != null) _refreshPartialIndexes(t);
        }
      }
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
    // Reset per-statement observability state.
    _lastCteHints = const {};
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
    } else if (stmt is ReindexStmt) {
      result = _reindex(stmt);
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
      s is ReindexStmt ||
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
  // Paged-table dispatch (out-of-core `USING paged` backend)
  // ---------------------------------------------------------------------------

  /// Disallow DDL on paged tables inside a transaction. Paged DDL
  /// touches multiple files (heap, indexes, sidecar metadata, plus
  /// directory entries on CREATE/DROP/TRUNCATE) and isn't covered by
  /// the per-file undo journal, so we can't roll it back atomically.
  void _assertNoPagedDdlInTx(String action) {
    if (inTransaction) {
      throw UnsupportedError(
          '$action is not supported inside an active transaction. '
          'COMMIT or ROLLBACK first.');
    }
  }

  /// Disallow paged DML while a SAVEPOINT is open. Paged-table writes
  /// inside a savepoint can't be selectively rolled back by
  /// `ROLLBACK TO`; that would silently leave the on-disk paged side
  /// ahead of the in-memory snapshot, so we refuse the write up-front.
  void _assertPagedWriteAllowed(String action) {
    if (_savepoints.isNotEmpty) {
      throw UnsupportedError(
          '$action is not supported while a SAVEPOINT is open. '
          'RELEASE the savepoint first.');
    }
  }

  /// If [stmt] is either a `CREATE TABLE … USING paged` or a DML/SELECT
  /// targeting a registered paged table, execute it via the async
  /// PagedTable API and return the result. Returns null when the
  /// caller should fall through to the regular synchronous dispatch.
  Future<QueryResult?> _maybeRunPagedStmt(Statement stmt) async {
    if (stmt is CreateTableStmt && (stmt.usingPaged || _shouldAutoPage(stmt))) {
      _assertNoPagedDdlInTx('CREATE TABLE … USING paged');
      return _createPagedTable(stmt);
    }
    // CREATE INDEX may target a paged table; we look up by table name.
    if (stmt is CreateIndexStmt) {
      final pt = _pagedTable(stmt.table);
      if (pt != null) {
        _assertNoPagedDdlInTx('CREATE INDEX on paged table ${stmt.table}');
        return _pagedCreateIndex(stmt, pt);
      }
      return null;
    }
    // DROP INDEX routes through the registered-owner map.
    if (stmt is DropIndexStmt) {
      final ownerTable = _pagedIndexOwners[stmt.indexName];
      if (ownerTable != null) {
        final pt = _pagedTable(ownerTable);
        if (pt != null) {
          _assertNoPagedDdlInTx('DROP INDEX on paged table $ownerTable');
          return _pagedDropIndex(stmt, pt);
        }
      }
      return null;
    }
    final tname = _statementTable(stmt);
    if (tname == null) return null;
    final pt = _pagedTable(tname);
    if (pt == null) {
      // The FROM table is in-memory — but a SELECT can still join
      // *to* a paged table. Detect that and run the join through
      // the in-memory executor with snapshot-materialised paged
      // participants.
      if (stmt is SelectStmt && stmt.joins.isNotEmpty) {
        final pagedJoined = <String>[
          for (final j in stmt.joins)
            if (j.table != null && _isPaged(j.table)) j.table!,
        ];
        if (pagedJoined.isNotEmpty) {
          return _pagedJoinSelect(stmt, [tname, ...pagedJoined]);
        }
      }
      return null;
    }
    if (stmt is InsertStmt) {
      _assertPagedWriteAllowed('INSERT into paged table $tname');
      return _pagedInsert(stmt, pt);
    }
    if (stmt is SelectStmt) {
      // Paged FROM with joins: needs the materialise-then-join path.
      if (stmt.joins.isNotEmpty) {
        final referenced = <String>{
          tname,
          for (final j in stmt.joins)
            if (j.table != null) j.table!,
        };
        return _pagedJoinSelect(stmt, referenced.toList());
      }
      return _pagedSelect(stmt, pt);
    }
    if (stmt is UpdateStmt) {
      _assertPagedWriteAllowed('UPDATE on paged table $tname');
      return _pagedUpdate(stmt, pt);
    }
    if (stmt is DeleteStmt) {
      _assertPagedWriteAllowed('DELETE on paged table $tname');
      return _pagedDelete(stmt, pt);
    }
    if (stmt is DropTableStmt) {
      _assertNoPagedDdlInTx('DROP TABLE on paged table $tname');
      return _pagedDrop(stmt, pt);
    }
    if (stmt is TruncateTableStmt) {
      _assertNoPagedDdlInTx('TRUNCATE on paged table $tname');
      return _pagedTruncate(stmt, pt);
    }
    if (stmt is DescribeStmt) {
      // Cheap: synthesize a Table row-set off the paged columns.
      return QueryResult(columns: const [
        'name',
        'type',
      ], rows: [
        for (final c in pt.columns) [c.name, c.type.name],
      ]);
    }
    throw UnsupportedError(
        'Statement ${stmt.runtimeType} not supported on USING paged table '
        '"$tname". Paged tables currently support: INSERT, SELECT (full '
        'scan or WHERE pk = literal), UPDATE/DELETE WHERE pk = literal, '
        'DROP TABLE, TRUNCATE TABLE, DESCRIBE.');
  }

  Future<QueryResult> _pagedCreateIndex(
      CreateIndexStmt s, PagedTable pt) async {
    if (s.exprSql != null) {
      throw UnsupportedError(
          'CREATE INDEX on paged table ${s.table}: expression indexes '
          'are not supported.');
    }
    if (s.whereSql != null) {
      throw UnsupportedError(
          'CREATE INDEX on paged table ${s.table}: partial indexes are '
          'not supported.');
    }
    if (_pagedIndexOwners.containsKey(s.indexName)) {
      throw StateError('Index ${s.indexName} already exists on paged table '
          '${_pagedIndexOwners[s.indexName]}');
    }
    await pt.createIndex(s.indexName, s.columns, unique: s.unique);
    _pagedIndexOwners[s.indexName] = s.table;
    return QueryResult.message('index ${s.indexName} '
        '${s.unique ? "(unique) " : ""}'
        'created on ${s.table}(${s.columns.join(', ')})');
  }

  Future<QueryResult> _pagedDropIndex(DropIndexStmt s, PagedTable pt) async {
    final dropped = await pt.dropIndex(s.indexName);
    if (dropped) _pagedIndexOwners.remove(s.indexName);
    return QueryResult.message(
        dropped ? 'index ${s.indexName} dropped' : 'no such index');
  }

  /// Map a SQL [DataType] to the PagedTable column-type enum.
  PagedColumnType _toPagedType(DataType t) {
    switch (t) {
      case DataType.integer:
        return PagedColumnType.intType;
      case DataType.real:
      case DataType.numeric:
        return PagedColumnType.realType;
      case DataType.boolean:
        return PagedColumnType.boolType;
      case DataType.blob:
        return PagedColumnType.blobType;
      case DataType.text:
      case DataType.any:
        return PagedColumnType.textType;
    }
  }

  /// Inverse of [_toPagedType] — used when snapshotting a paged table
  /// into a transient in-memory [Table] for join queries.
  DataType _fromPagedType(PagedColumnType t) {
    switch (t) {
      case PagedColumnType.intType:
        return DataType.integer;
      case PagedColumnType.realType:
        return DataType.real;
      case PagedColumnType.boolType:
        return DataType.boolean;
      case PagedColumnType.blobType:
        return DataType.blob;
      case PagedColumnType.textType:
        return DataType.text;
    }
  }

  /// Handle a SELECT that joins one or more paged tables.
  ///
  /// Optimisation: when there is exactly one paged participant and the
  /// query carries an equi-join predicate `paged.col = mem.col` (in an
  /// ON or WHERE clause) against an in-memory table, we only snapshot
  /// the paged rows whose `col` value appears in the in-memory side's
  /// distinct value set. If the paged table has an index (PK or
  /// secondary) on that column, the matched rows are pulled by
  /// `get` / `indexLookup` per key; otherwise we scan and filter. The
  /// matched rows are installed as a transient in-memory `Table` and
  /// the query is then dispatched to the regular in-memory executor,
  /// which still handles ORDER BY / GROUP BY / projection.
  ///
  /// We bail out and snapshot the paged side in full when:
  ///   - more than one paged participant is referenced (would require
  ///     bootstrapping one side from the other);
  ///   - any LEFT / RIGHT / FULL join is involved (preserving-side
  ///     rows can't be safely dropped);
  ///   - no usable equi-join column reference for the paged side is
  ///     found.
  /// Falling back preserves correctness in every case.
  Future<QueryResult> _pagedJoinSelect(
      SelectStmt s, List<String> pagedNames) async {
    final installed = <String>[];
    try {
      // Decide pre-filter eligibility for each paged participant.
      final filters = _pagedJoinFilters(s, pagedNames);
      for (final name in pagedNames) {
        if (!_isPaged(name)) continue;
        if (_tables.containsKey(name)) {
          throw StateError(
              'paged join: name collision with in-memory table $name '
              '(should not happen — names are unique across maps)');
        }
        final pt = _pagedTable(name)!;
        final colDefs = <ColumnDef>[
          for (var i = 0; i < pt.columns.length; i++)
            ColumnDef(
              pt.columns[i].name,
              _fromPagedType(pt.columns[i].type),
              primaryKey: i == pt.primaryKeyIndex,
            ),
        ];
        final tbl = Table(name, colDefs);
        final filter = filters[name];
        if (filter != null) {
          await _populateFilteredPagedSnapshot(pt, filter, tbl);
        } else {
          await for (final row in pt.scan()) {
            tbl.rows.add([for (final c in pt.columns) row[c.name]]);
          }
        }
        _tables[name] = tbl;
        installed.add(name);
      }
      // Now defer to the regular in-memory executor.
      return _selectTopLevel(s);
    } finally {
      for (final name in installed) {
        _tables.remove(name);
      }
    }
  }

  /// For each paged participant whose snapshot can be safely
  /// restricted by an equi-join key set, return a record describing
  /// the paged column to filter on and the set of keys observed on
  /// the in-memory side. Returns an empty map if no participant is
  /// eligible — callers fall back to the full-scan path.
  Map<String, ({String pagedCol, Set<Object> keys})> _pagedJoinFilters(
      SelectStmt s, List<String> pagedNames) {
    final result = <String, ({String pagedCol, Set<Object> keys})>{};
    // Only safe when no preserving-side semantics are involved.
    for (final j in s.joins) {
      final t = j.type.toUpperCase();
      if (t != 'INNER' && t != 'CROSS') return result;
    }
    if (pagedNames.length != 1) return result;
    final pname = pagedNames.single;
    final pt = _pagedTable(pname);
    if (pt == null) return result;
    final pagedCols = {for (final c in pt.columns) c.name.toLowerCase()};

    // Collect every AND-conjunct from every join's ON clause and from
    // the top-level WHERE.
    final conjuncts = <Expr>[];
    void splitAnd(Expr? e) {
      if (e == null) return;
      if (e is BinaryExpr && e.op.toUpperCase() == 'AND') {
        splitAnd(e.left);
        splitAnd(e.right);
      } else {
        conjuncts.add(e);
      }
    }

    for (final j in s.joins) {
      splitAnd(j.on);
    }
    splitAnd(s.where);

    // Find the first `paged.col = mem.col` conjunct.
    for (final c in conjuncts) {
      if (c is! BinaryExpr || c.op != '=') continue;
      final l = c.left;
      final r = c.right;
      if (l is! ColumnExpr || r is! ColumnExpr) continue;
      final lt = l.table?.toLowerCase();
      final rt = r.table?.toLowerCase();
      if (lt == null || rt == null) continue;
      String? memName;
      String? memCol;
      String? pgCol;
      if (lt == pname.toLowerCase() &&
          pagedCols.contains(l.name.toLowerCase())) {
        memName = r.table;
        memCol = r.name;
        pgCol = l.name;
      } else if (rt == pname.toLowerCase() &&
          pagedCols.contains(r.name.toLowerCase())) {
        memName = l.table;
        memCol = l.name;
        pgCol = r.name;
      } else {
        continue;
      }
      if (memName == null) continue;
      final mem = _tables[memName];
      if (mem == null) continue; // not in-memory, or unknown
      final colIdx = mem.columns
          .indexWhere((cd) => cd.name.toLowerCase() == memCol!.toLowerCase());
      if (colIdx < 0) continue;
      final keys = <Object>{};
      for (final row in mem.rows) {
        final v = row[colIdx];
        if (v != null) keys.add(v);
      }
      result[pname] = (pagedCol: pgCol, keys: keys);
      return result;
    }
    return result;
  }

  /// Snapshot only the rows of [pt] whose `filter.pagedCol` value is
  /// in `filter.keys`. Uses the cheapest available access path:
  /// primary-key point lookup, secondary-index lookup, or a filtered
  /// full scan.
  Future<void> _populateFilteredPagedSnapshot(
    PagedTable pt,
    ({String pagedCol, Set<Object> keys}) filter,
    Table tbl,
  ) async {
    if (filter.keys.isEmpty) return;
    final pkName = pt.primaryKey.name.toLowerCase();
    final colLower = filter.pagedCol.toLowerCase();
    // Primary-key fast path.
    if (colLower == pkName) {
      for (final k in filter.keys) {
        final row = await pt.get(k);
        if (row == null) continue;
        tbl.rows.add([for (final c in pt.columns) row[c.name]]);
      }
      return;
    }
    // Secondary-index fast path: look for a single-column index on
    // this column.
    String? matchIdx;
    for (final idxName in pt.secondaryIndexNames) {
      final cols = pt.indexColumns(idxName);
      if (cols != null &&
          cols.length == 1 &&
          cols.single.toLowerCase() == colLower) {
        matchIdx = idxName;
        break;
      }
    }
    if (matchIdx != null) {
      for (final k in filter.keys) {
        await for (final row in pt.indexLookup(matchIdx, [k])) {
          tbl.rows.add([for (final c in pt.columns) row[c.name]]);
        }
      }
      return;
    }
    // Fallback: streaming scan with residual filter.
    await for (final row in pt.scan()) {
      final v = row[filter.pagedCol];
      if (v != null && filter.keys.contains(v)) {
        tbl.rows.add([for (final c in pt.columns) row[c.name]]);
      }
    }
  }

  Future<QueryResult> _createPagedTable(CreateTableStmt s) async {
    if (_pagedDir == null) {
      throw StateError(
          'CREATE TABLE ${s.name} USING paged: requires a path-backed '
          'database (in-memory databases cannot host paged tables).');
    }
    if (_tables.containsKey(s.name) ||
        _views.containsKey(s.name) ||
        _isPaged(s.name)) {
      if (s.ifNotExists) return QueryResult.message('table exists');
      throw StateError('Object ${s.name} already exists');
    }
    // Resolve PRIMARY KEY: column-level flag, or a single-column
    // table-level PRIMARY KEY constraint. Composite PKs aren't yet
    // supported by PagedTable.
    String? pkName;
    for (final c in s.columns) {
      if (c.primaryKey) {
        if (pkName != null) {
          throw StateError(
              'CREATE TABLE ${s.name} USING paged: composite primary '
              'keys are not supported (already had $pkName).');
        }
        pkName = c.name;
      }
    }
    for (final tc in s.constraints) {
      if (tc is PrimaryKeyConstraint) {
        if (tc.columns.length != 1) {
          throw StateError(
              'CREATE TABLE ${s.name} USING paged: composite primary '
              'keys are not supported.');
        }
        if (pkName != null && pkName != tc.columns.single) {
          throw StateError(
              'CREATE TABLE ${s.name} USING paged: conflicting primary '
              'keys ($pkName vs ${tc.columns.single}).');
        }
        pkName = tc.columns.single;
      }
    }
    if (pkName == null) {
      throw StateError(
          'CREATE TABLE ${s.name} USING paged: a single-column PRIMARY '
          'KEY is required.');
    }
    final cols = [
      for (final c in s.columns) PagedColumn(c.name, _toPagedType(c.type)),
    ];
    final dir = Directory(_pagedDir!);
    if (!await dir.exists()) await dir.create(recursive: true);
    final ps = _pragmaPageSize();
    final cc = _pragmaCacheCapacity(ps);
    final pt = await PagedTable.create(
      '${_pagedDir!}/${s.name}',
      columns: cols,
      primaryKey: pkName,
      pageSize: ps,
      cacheCapacity: cc,
    );
    pt.tableName = s.name;
    _pagedTables[s.name] = pt;
    return QueryResult.message('paged table ${s.name} created');
  }

  Future<QueryResult> _pagedDrop(DropTableStmt s, PagedTable pt) async {
    final secNames = List<String>.from(pt.secondaryIndexNames);
    await pt.commit();
    await pt.close();
    _pagedTables.remove(s.name);
    for (final n in secNames) {
      _pagedIndexOwners.remove(n);
    }
    final base = '${_pagedDir!}/${s.name}';
    final extras = <String>[
      '.heap',
      '.heap.journal',
      '.idx',
      '.idx.journal',
      '.meta.json',
      '.meta.json.tmp',
      for (final n in secNames) ...['.idx_$n', '.idx_$n.journal'],
    ];
    for (final ext in extras) {
      final f = File('$base$ext');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    return QueryResult.message('paged table ${s.name} dropped');
  }

  Future<QueryResult> _pagedTruncate(TruncateTableStmt s, PagedTable pt) async {
    // No bulk-truncate primitive yet — drop and re-create with the same
    // schema. Callers see this as a single statement; if the process
    // crashes between the two halves the meta.json deletion is the
    // commit point so a retry works. Secondary indexes are NOT carried
    // across truncate — equivalent to DROP+CREATE.
    final cols = pt.columns;
    final pkName = cols[pt.primaryKeyIndex].name;
    final secNames = List<String>.from(pt.secondaryIndexNames);
    await pt.commit();
    await pt.close();
    _pagedTables.remove(s.name);
    for (final n in secNames) {
      _pagedIndexOwners.remove(n);
    }
    final base = '${_pagedDir!}/${s.name}';
    final extras = <String>[
      '.heap',
      '.heap.journal',
      '.idx',
      '.idx.journal',
      '.meta.json',
      '.meta.json.tmp',
      for (final n in secNames) ...['.idx_$n', '.idx_$n.journal'],
    ];
    for (final ext in extras) {
      final f = File('$base$ext');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    final ps = _pragmaPageSize();
    final cc = _pragmaCacheCapacity(ps);
    final fresh = await PagedTable.create(base,
        columns: cols, primaryKey: pkName, pageSize: ps, cacheCapacity: cc);
    fresh.tableName = s.name;
    _pagedTables[s.name] = fresh;
    return QueryResult.message('paged table ${s.name} truncated');
  }

  /// Reduce an expression to a Dart literal, refusing column references
  /// or anything that needs row context. Bind parameters were already
  /// substituted by [PreparedStatement].
  Object? _evalLiteral(Expr e, String context) {
    try {
      return e.eval(const <String, Object?>{});
    } catch (_) {
      throw UnsupportedError(
          '$context: only literal values are supported on paged tables.');
    }
  }

  /// Parsed shape of a paged-table WHERE clause. Either [eq] is set
  /// (point lookup) or the lower/upper bounds describe a contiguous
  /// PK-ordered range. Any field may be null. A `null` everywhere
  /// means no predicate (full scan).
  ///
  /// Bounds are tightened by intersecting all AND-connected
  /// comparisons against the PK column. We do not attempt to prove
  /// emptiness — if `lower > upper` the caller will simply see an
  /// empty stream from PagedTable.range.
  ///
  /// Any AND-conjuncts that don't simplify to a PK-range fragment are
  /// preserved verbatim in [_PagedRange.residual] and applied as a
  /// post-filter (`Expr.eval`) on each row the scan produces. So a
  /// query like `WHERE id BETWEEN 10 AND 20 AND name = 'x'` does the
  /// efficient index range on the PK *and* the cheap column filter on
  /// the residual half. OR-trees and BETWEEN on a non-PK column fall
  /// entirely into the residual.
  _PagedRange _pagedExtractPkRange(Expr? where, String pkName, String context) {
    final r = _PagedRange();
    if (where == null) return r;
    final residuals = <Expr>[];
    void merge(_PagedRange other) {
      if (other.eq != null) {
        if (r.eq != null && r.eq != other.eq) {
          r.eq = other.eq;
          r.contradiction = true;
        } else {
          r.eq = other.eq;
        }
      }
      if (other.lower != null) {
        if (r.lower == null || _compareLiteral(other.lower, r.lower!) > 0) {
          r.lower = other.lower;
          r.lowerInclusive = other.lowerInclusive;
        } else if (_compareLiteral(other.lower, r.lower!) == 0 &&
            !other.lowerInclusive) {
          r.lowerInclusive = false;
        }
      }
      if (other.upper != null) {
        if (r.upper == null || _compareLiteral(other.upper, r.upper!) < 0) {
          r.upper = other.upper;
          r.upperInclusive = other.upperInclusive;
        } else if (_compareLiteral(other.upper, r.upper!) == 0 &&
            !other.upperInclusive) {
          r.upperInclusive = false;
        }
      }
    }

    void walk(Expr e) {
      if (e is BinaryExpr && e.op == 'AND') {
        walk(e.left);
        walk(e.right);
        return;
      }
      final piece = _extractSingle(e, pkName);
      if (piece == null) {
        residuals.add(e);
      } else {
        merge(piece);
      }
    }

    walk(where);
    if (residuals.isNotEmpty) {
      Expr combined = residuals.first;
      for (var i = 1; i < residuals.length; i++) {
        combined = BinaryExpr('AND', combined, residuals[i]);
      }
      r.residual = combined;
    }
    return r;
  }

  /// Parse a single AND-conjunct. Returns a [_PagedRange] fragment if
  /// it can be turned into a PK comparison; returns null when the
  /// conjunct doesn't reference the PK at all (or references it in a
  /// shape we don't index-prune on, e.g. function calls). The caller
  /// keeps the original expression as a residual post-filter.
  _PagedRange? _extractSingle(Expr e, String pkName) {
    final r = _PagedRange();
    bool isPk(Expr x) =>
        x is ColumnExpr && x.name.toLowerCase() == pkName.toLowerCase();
    if (e is BinaryExpr) {
      final op = e.op;
      final lp = isPk(e.left);
      final rp = isPk(e.right);
      if (!lp && !rp) return null;
      // Normalise so the PK is on the left: rewrite `lit OP pk` as
      // `pk OP' lit` with op reversed.
      String nop = op;
      Expr litExpr;
      if (lp) {
        litExpr = e.right;
      } else {
        litExpr = e.left;
        switch (op) {
          case '<':
            nop = '>';
            break;
          case '<=':
            nop = '>=';
            break;
          case '>':
            nop = '<';
            break;
          case '>=':
            nop = '<=';
            break;
        }
      }
      // If the literal side isn't a constant (e.g. `pk = other_col`),
      // skip index-pruning and let it become a residual post-filter.
      Object? lit;
      try {
        lit = litExpr.eval(const <String, Object?>{});
      } catch (_) {
        return null;
      }
      switch (nop) {
        case '=':
          r.eq = lit;
          return r;
        case '<':
          r.upper = lit;
          r.upperInclusive = false;
          return r;
        case '<=':
          r.upper = lit;
          r.upperInclusive = true;
          return r;
        case '>':
          r.lower = lit;
          r.lowerInclusive = false;
          return r;
        case '>=':
          r.lower = lit;
          r.lowerInclusive = true;
          return r;
        default:
          // Other binary ops (!=, LIKE, IS, …) on the PK fall through
          // to the residual evaluator.
          return null;
      }
    }
    if (e is BetweenExpr) {
      if (!isPk(e.value) || e.negated) return null;
      Object? lo, hi;
      try {
        lo = e.low.eval(const <String, Object?>{});
        hi = e.high.eval(const <String, Object?>{});
      } catch (_) {
        return null;
      }
      r.lower = lo;
      r.lowerInclusive = true;
      r.upper = hi;
      r.upperInclusive = true;
      return r;
    }
    return null;
  }

  /// Compare two PK literals using SQL-ish semantics. Numbers compare
  /// numerically, strings lexicographically. Mixed types are rejected.
  int _compareLiteral(Object? a, Object? b) {
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    throw UnsupportedError(
        'paged table: cannot compare ${a.runtimeType} with ${b.runtimeType}.');
  }

  /// Stream rows matching a parsed range. Honours [_PagedRange.eq] as
  /// a single point lookup; otherwise calls PagedTable.range. When
  /// [_PagedRange.residual] is set, each streamed row is also fed
  /// through `residual.eval(row)` and dropped unless the result is
  /// truthy. Mirrors SQL NULL-as-false semantics.
  ///
  /// When the residual contains an `indexed_col = literal` conjunct
  /// AND no PK bounds were given, we route the candidate stream
  /// through `PagedTable.indexLookup` instead of a full table scan.
  /// The residual still runs on every yielded row, so any remaining
  /// conjuncts (`age > 25` etc.) keep filtering correctly.
  Stream<Map<String, Object?>> _pagedRangeStream(
      PagedTable pt, _PagedRange r) async* {
    if (r.contradiction) return;
    final residual = r.residual;
    bool passes(Map<String, Object?> row) {
      if (residual == null) return true;
      final v = residual.eval(row);
      return v == true;
    }

    final eq = r.eq;
    if (eq != null) {
      final row = await pt.get(eq);
      if (row != null && passes(row)) yield row;
      return;
    }
    // No PK predicate: see if we can route through a secondary index.
    if (r.lower == null && r.upper == null && residual != null) {
      final plan = _findIndexPlan(pt, residual);
      if (plan != null) {
        if (plan.isEquality) {
          await for (final row
              in pt.indexLookup(plan.indexName, plan.equalPrefix)) {
            if (passes(row)) yield row;
          }
        } else {
          await for (final row in pt.indexRange(
            plan.indexName,
            equalPrefix: plan.equalPrefix,
            lower: plan.lower,
            lowerInclusive: plan.lowerInclusive,
            upper: plan.upper,
            upperInclusive: plan.upperInclusive,
          )) {
            if (passes(row)) yield row;
          }
        }
        return;
      }
    }
    if (r.lower == null && r.upper == null) {
      await for (final row in pt.scan()) {
        if (passes(row)) yield row;
      }
      return;
    }
    await for (final row in pt.range(
      lower: r.lower,
      lowerInclusive: r.lowerInclusive,
      upper: r.upper,
      upperInclusive: r.upperInclusive,
    )) {
      if (passes(row)) yield row;
    }
  }

  /// Walk the residual AND-tree looking for predicates against the
  /// columns of a secondary index. For each index, we try to match as
  /// many *leading* columns as possible with equality predicates; if
  /// the next column past the equality prefix has a range predicate
  /// (`<`, `<=`, `>`, `>=`), we fold that in too. The first index
  /// covered by at least its leading column wins. The residual is
  /// left intact and re-applied per row by the caller.
  _PagedIndexPlan? _findIndexPlan(PagedTable pt, Expr e) {
    // Group conjuncts by column-name (lower-cased) → list of (op, lit).
    final byCol = <String, List<({String op, Object value})>>{};
    void visit(Expr expr) {
      if (expr is BinaryExpr && expr.op == 'AND') {
        visit(expr.left);
        visit(expr.right);
        return;
      }
      if (expr is! BinaryExpr) return;
      const ops = {'=', '<', '<=', '>', '>='};
      if (!ops.contains(expr.op)) return;
      ColumnExpr? col;
      Expr? lit;
      String op = expr.op;
      if (expr.left is ColumnExpr) {
        col = expr.left as ColumnExpr;
        lit = expr.right;
      } else if (expr.right is ColumnExpr) {
        col = expr.right as ColumnExpr;
        lit = expr.left;
        switch (op) {
          case '<':
            op = '>';
            break;
          case '<=':
            op = '>=';
            break;
          case '>':
            op = '<';
            break;
          case '>=':
            op = '<=';
            break;
        }
      }
      if (col == null || lit == null) return;
      Object? v;
      try {
        v = lit.eval(const <String, Object?>{});
      } catch (_) {
        return;
      }
      if (v == null) return;
      byCol
          .putIfAbsent(col.name.toLowerCase(), () => [])
          .add((op: op, value: v));
    }

    visit(e);
    if (byCol.isEmpty) return null;

    // Collect columns that have an `IS NULL` predicate anywhere in
    // the residual. We can't use a secondary index for those because
    // NULLs aren't indexed — the index would silently miss matching
    // rows.
    final nullCols = <String>{};
    void scanNulls(Expr expr) {
      if (expr is BinaryExpr && expr.op == 'AND') {
        scanNulls(expr.left);
        scanNulls(expr.right);
        return;
      }
      if (expr is UnaryExpr && expr.op == 'IS NULL') {
        final inner = expr.operand;
        if (inner is ColumnExpr) nullCols.add(inner.name.toLowerCase());
      }
    }

    scanNulls(e);

    // Collect every viable plan, then rank below. (Previously we returned
    // the first matching index in registration order — that gave the
    // wrong answer whenever a less-selective index happened to be
    // declared first.)
    final candidates = <_PagedIndexPlan>[];

    // For each index in registration order, try to build the strongest
    // plan it supports.
    for (final name in pt.secondaryIndexNames) {
      final idxCols = pt.indexColumns(name);
      if (idxCols == null || idxCols.isEmpty) continue;

      // If any indexed column has an IS NULL predicate in the residual,
      // routing through this index is unsound (it would miss the very
      // rows the predicate wants to match).
      final disqualified =
          idxCols.any((c) => nullCols.contains(c.toLowerCase()));
      if (disqualified) continue;

      // Walk leading columns collecting equality values.
      final equalPrefix = <Object>[];
      int rangeColIdx = -1;
      for (var i = 0; i < idxCols.length; i++) {
        final preds = byCol[idxCols[i].toLowerCase()];
        if (preds == null) {
          break;
        }
        // Equality wins; if not present, fall back to range on this
        // column and stop the prefix walk.
        Object? eqVal;
        for (final p in preds) {
          if (p.op == '=') {
            eqVal = p.value;
            break;
          }
        }
        if (eqVal != null) {
          equalPrefix.add(eqVal);
          continue;
        }
        rangeColIdx = i;
        break;
      }

      // We need at least one usable predicate.
      if (equalPrefix.isEmpty && rangeColIdx < 0) continue;

      // Build the range bounds on the column at rangeColIdx (if any).
      Object? lo;
      bool loInc = true;
      Object? hi;
      bool hiInc = false;
      if (rangeColIdx >= 0) {
        final preds = byCol[idxCols[rangeColIdx].toLowerCase()]!;
        for (final p in preds) {
          switch (p.op) {
            case '>=':
              if (lo == null || _compareLiteral(p.value, lo) > 0) {
                lo = p.value;
                loInc = true;
              }
              break;
            case '>':
              if (lo == null ||
                  _compareLiteral(p.value, lo) > 0 ||
                  (_compareLiteral(p.value, lo) == 0 && loInc)) {
                lo = p.value;
                loInc = false;
              }
              break;
            case '<=':
              if (hi == null || _compareLiteral(p.value, hi) < 0) {
                hi = p.value;
                hiInc = true;
              }
              break;
            case '<':
              if (hi == null ||
                  _compareLiteral(p.value, hi) < 0 ||
                  (_compareLiteral(p.value, hi) == 0 && hiInc)) {
                hi = p.value;
                hiInc = false;
              }
              break;
          }
        }
        if (lo == null && hi == null) {
          // No usable range predicates on this column after all.
          if (equalPrefix.isEmpty) continue;
        }
      }

      final isEquality =
          rangeColIdx < 0 && equalPrefix.length == idxCols.length;
      candidates.add(_PagedIndexPlan(
        indexName: name,
        isEquality: isEquality,
        equalPrefix: equalPrefix,
        lower: lo,
        lowerInclusive: loInc,
        upper: hi,
        upperInclusive: hiInc,
      ));
    }
    if (candidates.isEmpty) return null;
    // Rank candidates by selectivity proxy:
    //   1. Prefer plans whose equality prefix covers more columns
    //      (longer prefix = tighter probe).
    //   2. Prefer full-equality (`isEquality`) plans over hybrid
    //      equality+range plans of the same prefix length.
    //   3. Prefer plans that drive a UNIQUE index — at most one row.
    //   4. Tie-break on registration order (stable for reproducibility).
    candidates.sort((a, b) {
      // Longer equality prefix wins (descending).
      final ap = a.equalPrefix.length;
      final bp = b.equalPrefix.length;
      if (ap != bp) return bp - ap;
      // Pure equality wins over equality+range.
      if (a.isEquality != b.isEquality) return a.isEquality ? -1 : 1;
      // UNIQUE wins as a final selectivity hint.
      final au = pt.isIndexUnique(a.indexName);
      final bu = pt.isIndexUnique(b.indexName);
      if (au != bu) return au ? -1 : 1;
      return 0;
    });
    return candidates.first;
  }

  Future<QueryResult> _pagedInsert(InsertStmt s, PagedTable pt) async {
    final onConflict = s.onConflict;
    if (onConflict != null && s.mode != InsertMode.normal) {
      throw UnsupportedError(
          'INSERT OR ${s.mode.name} … ON CONFLICT is not supported on '
          'paged table ${s.table}; pick one conflict resolution.');
    }
    // Resolve the conflict target to a concrete probe strategy:
    //   - null         : no ON CONFLICT clause
    //   - 'pk'         : PK-only probe
    //   - 'any'        : PK then every UNIQUE secondary index
    //   - any other s  : name of a UNIQUE secondary index
    final pkName = pt.columns[pt.primaryKeyIndex].name;
    String? conflictProbe;
    if (onConflict != null) {
      if (onConflict.targetColumns.isEmpty) {
        conflictProbe = 'any';
      } else if (onConflict.targetColumns.length == 1 &&
          onConflict.targetColumns.first.toLowerCase() ==
              pkName.toLowerCase()) {
        conflictProbe = 'pk';
      } else {
        final idx = pt.findUniqueIndexByColumns(onConflict.targetColumns);
        if (idx == null) {
          throw UnsupportedError(
              'INSERT … ON CONFLICT (${onConflict.targetColumns.join(", ")}) '
              'on paged table ${s.table}: no matching primary key or UNIQUE '
              'index covers exactly those columns.');
        }
        conflictProbe = idx;
      }
    }
    // Materialise the source rows. For INSERT … SELECT we run the
    // inner SELECT through the regular executor first and convert
    // each value into a LiteralExpr so the rest of the path is
    // identical to the VALUES case. If the inner SELECT targets a
    // paged table (e.g. `INSERT INTO t SELECT … FROM t`) we route
    // through the async paged path; otherwise we fall back to the
    // synchronous in-memory executor.
    final List<List<Expr>> sourceRows;
    if (s.select != null) {
      final paged = await _maybeRunPagedStmt(s.select!);
      final res = paged ?? _selectTopLevel(s.select!);
      sourceRows = [
        for (final row in res.rows) [for (final v in row) LiteralExpr(v)],
      ];
    } else {
      sourceRows = s.rows ?? const <List<Expr>>[];
    }
    final colNames = s.columns ?? [for (final c in pt.columns) c.name];
    if (colNames.length != pt.columns.length) {
      // Allow positional INSERT with explicit column list shorter than
      // the schema — but every paged column must appear (PagedTable.insert
      // requires a complete row map).
      // Keep the diagnostic strict for now; relax later if needed.
      throw UnsupportedError(
          'INSERT into paged table ${s.table}: every column must be '
          'supplied (got ${colNames.length}, want ${pt.columns.length}).');
    }
    // Set up RETURNING projection, if any.
    final returningCols = <String>[];
    final returningExprs = <Expr>[];
    if (s.returning != null) {
      for (final item in s.returning!) {
        if (item.isStar) {
          for (final c in pt.columns) {
            returningCols.add(c.name);
            returningExprs.add(ColumnExpr(c.name));
          }
        } else {
          returningCols.add(item.alias ?? _exprLabel(item.expr!));
          returningExprs.add(item.expr!);
        }
      }
    }
    final returnedRows = <List<Object?>>[];
    var affected = 0;
    for (final r in sourceRows) {
      if (r.length != colNames.length) {
        throw StateError(
            'INSERT into ${s.table}: row arity ${r.length} ≠ column '
            'count ${colNames.length}.');
      }
      final map = <String, Object?>{};
      for (var i = 0; i < colNames.length; i++) {
        map[colNames[i]] =
            _evalLiteral(r[i], 'INSERT into paged table ${s.table}');
      }
      // ON CONFLICT path takes precedence over INSERT-mode handling
      // (we already rejected the two combined upstream).
      if (onConflict != null) {
        final hitPk =
            await _pagedFindConflictPk(pt, map, conflictProbe!, pkName);
        if (hitPk == null) {
          await pt.insert(map);
          affected++;
          if (returningExprs.isNotEmpty) {
            returnedRows.add([for (final e in returningExprs) e.eval(map)]);
          }
        } else if (onConflict.doNothing) {
          // DO NOTHING: leave the existing row alone; not counted.
        } else {
          // DO UPDATE: build evaluation context with existing.col
          // (bare names) and excluded.col (proposed insert), apply
          // WHERE filter if any, evaluate assignments, then update.
          final existing = (await pt.get(hitPk))!;
          final ctx = <String, Object?>{...existing};
          for (final c in pt.columns) {
            final v = map[c.name];
            ctx['excluded.${c.name}'] = v;
            ctx['EXCLUDED.${c.name}'] = v;
          }
          final w = onConflict.where;
          if (w == null || evalPredicate(_bindExpr(w), ctx)) {
            final newRow = <String, Object?>{...existing};
            onConflict.assignments.forEach((col, expr) {
              final hit = pt.columns.firstWhere(
                (c) => c.name.toLowerCase() == col.toLowerCase(),
                orElse: () => throw StateError(
                    'ON CONFLICT DO UPDATE on paged table ${s.table}: '
                    'unknown column $col'),
              );
              newRow[hit.name] = _bindExpr(expr).eval(ctx);
            });
            if (newRow[pkName] != existing[pkName]) {
              throw UnsupportedError(
                  'ON CONFLICT DO UPDATE on paged table ${s.table}: '
                  'cannot reassign the primary key column "$pkName".');
            }
            await pt.update(hitPk, newRow);
            affected++;
            if (returningExprs.isNotEmpty) {
              returnedRows
                  .add([for (final e in returningExprs) e.eval(newRow)]);
            }
          }
        }
        continue;
      }
      switch (s.mode) {
        case InsertMode.normal:
          await pt.insert(map);
          affected++;
          if (returningExprs.isNotEmpty) {
            returnedRows.add([for (final e in returningExprs) e.eval(map)]);
          }
        case InsertMode.orIgnore:
          // Silently skip rows that would conflict with PK or a
          // UNIQUE index. SQLite excludes ignored rows from the
          // affected count and from RETURNING.
          final inserted = await pt.insertOrIgnore(map);
          if (inserted) {
            affected++;
            if (returningExprs.isNotEmpty) {
              returnedRows.add([for (final e in returningExprs) e.eval(map)]);
            }
          }
        case InsertMode.orReplace:
          // Delete every conflicting row, then insert. SQLite counts
          // only the inserted row in `changes()`, so we do the same.
          await pt.insertOrReplace(map);
          affected++;
          if (returningExprs.isNotEmpty) {
            returnedRows.add([for (final e in returningExprs) e.eval(map)]);
          }
      }
    }
    if (inTransaction) {
      _pagedDirty.add(pt);
    } else {
      await pt.commit();
    }
    if (returningExprs.isNotEmpty) {
      return QueryResult(
          columns: returningCols, rows: returnedRows, affected: affected);
    }
    return QueryResult(affected: affected, message: '$affected row(s)');
  }

  /// Locate an existing row that conflicts with the proposed-insert
  /// [row] under the resolved ON CONFLICT probe [probe]. Returns the
  /// conflicting row's primary-key value, or null when none exists.
  /// [probe] is one of: `pk` (PK only), `any` (PK then every UNIQUE
  /// secondary index, first hit wins), or a UNIQUE secondary-index
  /// name.
  Future<Object?> _pagedFindConflictPk(PagedTable pt, Map<String, Object?> row,
      String probe, String pkName) async {
    if (probe == 'pk' || probe == 'any') {
      final pk = row[pkName];
      if (pk != null && (await pt.get(pk)) != null) return pk;
      if (probe == 'pk') return null;
    }
    if (probe == 'any') {
      for (final name in pt.secondaryIndexNames) {
        if (!pt.isIndexUnique(name)) continue;
        final hit = await pt.findConflictByUniqueIndex(name, row);
        if (hit != null) return hit;
      }
      return null;
    }
    // Named UNIQUE index.
    return pt.findConflictByUniqueIndex(probe, row);
  }

  /// Aggregate / GROUP BY path for `USING paged` SELECTs. Materialises
  /// every matched row into memory (the only place we deliberately do
  /// so on paged tables, since aggregation needs random access by
  /// group), then groups, computes aggregates, applies HAVING, ORDER
  /// BY and LIMIT/OFFSET.
  ///
  /// Supports COUNT / SUM / AVG / MIN / MAX / TOTAL / GROUP_CONCAT /
  /// STRING_AGG including DISTINCT and FILTER variants — same coverage
  /// as the in-memory executor's [_aggregateValue].
  Future<QueryResult> _pagedAggregateSelect(SelectStmt s, PagedTable pt) async {
    final pkName = pt.columns[pt.primaryKeyIndex].name;

    for (final p in s.projection) {
      if (p.isStar) {
        throw UnsupportedError(
            'SELECT on paged table ${s.fromTable}: SELECT * with '
            'GROUP BY / aggregates is not supported.');
      }
    }

    // Buffer all matched rows. Aggregation needs to revisit rows
    // per-group, so streaming isn't enough.
    final range = _pagedExtractPkRange(
        s.where, pkName, 'SELECT on paged table ${s.fromTable}');
    final rows = <Map<String, Object?>>[];
    await for (final row in _pagedRangeStream(pt, range)) {
      rows.add(row);
    }

    // Build group key per row. Empty GROUP BY = single global group.
    final groupExprs = s.groupBy;
    final groups = <String, List<Map<String, Object?>>>{};
    final groupOrder = <String>[];
    if (groupExprs.isEmpty) {
      groups[''] = rows;
      groupOrder.add('');
    } else {
      for (final row in rows) {
        final keyVals = <Object?>[
          for (final ge in groupExprs) ge.eval(row),
        ];
        final keyStr = jsonEncode(keyVals);
        groups.putIfAbsent(keyStr, () {
          groupOrder.add(keyStr);
          return <Map<String, Object?>>[];
        }).add(row);
      }
    }

    // Evaluator that recognises aggregate-function calls inside an
    // expression tree and routes them through [_aggregateValue], while
    // ordinary column refs / literals / non-aggregate functions are
    // evaluated against [sample] (the first row of the group).
    Object? evalInGroup(
        Expr e, List<Map<String, Object?>> grp, Map<String, Object?> sample) {
      if (e is FunctionCallExpr && e.isAggregate) {
        return _aggregateValue(e, grp);
      }
      if (e is BinaryExpr) {
        final l = evalInGroup(e.left, grp, sample);
        final r = evalInGroup(e.right, grp, sample);
        return BinaryExpr(e.op, LiteralExpr(l), LiteralExpr(r)).eval(const {});
      }
      if (e is UnaryExpr) {
        final v = evalInGroup(e.operand, grp, sample);
        return UnaryExpr(e.op, LiteralExpr(v)).eval(const {});
      }
      if (e is FunctionCallExpr) {
        final args = [
          for (final a in e.args) LiteralExpr(evalInGroup(a, grp, sample)),
        ];
        return FunctionCallExpr(e.name, args).eval(const {});
      }
      return e.eval(sample);
    }

    final outCols = <String>[
      for (final p in s.projection) p.alias ?? _exprLabel(p.expr!),
    ];

    // Build per-group output rows, applying HAVING.
    final survivors = <({
      List<Object?> outRow,
      List<Map<String, Object?>> grp,
      Map<String, Object?> sample,
    })>[];
    final having = s.having;
    for (final keyStr in groupOrder) {
      final grp = groups[keyStr]!;
      final sample = grp.isEmpty ? <String, Object?>{} : grp.first;
      if (having != null) {
        final v = evalInGroup(having, grp, sample);
        if (v != true) continue;
      }
      final outRow = <Object?>[
        for (final p in s.projection) evalInGroup(p.expr!, grp, sample),
      ];
      survivors.add((outRow: outRow, grp: grp, sample: sample));
    }

    // ORDER BY: evaluate each ORDER BY expression per-group. Column
    // references to projection aliases (e.g. `ORDER BY total` where
    // `SUM(salary) AS total` is in the projection) are resolved to
    // the original projection expression so aggregates work.
    if (s.orderBy.isNotEmpty) {
      final aliasMap = <String, Expr>{
        for (final p in s.projection)
          if (p.alias != null) p.alias!.toLowerCase(): p.expr!,
      };
      Expr resolveAlias(Expr e) {
        if (e is ColumnExpr) {
          final hit = aliasMap[e.name.toLowerCase()];
          if (hit != null) return hit;
        }
        return e;
      }

      survivors.sort((a, b) {
        for (final ob in s.orderBy) {
          final expr = resolveAlias(ob.expr);
          final av = evalInGroup(expr, a.grp, a.sample);
          final bv = evalInGroup(expr, b.grp, b.sample);
          int c;
          if (av == null && bv == null) {
            c = 0;
          } else if (av == null) {
            c = -1;
          } else if (bv == null) {
            c = 1;
          } else {
            c = _compareLiteral(av, bv);
          }
          if (c != 0) return ob.descending ? -c : c;
        }
        return 0;
      });
    }

    final offset = (s.offset ?? 0) < 0 ? 0 : (s.offset ?? 0);
    final limit = s.limit;
    final unlimited = limit == null || limit < 0;
    final start = offset.clamp(0, survivors.length);
    final end = unlimited
        ? survivors.length
        : (start + limit).clamp(0, survivors.length);
    return QueryResult(
      columns: outCols,
      rows: [for (var i = start; i < end; i++) survivors[i].outRow],
    );
  }

  Future<QueryResult> _pagedSelect(SelectStmt s, PagedTable pt) async {
    if (s.fromSubquery != null ||
        s.joins.isNotEmpty ||
        s.setOp != null ||
        s.distinct ||
        s.fromFunction != null) {
      throw UnsupportedError(
          'SELECT on paged table ${s.fromTable}: joins, DISTINCT and '
          'set ops are not supported.');
    }
    // Detect aggregation: any aggregate function call in the
    // projection, in HAVING, in ORDER BY, or any explicit GROUP BY.
    bool isAggregate(Expr? e) {
      if (e == null) return false;
      var found = false;
      void walk(Expr x) {
        if (found) return;
        if (x is FunctionCallExpr && x.isAggregate) {
          found = true;
          return;
        }
        if (x is BinaryExpr) {
          walk(x.left);
          walk(x.right);
        } else if (x is UnaryExpr) {
          walk(x.operand);
        } else if (x is FunctionCallExpr) {
          for (final a in x.args) {
            walk(a);
          }
        }
      }

      walk(e);
      return found;
    }

    final hasAggregates = s.groupBy.isNotEmpty ||
        s.having != null ||
        s.projection.any((p) => p.expr != null && isAggregate(p.expr)) ||
        s.orderBy.any((o) => isAggregate(o.expr));
    // Fast path: bare `SELECT COUNT(*) FROM t [WHERE …]` with no
    // GROUP BY / HAVING — count without materialising rows.
    bool isBareCountStar = false;
    String bareCountAlias = 'count(*)';
    if (hasAggregates &&
        s.groupBy.isEmpty &&
        s.having == null &&
        s.orderBy.isEmpty &&
        s.projection.length == 1) {
      final p = s.projection.single;
      final e = p.expr;
      if (e is FunctionCallExpr &&
          e.name.toUpperCase() == 'COUNT' &&
          e.isStarArg &&
          !e.distinct &&
          e.window == null &&
          e.filterExpr == null) {
        isBareCountStar = true;
        if (p.alias != null) bareCountAlias = p.alias!;
      }
    }
    if (hasAggregates && !isBareCountStar) {
      return _pagedAggregateSelect(s, pt);
    }
    final colNames = pt.columns.map((c) => c.name).toList();
    final pkName = pt.columns[pt.primaryKeyIndex].name;

    // ORDER BY: only `ORDER BY <pk> [ASC|DESC]`. ASC is the native
    // PagedTable iteration order; DESC buffers the matched rows and
    // reverses them, which is fine for the LIMIT-paired use case but
    // not for streaming a whole large table. Either direction also
    // forces a buffer-and-sort when the chosen access path is a
    // secondary-index range, because those stream in index order
    // rather than PK order.
    bool descending = false;
    bool hasOrderBy = false;
    if (s.orderBy.isNotEmpty) {
      hasOrderBy = true;
      if (s.orderBy.length > 1) {
        throw UnsupportedError(
            'SELECT on paged table ${s.fromTable}: ORDER BY may only '
            'reference a single column (the primary key).');
      }
      final ob = s.orderBy.single;
      final e = ob.expr;
      if (e is! ColumnExpr || e.name.toLowerCase() != pkName.toLowerCase()) {
        throw UnsupportedError(
            'SELECT on paged table ${s.fromTable}: ORDER BY must '
            'reference the primary key column "$pkName".');
      }
      descending = ob.descending;
    }

    // Detect COUNT(*) sole-projection (the bare fast path we set up
    // above). When [isBareCountStar] is true we skip projection setup
    // since the only output is the integer count.
    final isCountStar = isBareCountStar;
    final countAlias = bareCountAlias;

    // Normal projection. Supports:
    //   * `*` (all columns)
    //   * bare column references (`name`, `t.name`)
    //   * arbitrary scalar expressions (`id + 1`, `upper(name)`,
    //     `name || '!'`) — evaluated via Expr.eval on each row map.
    // Aggregates other than COUNT(*) are still rejected.
    List<String> outCols;
    bool selectAll = false;
    List<Object? Function(Map<String, Object?>)>? projectors;
    if (isCountStar) {
      outCols = [countAlias];
    } else if (s.projection.length == 1 && s.projection.single.isStar) {
      selectAll = true;
      outCols = colNames;
    } else {
      outCols = <String>[];
      projectors = <Object? Function(Map<String, Object?>)>[];
      for (final p in s.projection) {
        if (p.isStar) {
          throw UnsupportedError(
              'SELECT on paged table ${s.fromTable}: mixed `*` with '
              'other projections is not supported.');
        }
        final e = p.expr!;
        if (e is FunctionCallExpr && e.isAggregate) {
          throw UnsupportedError(
              'SELECT on paged table ${s.fromTable}: aggregate '
              '${e.name}() is not supported (only bare COUNT(*) is).');
        }
        if (e is ColumnExpr) {
          final hit = colNames.firstWhere(
            (c) => c.toLowerCase() == e.name.toLowerCase(),
            orElse: () => throw StateError(
                'SELECT on paged table ${s.fromTable}: unknown column '
                '${e.name}'),
          );
          outCols.add(p.alias ?? e.name);
          projectors.add((row) => row[hit]);
        } else {
          outCols.add(p.alias ?? _exprLabel(e));
          projectors.add(e.eval);
        }
      }
    }

    final range = _pagedExtractPkRange(
        s.where, pkName, 'SELECT on paged table ${s.fromTable}');

    // LIMIT / OFFSET. Negative LIMIT means "no limit" (SQLite-ish).
    final offset = (s.offset ?? 0) < 0 ? 0 : (s.offset ?? 0);
    final limit = s.limit;
    final unlimited = limit == null || limit < 0;

    if (isCountStar) {
      // Pure count: walk the matched stream without materialising
      // anything, then apply OFFSET / LIMIT to the single output row
      // (degenerate but matches SQLite when COUNT(*) is bare).
      var n = 0;
      await for (final _ in _pagedRangeStream(pt, range)) {
        n++;
      }
      final rows = (offset == 0 && (unlimited || limit > 0))
          ? [
              [n],
            ]
          : <List<Object?>>[];
      return QueryResult(columns: outCols, rows: rows);
    }

    // Streaming projection.
    List<Object?> project(Map<String, Object?> row) {
      if (selectAll) return [for (final c in colNames) row[c]];
      return [for (final fn in projectors!) fn(row)];
    }

    final rows = <List<Object?>>[];
    if (hasOrderBy) {
      // Buffer all matched rows, sort by PK, apply OFFSET/LIMIT. The
      // PK column is always present in the streamed row maps.
      final buf = <Map<String, Object?>>[];
      await for (final row in _pagedRangeStream(pt, range)) {
        buf.add(row);
      }
      buf.sort((a, b) {
        final c = _compareLiteral(a[pkName], b[pkName]);
        return descending ? -c : c;
      });
      final start = offset.clamp(0, buf.length);
      final end = unlimited ? buf.length : (start + limit).clamp(0, buf.length);
      for (var i = start; i < end; i++) {
        rows.add(project(buf[i]));
      }
      return QueryResult(columns: outCols, rows: rows);
    }
    {
      var skipped = 0;
      await for (final row in _pagedRangeStream(pt, range)) {
        if (skipped < offset) {
          skipped++;
          continue;
        }
        if (!unlimited && rows.length >= limit) break;
        rows.add(project(row));
      }
      return QueryResult(columns: outCols, rows: rows);
    }
  }

  Future<QueryResult> _pagedUpdate(UpdateStmt s, PagedTable pt) async {
    final pkName = pt.columns[pt.primaryKeyIndex].name;
    final range = _pagedExtractPkRange(
        s.where, pkName, 'UPDATE on paged table ${s.table}');
    // Resolve assignment columns once. Each RHS expression is kept
    // as an Expr so it can be evaluated against the current row at
    // mutation time — that supports things like `SET qty = qty + 1`.
    final assignExprs = <String, Expr>{};
    s.assignments.forEach((col, expr) {
      final hit = pt.columns.firstWhere(
        (c) => c.name.toLowerCase() == col.toLowerCase(),
        orElse: () => throw StateError(
            'UPDATE on paged table ${s.table}: unknown column $col'),
      );
      assignExprs[hit.name] = expr;
    });
    // PK reassignment is allowed: when the SET list touches the PK
    // column, we re-route that row through delete + insert below.
    final reassignsPk = assignExprs.containsKey(pkName);
    // Set up RETURNING projection, if any. SQLite returns the *new*
    // row values for UPDATE … RETURNING.
    final returningCols = <String>[];
    final returningExprs = <Expr>[];
    if (s.returning != null) {
      for (final item in s.returning!) {
        if (item.isStar) {
          for (final c in pt.columns) {
            returningCols.add(c.name);
            returningExprs.add(ColumnExpr(c.name));
          }
        } else {
          returningCols.add(item.alias ?? _exprLabel(item.expr!));
          returningExprs.add(item.expr!);
        }
      }
    }
    final returnedRows = <List<Object?>>[];
    // Materialise matching rows first (PK + current values) so we
    // don't mutate while iterating the index. _pagedRangeStream
    // handles both the eq fast-path and any residual post-filter.
    if (range.contradiction) {
      if (s.returning != null) {
        return QueryResult(
            columns: returningCols, rows: returnedRows, affected: 0);
      }
      return QueryResult(affected: 0, message: '0 row(s)');
    }
    final matches = <Map<String, Object?>>[];
    await for (final row in _pagedRangeStream(pt, range)) {
      matches.add(row);
    }
    var affected = 0;
    if (reassignsPk && matches.isNotEmpty) {
      // Two-phase apply so chained reassignments like `UPDATE t SET
      // id = id + 1` (which would otherwise collide row-by-row) work:
      //   1. Compute every (oldPk, newRow) pair from the *original*
      //      row values, without mutating anything.
      //   2. Pre-validate the post-update state for PK and UNIQUE
      //      collisions — both against rows untouched by this UPDATE
      //      and within the new-row set itself.
      //   3. Delete every old row whose PK actually changes.
      //   4. Insert every new row.
      //
      // Rows whose PK is unchanged are still applied via plain
      // update so secondary-index entries aren't needlessly torn
      // down and rebuilt.
      final plan = <({Object oldPk, Object newPk, Map<String, Object?> row})>[];
      for (final row in matches) {
        final pkVal = row[pkName];
        if (pkVal == null) continue;
        final updated = Map<String, Object?>.from(row);
        assignExprs.forEach((col, expr) {
          updated[col] = expr.eval(row);
        });
        final newPk = updated[pkName];
        if (newPk == null) {
          throw StateError(
              'UPDATE on paged table ${s.table}: primary key column '
              '"$pkName" cannot be set to NULL.');
        }
        plan.add((oldPk: pkVal, newPk: newPk, row: updated));
      }
      // Pre-validation phase. Only rows whose PK actually moves
      // participate in the cross-row checks (same-PK rows are
      // handled via in-place update and PagedTable.update already
      // enforces UNIQUE-index constraints).
      final moving = [
        for (final p in plan)
          if (_compareLiteral(p.oldPk, p.newPk) != 0) p
      ];
      // Set of oldPks being vacated by this UPDATE. JSON-encode for
      // stable equality on heterogeneous PK types.
      final vacated = <String>{
        for (final p in moving) jsonEncode(p.oldPk),
      };
      // 1. New PKs must be distinct within the plan and must not
      //    already exist outside the vacated set.
      final seenNewPk = <String>{};
      for (final p in moving) {
        final tag = jsonEncode(p.newPk);
        if (!seenNewPk.add(tag)) {
          throw StateError(
              'UPDATE on paged table ${s.table}: multiple rows would '
              'be assigned primary key ${jsonEncode(p.newPk)}.');
        }
        if (vacated.contains(tag)) continue;
        if ((await pt.get(p.newPk)) != null) {
          throw StateError('UPDATE on paged table ${s.table}: cannot reassign '
              'primary key to ${jsonEncode(p.newPk)} — row already exists.');
        }
      }
      // 2. UNIQUE-index pre-check: per index, ensure new prefixes
      //    don't collide with non-vacated existing rows or with
      //    each other.
      for (final idxName in pt.secondaryIndexNames) {
        if (!pt.isIndexUnique(idxName)) continue;
        final cols = pt.indexColumns(idxName)!;
        final seenPrefix = <String>{};
        for (final p in moving) {
          // Skip rows whose indexed tuple contains a NULL — those
          // don't participate in the UNIQUE constraint.
          var anyNull = false;
          final parts = <Object?>[];
          for (final c in cols) {
            final v = p.row[c];
            if (v == null) {
              anyNull = true;
              break;
            }
            parts.add(v);
          }
          if (anyNull) continue;
          final tag = jsonEncode(parts);
          if (!seenPrefix.add(tag)) {
            throw StateError(
                'UPDATE on paged table ${s.table}: UNIQUE constraint '
                'violated on index $idxName (${cols.join(", ")}) — '
                'multiple updated rows share the same value.');
          }
          final hitPk = await pt.findConflictByUniqueIndex(idxName, p.row);
          if (hitPk == null) continue;
          if (vacated.contains(jsonEncode(hitPk))) continue;
          throw StateError(
              'UPDATE on paged table ${s.table}: UNIQUE constraint '
              'violated on index $idxName (${cols.join(", ")}).');
        }
      }
      // Phase 1: in-place updates for rows whose PK didn't change.
      for (final p in plan) {
        if (_compareLiteral(p.oldPk, p.newPk) == 0) {
          await pt.update(p.oldPk, p.row);
        }
      }
      // Phase 2: delete every row whose PK is moving away.
      for (final p in moving) {
        await pt.delete(p.oldPk);
      }
      // Phase 3: insert every moved row. After the pre-validation
      // above these inserts are guaranteed not to conflict.
      for (final p in moving) {
        await pt.insert(p.row);
      }
      affected = plan.length;
      if (returningExprs.isNotEmpty) {
        for (final p in plan) {
          returnedRows.add([for (final e in returningExprs) e.eval(p.row)]);
        }
      }
    } else {
      for (final row in matches) {
        final pkVal = row[pkName];
        if (pkVal == null) continue;
        // Evaluate each assignment against the *current* row so
        // expressions like `qty = qty + 1` see the pre-update value.
        final updated = Map<String, Object?>.from(row);
        assignExprs.forEach((col, expr) {
          updated[col] = expr.eval(row);
        });
        await pt.update(pkVal, updated);
        affected++;
        if (returningExprs.isNotEmpty) {
          returnedRows.add([for (final e in returningExprs) e.eval(updated)]);
        }
      }
    }
    if (affected > 0) {
      if (inTransaction) {
        _pagedDirty.add(pt);
      } else {
        await pt.commit();
      }
    }
    if (s.returning != null) {
      return QueryResult(
          columns: returningCols, rows: returnedRows, affected: affected);
    }
    return QueryResult(affected: affected, message: '$affected row(s)');
  }

  Future<QueryResult> _pagedDelete(DeleteStmt s, PagedTable pt) async {
    final pkName = pt.columns[pt.primaryKeyIndex].name;
    final range = _pagedExtractPkRange(
        s.where, pkName, 'DELETE on paged table ${s.table}');
    // Set up RETURNING projection, if any. SQLite returns the *pre-
    // deletion* row values for DELETE … RETURNING.
    final returningCols = <String>[];
    final returningExprs = <Expr>[];
    if (s.returning != null) {
      for (final item in s.returning!) {
        if (item.isStar) {
          for (final c in pt.columns) {
            returningCols.add(c.name);
            returningExprs.add(ColumnExpr(c.name));
          }
        } else {
          returningCols.add(item.alias ?? _exprLabel(item.expr!));
          returningExprs.add(item.expr!);
        }
      }
    }
    final returnedRows = <List<Object?>>[];
    if (range.contradiction) {
      if (s.returning != null) {
        return QueryResult(
            columns: returningCols, rows: returnedRows, affected: 0);
      }
      return QueryResult(affected: 0, message: '0 row(s)');
    }
    // Materialise matching rows first (don't mutate during traversal).
    // We keep the full row map (not just PKs) so RETURNING can
    // evaluate against the pre-deletion image.
    final matched = <Map<String, Object?>>[];
    await for (final row in _pagedRangeStream(pt, range)) {
      matched.add(row);
    }
    var affected = 0;
    for (final row in matched) {
      final pk = row[pkName];
      if (pk == null) continue;
      if (await pt.delete(pk)) {
        affected++;
        if (returningExprs.isNotEmpty) {
          returnedRows.add([for (final e in returningExprs) e.eval(row)]);
        }
      }
    }
    if (affected > 0) {
      if (inTransaction) {
        _pagedDirty.add(pt);
      } else {
        await pt.commit();
      }
    }
    if (s.returning != null) {
      return QueryResult(
          columns: returningCols, rows: returnedRows, affected: affected);
    }
    return QueryResult(affected: affected, message: '$affected row(s)');
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
    t.invalidateUniqueCaches();
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
    t.invalidateKeyCache();
    t.invalidateUniqueCaches();
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
      defaultExprSql: old.defaultExprSql,
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
    t.invalidateKeyCache();
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
    t.invalidateKeyCache();
    return QueryResult.message('Table ${s.oldName} renamed to ${s.newName}');
  }

  /// Recompute GENERATED column values for all rows in [t].
  void _recomputeGenerated(Table t, ColumnDef col) {
    final idx = t.columnIndex(col.name);
    final expr = _parseSelectExprCached(col.generatedExprSql!);
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
    // Drop any stale cached AST for this name (in case the same name was
    // previously used for a different predicate).
    _partialIndexAstCache.remove(s.indexName);
    _exprIndexAstCache.remove(s.indexName);
    if ((s.whereSql != null || s.exprSql != null)) {
      _refreshPartialIndexes(t);
    }
    return QueryResult.message('Index ${s.indexName} created');
  }

  QueryResult _dropIndex(DropIndexStmt s) {
    for (final t in _tables.values) {
      if (t.indexDefs.containsKey(s.indexName)) {
        t.dropIndex(s.indexName);
        _partialIndexAstCache.remove(s.indexName);
        _exprIndexAstCache.remove(s.indexName);
        return QueryResult.message('Index ${s.indexName} dropped');
      }
    }
    if (s.ifExists) {
      return QueryResult.message('Index ${s.indexName} did not exist');
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
        if (c.defaultValue != null) {
          row[i] = coerce(c.defaultValue, c.type);
        } else if (c.defaultExprSql != null) {
          row[i] = _evalDefaultExpr(t, c, row);
        }
      }
      if (s.columns == null) {
        if (values.isEmpty) {
          // INSERT INTO t DEFAULT VALUES — leave row as defaults/NULLs.
        } else if (values.length != t.columns.length) {
          throw StateError(
              'Expected ${t.columns.length} values, got ${values.length}');
        } else {
          for (var i = 0; i < values.length; i++) {
            row[i] = coerceForColumn(_evalScalar(values[i]), t.columns[i],
                strict: t.strict);
          }
        }
      } else {
        if (values.length != s.columns!.length) {
          throw StateError('Column/value count mismatch');
        }
        for (var i = 0; i < s.columns!.length; i++) {
          final colIdx = t.columnIndex(s.columns![i]);
          // Generated columns cannot be assigned by an INSERT.
          if (t.columns[colIdx].generatedExprSql != null) {
            throw StateError(
                'cannot INSERT into generated column "${t.columns[colIdx].name}"');
          }
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
        _lastInsertRowid = _rowidOfInsertedRow(t, row);
        _fireTriggers(t.name, 'INSERT', 'AFTER', newRow: row, sourceTable: t);
        _recordChange(t, 'INSERT', null, row);
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

  /// Pick a rowid for [row] just inserted into [t], for the purpose of
  /// `last_insert_rowid()`. SQLite uses the value of an INTEGER PRIMARY
  /// KEY column when present (it IS the rowid); otherwise the rowid is
  /// the 1-based position of the row in the table.
  int _rowidOfInsertedRow(Table t, List<Object?> row) {
    for (var i = 0; i < t.columns.length; i++) {
      final c = t.columns[i];
      if (c.primaryKey && c.type == DataType.integer) {
        final v = row[i];
        if (v is int) return v;
      }
    }
    return t.rows.length;
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
    t.invalidateUniqueCaches();
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
    _recordChange(t, 'UPDATE', oldRow, newRow);
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
      // Optional FROM-table source for `UPDATE t SET ... FROM other`.
      Table? fromT;
      if (s.fromTable != null) {
        fromT = _requireTable(s.fromTable!);
      }
      // INDEXED BY: resolve a candidate rowId set up-front. NOT INDEXED
      // and the absence of any hint both fall through to a full scan.
      final hintedRows = _resolveHintedRowIds(t, s.where, s.indexedBy);
      final rowOrder = hintedRows ??
          List<int>.generate(t.rows.length, (i) => i, growable: false);
      final lim = s.limit == null
          ? -1
          : ((_evalScalar(s.limit!, const {}) as num?)?.toInt() ?? -1);
      var skip = s.offset == null
          ? 0
          : ((_evalScalar(s.offset!, const {}) as num?)?.toInt() ?? 0);
      for (final ri in rowOrder) {
        if (lim == 0 || (lim > 0 && count >= lim)) break;
        final row = t.rows[ri];
        final view = t.rowToMap(row);
        // For UPDATE ... FROM other, look for the first `other` row that
        // satisfies WHERE; bind its columns into the evaluation context.
        Map<String, Object?>? matchedView;
        if (fromT != null) {
          for (final fr in fromT.rows) {
            final joinView = <String, Object?>{
              ...view,
              ...fromT.rowToMap(fr, alias: s.fromAlias),
            };
            if (s.where == null ||
                evalPredicate(_bindExpr(s.where!), joinView)) {
              matchedView = joinView;
              break;
            }
          }
          if (matchedView == null) continue;
        } else {
          if (s.where != null && !evalPredicate(_bindExpr(s.where!), view)) {
            continue;
          }
          matchedView = view;
        }
        if (skip > 0) {
          skip--;
          continue;
        }
        final old = List<Object?>.from(row);
        _fireTriggers(t.name, 'UPDATE', 'BEFORE',
            oldRow: old, newRow: row, sourceTable: t);
        s.assignments.forEach((col, expr) {
          final colIdx = t.columnIndex(col);
          if (t.columns[colIdx].generatedExprSql != null) {
            throw StateError(
                'cannot UPDATE generated column "${t.columns[colIdx].name}"');
          }
          row[colIdx] = coerceForColumn(
              _evalScalar(expr, matchedView!), t.columns[colIdx],
              strict: t.strict);
        });
        _evaluateGenerated(t, row);
        _enforceChecks(t, row);
        _enforceForeignKeysOnInsert(t, row);
        _cascadeOnUpdate(t, old, row);
        _fireTriggers(t.name, 'UPDATE', 'AFTER',
            oldRow: old, newRow: row, sourceTable: t);
        _recordChange(t, 'UPDATE', old, row);
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
      final lim = s.limit == null
          ? -1
          : ((_evalScalar(s.limit!, const {}) as num?)?.toInt() ?? -1);
      var skip = s.offset == null
          ? 0
          : ((_evalScalar(s.offset!, const {}) as num?)?.toInt() ?? 0);
      bool admit() {
        if (lim == 0) return false;
        if (skip > 0) {
          skip--;
          return false;
        }
        if (lim > 0 && deleted.length >= lim) return false;
        return true;
      }

      final hintedRows = _resolveHintedRowIds(t, s.where, s.indexedBy);
      if (hintedRows != null) {
        final toDelete = <int>{};
        for (final ri in hintedRows) {
          final row = t.rows[ri];
          final view = t.rowToMap(row);
          final shouldDelete =
              s.where == null || evalPredicate(_bindExpr(s.where!), view);
          if (shouldDelete && admit()) {
            deleted.add(row);
            toDelete.add(ri);
            if (returningExprs.isNotEmpty) {
              returnedRows
                  .add(returningExprs.map((e) => e.eval(view)).toList());
            }
          }
        }
        for (var i = 0; i < t.rows.length; i++) {
          if (!toDelete.contains(i)) keep.add(t.rows[i]);
        }
      } else {
        for (final row in t.rows) {
          final view = t.rowToMap(row);
          final shouldDelete =
              s.where == null || evalPredicate(_bindExpr(s.where!), view);
          if (shouldDelete && admit()) {
            deleted.add(row);
            if (returningExprs.isNotEmpty) {
              returnedRows
                  .add(returningExprs.map((e) => e.eval(view)).toList());
            }
          } else {
            keep.add(row);
          }
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
        _recordChange(t, 'DELETE', row, null);
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

  /// Evaluate a column's `DEFAULT (<expr>)` clause in the context of the
  /// partially-built [row]. Returns the coerced value (or null).
  Object? _evalDefaultExpr(Table t, ColumnDef c, List<Object?> row) {
    final expr = _parseSelectExprCached(c.defaultExprSql!);
    final v = _bindExpr(expr).eval(t.rowToMap(row));
    return v == null ? null : coerce(v, c.type);
  }

  /// Evaluate any GENERATED ALWAYS columns in [row]; mutates [row] in place.
  void _evaluateGenerated(Table t, List<Object?> row) {
    for (var i = 0; i < t.columns.length; i++) {
      final c = t.columns[i];
      if (c.generatedExprSql == null) continue;
      final expr = _parseSelectExprCached(c.generatedExprSql!);
      final view = t.rowToMap(row);
      final v = _bindExpr(expr).eval(view);
      row[i] = v == null ? null : coerce(v, c.type);
    }
  }

  // ---------------------------------------------------------------------------
  // Constraints
  // ---------------------------------------------------------------------------
  void _enforceChecks(Table t, List<Object?> row) {
    // When `PRAGMA defer_checks = 1` is in effect inside a transaction,
    // record the table for end-of-transaction re-validation instead of
    // checking the row now. We validate every live row of the table at
    // COMMIT, which sidesteps stale intermediate row images.
    if (_deferChecks && inTransaction) {
      _deferredCheckTables.add(t.name);
      return;
    }
    _runChecks(t, row);
  }

  /// Apply all column- and table-level CHECK constraints to [row]
  /// immediately and throw on the first failure.
  void _runChecks(Table t, List<Object?> row) {
    final view = t.rowToMap(row);
    for (var i = 0; i < t.columns.length; i++) {
      final c = t.columns[i];
      if (c.checkExprSql != null) {
        final expr = _parseSelectExprCached(c.checkExprSql!);
        if (!evalPredicate(_bindExpr(expr), view)) {
          throw StateError('CHECK constraint failed on column ${c.name}');
        }
      }
    }
    for (final con in t.constraints) {
      if (con is CheckConstraint) {
        final expr = _parseSelectExprCached(con.sql);
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
    if (s.cteMaterialized.isNotEmpty) {
      _lastCteHints = Map<String, bool>.from(s.cteMaterialized);
    }
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
    // GROUPING SETS / ROLLUP / CUBE: run aggregation once per set,
    // blank out any projection that uses a grouping-key NOT in the
    // current set, and concatenate.
    if (s.groupingSets != null && s.groupingSets!.isNotEmpty) {
      return _selectGroupingSets(s, outer);
    }
    return _selectInnerCore(s, outer);
  }

  /// Expand a SELECT with GROUPING SETS / ROLLUP / CUBE into one
  /// per-set aggregation, blanking out projections of any grouping
  /// key that is NOT in the current set, and concatenate the results.
  QueryResult _selectGroupingSets(SelectStmt s, Map<String, Object?> outer) {
    final allKeys = s.groupBy;
    String key(Expr e) {
      // Structural string. Default Object.toString() collapses every
      // ColumnExpr (etc.) to "Instance of '...'", which would make
      // every key indistinguishable.
      if (e is ColumnExpr) {
        final t = e.table == null ? '' : '${e.table!.toLowerCase()}.';
        return 'col:$t${e.name.toLowerCase()}';
      }
      if (e is LiteralExpr) return 'lit:${e.value}';
      if (e is FunctionCallExpr) {
        return 'fn:${e.name.toUpperCase()}(${e.args.map(key).join(",")})';
      }
      if (e is BinaryExpr) {
        return 'bin:${e.op}(${key(e.left)},${key(e.right)})';
      }
      if (e is UnaryExpr) return 'un:${e.op}(${key(e.operand)})';
      return e.toString();
    }

    final allKeyStrings = allKeys.map(key).toSet();
    final unionRows = <List<Object?>>[];
    List<String>? cols;
    for (final set in s.groupingSets!) {
      final setKeyStrings = set.map(key).toSet();
      // Build a copy with this set's GROUP BY active and groupingSets
      // cleared so we hit the normal aggregation path.
      final perSet = SelectStmt(
        projection: s.projection,
        fromTable: s.fromTable,
        fromSubquery: s.fromSubquery,
        fromAlias: s.fromAlias,
        joins: s.joins,
        where: s.where,
        groupBy: List<Expr>.from(set),
        having: s.having,
        orderBy: const [],
        limit: null,
        offset: null,
        distinct: s.distinct,
        ctes: s.ctes,
        cteColumns: s.cteColumns,
        ctesRecursive: s.ctesRecursive,
        cteMaterialized: s.cteMaterialized,
        fromFunction: s.fromFunction,
        namedWindows: s.namedWindows,
        indexedBy: s.indexedBy,
        // groupingSets intentionally null
      );
      // Empty grouping set with no aggregates → still produce one
      // row with all NULLs. Run normally; aggregates over the whole
      // input will collapse to a single row.
      final res = _selectInnerCore(perSet, outer);
      cols ??= res.columns;
      // Compute, for each projection column, whether its expression
      // was a grouping-key in the union but NOT in this set; those
      // columns get NULL'd out for every row from this set.
      final blank = <int>[];
      // Compute, for each projection column that is a GROUPING(expr)
      // call, whether its argument is rolled up in the current set
      // (i.e. NOT in setKeyStrings). If so, overwrite the column's
      // value with 1 instead of the default 0.
      final groupingOne = <int>[];
      for (var i = 0; i < s.projection.length; i++) {
        final p = s.projection[i];
        if (p.expr == null) continue;
        final pk = key(p.expr!);
        if (allKeyStrings.contains(pk) && !setKeyStrings.contains(pk)) {
          blank.add(i);
        }
        final pe = p.expr;
        if (pe is FunctionCallExpr &&
            pe.name.toUpperCase() == 'GROUPING' &&
            pe.args.length == 1) {
          final ak = key(pe.args.first);
          if (allKeyStrings.contains(ak) && !setKeyStrings.contains(ak)) {
            groupingOne.add(i);
          }
        }
      }
      for (final row in res.rows) {
        final r = List<Object?>.from(row);
        for (final i in blank) {
          r[i] = null;
        }
        for (final i in groupingOne) {
          r[i] = 1;
        }
        unionRows.add(r);
      }
    }
    // Apply ORDER BY / LIMIT / OFFSET to the combined result if any.
    var combined = QueryResult(columns: cols ?? const [], rows: unionRows);
    if (s.orderBy.isNotEmpty || s.limit != null || s.offset != null) {
      combined = _applyCompoundOrderLimit(combined, s);
    }
    return combined;
  }

  QueryResult _selectInnerCore(SelectStmt s,
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
    var working = fromRows;
    if (s.where != null) {
      // Bind once outside the row loop — _bindExpr rebuilds the entire
      // expression tree (subqueries, casts, function args, etc.), so
      // calling it per row turns an O(N) scan into O(N * depth(expr)).
      final boundWhere = _bindExpr(s.where!, outer);
      working = fromRows.where((r) => evalPredicate(boundWhere, r)).toList();
    }

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
            // For composite ORDER BY expressions, build an evaluation scope
            // that overlays projected aliases on top of the source row so
            // `ORDER BY alias + 1` (where `alias` was introduced in the
            // SELECT list) works the same way SQLite does.
            Map<String, Object?> scope(_Pair p) {
              final m = Map<String, Object?>.from(p.src);
              for (var j = 0; j < outCols.length && j < p.row.length; j++) {
                m[outCols[j]] = p.row[j];
              }
              return m;
            }

            try {
              av = boundExpr.eval(scope(a));
              bv = boundExpr.eval(scope(b));
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
    // Prefer ANALYZE-derived stats when present — they win over the live
    // row count so a recently-analyzed snapshot drives join order even
    // while concurrent inserts perturb the live size. (Matches SQLite,
    // which only consults sqlite_stat1 at prepare time.) Paged tables
    // have no live `rows.length` so stats are the only signal.
    final stats = _stats[tableName];
    if (stats != null) return stats.rowCount;
    final t = _tables[tableName];
    if (t != null) return t.rows.length;
    final pt = _pagedTable(tableName);
    if (pt != null) return pt.length;
    // Unknown (CTE / view alias not in _tables): assume 100.
    return 100;
  }

  /// Test/diagnostics hook: the row count the planner currently sees for
  /// [tableName]. Reflects whichever signal `_tableRowCountEstimate`
  /// picks — ANALYZE stats first, then live row count, then 100.
  int plannerRowCountEstimate(String tableName) =>
      _tableRowCountEstimate(tableName);

  /// Test/diagnostics hook: the average rows-per-key the planner would
  /// charge an equality probe on `tableName.column`, mirroring the
  /// internal `_estimateEqualityHits` heuristic. Paged tables aren't
  /// supported (their stats path doesn't go through `_estimateEqualityHits`).
  int? plannerEqualityHitsEstimate(String tableName, String column) {
    final t = _tables[tableName];
    if (t == null) return null;
    return _estimateEqualityHits(t, column);
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

    // Honor `NOT INDEXED`: skip the index planner entirely.
    final hint = s.indexedBy;
    if (hint != null && hint.notIndexed) return null;

    // R-tree fast path: bbox-intersection query on an rtree virtual table.
    if (_rtreeTables.contains(t.name.toLowerCase())) {
      final rows = _planRtreeScan(t, conjuncts, s, outer);
      if (rows != null) return rows;
    }

    final prevConjuncts = _currentScanConjuncts;
    _currentScanConjuncts = conjuncts;
    try {
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
      // Expression-index plans: a conjunct `<expr> = literal` where
      // `<expr>` structurally matches a `CREATE INDEX ... ON t(<expr>)`
      // becomes a single equality probe of the expression index.
      candidates.addAll(_classifyExpressionIndexPlans(t, conjuncts));

      // Honor `INDEXED BY name`: restrict to plans using that index, and
      // bypass the cost-vs-scan threshold so the user's choice is forced.
      // If no plan can use the named index, raise like SQLite does.
      if (hint != null && hint.indexName != null) {
        final wanted = hint.indexName!.toLowerCase();
        final usable =
            candidates.where((p) => p.index.toLowerCase() == wanted).toList();
        if (usable.isEmpty) {
          throw FormatException(
              'no query solution for INDEXED BY ${hint.indexName} on ${t.name}');
        }
        usable.sort((a, b) {
          final c = a.estHits.compareTo(b.estHits);
          if (c != 0) return c;
          return (a.equalityKeys != null ? 0 : 1) -
              (b.equalityKeys != null ? 0 : 1);
        });
        final best = usable.first;
        _planTrace = [best.describe()];
        final rowIds = _executeIndexPlan(t, best);
        return [
          for (final ri in rowIds)
            {...outer, ...t.rowToMap(t.rows[ri], alias: s.fromAlias)},
        ];
      }

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
    } finally {
      _currentScanConjuncts = prevConjuncts;
    }
  }

  /// Resolve `INDEXED BY name` / `NOT INDEXED` for UPDATE / DELETE on
  /// table [t]. Returns:
  ///   * `null` to scan all rows (no hint or `NOT INDEXED`);
  ///   * the rowIds produced by the named index plan when `INDEXED BY`
  ///     is given and the WHERE has a classifiable predicate using it;
  /// Throws FormatException when `INDEXED BY name` cannot be satisfied,
  /// matching SQLite's "no query solution" behaviour.
  List<int>? _resolveHintedRowIds(Table t, Expr? where, IndexHint? hint) {
    if (hint == null) return null;
    if (hint.notIndexed) return null;
    if (hint.indexName == null) return null;
    final wanted = hint.indexName!.toLowerCase();
    // Validate the index name exists on this table at all.
    final indexExists =
        t.indexDefs.values.any((ix) => ix.name.toLowerCase() == wanted);
    if (!indexExists) {
      throw FormatException('no such index: ${hint.indexName} on ${t.name}');
    }
    if (where == null) {
      throw FormatException(
          'no query solution for INDEXED BY ${hint.indexName} on ${t.name}');
    }
    final conjuncts = _splitAndConjuncts(where);
    final prevConjuncts = _currentScanConjuncts;
    _currentScanConjuncts = conjuncts;
    try {
      final candidates = <_IndexPlan>[];
      for (final c in conjuncts) {
        final p = _classifyConjunct(t, c);
        if (p != null) candidates.add(p);
      }
      candidates.addAll(_classifyMultiColumnPlans(t, conjuncts));
      candidates.addAll(_classifyExpressionIndexPlans(t, conjuncts));
      final usable =
          candidates.where((p) => p.index.toLowerCase() == wanted).toList();
      if (usable.isEmpty) {
        throw FormatException(
            'no query solution for INDEXED BY ${hint.indexName} on ${t.name}');
      }
      usable.sort((a, b) => a.estHits.compareTo(b.estHits));
      final best = usable.first;
      _planTrace = [best.describe()];
      return _executeIndexPlan(t, best);
    } finally {
      _currentScanConjuncts = prevConjuncts;
    }
  }

  /// Bbox-intersection planner for rtree virtual tables. Looks at the
  /// query's AND-conjuncts for `<minCol> <= K` and `<maxCol> >= K`
  /// patterns (and the literal-on-left flips) per axis, builds a query
  /// bbox, and returns rows whose stored bbox intersects it. Per-row
  /// re-evaluation of the original WHERE is left to the caller, so it's
  /// safe to be conservative: unrecognised shapes just fall through.
  List<Map<String, Object?>>? _planRtreeScan(
      Table t, List<Expr> conjuncts, SelectStmt s, Map<String, Object?> outer) {
    final dims = (t.columns.length - 1) ~/ 2;
    if (dims <= 0) return null;
    // Lower/upper bounds of the query bbox per axis; default to ±∞.
    final qmin = List<double>.filled(dims, double.negativeInfinity);
    final qmax = List<double>.filled(dims, double.infinity);
    var anyBoundSeen = false;
    // Column name (lowercased) -> (axis, isMinCol).
    final colMap = <String, (int, bool)>{};
    for (var d = 0; d < dims; d++) {
      colMap[t.columns[1 + d * 2].name.toLowerCase()] = (d, true);
      colMap[t.columns[2 + d * 2].name.toLowerCase()] = (d, false);
    }
    for (final c in conjuncts) {
      if (c is! BinaryExpr) continue;
      final op = c.op;
      if (op != '<' && op != '<=' && op != '>' && op != '>=' && op != '=') {
        continue;
      }
      String? colName;
      double? lit;
      var flipped = false;
      if (c.left is ColumnExpr && _isConstExpr(c.right)) {
        colName = (c.left as ColumnExpr).name.toLowerCase();
        final v = _evalConst(c.right);
        if (v is num) lit = v.toDouble();
      } else if (c.right is ColumnExpr && _isConstExpr(c.left)) {
        colName = (c.right as ColumnExpr).name.toLowerCase();
        final v = _evalConst(c.left);
        if (v is num) lit = v.toDouble();
        flipped = true;
      }
      if (colName == null || lit == null) continue;
      final info = colMap[colName];
      if (info == null) continue;
      final (axis, _) = info;
      final effOp = flipped ? _flipComparison(op) : op;
      // `xMIN <= K` => bbox.minOf(axis) <= K, i.e. xMIN is bounded above
      //                by K. Since we want intersection with query box
      //                [qmin, qmax], that means qmax[axis] = K.
      // `xMAX >= K` => bbox.maxOf(axis) >= K, so qmin[axis] = K.
      // `xMIN = K`  => qmax[axis] = min(qmax,K) (xMIN cannot exceed K).
      // `xMAX = K`  => qmin[axis] = max(qmin,K).
      final isMinCol = info.$2;
      switch (effOp) {
        case '<':
        case '<=':
          if (isMinCol && lit < qmax[axis]) qmax[axis] = lit;
          anyBoundSeen = true;
          break;
        case '>':
        case '>=':
          if (!isMinCol && lit > qmin[axis]) qmin[axis] = lit;
          anyBoundSeen = true;
          break;
        case '=':
          if (isMinCol && lit < qmax[axis]) qmax[axis] = lit;
          if (!isMinCol && lit > qmin[axis]) qmin[axis] = lit;
          anyBoundSeen = true;
          break;
      }
    }
    if (!anyBoundSeen) return null;
    // Replace ±∞ with the data extent so BBox.fromMinMax accepts the box.
    for (var d = 0; d < dims; d++) {
      if (qmin[d].isInfinite) qmin[d] = -1e308;
      if (qmax[d].isInfinite) qmax[d] = 1e308;
      if (qmin[d] > qmax[d]) return const <Map<String, Object?>>[];
    }
    final idx = _rtreeIndexFor(t);
    final query = BBox.fromMinMax(qmin, qmax);
    final hits = idx.search(query).toSet();
    if (hits.isEmpty) return const <Map<String, Object?>>[];
    _planTrace = ['SEARCH ${t.name} USING RTREE'];
    final out = <Map<String, Object?>>[];
    for (final row in t.rows) {
      final rowid = (row[0] as num).toInt();
      if (!hits.contains(rowid)) continue;
      out.add({...outer, ...t.rowToMap(row, alias: s.fromAlias)});
    }
    return out;
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
      if (def.exprSql != null) continue;
      if (def.columns.length < 2) continue;
      if (!_partialIndexUsable(def)) continue;
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

  /// Cached parsed ASTs of `CREATE INDEX ... ON t(<expr>)` index
  /// expressions, keyed by index name.
  final Map<String, Expr> _exprIndexAstCache = <String, Expr>{};

  /// Build single-key equality plans for expression indexes. Scans
  /// [conjuncts] for `<expr> = <literal>` (or the literal-on-left form)
  /// where `<expr>` structurally matches one of [t]'s expression indexes.
  List<_IndexPlan> _classifyExpressionIndexPlans(
      Table t, List<Expr> conjuncts) {
    final out = <_IndexPlan>[];
    for (final def in t.indexDefs.values) {
      if (def.exprSql == null) continue;
      if (!_partialIndexUsable(def)) continue;
      final ast = _exprIndexAstCache.putIfAbsent(def.name, () {
        final stmt = Parser.fromString('SELECT ${def.exprSql}').parseStatement()
            as SelectStmt;
        return stmt.projection.first.expr!;
      });
      for (final c in conjuncts) {
        if (c is! BinaryExpr || c.op != '=') continue;
        Expr? other;
        if (_exprStructEq(c.left, ast) && _isConstExpr(c.right)) {
          other = c.right;
        } else if (_exprStructEq(c.right, ast) && _isConstExpr(c.left)) {
          other = c.left;
        }
        if (other == null) continue;
        final key = _evalConst(other);
        if (key == null) continue;
        out.add(_IndexPlan.equality(
          table: t.name,
          index: def.name,
          column: def.exprSql!,
          equalityKey: key,
          estHits: _estimateEqualityHits(t, def.column),
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
    // LIKE 'prefix%' on a BINARY-collated indexed text column rewrites to
    // a half-open range scan over [prefix, prefix++). When the pattern
    // contains '%' or '_' anywhere before the trailing '%' (or contains
    // a backslash-escape) we conservatively decline.
    if (conjunct is BinaryExpr && conjunct.op == 'LIKE') {
      if (conjunct.left is! ColumnExpr) return null;
      if (!_isConstExpr(conjunct.right)) return null;
      final col = (conjunct.left as ColumnExpr).name;
      final idx = _findIndexForColumn(t, col);
      if (idx == null) return null;
      if (idx.columns.length > 1) return null;
      // This engine's LIKE is case-sensitive (== BINARY semantics), so a
      // BINARY-collated index is safe to range-scan. NOCASE indexes store
      // lower-cased keys; the pattern's case would have to be normalised
      // first, but since LIKE is already case-sensitive here a NOCASE
      // index can never be used safely for LIKE prefix.
      final isNocase = idx.collations.isNotEmpty &&
          idx.collations[0].toUpperCase() == 'NOCASE';
      if (isNocase) return null;
      final pat = _evalConst(conjunct.right);
      if (pat is! String) return null;
      final prefix = _likePrefix(pat);
      if (prefix == null || prefix.isEmpty) return null;
      // Build the half-open range [prefix, succ(prefix)).
      final hi = _stringSuccessor(prefix);
      return _IndexPlan.range(
          table: t.name,
          index: idx.name,
          column: col,
          lo: prefix,
          hi: hi,
          loInclusive: true,
          hiInclusive: false,
          estHits: _estimateRangeHits(t));
    }
    return null;
  }

  /// If [pattern] is `prefix%` with no LIKE wildcards (`%`, `_`) inside
  /// `prefix`, returns the prefix. Otherwise returns null. Recognises a
  /// trailing `%` (zero or more chars) — every other LIKE pattern is
  /// rejected.
  String? _likePrefix(String pattern) {
    if (pattern.isEmpty) return null;
    if (!pattern.endsWith('%')) return null;
    final head = pattern.substring(0, pattern.length - 1);
    if (head.contains('%') || head.contains('_')) return null;
    return head;
  }

  /// Lexicographic successor of [s]: the smallest string strictly greater
  /// than [s] under string compareTo. Implemented by incrementing the
  /// final code unit; when the final unit is U+FFFF we append a
  /// zero-width sentinel character so the bound still satisfies s < succ.
  String _stringSuccessor(String s) {
    if (s.isEmpty) return '\u0000';
    final last = s.codeUnitAt(s.length - 1);
    if (last < 0xFFFF) {
      return s.substring(0, s.length - 1) + String.fromCharCode(last + 1);
    }
    return '$s\u0000';
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
          d.columns.length == 1 &&
          d.column.toLowerCase() == lc &&
          _partialIndexUsable(d)) {
        return d;
      }
    }
    // Fallback: a multi-column index whose LEADING column matches. The
    // executor handles this via a prefix scan over the composite-key
    // SplayTreeMap (see [_executeIndexPlan]).
    for (final d in t.indexDefs.values) {
      if (d.exprSql == null &&
          d.columns.length > 1 &&
          d.columns.first.toLowerCase() == lc &&
          _partialIndexUsable(d)) {
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
      // Bind ON once per join — _bindExpr rebuilds the whole tree, so
      // calling it per (l, r) pair turned a 1k x 1k join into a million
      // tree rebuilds.
      final boundOn = onExpr == null ? null : _bindExpr(onExpr);

      // Hash-join fast path: when ON is a conjunction of equalities and
      // every equality has one side that is a bare ColumnExpr qualified
      // by the right-hand alias / table, we can index `right` by the
      // tuple of those right-side keys and probe per left row instead of
      // doing a full nested loop.
      final rightAlias = (j.alias ?? j.table)?.toLowerCase();
      final hashPlan = (j.type == 'INNER' || j.type == 'LEFT') &&
              boundOn != null &&
              rightAlias != null
          ? _tryEquiHashPlan(boundOn, rightAlias)
          : null;
      if (hashPlan != null) {
        // Build hash on right side keyed by the tuple of right-side
        // ColumnExpr values.
        final rightKeyExprs = hashPlan.rightKeyExprs;
        final leftKeyExprs = hashPlan.leftKeyExprs;
        final residual = hashPlan.residual;
        final hash = <_TupleKey, List<Map<String, Object?>>>{};
        for (final r in right) {
          final keyVals = [for (final ke in rightKeyExprs) ke.eval(r)];
          if (keyVals.contains(null)) continue; // SQL NULL never equi-matches
          final k = _TupleKey(keyVals);
          (hash[k] ??= []).add(r);
        }
        for (final l in working) {
          final probeVals = [for (final ke in leftKeyExprs) ke.eval(l)];
          var matched = false;
          if (!probeVals.contains(null)) {
            final bucket = hash[_TupleKey(probeVals)];
            if (bucket != null) {
              for (final r in bucket) {
                final combined = {...l, ...r};
                if (residual == null || evalPredicate(residual, combined)) {
                  next.add(combined);
                  matched = true;
                }
              }
            }
          }
          if (!matched && j.type == 'LEFT') {
            next.add({...l, ..._nullsForJoin(j)});
          }
        }
        working = next;
        continue;
      }

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
              if (boundOn != null && evalPredicate(boundOn, combined)) {
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
              if (boundOn != null && evalPredicate(boundOn, combined)) {
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
              if (boundOn != null && evalPredicate(boundOn, combined)) {
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
              if (boundOn != null && evalPredicate(boundOn, combined)) {
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

  /// Walks an AND-conjunction. Returns a hash-join plan iff every leaf
  /// is `=` with one side being a bare ColumnExpr qualified by [rightAlias]
  /// (and the other side referencing the left set, i.e. NOT qualified by
  /// the right alias). Otherwise returns null and the caller falls back
  /// to nested-loop. Non-equality conjuncts are collected into [residual]
  /// and re-evaluated after the hash probe matches a bucket.
  _HashJoinPlan? _tryEquiHashPlan(Expr boundOn, String rightAlias) {
    final leftKeys = <Expr>[];
    final rightKeys = <Expr>[];
    final residuals = <Expr>[];
    bool walk(Expr e) {
      if (e is BinaryExpr && e.op == 'AND') {
        return walk(e.left) && walk(e.right);
      }
      if (e is BinaryExpr && e.op == '=') {
        final lIsRight = _isQualifiedBy(e.left, rightAlias);
        final rIsRight = _isQualifiedBy(e.right, rightAlias);
        if (lIsRight && !rIsRight && !_referencesAlias(e.right, rightAlias)) {
          rightKeys.add(e.left);
          leftKeys.add(e.right);
          return true;
        }
        if (rIsRight && !lIsRight && !_referencesAlias(e.left, rightAlias)) {
          rightKeys.add(e.right);
          leftKeys.add(e.left);
          return true;
        }
      }
      // Anything else is a residual filter — only safe if it doesn't
      // need both sides correlated through the hash key (which it
      // might). We allow residuals that DO reference the right alias
      // because they'll still be evaluated against `combined`.
      residuals.add(e);
      return true;
    }

    final ok = walk(boundOn);
    if (!ok || rightKeys.isEmpty) return null;
    Expr? residual;
    for (final r in residuals) {
      residual = residual == null ? r : BinaryExpr('AND', residual, r);
    }
    return _HashJoinPlan(leftKeys, rightKeys, residual);
  }

  /// True iff [e] is a bare `ColumnExpr` whose `.table` (case-insensitive)
  /// equals [alias].
  bool _isQualifiedBy(Expr e, String alias) {
    return e is ColumnExpr &&
        e.table != null &&
        e.table!.toLowerCase() == alias;
  }

  /// True iff any ColumnExpr inside [e] is qualified by [alias].
  bool _referencesAlias(Expr e, String alias) {
    if (e is ColumnExpr) {
      return e.table != null && e.table!.toLowerCase() == alias;
    }
    if (e is BinaryExpr) {
      return _referencesAlias(e.left, alias) ||
          _referencesAlias(e.right, alias);
    }
    if (e is UnaryExpr) return _referencesAlias(e.operand, alias);
    if (e is FunctionCallExpr) {
      for (final a in e.args) {
        if (_referencesAlias(a, alias)) return true;
      }
      return false;
    }
    if (e is CastExpr) return _referencesAlias(e.expr, alias);
    if (e is BetweenExpr) {
      return _referencesAlias(e.value, alias) ||
          _referencesAlias(e.low, alias) ||
          _referencesAlias(e.high, alias);
    }
    if (e is InExpr) {
      if (_referencesAlias(e.value, alias)) return true;
      for (final v in e.values) {
        if (_referencesAlias(v, alias)) return true;
      }
      return false;
    }
    return false;
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
    // SQLite schema introspection: sqlite_master / sqlite_schema /
    // sqlite_temp_master. We synthesise rows from the in-memory schema.
    final lower = name.toLowerCase();
    if (lower == 'sqlite_master' ||
        lower == 'sqlite_schema' ||
        lower == 'sqlite_temp_master' ||
        lower == 'sqlite_temp_schema') {
      return _sqliteMasterRows(name, alias, outer);
    }
    if (lower == 'sqlite_stmt') {
      return _sqliteStmtRows(name, alias, outer);
    }
    if (lower == 'sqlite_dbpage') {
      return _sqliteDbpageRows(name, alias, outer);
    }
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
      final outerEmpty = outer.isEmpty;
      // Fast path: no outer scope to splat into every row. The default
      // rowToMap construction already avoids the intermediate copy.
      if (outerEmpty) {
        final out = <Map<String, Object?>>[];
        for (final r in t.rows) {
          out.add(t.rowToMap(r, alias: alias));
        }
        return out;
      }
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

  /// Build the schema-introspection rows for `sqlite_master` /
  /// `sqlite_schema`. One row per base table, view, and named index;
  /// columns: type, name, tbl_name, rootpage (always 0), sql.
  List<Map<String, Object?>> _sqliteMasterRows(
      String name, String? alias, Map<String, Object?> outer) {
    final rows = <Map<String, Object?>>[];
    void emit(String type, String objName, String tblName, String? sql) {
      final base = <String, Object?>{
        'type': type,
        'name': objName,
        'tbl_name': tblName,
        'rootpage': 0,
        'sql': sql,
      };
      final m = <String, Object?>{...outer, ...base};
      for (final e in base.entries) {
        m['$name.${e.key}'] = e.value;
        if (alias != null) m['$alias.${e.key}'] = e.value;
      }
      rows.add(m);
    }

    final tableNames = _tables.keys.toList()..sort();
    for (final tn in tableNames) {
      final t = _tables[tn]!;
      emit('table', tn, tn, _reconstructCreateTableSql(t));
      for (final ix in t.indexDefs.keys) {
        emit('index', ix, tn, null);
      }
    }
    final viewNames = _views.keys.toList()..sort();
    for (final vn in viewNames) {
      final sql = _viewSql[vn];
      emit('view', vn, vn, sql == null ? null : 'CREATE VIEW $vn AS $sql');
    }
    return rows;
  }

  /// Best-effort CREATE TABLE SQL reconstruction used in sqlite_master.
  String _reconstructCreateTableSql(Table t) {
    final cols = <String>[];
    for (final c in t.columns) {
      final parts = <String>[c.name];
      if (c.type != DataType.any) {
        parts.add(c.type.name.toUpperCase());
      }
      if (c.primaryKey) parts.add('PRIMARY KEY');
      if (c.autoIncrement) parts.add('AUTOINCREMENT');
      if (c.notNull) parts.add('NOT NULL');
      if (c.unique) parts.add('UNIQUE');
      cols.add(parts.join(' '));
    }
    final tail = <String>[];
    if (t.withoutRowid) tail.add('WITHOUT ROWID');
    if (t.strict) tail.add('STRICT');
    final tailStr = tail.isEmpty ? '' : ' ${tail.join(', ')}';
    return 'CREATE TABLE ${t.name}(${cols.join(', ')})$tailStr';
  }

  /// Synthesize SQLite's `sqlite_stmt` virtual table. We don't keep a
  /// per-statement bytecode cache, so this is always empty but presents
  /// the right column shape so SELECTs against it succeed.
  List<Map<String, Object?>> _sqliteStmtRows(
      String name, String? alias, Map<String, Object?> outer) {
    const cols = <String>[
      'sql',
      'ncol',
      'ro',
      'busy',
      'nscan',
      'nsort',
      'naidx',
      'nstep',
      'reprep',
      'run',
      'mem',
    ];
    final empty = <Map<String, Object?>>[];
    // Column-shape advertisement only; rows always empty.
    final qual = alias ?? name;
    for (final r in empty) {
      for (final c in cols) {
        r['$qual.$c'] = r[c];
      }
    }
    return empty;
  }

  /// Synthesize SQLite's `sqlite_dbpage` virtual table. We expose page
  /// numbers 1..page_count with NULL data, so SELECT count(*) and
  /// SELECT pgno work but raw page bytes are not surfaced.
  List<Map<String, Object?>> _sqliteDbpageRows(
      String name, String? alias, Map<String, Object?> outer) {
    final pageCount = (_pragmas['page_count'] as num?)?.toInt() ?? 0;
    final qual = alias ?? name;
    final out = <Map<String, Object?>>[];
    for (var p = 1; p <= pageCount; p++) {
      final base = <String, Object?>{'pgno': p, 'data': null, 'schema': 'main'};
      final m = <String, Object?>{...outer, ...base};
      for (final e in base.entries) {
        m['$name.${e.key}'] = e.value;
        if (alias != null) m['$alias.${e.key}'] = e.value;
      }
      m['$qual.pgno'] = p;
      out.add(m);
    }
    return out;
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
      case 'GENERATE_SERIES':
        rows = _generateSeriesRows(args);
        break;
      default:
        if (upper.startsWith('PRAGMA_')) {
          rows = _pragmaTableFunctionRows(upper, args);
          break;
        }
        throw StateError('Unknown table-valued function: ${fn.name}');
    }
    return rows
        .map((r) => <String, Object?>{
              ...r,
              for (final e in r.entries) '$qual.${e.key}': e.value,
            })
        .toList();
  }

  /// Synthesise rows for `pragma_table_info('t')` style table-valued
  /// PRAGMA wrappers by reusing [_pragma]'s introspection logic.
  List<Map<String, Object?>> _pragmaTableFunctionRows(
      String upper, List<Object?> args) {
    final pragmaName = upper.substring('PRAGMA_'.length).toLowerCase();
    final value = args.isNotEmpty ? args[0]?.toString() : null;
    final result = _pragma(PragmaStmt(pragmaName, value));
    return [
      for (final row in result.rows)
        <String, Object?>{
          for (var i = 0; i < result.columns.length; i++)
            result.columns[i]: i < row.length ? row[i] : null,
        }
    ];
  }

  /// Implementation of `generate_series(start, stop[, step])` table-valued
  /// function. Yields one row per integer with column `value`. `step`
  /// defaults to 1; a negative step counts down. An empty/invalid range
  /// yields no rows.
  List<Map<String, Object?>> _generateSeriesRows(List<Object?> args) {
    if (args.isEmpty || args[0] == null) return const [];
    final start = (args[0] as num).toInt();
    final stop =
        args.length >= 2 && args[1] != null ? (args[1] as num).toInt() : start;
    final step =
        args.length >= 3 && args[2] != null ? (args[2] as num).toInt() : 1;
    if (step == 0) return const [];
    final out = <Map<String, Object?>>[];
    if (step > 0) {
      for (var v = start; v <= stop; v += step) {
        out.add({'value': v});
      }
    } else {
      for (var v = start; v >= stop; v += step) {
        out.add({'value': v});
      }
    }
    return out;
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
    // Resolve `GROUP BY <int>` to the underlying projection expression
    // (1-based, like ORDER BY positions). Non-integer GROUP BY items are
    // bound and evaluated as usual.
    Expr resolveGroupExpr(Expr g) {
      if (g is LiteralExpr && g.value is int) {
        final pos = (g.value as int) - 1;
        if (pos < 0 || pos >= s.projection.length) {
          throw StateError('GROUP BY position out of range');
        }
        final item = s.projection[pos];
        if (item.isStar || item.expr == null) {
          throw StateError('GROUP BY position refers to *');
        }
        return _bindExpr(item.expr!);
      }
      return _bindExpr(g);
    }

    final boundGroup = s.groupBy.map(resolveGroupExpr).toList();
    // Group rows by GROUP BY key (empty group-by => single group).
    final groups = <String, List<Map<String, Object?>>>{};
    final groupKeys = <String, List<Object?>>{};
    final groupOrder = <String>[];
    for (final r in rows) {
      final keyVals = boundGroup.map((g) => g.eval(r)).toList();
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
    if (e.aggOrderBy != null && e.aggOrderBy!.isNotEmpty) {
      final bound = [
        for (final ob in e.aggOrderBy!) (_bindExpr(ob.expr), ob),
      ];
      grp = List<Map<String, Object?>>.from(grp)
        ..sort((a, b) {
          for (final pair in bound) {
            final ex = pair.$1;
            final ob = pair.$2;
            final av = ex.eval(a);
            final bv = ex.eval(b);
            final nullsFirst = ob.nullsFirst ?? !ob.descending;
            int cmp;
            if (av == null && bv == null) {
              cmp = 0;
            } else if (av == null) {
              cmp = nullsFirst ? -1 : 1;
            } else if (bv == null) {
              cmp = nullsFirst ? 1 : -1;
            } else {
              cmp = sqlCompare(av, bv);
            }
            if (cmp != 0) return ob.descending ? -cmp : cmp;
          }
          return 0;
        });
    }
    switch (e.name) {
      case 'COUNT':
        if (e.isStarArg) return grp.length;
        if (e.args.isEmpty) return grp.length;
        final boundArg = _bindExpr(e.args.first);
        final values = grp.map((r) => boundArg.eval(r)).where((v) => v != null);
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
      case 'TOTAL':
        {
          // SQLite TOTAL: always returns a float, returns 0.0 on empty.
          var acc = 0.0;
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (v is! num) {
              throw StateError('TOTAL requires numeric, got ${v.runtimeType}');
            }
            acc += v.toDouble();
          }
          return acc;
        }
      case 'GROUP_CONCAT':
      case 'STRING_AGG':
      case 'LISTAGG':
        {
          // GROUP_CONCAT(expr [, sep]) -- defaults to ','.
          // STRING_AGG(expr, sep) -- separator is required, but we accept
          // a missing one too for symmetry.
          String sep = ',';
          if (e.args.length > 1) {
            final s = _bindExpr(e.args[1]).eval(grp.isEmpty ? {} : grp.first);
            sep = s?.toString() ?? ',';
          }
          final parts = <String>[];
          if (e.args.isNotEmpty) {
            final arg = _bindExpr(e.args.first);
            if (e.distinct) {
              final seen = <String>{};
              for (final r in grp) {
                final v = arg.eval(r);
                if (v == null) continue;
                final s = v.toString();
                if (seen.add(s)) parts.add(s);
              }
            } else {
              for (final r in grp) {
                final v = arg.eval(r);
                if (v == null) continue;
                parts.add(v.toString());
              }
            }
          }
          if (parts.isEmpty) return null;
          return parts.join(sep);
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
      case 'JSONB_GROUP_ARRAY':
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
      case 'JSONB_GROUP_OBJECT':
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
      case 'BIT_AND':
        {
          int? acc;
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (v is! num) {
              throw StateError('BIT_AND requires integer');
            }
            final iv = v.toInt();
            acc = acc == null ? iv : (acc & iv);
          }
          return acc;
        }
      case 'BIT_OR':
        {
          int? acc;
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (v is! num) {
              throw StateError('BIT_OR requires integer');
            }
            final iv = v.toInt();
            acc = acc == null ? iv : (acc | iv);
          }
          return acc;
        }
      case 'BIT_XOR':
        {
          int? acc;
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (v is! num) {
              throw StateError('BIT_XOR requires integer');
            }
            final iv = v.toInt();
            acc = acc == null ? iv : (acc ^ iv);
          }
          return acc;
        }
      case 'ANY_VALUE':
        {
          for (final v in _aggValues(e, grp)) {
            if (v != null) return v;
          }
          return null;
        }
      case 'MEDIAN':
        {
          final nums = <double>[];
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (v is! num) {
              throw StateError('MEDIAN requires numeric');
            }
            nums.add(v.toDouble());
          }
          if (nums.isEmpty) return null;
          nums.sort();
          final mid = nums.length ~/ 2;
          if (nums.length.isOdd) return nums[mid];
          return (nums[mid - 1] + nums[mid]) / 2;
        }
      case 'STDDEV':
      case 'STDDEV_SAMP':
      case 'STDDEV_POP':
      case 'VARIANCE':
      case 'VAR_SAMP':
      case 'VAR_POP':
        {
          final nums = <double>[];
          for (final v in _aggValues(e, grp)) {
            if (v == null) continue;
            if (v is! num) {
              throw StateError('${e.name} requires numeric');
            }
            nums.add(v.toDouble());
          }
          if (nums.isEmpty) return null;
          final mean = nums.reduce((a, b) => a + b) / nums.length;
          var sumSq = 0.0;
          for (final x in nums) {
            final d = x - mean;
            sumSq += d * d;
          }
          final isPop = e.name == 'STDDEV_POP' || e.name == 'VAR_POP';
          final denom = isPop ? nums.length : nums.length - 1;
          if (denom <= 0) return null;
          final variance = sumSq / denom;
          final isVar = e.name.startsWith('VAR');
          return isVar ? variance : math.sqrt(variance);
        }
      case 'COVAR_POP':
      case 'COVAR_SAMP':
      case 'CORR':
        {
          if (e.args.length < 2) return null;
          final xExpr = _bindExpr(e.args[0]);
          final yExpr = _bindExpr(e.args[1]);
          final xs = <double>[];
          final ys = <double>[];
          for (final r in grp) {
            final xv = xExpr.eval(r);
            final yv = yExpr.eval(r);
            if (xv == null || yv == null) continue;
            if (xv is! num || yv is! num) {
              throw StateError('${e.name} requires numeric');
            }
            xs.add(xv.toDouble());
            ys.add(yv.toDouble());
          }
          if (xs.isEmpty) return null;
          final mx = xs.reduce((a, b) => a + b) / xs.length;
          final my = ys.reduce((a, b) => a + b) / ys.length;
          var sxy = 0.0;
          var sxx = 0.0;
          var syy = 0.0;
          for (var i = 0; i < xs.length; i++) {
            final dx = xs[i] - mx;
            final dy = ys[i] - my;
            sxy += dx * dy;
            sxx += dx * dx;
            syy += dy * dy;
          }
          if (e.name == 'CORR') {
            final denom = math.sqrt(sxx * syy);
            if (denom == 0) return null;
            return sxy / denom;
          }
          final denom = e.name == 'COVAR_POP' ? xs.length : xs.length - 1;
          if (denom <= 0) return null;
          return sxy / denom;
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
          // RANGE / GROUPS: tie-aware behaviour.
          //
          // RANGE n PRECEDING/FOLLOWING uses the ORDER BY value's
          // numeric distance from the current row (one ORDER BY key
          // required). GROUPS n PRECEDING/FOLLOWING counts peer groups.
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

          // RANGE numeric-distance scan. Walks outward from k stopping
          // when |key(j) - key(k)| > off.
          int rangeBound(num off, {required bool forward}) {
            if (spec.orderBy.length != 1) {
              // Fall back to ROWS-style offset when ORDER BY arity != 1.
              return forward
                  ? (k + off.toInt()).clamp(0, ordered.length - 1)
                  : (k - off.toInt()).clamp(0, ordered.length - 1);
            }
            final ob = spec.orderBy.single;
            final keyK = ob.expr.eval(partRows[k]);
            if (keyK is! num) {
              // Non-numeric ORDER BY → degenerate to peer-of-current.
              return forward ? peerEnd(k) : peerStart(k);
            }
            // Forward = following (positive direction in undescended
            // ordering). When ORDER BY is DESC the direction is flipped.
            final dir = ob.descending ? -1 : 1;
            final desired = forward ? keyK + dir * off : keyK - dir * off;
            var best = k;
            if (forward) {
              for (var i = k; i < ordered.length; i++) {
                final v = ob.expr.eval(partRows[i]);
                if (v is! num) break;
                final inWindow =
                    ob.descending ? v >= desired - 1e-12 : v <= desired + 1e-12;
                if (inWindow) {
                  best = i;
                } else {
                  break;
                }
              }
            } else {
              for (var i = k; i >= 0; i--) {
                final v = ob.expr.eval(partRows[i]);
                if (v is! num) break;
                final inWindow =
                    ob.descending ? v <= desired + 1e-12 : v >= desired - 1e-12;
                if (inWindow) {
                  best = i;
                } else {
                  break;
                }
              }
            }
            return best;
          }

          // GROUPS counts peer groups in either direction.
          int groupsBound(int off, {required bool forward}) {
            var idx = k;
            var moved = 0;
            while (moved < off &&
                (forward ? idx + 1 < ordered.length : idx - 1 >= 0)) {
              final next = forward ? idx + 1 : idx - 1;
              if (!sameOrderKey(ordered[idx], ordered[next])) moved++;
              idx = next;
            }
            return forward ? peerEnd(idx) : peerStart(idx);
          }

          int boundFor(FrameBound b, {required bool isStart}) {
            switch (b.kind) {
              case FrameBoundKind.unboundedPreceding:
                return 0;
              case FrameBoundKind.preceding:
                final off = b.offset!.eval(const {}) as num;
                if (frame.mode == FrameMode.range) {
                  final t = rangeBound(off, forward: false);
                  return isStart ? peerStart(t) : peerEnd(t);
                } else {
                  // GROUPS
                  return groupsBound(off.toInt(), forward: false);
                }
              case FrameBoundKind.currentRow:
                return isStart ? peerStart(k) : peerEnd(k);
              case FrameBoundKind.following:
                final off = b.offset!.eval(const {}) as num;
                if (frame.mode == FrameMode.range) {
                  final t = rangeBound(off, forward: true);
                  return isStart ? peerStart(t) : peerEnd(t);
                } else {
                  return groupsBound(off.toInt(), forward: true);
                }
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
        case 'STRING_AGG':
        case 'LISTAGG':
        case 'JSON_GROUP_ARRAY':
        case 'JSON_GROUP_OBJECT':
        case 'JSONB_GROUP_ARRAY':
        case 'JSONB_GROUP_OBJECT':
        case 'BIT_AND':
        case 'BIT_OR':
        case 'BIT_XOR':
        case 'ANY_VALUE':
        case 'MEDIAN':
        case 'STDDEV':
        case 'STDDEV_POP':
        case 'STDDEV_SAMP':
        case 'VARIANCE':
        case 'VAR_POP':
        case 'VAR_SAMP':
        case 'COVAR_POP':
        case 'COVAR_SAMP':
        case 'CORR':
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
    if (e is UnaryExpr) {
      return UnaryExpr(e.op, _bindExpr(e.operand, outerScope));
    }
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
    if (e is CastExpr) {
      return CastExpr(_bindExpr(e.expr, outerScope), e.targetType);
    }
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
              : _bindExpr(e.filterExpr!, outerScope),
          aggOrderBy: e.aggOrderBy);
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
    _pagedDirty.clear();
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
    // Replay any deferred CHECK validations: every row of every table
    // that had a mutating operation during the transaction is re-checked
    // against its CHECK constraints.
    if (_deferredCheckTables.isNotEmpty && !_readOnlySnapshot) {
      final queued = Set<String>.from(_deferredCheckTables);
      _deferredCheckTables.clear();
      for (final name in queued) {
        final t = _tables[name];
        if (t == null) continue;
        try {
          for (final r in t.rows) {
            _runChecks(t, r);
          }
        } catch (e) {
          _rollback();
          throw StateError('DEFERRED CHECK constraint failed on commit: $e');
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
    // Hand the dirty paged tables to the async drainer so executeStmt
    // can await their commits after _dispatch returns.
    _pendingPagedCommit.addAll(_pagedDirty);
    _pagedDirty.clear();
    _snapshot = null;
    _viewSnapshot = null;
    return QueryResult.message('Transaction committed');
  }

  QueryResult _rollback() {
    if (!inTransaction) throw StateError('No transaction in progress');
    _deferredFkChecks.clear();
    _deferredCheckTables.clear();
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
    // Hand the dirty paged tables to the async drainer so executeStmt
    // can await their rollbacks after _dispatch returns.
    _pendingPagedRollback.addAll(_pagedDirty);
    _pagedDirty.clear();
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
    if (s.isQueryPlan) {
      final rows = <List<Object?>>[];
      _explainQueryPlanInto(s.target, parentId: 0, nextId: [1], out: rows);
      _lastBytecode = const [];
      return QueryResult(
        columns: const ['id', 'parent', 'notused', 'detail'],
        rows: rows,
      );
    }
    final code = _explainBytecode(s.target);
    _lastBytecode = code;
    return QueryResult(
      columns: const [
        'addr',
        'opcode',
        'p1',
        'p2',
        'p3',
        'p4',
        'p5',
        'comment',
      ],
      rows: [for (final op in code) op.toList()],
    );
  }

  /// Buffer of the most recently emitted EXPLAIN bytecode rows; surfaced
  /// by `PRAGMA vdbe_listing` so tools can re-read the last plan.
  List<List<Object?>> _lastBytecode = const [];

  /// Walk a statement and emit SQLite-shaped EXPLAIN QUERY PLAN rows.
  void _explainQueryPlanInto(
    Statement stmt, {
    required int parentId,
    required List<int> nextId,
    required List<List<Object?>> out,
  }) {
    if (stmt is SelectStmt) {
      final myId = nextId[0]++;
      final t = _tables[stmt.fromTable];
      String detail;
      if (t == null) {
        detail = 'SCAN ${stmt.fromTable}';
      } else if (stmt.where != null) {
        // Look for an index that covers any equality column in WHERE.
        final used = _pickIndexForWhere(t, stmt.where!);
        detail = used == null
            ? 'SCAN ${stmt.fromTable}'
            : 'SEARCH ${stmt.fromTable} USING INDEX $used';
      } else {
        detail = 'SCAN ${stmt.fromTable}';
      }
      out.add([myId, parentId, 0, detail]);
      for (final j in stmt.joins) {
        final jId = nextId[0]++;
        out.add([jId, myId, 0, '${j.type} JOIN ${j.table}']);
      }
      if (stmt.groupBy.isNotEmpty) {
        out.add([nextId[0]++, myId, 0, 'USE TEMP B-TREE FOR GROUP BY']);
      }
      if (stmt.orderBy.isNotEmpty) {
        out.add([nextId[0]++, myId, 0, 'USE TEMP B-TREE FOR ORDER BY']);
      }
      if (stmt.setOp != null && stmt.setOpRight != null) {
        out.add([nextId[0]++, myId, 0, 'COMPOUND ${stmt.setOp}']);
        _explainQueryPlanInto(stmt.setOpRight!,
            parentId: myId, nextId: nextId, out: out);
      }
    } else {
      out.add([nextId[0]++, parentId, 0, stmt.runtimeType.toString()]);
    }
  }

  /// Best-effort: pick an index whose first column appears in an equality
  /// against a literal in [where]. Returns the index name, or null.
  String? _pickIndexForWhere(Table t, Expr where) {
    final eqCols = <String>{};
    void walk(Expr e) {
      if (e is BinaryExpr) {
        if (e.op == '=' || e.op.toUpperCase() == 'IS') {
          if (e.left is ColumnExpr && e.right is LiteralExpr) {
            eqCols.add((e.left as ColumnExpr).name.toLowerCase());
          } else if (e.right is ColumnExpr && e.left is LiteralExpr) {
            eqCols.add((e.right as ColumnExpr).name.toLowerCase());
          }
        } else if (e.op.toUpperCase() == 'AND') {
          walk(e.left);
          walk(e.right);
        }
      }
    }

    walk(where);
    if (eqCols.isEmpty) return null;
    for (final entry in t.indexDefs.entries) {
      if (entry.value.columns.isNotEmpty &&
          eqCols.contains(entry.value.columns.first.toLowerCase())) {
        return entry.key;
      }
    }
    return null;
  }

  /// Synthesize a SQLite-shaped VDBE bytecode listing for [stmt]. We
  /// don't run a real VDBE, but this approximates the shape of the
  /// bytecode that SQLite would emit for the same logical plan, so
  /// tools that consume `EXPLAIN`'s 8-column format keep working.
  List<List<Object?>> _explainBytecode(Statement stmt) {
    final rows = <List<Object?>>[];
    var addr = 0;
    void emit(String opcode,
        [int p1 = 0,
        int p2 = 0,
        int p3 = 0,
        Object? p4,
        int p5 = 0,
        String comment = '']) {
      rows.add([addr++, opcode, p1, p2, p3, p4, p5, comment]);
    }

    emit('Init', 0, rows.length + 1, 0, null, 0, 'Start at 1');
    if (stmt is SelectStmt) {
      final t = _tables[stmt.fromTable];
      final cols = t?.columns.length ?? stmt.projection.length;
      emit('OpenRead', 0, 2, 0, '$cols', 0, stmt.fromTable ?? '');
      final rewindAddr = addr;
      emit('Rewind', 0, 0, 0, null, 0, 'jump if empty');
      final loopStart = addr;
      for (var i = 0; i < cols; i++) {
        emit('Column', 0, i, i + 1, null, 0,
            t != null ? t.columns[i].name : 'col$i');
      }
      emit('ResultRow', 1, cols, 0, null, 0, '');
      emit('Next', 0, loopStart, 0, null, 1, '');
      // Patch Rewind's p2 to point past the loop (Halt address).
      final haltAddr = addr;
      rows[rewindAddr][3] = haltAddr;
      emit('Halt', 0, 0, 0, null, 0, '');
      emit('Transaction', 0, 0, 1, '0', 1, '');
      emit('Goto', 0, 1, 0, null, 0, '');
    } else if (stmt is InsertStmt) {
      emit('OpenWrite', 0, 2, 0, null, 0, stmt.table);
      emit('NewRowid', 0, 1, 0, null, 0, '');
      emit('MakeRecord', 2, 1, 3, null, 0, '');
      emit('Insert', 0, 3, 1, stmt.table, 0, '');
      emit('Halt', 0, 0, 0, null, 0, '');
    } else if (stmt is UpdateStmt) {
      emit('OpenWrite', 0, 2, 0, null, 0, stmt.table);
      emit('Rewind', 0, addr + 4, 0, null, 0, '');
      emit('Column', 0, 0, 1, null, 0, '');
      emit('MakeRecord', 1, 1, 2, null, 0, '');
      emit('Insert', 0, 2, 0, stmt.table, 0, '');
      emit('Next', 0, addr - 3, 0, null, 1, '');
      emit('Halt', 0, 0, 0, null, 0, '');
    } else if (stmt is DeleteStmt) {
      emit('OpenWrite', 0, 2, 0, null, 0, stmt.table);
      emit('Rewind', 0, addr + 3, 0, null, 0, '');
      emit('Delete', 0, 0, 0, null, 0, '');
      emit('Next', 0, addr - 2, 0, null, 1, '');
      emit('Halt', 0, 0, 0, null, 0, '');
    } else {
      emit('Noop', 0, 0, 0, stmt.runtimeType.toString(), 0, '');
      emit('Halt', 0, 0, 0, null, 0, '');
    }
    return rows;
  }

  // ---------------------------------------------------------------------------
  // PRAGMA
  // ---------------------------------------------------------------------------
  QueryResult _pragma(PragmaStmt s) {
    final name = s.name.toLowerCase();
    final target = s.value?.toString();
    // Setter form: PRAGMA name = value  /  PRAGMA name(value) where the
    // pragma is not an introspection one. Detect via [name] below.
    const introspectionWithArg = <String>{
      'table_info',
      'table_xinfo',
      'index_list',
      'index_info',
      'index_xinfo',
      'foreign_key_list',
    };
    if (s.value != null && !introspectionWithArg.contains(name)) {
      _pragmas[name] = s.value;
      // Side-effect: enable / disable wal2 dual-log persistence.
      if (name == 'journal_mode') {
        final v = s.value.toString().toLowerCase();
        _persistAsWal2 = (v == 'wal2');
      }
      return QueryResult.message('PRAGMA $name = ${s.value}');
    }
    // Special introspection PRAGMAs.
    switch (name) {
      case 'table_info':
      case 'table_xinfo':
        {
          final rows = <List<Object?>>[];
          if (target != null && _tables.containsKey(target)) {
            final t = _tables[target]!;
            for (var i = 0; i < t.columns.length; i++) {
              final c = t.columns[i];
              rows.add([
                i,
                c.name,
                c.type == DataType.any ? '' : c.type.name.toUpperCase(),
                c.notNull ? 1 : 0,
                c.defaultValue,
                c.primaryKey ? 1 : 0,
              ]);
            }
          }
          return QueryResult(columns: const [
            'cid',
            'name',
            'type',
            'notnull',
            'dflt_value',
            'pk'
          ], rows: rows);
        }
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
        {
          final rows = <List<Object?>>[];
          if (target != null && _tables.containsKey(target)) {
            final t = _tables[target]!;
            var seq = 0;
            for (final entry in t.indexDefs.entries) {
              rows.add([seq++, entry.key, entry.value.unique ? 1 : 0]);
            }
          }
          return QueryResult(
              columns: const ['seq', 'name', 'unique'], rows: rows);
        }
      case 'index_info':
      case 'index_xinfo':
        {
          final rows = <List<Object?>>[];
          if (target != null) {
            for (final t in _tables.values) {
              final def = t.indexDefs[target];
              if (def != null) {
                for (var i = 0; i < def.columns.length; i++) {
                  rows.add([i, t.columnIndex(def.columns[i]), def.columns[i]]);
                }
                break;
              }
            }
          }
          return QueryResult(
              columns: const ['seqno', 'cid', 'name'], rows: rows);
        }
      case 'foreign_key_list':
        {
          final rows = <List<Object?>>[];
          if (target != null && _tables.containsKey(target)) {
            final t = _tables[target]!;
            var id = 0;
            for (final fk in _foreignKeysOf(t)) {
              for (var i = 0; i < fk.columns.length; i++) {
                rows.add([
                  id,
                  i,
                  fk.references.table,
                  fk.columns[i],
                  i == 0 ? fk.references.column : null,
                  fk.references.onUpdate,
                  fk.references.onDelete,
                  'NONE',
                ]);
              }
              id++;
            }
          }
          return QueryResult(columns: const [
            'id',
            'seq',
            'table',
            'from',
            'to',
            'on_update',
            'on_delete',
            'match'
          ], rows: rows);
        }
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
        {
          final names = <String>{
            ...kScalarFunctions.keys,
            ...kAggregateFunctions,
          }.toList()
            ..sort();
          return QueryResult(columns: const [
            'name'
          ], rows: [
            for (final n in names) [n.toLowerCase()]
          ]);
        }
      case 'module_list':
        return QueryResult(columns: const [
          'name'
        ], rows: const [
          ['fts5'],
          ['rtree'],
          ['json_each'],
          ['json_tree'],
          ['generate_series'],
        ]);
      case 'pragma_list':
        {
          const names = <String>[
            'application_id',
            'auto_vacuum',
            'busy_timeout',
            'cache_size',
            'cache_spill',
            'case_sensitive_like',
            'cell_size_check',
            'checkpoint_fullfsync',
            'collation_list',
            'compile_options',
            'database_list',
            'defer_foreign_keys',
            'encoding',
            'foreign_key_list',
            'foreign_keys',
            'freelist_count',
            'fullfsync',
            'function_list',
            'ignore_check_constraints',
            'index_info',
            'index_list',
            'index_xinfo',
            'integrity_check',
            'journal_mode',
            'journal_size_limit',
            'legacy_alter_table',
            'legacy_file_format',
            'locking_mode',
            'max_page_count',
            'mmap_size',
            'module_list',
            'page_count',
            'page_size',
            'pragma_list',
            'query_only',
            'quick_check',
            'read_uncommitted',
            'recursive_triggers',
            'reverse_unordered_selects',
            'schema_version',
            'secure_delete',
            'soft_heap_limit',
            'synchronous',
            'table_info',
            'table_list',
            'table_xinfo',
            'temp_store',
            'threads',
            'trusted_schema',
            'user_version',
            'wal_autocheckpoint',
            'wal_checkpoint',
          ];
          return QueryResult(columns: const [
            'name'
          ], rows: [
            for (final n in names) [n]
          ]);
        }
      case 'table_list':
        {
          final rows = <List<Object?>>[];
          for (final t in _tables.values) {
            rows.add(['main', t.name, 'table', t.columns.length, 0, 0]);
          }
          for (final v in _views.keys) {
            rows.add(['main', v, 'view', 0, 0, 0]);
          }
          return QueryResult(
              columns: const ['schema', 'name', 'type', 'ncol', 'wr', 'strict'],
              rows: rows);
        }
      case 'optimize':
        {
          // SQLite normally inspects each table and may run ANALYZE on
          // those whose statistics are stale. We have no cost-driven
          // planner that depends on stats, so PRAGMA optimize is a no-op
          // that reports completion.
          return QueryResult.message('optimize: 0 tables analyzed');
        }
      case 'vdbe_listing':
      case 'vdbe_trace':
      case 'vdbe_addoptrace':
      case 'vdbe_debug':
        {
          // Bytecode VM introspection toggles. We don't run a real VDBE,
          // but we surface the synthesized bytecode left behind by the
          // most recent EXPLAIN so tools that toggle this pragma and
          // re-read the listing keep working.
          if (s.value != null) _pragmas[name] = s.value;
          return QueryResult(columns: const [
            'addr',
            'opcode',
            'p1',
            'p2',
            'p3',
            'p4',
            'p5',
            'comment',
          ], rows: [
            for (final r in _lastBytecode) List<Object?>.from(r)
          ]);
        }
      case 'shrink_memory':
      case 'incremental_vacuum':
      case 'wal_checkpoint':
        {
          if (_persistAsSqlite && path != null) {
            // Fold any pending WAL into the main file. Fire-and-forget
            // because PRAGMA dispatch is sync; the underlying file
            // operations are protected by the same DbFileLock as commits.
            // ignore: unawaited_futures
            checkpointSqlite();
          }
          return QueryResult(columns: const [
            'busy',
            'log',
            'checkpointed'
          ], rows: const [
            [0, 0, 0]
          ]);
        }
      case 'wal2_checkpoint':
        {
          // WAL2 mode keeps two alternating `-wal` companions. Folding
          // both back into the main file is exactly what checkpointSqlite
          // already does, so route through it.
          if (_persistAsSqlite && path != null) {
            // ignore: unawaited_futures
            checkpointSqlite();
          }
          return QueryResult(columns: const [
            'busy',
            'log',
            'checkpointed'
          ], rows: const [
            [0, 0, 0]
          ]);
        }
      case 'max_trigger_depth':
        {
          if (s.value != null) {
            _pragmas[name] = s.value;
            return QueryResult.message('max_trigger_depth = ${s.value}');
          }
          return QueryResult(columns: const [
            'max_trigger_depth'
          ], rows: [
            [_pragmas[name] ?? 1000]
          ]);
        }
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
    final maxDepth = (_pragmas['max_trigger_depth'] as num?)?.toInt() ?? 1000;
    final recursive = _truthy(_pragmas['recursive_triggers'] ?? 1);
    if (_triggerDepth >= maxDepth) {
      _triggerScope = saved;
      throw StateError('too many levels of trigger recursion');
    }
    if (!recursive && _triggerDepth > 0) {
      _triggerScope = saved;
      return; // recursive triggers disabled
    }
    _triggerDepth++;
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
      _triggerDepth--;
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
    final walBytes = _pickFreshWalBytesSync(path);
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
  /// database on every mutation, so plain `VACUUM` has no internal work
  /// to do. `VACUUM INTO 'path'` writes a consistent SQLite-format
  /// image of the current database to the given path (the local engine
  /// is not modified). The destination file is overwritten if it exists.
  QueryResult _vacuum(VacuumStmt s) {
    final dest = s.intoPath;
    if (dest == null) return QueryResult.message('VACUUM ok');
    final bytes = _buildSqliteBytes(pageSize: _sqlitePageSize);
    _atomicWriteBytesSync(dest, bytes);
    return QueryResult.message('VACUUM INTO ok');
  }

  /// Online backup: write a consistent SQLite-format snapshot of the
  /// current database to [destPath]. Acquires the writer arm of the
  /// engine's read/write lock briefly to take the snapshot, then writes
  /// outside the lock so concurrent readers/writers are not blocked
  /// for the duration of the disk I/O.
  ///
  /// The destination is written via `<dest>.tmp` + atomic rename, so
  /// readers of [destPath] either see the previous file or the new
  /// complete file, never a partial write.
  Future<void> backup(String destPath, {int pageSize = 4096}) async {
    final bytes =
        await _lock.write(() async => _buildSqliteBytes(pageSize: pageSize));
    await _atomicWriteBytes(destPath, bytes);
  }

  /// Open an incremental BLOB I/O handle on a row's BLOB column,
  /// analogous to SQLite's `sqlite3_blob_open`. [rowid] resolves the
  /// target row by INTEGER PRIMARY KEY value when the table has one,
  /// falling back to 1-based row position. The returned handle lets
  /// callers stream bytes in/out of the column without copying the
  /// entire blob through user code.
  ///
  /// Writable handles cannot grow the blob — pre-size with
  /// `UPDATE t SET col = zeroblob(N) WHERE ...` first if needed.
  ///
  /// The handle holds a direct reference to the in-memory row, so
  /// concurrent mutations to the same row are visible (and may
  /// invalidate offsets). Treat handles as short-lived.
  BlobHandle openBlob({
    required String table,
    required String column,
    required int rowid,
    bool writable = false,
  }) {
    final t = _tables[table] ??
        _tables[table.toLowerCase()] ??
        _tables[table.toUpperCase()];
    if (t == null) {
      throw ArgumentError('No such table: $table');
    }
    final colIdx = t.columnIndex(column);
    final col = t.columns[colIdx];
    if (col.type != DataType.blob && col.type != DataType.any) {
      throw ArgumentError(
          'Column $table.$column is ${col.type.name}, not BLOB');
    }
    int? pkIdx;
    for (var i = 0; i < t.columns.length; i++) {
      final c = t.columns[i];
      if (c.primaryKey && c.type == DataType.integer) {
        pkIdx = i;
        break;
      }
    }
    List<Object?>? row;
    if (pkIdx != null) {
      for (final r in t.rows) {
        final v = r[pkIdx];
        if (v is int && v == rowid) {
          row = r;
          break;
        }
      }
    } else {
      final idx = rowid - 1;
      if (idx >= 0 && idx < t.rows.length) row = t.rows[idx];
    }
    if (row == null) {
      throw StateError('No row with rowid $rowid in $table');
    }
    return BlobHandle.internal(row, colIdx,
        tableName: table, columnName: column, writable: writable);
  }

  /// REINDEX: rebuild ordered index structures from the underlying rows.
  /// With no target, every index in every table is rebuilt. A target may
  /// be an index name, a table name (rebuild all its indexes), or a
  /// collation name (no-op, since the engine has no user collations).
  QueryResult _reindex(ReindexStmt s) {
    int rebuilt = 0;
    void rebuildTable(Table t) {
      final defs = List<IndexDef>.from(t.indexDefs.values);
      for (final d in defs) {
        t.dropIndex(d.name);
        t.createIndex(d);
        rebuilt++;
      }
    }

    final target = s.target;
    if (target == null) {
      for (final t in _tables.values) {
        rebuildTable(t);
      }
      return QueryResult.message('REINDEX rebuilt $rebuilt index(es)');
    }

    // Try as a table name first.
    final tbl = _tables[target];
    if (tbl != null) {
      rebuildTable(tbl);
      return QueryResult.message(
          'REINDEX rebuilt $rebuilt index(es) on $target');
    }
    // Try as an index name across all tables.
    for (final t in _tables.values) {
      final def = t.indexDefs[target];
      if (def != null) {
        t.dropIndex(def.name);
        t.createIndex(def);
        return QueryResult.message('REINDEX rebuilt index $target');
      }
    }
    // SQLite treats unknown names as collation names and silently no-ops.
    return QueryResult.message('REINDEX ok');
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
    if (module == 'rtree') {
      _rtreeTables.add(s.name.toLowerCase());
    }
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
    await _atomicWriteBytes(
        path!, Uint8List.fromList(utf8.encode(jsonEncode(out))));
  }

  /// Crash-safe write: writes to `<dest>.tmp`, fsyncs the temp file's
  /// contents, then atomically renames it over `dest`. On Windows the
  /// rename can't overwrite an existing file, so we delete the
  /// destination first; the surrounding [DbFileLock] keeps other
  /// processes out of the brief gap.
  ///
  /// A torn write therefore manifests as either:
  ///  * the original file unchanged (rename never ran); or
  ///  * the new file fully written (rename completed),
  /// and never as a half-written destination.
  static Future<void> _atomicWriteBytes(String dest, List<int> bytes) async {
    final tmp = '$dest.tmp';
    final raf = await File(tmp).open(mode: FileMode.write);
    try {
      await raf.writeFrom(bytes);
      await raf.flush(); // request fsync
    } finally {
      await raf.close();
    }
    if (Platform.isWindows) {
      final destFile = File(dest);
      if (await destFile.exists()) {
        try {
          await destFile.delete();
        } catch (_) {/* best-effort */}
      }
    }
    await File(tmp).rename(dest);
  }

  /// Synchronous variant of [_atomicWriteBytes]. Used from synchronous
  /// dispatch paths (e.g. `VACUUM INTO`) where we cannot await.
  static void _atomicWriteBytesSync(String dest, List<int> bytes) {
    final tmp = '$dest.tmp';
    final raf = File(tmp).openSync(mode: FileMode.write);
    try {
      raf.writeFromSync(bytes);
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    if (Platform.isWindows) {
      final destFile = File(dest);
      if (destFile.existsSync()) {
        try {
          destFile.deleteSync();
        } catch (_) {/* best-effort */}
      }
    }
    File(tmp).renameSync(dest);
  }

  /// Recover from a previous crash mid-[_atomicWriteBytes]: if a stale
  /// `<path>.tmp` is sitting next to the data file, it's an incomplete
  /// write that never made it to the rename step — discard it.
  Future<void> _reapStaleTempFiles() async {
    if (path == null) return;
    for (final p in [
      '$path.tmp',
      '${path!}-wal.tmp',
      '${path!}-wal2.tmp',
    ]) {
      final f = File(p);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {/* best-effort */}
      }
    }
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
    final wal2Path = '${path!}-wal2';
    final ps = _sqlitePageSize;
    final canDiff = baseline != null &&
        baseline.length % ps == 0 &&
        current.length % ps == 0 &&
        current.length >= baseline.length;
    if (!canDiff) {
      // Full rewrite path.
      await _atomicWriteBytes(path!, current);
      _sqliteBaselineBytes = Uint8List.fromList(current);
      for (final p in [walPath, wal2Path]) {
        final wf = File(p);
        if (await wf.exists()) await wf.delete();
      }
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
      // No-op commit; drop any stale WALs.
      for (final p in [walPath, wal2Path]) {
        final wf = File(p);
        if (await wf.exists()) await wf.delete();
      }
      return;
    }
    final ratio = overrides.length / pages;
    if (ratio >= _walAutoCheckpointThreshold) {
      // Too churny: rewrite the main file and reset baseline.
      await _atomicWriteBytes(path!, current);
      _sqliteBaselineBytes = Uint8List.fromList(current);
      for (final p in [walPath, wal2Path]) {
        final wf = File(p);
        if (await wf.exists()) await wf.delete();
      }
      return;
    }
    final wal = buildWal(
      pageSize: ps,
      pageOverrides: overrides,
      dbSizeAfterCommit: pages,
    );
    if (_persistAsWal2) {
      // Alternate write target so the previous-commit snapshot survives
      // a torn write of the new one.
      _wal2Counter++;
      final liveSlot = _wal2Counter.isOdd ? 1 : 2;
      final live = liveSlot == 1 ? walPath : wal2Path;
      await _atomicWriteBytes(live, wal);
      // Persist which slot is live so that a fresh open knows which
      // companion to overlay (mtime resolution can be too coarse).
      await _atomicWriteBytes(
          '${path!}-wal2.meta', Uint8List.fromList(utf8.encode('$liveSlot')));
    } else {
      await _atomicWriteBytes(walPath, wal);
    }
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
    await _atomicWriteBytes(path!, bytes);
    _sqliteBaselineBytes = Uint8List.fromList(bytes);
    for (final p in ['${path!}-wal', '${path!}-wal2', '${path!}-wal2.meta']) {
      final wf = File(p);
      if (await wf.exists()) await wf.delete();
    }
    _wal2Counter = 0;
  }

  /// Pick the freshest WAL companion next to [mainPath] across both
  /// possible slots (`-wal` and `-wal2`). Used when reading an
  /// on-disk SQLite file that may have been written in wal2 mode.
  /// Returns null when no WAL exists.
  Future<Uint8List?> _pickFreshWalBytes(String mainPath) async {
    // Prefer the explicit live-slot record written by wal2 mode.
    final meta = File('$mainPath-wal2.meta');
    if (await meta.exists()) {
      try {
        final live = int.parse(utf8.decode(await meta.readAsBytes()).trim());
        final p = live == 1 ? '$mainPath-wal' : '$mainPath-wal2';
        final f = File(p);
        if (await f.exists()) return f.readAsBytes();
      } catch (_) {/* fall through to mtime-based pick */}
    }
    final candidates = <File>[];
    for (final p in ['$mainPath-wal', '$mainPath-wal2']) {
      final f = File(p);
      if (await f.exists()) candidates.add(f);
    }
    if (candidates.isEmpty) return null;
    candidates
        .sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return candidates.first.readAsBytes();
  }

  /// Synchronous variant for code paths that already use sync I/O
  /// (currently only the ATTACH-as-SQLite read path).
  Uint8List? _pickFreshWalBytesSync(String mainPath) {
    final meta = File('$mainPath-wal2.meta');
    if (meta.existsSync()) {
      try {
        final live = int.parse(utf8.decode(meta.readAsBytesSync()).trim());
        final p = live == 1 ? '$mainPath-wal' : '$mainPath-wal2';
        final f = File(p);
        if (f.existsSync()) return f.readAsBytesSync();
      } catch (_) {/* fall through */}
    }
    final candidates = <File>[];
    for (final p in ['$mainPath-wal', '$mainPath-wal2']) {
      final f = File(p);
      if (f.existsSync()) candidates.add(f);
    }
    if (candidates.isEmpty) return null;
    candidates
        .sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return candidates.first.readAsBytesSync();
  }

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
        // stale WAL(s) — the in-memory state already equals "baseline +
        // its original WAL", so the baseline alone is canonical.
        for (final p in [
          '${path!}-wal',
          '${path!}-wal2',
          '${path!}-wal2.meta',
        ]) {
          final wf = File(p);
          if (await wf.exists()) await wf.delete();
        }
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
    await _atomicWriteBytes(path, bytes);
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
    // If the database is in WAL (or WAL2) mode, a `<path>-wal` and/or
    // `<path>-wal2` companion may hold newer page versions. Pick the
    // freshest one and overlay it transparently.
    final walBytes = await _pickFreshWalBytes(path);
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
      // emits per-index rows where `stat` is `<rowCount> <avgRowsPerKey>
      // ...`; the first integer doubles as the table row count, and the
      // second (when present) lets us recover the indexed column's
      // distinct cardinality.
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
      // Second pass: extract per-index distinct counts from the
      // `<n> <avgRowsPerKey>` form on index-stat rows.
      for (final r in stat.rows) {
        final tname = r[0]?.toString();
        final idxName = r[1]?.toString();
        final statStr = r[2]?.toString();
        if (tname == null || idxName == null || statStr == null) continue;
        final parts = statStr.split(' ');
        if (parts.length < 2) continue;
        final n = int.tryParse(parts[0]);
        final avg = int.tryParse(parts[1]);
        if (n == null || avg == null || avg <= 0) continue;
        final tbl = _tables[tname];
        if (tbl == null) continue;
        final def = tbl.indexDefs[idxName];
        if (def == null) continue;
        final distinct = (n / avg).ceil();
        final ts =
            _stats.putIfAbsent(tname, () => _TableStats(n, <String, int>{}));
        ts.distinctByColumn[def.column.toLowerCase()] = distinct;
      }
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

  /// Phase-0 unification scaffold: look up a table by name across both
  /// the in-memory and paged backends and return the shared
  /// [TableBackend] view of it. Returns null when no table by that
  /// name exists in either registry. Prefer this over poking at
  /// [_tables] / [_pagedTables] directly when you only need metadata
  /// (existence / column names / which backend it lives on).
  TableBackend? lookupBackend(String name) {
    final t = _tables[name];
    if (t != null) return t;
    return _pagedTables[name];
  }

  /// Every backend known to this database — both in-memory and paged.
  /// Order is unspecified.
  Iterable<TableBackend> get backends sync* {
    yield* _tables.values;
    yield* _pagedTables.values;
  }

  /// Internal: route a paged-table lookup through [lookupBackend] so
  /// every read site funnels through the same predicate. Returns the
  /// concrete [PagedTable] (callers still need its async API), or
  /// null when [name] is null, unknown, or refers to an in-memory
  /// table.
  PagedTable? _pagedTable(String? name) {
    if (name == null) return null;
    final b = lookupBackend(name);
    return b is PagedTable ? b : null;
  }

  /// Internal: predicate form of [_pagedTable]. Use at sites that only
  /// need to know whether [name] resolves to a paged table.
  bool _isPaged(String? name) => _pagedTable(name) != null;

  /// Phase 0.3: resolve the current `PRAGMA page_size` to a value
  /// valid for [PagedTable] / [PagedFile]. SQLite accepts power-of-two
  /// page sizes in [512, 65536]; we follow the same rule and silently
  /// fall back to 4096 for anything else (matches SQLite's behaviour
  /// of ignoring invalid page_size values).
  int _pragmaPageSize() {
    final raw = _pragmas['page_size'];
    final n = raw is num ? raw.toInt() : int.tryParse('$raw') ?? 4096;
    if (n < 512 || n > 65536) return 4096;
    // Power-of-two check.
    if ((n & (n - 1)) != 0) return 4096;
    return n;
  }

  /// Phase 0.3: resolve the current `PRAGMA cache_size` to the number
  /// of pages we want the paged-table LRU to hold. SQLite convention:
  /// negative values are sized in KiB (so cache_size = -2000 means
  /// 2 MiB regardless of page_size); positive values are page counts.
  /// Zero means "engine default" — we use 64 pages.
  int _pragmaCacheCapacity(int pageSize) {
    final raw = _pragmas['cache_size'];
    final n = raw is num ? raw.toInt() : int.tryParse('$raw') ?? -2000;
    if (n == 0) return 64;
    if (n > 0) return n.clamp(2, 1 << 20);
    final kib = -n;
    final pages = (kib * 1024) ~/ pageSize;
    return pages.clamp(2, 1 << 20);
  }

  /// Phase 0.2: decide whether a bare `CREATE TABLE` (no explicit
  /// `USING paged`) should be auto-routed to the paged backend based
  /// on the `default_table_kind` PRAGMA. Returns true only when paged
  /// is currently selected AND the table shape is compatible with
  /// [_createPagedTable]; otherwise falls back to the in-memory path.
  ///
  /// Compatibility predicates (mirror [_createPagedTable] checks):
  ///   * _pagedDir != null (database is path-backed)
  ///   * not STRICT and not WITHOUT ROWID
  ///   * exactly one column flagged PRIMARY KEY, or a single-column
  ///     table-level PRIMARY KEY constraint
  bool _shouldAutoPage(CreateTableStmt s) {
    if (s.usingPaged) return false; // already handled explicitly
    final kind = _pragmas['default_table_kind']?.toString().toLowerCase();
    if (kind != 'paged') return false;
    if (_pagedDir == null) return false;
    if (s.strict || s.withoutRowid) return false;
    var pkCount = 0;
    for (final c in s.columns) {
      if (c.primaryKey) pkCount++;
    }
    for (final tc in s.constraints) {
      if (tc is PrimaryKeyConstraint) {
        if (tc.columns.length != 1) return false;
        pkCount += 1;
      }
    }
    return pkCount == 1;
  }

  Table _requireTable(String name) {
    final t = _tables[name];
    if (t == null) throw StateError('No such table: $name');
    return t;
  }

  // ---------------------------------------------------------------------------
  // Session / changeset extension
  // ---------------------------------------------------------------------------

  /// Live recording sessions. Mutations on watched tables are appended
  /// to each one inside [_recordChange].
  final List<Session> _sessions = [];

  /// Begin a new mutation-recording session. By default the session
  /// records every table; call [Session.attach] to scope it.
  Session beginSession() {
    final s = Session();
    _sessions.add(s);
    return s;
  }

  /// Forget the session. Future mutations will not be recorded into
  /// it. The session itself remains valid for inspecting captured
  /// changes / producing a changeset.
  void detachSession(Session s) {
    _sessions.remove(s);
    s.close();
  }

  List<String> _pkColumnsOf(Table t) {
    final out = <String>[];
    for (final c in t.columns) {
      if (c.primaryKey) out.add(c.name);
    }
    if (out.isEmpty) {
      for (final con in t.constraints) {
        if (con is PrimaryKeyConstraint) {
          out.addAll(con.columns);
          break;
        }
      }
    }
    return out;
  }

  void _recordChange(
      Table t, String op, List<Object?>? oldRow, List<Object?>? newRow) {
    if (_sessions.isEmpty) return;
    final cols = [for (final c in t.columns) c.name];
    final pk = _pkColumnsOf(t);
    final change = Change(
      op: op,
      table: t.name,
      columns: cols,
      pkColumns: pk,
      oldValues: oldRow == null ? null : List<Object?>.from(oldRow),
      newValues: newRow == null ? null : List<Object?>.from(newRow),
    );
    for (final s in _sessions) {
      s.recordInternal(change);
    }
  }

  /// Apply a previously-recorded changeset blob to this database.
  /// Returns the number of changes applied (skipped/aborted changes are
  /// not counted). Pass [onConflict] to decide what to do when a row
  /// is missing for UPDATE/DELETE or already present for INSERT — by
  /// default conflicts are silently skipped.
  Future<int> applyChangeset(
    Uint8List bytes, {
    ChangesetConflictHandler? onConflict,
  }) async {
    final changes = Session.decode(bytes);
    final handler = onConflict ?? (_, __) => ConflictResolution.skip;
    var applied = 0;
    return _lock.write(() async {
      for (final c in changes) {
        final t = _tables[c.table] ??
            _tables[c.table.toLowerCase()] ??
            _tables[c.table.toUpperCase()];
        if (t == null) {
          final res = handler(c, ConflictKind.notFound);
          if (res == ConflictResolution.abort) return applied;
          continue;
        }
        // Map recorded column order -> current column order.
        int? colIdxIn(List<String> cols, String name) {
          for (var i = 0; i < cols.length; i++) {
            if (cols[i].toLowerCase() == name.toLowerCase()) return i;
          }
          return null;
        }

        List<Object?> projectToCurrent(List<Object?> recorded) {
          final out = List<Object?>.filled(t.columns.length, null);
          for (var i = 0; i < t.columns.length; i++) {
            final src = colIdxIn(c.columns, t.columns[i].name);
            if (src != null && src < recorded.length) out[i] = recorded[src];
          }
          return out;
        }

        int? findRow(List<Object?> recorded) {
          if (c.pkColumns.isEmpty) {
            // Fall back to whole-row equality on the recorded columns.
            for (var ri = 0; ri < t.rows.length; ri++) {
              var match = true;
              for (var k = 0; k < c.columns.length; k++) {
                final ti = colIdxIn(
                    [for (final col in t.columns) col.name], c.columns[k]);
                if (ti == null) {
                  match = false;
                  break;
                }
                if (t.rows[ri][ti] != recorded[k]) {
                  match = false;
                  break;
                }
              }
              if (match) return ri;
            }
            return null;
          }
          // Locate by primary-key columns.
          final pkIdxRecorded = [
            for (final p in c.pkColumns) colIdxIn(c.columns, p)
          ];
          if (pkIdxRecorded.contains(null)) return null;
          final pkIdxTable = [for (final p in c.pkColumns) t.columnIndex(p)];
          for (var ri = 0; ri < t.rows.length; ri++) {
            var match = true;
            for (var k = 0; k < c.pkColumns.length; k++) {
              if (t.rows[ri][pkIdxTable[k]] != recorded[pkIdxRecorded[k]!]) {
                match = false;
                break;
              }
            }
            if (match) return ri;
          }
          return null;
        }

        switch (c.op) {
          case 'INSERT':
            final candidate = projectToCurrent(c.newValues!);
            if (findRow(c.newValues!) != null) {
              final res = handler(c, ConflictKind.notUnique);
              if (res == ConflictResolution.abort) return applied;
              if (res == ConflictResolution.replace) {
                final ri = findRow(c.newValues!)!;
                t.rows[ri] = candidate;
                _rebuildIndexes(t);
                applied++;
              }
              continue;
            }
            t.insertRow(candidate);
            _rebuildIndexes(t);
            applied++;
            break;
          case 'DELETE':
            final ri = findRow(c.oldValues!);
            if (ri == null) {
              final res = handler(c, ConflictKind.notFound);
              if (res == ConflictResolution.abort) return applied;
              continue;
            }
            t.rows.removeAt(ri);
            _rebuildIndexes(t);
            applied++;
            break;
          case 'UPDATE':
            final ri = findRow(c.oldValues!);
            if (ri == null) {
              final res = handler(c, ConflictKind.notFound);
              if (res == ConflictResolution.abort) return applied;
              continue;
            }
            t.rows[ri] = projectToCurrent(c.newValues!);
            _rebuildIndexes(t);
            applied++;
            break;
          default:
            // unknown op — treat as conflict
            final res = handler(c, ConflictKind.data);
            if (res == ConflictResolution.abort) return applied;
        }
      }
      await _persist();
      return applied;
    });
  }
}

class _Pair {
  final Map<String, Object?> src;
  final List<Object?> row;
  _Pair(this.src, this.row);
}

class _HashJoinPlan {
  final List<Expr> leftKeyExprs;
  final List<Expr> rightKeyExprs;
  final Expr? residual;
  _HashJoinPlan(this.leftKeyExprs, this.rightKeyExprs, this.residual);
}

/// Hashable wrapper around a list of values. Two _TupleKey instances
/// are equal iff their values compare equal element-wise.
class _TupleKey {
  final List<Object?> values;
  final int _hash;
  _TupleKey(this.values) : _hash = _hashValues(values);

  static int _hashValues(List<Object?> vs) {
    var h = 17;
    for (final v in vs) {
      h = (h * 31 + (v?.hashCode ?? 0)) & 0x3fffffff;
    }
    return h;
  }

  @override
  int get hashCode => _hash;

  @override
  bool operator ==(Object other) {
    if (other is! _TupleKey) return false;
    if (other._hash != _hash) return false;
    if (other.values.length != values.length) return false;
    for (var i = 0; i < values.length; i++) {
      if (values[i] != other.values[i]) return false;
    }
    return true;
  }
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

/// Parsed shape of a paged-table WHERE clause. Used by the executor
/// helpers to drive either a `PagedTable.get` point lookup or a
/// `PagedTable.range` streaming scan. See [Database._pagedExtractPkRange].
class _PagedRange {
  /// When non-null, a single primary-key equality. Mutually exclusive
  /// with [lower] / [upper] in the success path.
  Object? eq;
  Object? lower;
  bool lowerInclusive = true;
  Object? upper;
  bool upperInclusive = true;

  /// Set when AND-merging produced an unsatisfiable predicate (e.g.
  /// two distinct equalities on the same PK). The executor returns an
  /// empty result without touching disk.
  bool contradiction = false;

  /// AND-conjunct(s) that didn't reduce to a PK-range fragment.
  /// Evaluated row-by-row via [Expr.eval] after streaming candidate
  /// rows from the index. `null` means "no residual" — every streamed
  /// row passes.
  Expr? residual;
}

/// Index-driven access plan for a `USING paged` table. Produced by
/// [Database._findIndexPlan] when the WHERE residual contains
/// indexable predicates. `isEquality` flips between `indexLookup` and
/// `indexRange`; the residual is still re-applied per row by the
/// caller.
///
/// [equalPrefix] pins the leading columns by equality. When
/// `isEquality` is true, every indexed column is covered by
/// [equalPrefix] (and [lower] / [upper] are null). Otherwise the next
/// column after the prefix is range-scanned using [lower] / [upper].
class _PagedIndexPlan {
  final String indexName;
  final bool isEquality;
  final List<Object> equalPrefix;
  final Object? lower;
  final bool lowerInclusive;
  final Object? upper;
  final bool upperInclusive;
  _PagedIndexPlan({
    required this.indexName,
    required this.isEquality,
    required this.equalPrefix,
    required this.lower,
    required this.lowerInclusive,
    required this.upper,
    required this.upperInclusive,
  });
}
