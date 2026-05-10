/// Result of executing a [Statement].
library;

import 'schema.dart' show storageToJsonValue;

class QueryResult {
  /// Column names of the result set, when applicable.
  final List<String> columns;

  /// Result rows. Each row aligns with [columns].
  final List<List<Object?>> rows;

  /// Number of rows affected (INSERT/UPDATE/DELETE).
  final int affected;

  /// Optional human-readable status message (DDL etc).
  final String? message;

  const QueryResult({
    this.columns = const [],
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
