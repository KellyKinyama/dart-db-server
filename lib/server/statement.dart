/// Parsed SQL statement AST.
library;

import 'expression.dart';
import 'schema.dart';

abstract class Statement {}

class CreateTableStmt extends Statement {
  final String name;
  final List<ColumnDef> columns;
  final List<TableConstraint> constraints;
  final bool ifNotExists;
  final bool strict;
  final bool withoutRowid;

  /// True for `CREATE TABLE name (...) USING paged`. Routes the table
  /// to the out-of-core PagedTable backend instead of the in-memory
  /// Table store. Restricts the supported query surface (see
  /// Database._executePagedStmt).
  final bool usingPaged;

  CreateTableStmt(this.name, this.columns,
      {this.constraints = const [],
      this.ifNotExists = false,
      this.strict = false,
      this.withoutRowid = false,
      this.usingPaged = false});
}

class DropTableStmt extends Statement {
  final String name;
  final bool ifExists;
  DropTableStmt(this.name, {this.ifExists = false});
}

class TruncateTableStmt extends Statement {
  final String name;
  TruncateTableStmt(this.name);
}

class AlterTableAddColumnStmt extends Statement {
  final String table;
  final ColumnDef column;
  AlterTableAddColumnStmt(this.table, this.column);
}

class AlterTableDropColumnStmt extends Statement {
  final String table;
  final String column;
  AlterTableDropColumnStmt(this.table, this.column);
}

class AlterTableRenameColumnStmt extends Statement {
  final String table;
  final String oldName;
  final String newName;
  AlterTableRenameColumnStmt(this.table, this.oldName, this.newName);
}

class AlterTableRenameStmt extends Statement {
  final String oldName;
  final String newName;
  AlterTableRenameStmt(this.oldName, this.newName);
}

class CreateIndexStmt extends Statement {
  final String indexName;
  final String table;

  /// Single source column (when [exprSql] is null).
  final String column;
  final bool unique;

  /// Optional WHERE predicate source for partial indexes.
  final String? whereSql;

  /// Optional indexed-expression source. When non-null, this index is an
  /// expression index and [column] holds a synthetic key (the SQL text).
  final String? exprSql;

  /// Full ordered list of indexed columns. For single-column indexes this
  /// is `[column]`; multi-column index DDL fills in every key column so
  /// it can be preserved through file-format round-trips.
  final List<String> columns;

  /// Per-column collation names ('BINARY' default; 'NOCASE' supported).
  final List<String> collations;

  CreateIndexStmt(this.indexName, this.table, this.column,
      {this.unique = false,
      this.whereSql,
      this.exprSql,
      List<String>? columns,
      List<String>? collations})
      : columns = columns ?? [column],
        collations = collations ??
            List<String>.filled((columns ?? [column]).length, 'BINARY');
}

class DropIndexStmt extends Statement {
  final String indexName;
  final bool ifExists;
  DropIndexStmt(this.indexName, {this.ifExists = false});
}

class CreateViewStmt extends Statement {
  final String name;
  final SelectStmt select;
  final bool ifNotExists;

  /// Original SQL text of the SELECT clause (everything after `AS`),
  /// preserved so views can be persisted and re-parsed verbatim across
  /// open/close cycles. Empty for views created programmatically.
  final String selectSql;
  CreateViewStmt(this.name, this.select,
      {this.ifNotExists = false, this.selectSql = ''});
}

class DropViewStmt extends Statement {
  final String name;
  final bool ifExists;
  DropViewStmt(this.name, {this.ifExists = false});
}

/// Conflict-resolution mode for INSERT.
enum InsertMode { normal, orReplace, orIgnore }

/// `ON CONFLICT (cols) DO {NOTHING | UPDATE SET ... [WHERE ...]}` clause
/// attached to an INSERT to form an UPSERT.
class OnConflictClause {
  /// Conflict-target column names. Empty means "any unique constraint
  /// violation" (SQLite shorthand: `ON CONFLICT DO ...`).
  final List<String> targetColumns;

  /// True for `DO NOTHING`, false for `DO UPDATE SET ...`.
  final bool doNothing;

  /// Assignments for `DO UPDATE SET col = expr, ...`. Empty when [doNothing].
  final Map<String, Expr> assignments;

  /// Optional `WHERE` filter on the UPDATE branch.
  final Expr? where;

  OnConflictClause({
    this.targetColumns = const [],
    this.doNothing = false,
    this.assignments = const {},
    this.where,
  });
}

class InsertStmt extends Statement {
  final String table;
  final List<String>? columns; // null => all columns in table order
  /// Either [rows] or [select] is non-null. When [select] is set, the values
  /// for each inserted row come from running it as a subquery.
  final List<List<Expr>>? rows;
  final SelectStmt? select;
  final InsertMode mode;

  /// Optional `RETURNING ...` projection.
  final List<SelectItem>? returning;

  /// Optional `WITH name AS (...)` CTE bindings.
  final Map<String, SelectStmt> ctes;
  final Map<String, List<String>> cteColumns;
  final bool ctesRecursive;

  /// Optional UPSERT clause.
  final OnConflictClause? onConflict;
  InsertStmt(this.table, this.columns, this.rows,
      {this.mode = InsertMode.normal,
      this.select,
      this.returning,
      this.ctes = const {},
      this.cteColumns = const {},
      this.ctesRecursive = false,
      this.onConflict});
}

/// Optional `INDEXED BY name` / `NOT INDEXED` hint attached to a table
/// reference. SQLite-compatible; when [notIndexed] the planner must skip
/// index lookups; when [indexName] is set the planner must use exactly
/// that index or raise an error.
class IndexHint {
  final String? indexName;
  final bool notIndexed;
  const IndexHint.byName(String name)
      : indexName = name,
        notIndexed = false;
  const IndexHint.notIndexed()
      : indexName = null,
        notIndexed = true;
}

class JoinClause {
  final String type; // INNER, LEFT, RIGHT, FULL, CROSS
  /// Base relation name. Mutually exclusive with [subquery].
  final String? table;

  /// Derived-table source (subquery in FROM). Mutually exclusive with [table].
  final SelectStmt? subquery;
  final String? alias;
  final Expr? on; // null for CROSS / NATURAL / USING

  /// `JOIN ... USING (c1, c2)` — column names to equi-join on.
  final List<String>? using;

  /// `NATURAL [LEFT|RIGHT|FULL] JOIN` — join on every common column.
  final bool natural;

  /// Optional `INDEXED BY` / `NOT INDEXED` hint on this joined relation.
  final IndexHint? indexedBy;

  JoinClause(this.type, this.table, this.alias, this.on,
      {this.subquery, this.using, this.natural = false, this.indexedBy});
}

class SelectStmt extends Statement {
  final List<SelectItem> projection;

  /// Either [fromTable] or [fromSubquery] may be non-null (or both null when
  /// the SELECT has no FROM).
  final String? fromTable;
  final SelectStmt? fromSubquery;
  final String? fromAlias;
  final List<JoinClause> joins;
  final Expr? where;
  final List<Expr> groupBy;
  final Expr? having;
  final List<OrderByItem> orderBy;
  final int? limit;
  final int? offset;
  final bool distinct;

  /// Optional set-operation chain (UNION / UNION ALL / EXCEPT / INTERSECT).
  /// When present, this SELECT's result is combined with [setOpRight].
  final String? setOp; // 'UNION', 'UNION ALL', 'EXCEPT', 'INTERSECT'
  final SelectStmt? setOpRight;

  /// Optional `WITH name AS (...)` CTE bindings. Visible to this SELECT and
  /// any subqueries it nests.
  final Map<String, SelectStmt> ctes;

  /// Optional explicit column names per CTE: `WITH name(c1, c2) AS (...)`.
  final Map<String, List<String>> cteColumns;

  /// True when introduced via `WITH RECURSIVE ...`.
  final bool ctesRecursive;

  /// Per-CTE materialization hint. Key = CTE name, value = `true` for
  /// `MATERIALIZED`, `false` for `NOT MATERIALIZED`. CTEs without an
  /// explicit hint are absent from the map (default = planner's choice).
  final Map<String, bool> cteMaterialized;

  /// When the FROM clause is a table-valued function call (e.g.
  /// `json_each(...)`), the call is captured here. Mutually exclusive with
  /// [fromTable] / [fromSubquery].
  final FunctionCallExpr? fromFunction;

  /// Named WINDOW clauses: `WINDOW w AS (PARTITION BY ... ORDER BY ...)`.
  /// Visible to all `OVER w` references in this SELECT.
  final Map<String, WindowSpec> namedWindows;

  /// Optional `INDEXED BY` / `NOT INDEXED` hint attached to the FROM table.
  final IndexHint? indexedBy;

  /// When the GROUP BY clause uses ROLLUP / CUBE / GROUPING SETS, this
  /// holds the expanded list of grouping-key sets (one list per set).
  /// `groupBy` then holds the union of every set's keys for binding /
  /// validation; the executor iterates [groupingSets], runs the
  /// aggregation per set, and unions the results.
  final List<List<Expr>>? groupingSets;

  SelectStmt({
    required this.projection,
    this.fromTable,
    this.fromSubquery,
    this.fromAlias,
    this.joins = const [],
    this.where,
    this.groupBy = const [],
    this.having,
    this.orderBy = const [],
    this.limit,
    this.offset,
    this.distinct = false,
    this.setOp,
    this.setOpRight,
    this.ctes = const {},
    this.cteColumns = const {},
    this.ctesRecursive = false,
    this.cteMaterialized = const {},
    this.fromFunction,
    this.namedWindows = const {},
    this.indexedBy,
    this.groupingSets,
  });
}

class SelectItem {
  final bool isStar;
  final String? starTable; // for `t.*`
  final Expr? expr;
  final String? alias;
  SelectItem.star({this.starTable})
      : isStar = true,
        expr = null,
        alias = null;
  SelectItem.expr(Expr this.expr, {this.alias})
      : isStar = false,
        starTable = null;
}

class OrderByItem {
  final Expr expr;
  final bool descending;
  final bool?
      nullsFirst; // null => default (NULLS FIRST for ASC, LAST for DESC)
  OrderByItem(this.expr, {this.descending = false, this.nullsFirst});
}

class UpdateStmt extends Statement {
  final String table;
  final Map<String, Expr> assignments;
  final Expr? where;
  final List<SelectItem>? returning;
  final Map<String, SelectStmt> ctes;
  final Map<String, List<String>> cteColumns;
  final bool ctesRecursive;
  final IndexHint? indexedBy;

  /// Optional `UPDATE t SET ... FROM <fromTable> [AS fromAlias]` source
  /// (SQLite ≥ 3.33). Columns of the FROM table are visible in both the
  /// SET expressions and the WHERE clause; the WHERE acts as the join
  /// predicate.
  final String? fromTable;
  final String? fromAlias;
  final Expr? limit;
  final Expr? offset;
  UpdateStmt(this.table, this.assignments, this.where,
      {this.returning,
      this.ctes = const {},
      this.cteColumns = const {},
      this.ctesRecursive = false,
      this.indexedBy,
      this.fromTable,
      this.fromAlias,
      this.limit,
      this.offset});
}

class DeleteStmt extends Statement {
  final String table;
  final Expr? where;
  final List<SelectItem>? returning;
  final Map<String, SelectStmt> ctes;
  final Map<String, List<String>> cteColumns;
  final bool ctesRecursive;
  final IndexHint? indexedBy;
  final Expr? limit;
  final Expr? offset;
  DeleteStmt(this.table, this.where,
      {this.returning,
      this.ctes = const {},
      this.cteColumns = const {},
      this.ctesRecursive = false,
      this.indexedBy,
      this.limit,
      this.offset});
}

class BeginStmt extends Statement {}

class CommitStmt extends Statement {}

class RollbackStmt extends Statement {}

class ShowTablesStmt extends Statement {}

class CreateVirtualTableStmt extends Statement {
  final String name;
  final String module; // e.g. fts5, rtree
  final List<String> args; // module-specific arguments (column names etc.)
  final bool ifNotExists;
  CreateVirtualTableStmt(this.name, this.module, this.args,
      {this.ifNotExists = false});
}

class VacuumStmt extends Statement {
  final String? schema;
  VacuumStmt({this.schema});
}

class AnalyzeStmt extends Statement {
  final String? target; // optional table or schema name
  AnalyzeStmt({this.target});
}

class ReindexStmt extends Statement {
  /// Optional target: a table name, index name, or collation name. When
  /// null, every index in the database is rebuilt.
  final String? target;
  ReindexStmt({this.target});
}

class DescribeStmt extends Statement {
  final String table;
  DescribeStmt(this.table);
}

class ExplainStmt extends Statement {
  final Statement target;

  /// True for `EXPLAIN QUERY PLAN <stmt>` (returns the SQLite-shaped
  /// `(id, parent, notused, detail)` tree). False for plain `EXPLAIN`,
  /// which returns synthesized VDBE bytecode rows.
  final bool isQueryPlan;
  ExplainStmt(this.target, {this.isQueryPlan = false});
}

class CreateTriggerStmt extends Statement {
  final String name;

  /// 'BEFORE' or 'AFTER' (INSTEAD OF unsupported on tables — treated as AFTER).
  final String timing;

  /// 'INSERT' | 'UPDATE' | 'DELETE'.
  final String event;
  final String table;
  final Expr? when;
  final List<Statement> body;
  final bool ifNotExists;
  CreateTriggerStmt(
      this.name, this.timing, this.event, this.table, this.when, this.body,
      {this.ifNotExists = false});
}

class DropTriggerStmt extends Statement {
  final String name;
  final bool ifExists;
  DropTriggerStmt(this.name, {this.ifExists = false});
}

class SavepointStmt extends Statement {
  final String name;
  SavepointStmt(this.name);
}

class ReleaseSavepointStmt extends Statement {
  final String name;
  ReleaseSavepointStmt(this.name);
}

class RollbackToSavepointStmt extends Statement {
  final String name;
  RollbackToSavepointStmt(this.name);
}

class PragmaStmt extends Statement {
  final String name;
  final Object? value;
  PragmaStmt(this.name, this.value);
}

class AttachDatabaseStmt extends Statement {
  final String path;
  final String alias;
  AttachDatabaseStmt(this.path, this.alias);
}

class DetachDatabaseStmt extends Statement {
  final String alias;
  DetachDatabaseStmt(this.alias);
}

// =============================================================================
// Subquery expression placeholders.
//
// These live here (not in expression.dart) because they hold SelectStmt and
// must avoid a circular import. The Database executor recognises them and
// runs the inner SELECT.
// =============================================================================

class SubquerySelectExpr extends Expr {
  final SelectStmt select;
  SubquerySelectExpr(this.select);
  @override
  Object? eval(Map<String, Object?> row) {
    throw StateError(
        'SubquerySelectExpr must be evaluated by the database executor.');
  }
}

class SubqueryInExpr extends Expr {
  final Expr value;
  final SelectStmt select;
  final bool negated;
  SubqueryInExpr(this.value, this.select, {this.negated = false});
  @override
  Object? eval(Map<String, Object?> row) {
    throw StateError(
        'SubqueryInExpr must be evaluated by the database executor.');
  }
}

class SubqueryExistsExpr extends Expr {
  final SelectStmt select;
  final bool negated;
  SubqueryExistsExpr(this.select, {this.negated = false});
  @override
  Object? eval(Map<String, Object?> row) {
    throw StateError(
        'SubqueryExistsExpr must be evaluated by the database executor.');
  }
}
