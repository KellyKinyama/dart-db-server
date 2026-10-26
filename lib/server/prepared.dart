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
import 'lexer.dart';
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
      // Bind-aware op-log capture: when the op-log is on, log the statement
      // with its bound values spliced in as literals so it replays faithfully.
      // Best-effort — an unrenderable bind falls back to not capturing (the
      // prior behavior) rather than failing the user's query.
      String? sourceSql;
      if (_db.opLog != null) {
        try {
          sourceSql = _expandBinds(sql, scope);
        } catch (_) {
          sourceSql = null;
        }
      }
      return await _db.executeStmt(_stmt, sourceSql: sourceSql);
    } finally {
      BindParamExpr.scopeStack.removeLast();
    }
  }

  @override
  String toString() =>
      'PreparedStatement(${sql.length > 60 ? '${sql.substring(0, 60)}...' : sql})';
}

/// Render [sql] with every bind placeholder replaced by the SQL literal of its
/// value in [scope], so the result is a standalone statement the op-log can
/// replay. Placeholder numbering mirrors the parser: bare `?` auto-increments,
/// `?N` is explicit, `:name`/`@name`/`$name` resolve by name.
String _expandBinds(String sql, BindScope scope) {
  final tokens = Lexer(sql).tokenize();
  final buf = StringBuffer();
  var cursor = 0;
  var paramCount = 0;
  for (final tok in tokens) {
    if (tok.type != TokType.param) continue;
    buf.write(sql.substring(cursor, tok.offset));
    final spelling = tok.text;
    Object? value;
    if (spelling == '?') {
      paramCount++;
      value = scope.lookupPositional(paramCount, spelling);
    } else if (spelling.startsWith('?')) {
      final n = int.parse(spelling.substring(1));
      if (n > paramCount) paramCount = n;
      value = scope.lookupPositional(n, spelling);
    } else {
      value = scope.lookupNamed(spelling.substring(1), spelling);
    }
    buf.write(_sqlLiteral(value));
    cursor = tok.offset + spelling.length;
  }
  buf.write(sql.substring(cursor));
  return buf.toString();
}

/// Render a bound value as a SQL literal for op-log capture.
String _sqlLiteral(Object? v) {
  if (v == null) return 'NULL';
  if (v is bool) return v ? '1' : '0';
  if (v is int) return v.toString();
  if (v is double) return (v.isNaN || v.isInfinite) ? 'NULL' : v.toString();
  if (v is List<int>) {
    final sb = StringBuffer("X'");
    for (final b in v) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0'));
    }
    sb.write("'");
    return sb.toString();
  }
  final s = v is String ? v : v.toString();
  return "'${s.replaceAll("'", "''")}'";
}

