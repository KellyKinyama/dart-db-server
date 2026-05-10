/// Prepared statements: parse-once / bind-many surface for [Database].
///
/// The hard work is done by `Parser` (which counts `?` placeholders and
/// collects named parameters into `paramCount` / `namedParams`) and by
/// `BindParamExpr` (which looks bindings up via a static scope stack at
/// eval time). This file just owns the public API and the
/// scope-push/pop dance.
library;

import 'database.dart';
import 'expression.dart';
import 'result.dart';
import 'statement.dart';

/// A statement parsed once and re-bindable. Hold on to the prepared
/// statement and call [execute] repeatedly with different parameter
/// values to avoid re-parsing.
class PreparedStatement {
  final Database _db;
  final Statement _stmt;

  /// Original SQL source (for diagnostics/toString).
  final String sql;

  /// Highest 1-based positional parameter index referenced in the SQL
  /// (also = number of values [execute] expects in `positional`).
  final int positionalCount;

  /// Named parameter spellings (with leading sigil) referenced in the
  /// SQL. e.g. `{':name', '@id'}`.
  final Set<String> namedParams;

  /// Internal constructor used by [Database.prepare]. Application code
  /// should not call this directly.
  PreparedStatement.internal({
    required Database db,
    required Statement stmt,
    required this.sql,
    required this.positionalCount,
    required this.namedParams,
  })  : _db = db,
        _stmt = stmt;

  /// Execute the statement with [positional] (1-based, in source order)
  /// and/or [named] bindings.
  ///
  /// All positional placeholders the SQL references must be supplied;
  /// extra positional values are tolerated. All named placeholders must
  /// be present in [named]; extras throw to catch typos early.
  Future<QueryResult> execute({
    List<Object?> positional = const [],
    Map<String, Object?> named = const {},
  }) async {
    if (positional.length < positionalCount) {
      throw ArgumentError(
          'Prepared statement expects $positionalCount positional '
          'parameters, got ${positional.length}');
    }
    // Validate named bindings by bare name (sigil-agnostic): every
    // name referenced must be supplied, and every supplied name must
    // be referenced (catches typos).
    String stripSigil(String s) =>
        (s.isNotEmpty && (s[0] == ':' || s[0] == '@' || s[0] == r'$'))
            ? s.substring(1)
            : s;
    final referencedBare = {for (final r in namedParams) stripSigil(r)};
    final suppliedBare = {for (final k in named.keys) stripSigil(k)};
    for (final ref in referencedBare) {
      if (!suppliedBare.contains(ref)) {
        throw ArgumentError(
            'Named parameter $ref referenced in SQL but not supplied');
      }
    }
    for (final supplied in suppliedBare) {
      if (!referencedBare.contains(supplied)) {
        throw ArgumentError('Named binding $supplied does not appear in SQL');
      }
    }
    final normalisedNamed = <String, Object?>{
      for (final entry in named.entries) stripSigil(entry.key): entry.value,
    };
    final scope = BindScope(positional: positional, named: normalisedNamed);
    BindParamExpr.scopeStack.add(scope);
    try {
      return await _db.executeStmt(_stmt);
    } finally {
      BindParamExpr.scopeStack.removeLast();
    }
  }

  @override
  String toString() =>
      'PreparedStatement(${sql.length > 60 ? '${sql.substring(0, 60)}...' : sql})';
}
