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
  CreateTableStmt(this.name, this.columns,
      {this.constraints = const [],
      this.ifNotExists = false,
      this.strict = false});
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
  CreateIndexStmt(this.indexName, this.table, this.column,
      {this.unique = false, this.whereSql, this.exprSql});
}

class DropIndexStmt extends Statement {
  final String indexName;
  DropIndexStmt(this.indexName);
}

class CreateViewStmt extends Statement {
  final String name;
  final SelectStmt select;
  final bool ifNotExists;
  CreateViewStmt(this.name, this.select, {this.ifNotExists = false});
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

  JoinClause(this.type, this.table, this.alias, this.on,
      {this.subquery, this.using, this.natural = false});
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

  /// When the FROM clause is a table-valued function call (e.g.
  /// `json_each(...)`), the call is captured here. Mutually exclusive with
  /// [fromTable] / [fromSubquery].
  final FunctionCallExpr? fromFunction;

  /// Named WINDOW clauses: `WINDOW w AS (PARTITION BY ... ORDER BY ...)`.
  /// Visible to all `OVER w` references in this SELECT.
  final Map<String, WindowSpec> namedWindows;

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
    this.fromFunction,
    this.namedWindows = const {},
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
  UpdateStmt(this.table, this.assignments, this.where,
      {this.returning,
      this.ctes = const {},
      this.cteColumns = const {},
      this.ctesRecursive = false});
}

class DeleteStmt extends Statement {
  final String table;
  final Expr? where;
  final List<SelectItem>? returning;
  final Map<String, SelectStmt> ctes;
  final Map<String, List<String>> cteColumns;
  final bool ctesRecursive;
  DeleteStmt(this.table, this.where,
      {this.returning,
      this.ctes = const {},
      this.cteColumns = const {},
      this.ctesRecursive = false});
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

class DescribeStmt extends Statement {
  final String table;
  DescribeStmt(this.table);
}

class ExplainStmt extends Statement {
  final Statement target;
  ExplainStmt(this.target);
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
