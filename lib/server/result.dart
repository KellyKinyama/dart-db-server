/// Result of executing a [Statement].
library;

import 'schema.dart' show storageToJsonValue;

class QueryResult {
  /// Column names of the result set, when applicable.
  final List<String> columns;

  /// Declared DDL type token per result column (e.g. `CLOB`, `JSON`, `BLOB`,
  /// `VECTOR`), aligned with [columns]. An entry is null when the column is
  /// not a direct base-table column reference (an expression, function, or
  /// set-operation output) or has no declared type. Populated for simple
  /// column-projection SELECTs so the Oracle wire layer can describe a column
  /// with its true type; consumers that don't need it may ignore it.
  final List<String?>? columnTypes;

  /// Result rows. Each row aligns with [columns].
  final List<List<Object?>> rows;

  /// Number of rows affected (INSERT/UPDATE/DELETE).
  final int affected;

  /// Optional human-readable status message (DDL etc).
  final String? message;

  const QueryResult({
    this.columns = const [],
    this.columnTypes,
    this.rows = const [],
    this.affected = 0,
    this.message,
  });

  static const empty = QueryResult();

  factory QueryResult.message(String msg, {int affected = 0}) =>
      QueryResult(message: msg, affected: affected);

  Map<String, Object?> toJson() => {
        'columns': columns,
        'rows': rows.map((r) => r.map(storageToJsonValue).toList()).toList(),
        'affected': affected,
        if (message != null) 'message': message,
      };
}

/// A materialized ref-cursor value: the result of `OPEN cur FOR <select>` in
/// PL/SQL. Carried as a routine variable, function RETURN value, or OUT
/// parameter and surfaced to the caller as a [result] set.
class CursorValue {
  final QueryResult result;
  const CursorValue(this.result);
}
