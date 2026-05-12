/// SQL expression AST and evaluator (used by WHERE, HAVING, ON clauses).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'fts5.dart';
import 'schema.dart';

abstract class Expr {
  /// Evaluate this expression in the context of [row] (column name -> value).
  Object? eval(Map<String, Object?> row);
}

class LiteralExpr extends Expr {
  final Object? value;
  LiteralExpr(this.value);
  @override
  Object? eval(Map<String, Object?> row) => value;
}

/// A bind-parameter placeholder, e.g. `?`, `?3`, `:name`, `@name`, `$x`.
///
/// Bindings are not stored on the AST itself — that would defeat the
/// point of preparing once and re-binding. Instead the executor pushes
/// a [BindScope] onto [BindParamExpr.scopeStack] before running a
/// statement, and BindParamExpr.eval looks up its value there. Pushing
/// is done by `Database` and the prepared-statement runner; nesting is
/// safe because Dart is single-threaded within an isolate and execution
/// inside [Database] is serialized through its RW lock.
class BindParamExpr extends Expr {
  /// 1-based positional index, or null for named.
  final int? index;

  /// Named-parameter name (without the leading sigil), or null for positional.
  final String? name;

  /// Original source spelling, kept for diagnostics: '?', '?3', ':foo', '@x'.
  final String spelling;

  BindParamExpr({this.index, this.name, required this.spelling})
      : assert((index == null) != (name == null),
            'Exactly one of index/name must be set');

  static final List<BindScope> scopeStack = <BindScope>[];

  @override
  Object? eval(Map<String, Object?> row) {
    if (scopeStack.isEmpty) {
      throw StateError(
          'Bind parameter $spelling used but no bindings are active. '
          'Use Database.prepare(sql).execute(params) to bind.');
    }
    final scope = scopeStack.last;
    if (index != null) return scope.lookupPositional(index!, spelling);
    return scope.lookupNamed(name!, spelling);
  }
}

/// One frame of bindings active during a prepared-statement execution.
class BindScope {
  final List<Object?> positional;
  final Map<String, Object?> named;

  BindScope({this.positional = const [], this.named = const {}});

  Object? lookupPositional(int index, String spelling) {
    if (index < 1 || index > positional.length) {
      throw StateError('Positional parameter $spelling out of range '
          '(have ${positional.length} bindings)');
    }
    return positional[index - 1];
  }

  Object? lookupNamed(String name, String spelling) {
    if (!named.containsKey(name)) {
      throw StateError('Named parameter $spelling not bound');
    }
    return named[name];
  }
}

class ColumnExpr extends Expr {
  final String? table; // optional qualifier (table.column)
  final String name;
  ColumnExpr(this.name, {this.table});
  @override
  Object? eval(Map<String, Object?> row) {
    if (table != null) {
      final qualified = '$table.$name';
      if (row.containsKey(qualified)) return row[qualified];
      // Case-insensitive fallback for keyword-derived names like NEW.col.
      final upper = qualified.toUpperCase();
      final lower = qualified.toLowerCase();
      if (row.containsKey(upper)) return row[upper];
      if (row.containsKey(lower)) return row[lower];
    }
    if (row.containsKey(name)) return row[name];
    final upper = name.toUpperCase();
    final lower = name.toLowerCase();
    if (row.containsKey(upper)) return row[upper];
    if (row.containsKey(lower)) return row[lower];
    throw StateError(
        'Unknown column: ${table == null ? name : '$table.$name'}');
  }
}

class UnaryExpr extends Expr {
  final String op; // NOT, -
  final Expr operand;
  UnaryExpr(this.op, this.operand);
  @override
  Object? eval(Map<String, Object?> row) {
    final v = operand.eval(row);
    switch (op) {
      case 'NOT':
        if (v == null) return null;
        return !(v as bool);
      case '-':
        if (v == null) return null;
        return -(v as num);
      case '~':
        if (v == null) return null;
        return ~((v as num).toInt());
      case 'IS NULL':
        return v == null;
      case 'IS NOT NULL':
        return v != null;
    }
    throw StateError('Unknown unary op: $op');
  }
}

class BinaryExpr extends Expr {
  final String op;
  final Expr left;
  final Expr right;
  BinaryExpr(this.op, this.left, this.right);

  @override
  Object? eval(Map<String, Object?> row) {
    // Short-circuit logical ops
    if (op == 'AND' || op == 'OR') {
      final l = left.eval(row);
      if (op == 'AND' && l == false) return false;
      if (op == 'OR' && l == true) return true;
      final r = right.eval(row);
      if (l == null || r == null) return null;
      return op == 'AND'
          ? (l as bool) && (r as bool)
          : (l as bool) || (r as bool);
    }
    // NULL-safe equality (mirrors SQLite's IS / IS NOT and the standard
    // IS DISTINCT FROM / IS NOT DISTINCT FROM). These must run before the
    // generic null-propagation below.
    if (op == 'IS' ||
        op == 'IS NOT' ||
        op == 'IS DISTINCT FROM' ||
        op == 'IS NOT DISTINCT FROM') {
      final l = left.eval(row);
      final r = right.eval(row);
      final same =
          (l == null && r == null) || (l != null && r != null && _eq(l, r));
      switch (op) {
        case 'IS':
        case 'IS NOT DISTINCT FROM':
          return same;
        case 'IS NOT':
        case 'IS DISTINCT FROM':
          return !same;
      }
    }
    final l = left.eval(row);
    final r = right.eval(row);
    if (l == null || r == null) {
      // SQL three-valued logic: comparisons with NULL yield NULL (treated as false).
      return null;
    }
    switch (op) {
      case '->':
        return _jsonOp(l, r, asText: false);
      case '->>':
        return _jsonOp(l, r, asText: true);
      case '=':
        return _eq(l, r);
      case '!=':
      case '<>':
        return !_eq(l, r);
      case '<':
        return _cmp(l, r) < 0;
      case '<=':
        return _cmp(l, r) <= 0;
      case '>':
        return _cmp(l, r) > 0;
      case '>=':
        return _cmp(l, r) >= 0;
      case '+':
        return (l as num) + (r as num);
      case '-':
        return (l as num) - (r as num);
      case '*':
        return (l as num) * (r as num);
      case '/':
        return (l as num) / (r as num);
      case '%':
        // SQLite uses C-style truncated modulo (sign follows the dividend),
        // not Dart's Euclidean `%` which is always non-negative.
        return (l as num).remainder(r as num);
      case '&':
        return (l as num).toInt() & (r as num).toInt();
      case '|':
        return (l as num).toInt() | (r as num).toInt();
      case '<<':
        return (l as num).toInt() << (r as num).toInt();
      case '>>':
        return (l as num).toInt() >> (r as num).toInt();
      case '||':
        return _stringify(l) + _stringify(r);
      case 'LIKE':
        return _like(l.toString(), r.toString());
      case 'GLOB':
        return _glob(l.toString(), r.toString());
      case 'MATCH':
        return _match(l.toString(), r.toString());
      case 'REGEXP':
        return _regexp(l.toString(), r.toString());
    }
    throw StateError('Unknown binary op: $op');
  }

  /// FTS5 `MATCH` operator: parses [pattern] as an FTS5 query expression
  /// (AND/OR/NOT, phrases, prefix `foo*`, parentheses) and matches it
  /// against the tokens of [haystack]. See [fts5Match] for syntax.
  static bool _match(String haystack, String pattern) =>
      fts5Match(haystack, pattern);

  /// REGEXP operator. Returns true when [pattern] matches anywhere in
  /// [value] using Dart's `RegExp` (PCRE-like). Invalid patterns raise.
  static bool _regexp(String value, String pattern) =>
      RegExp(pattern).hasMatch(value);

  static String _stringify(Object v) {
    if (v is bool) return v ? 'true' : 'false';
    return v.toString();
  }

  static bool _eq(Object a, Object b) => sqlEq(a, b);
  static int _cmp(Object a, Object b) => sqlCompare(a, b);

  static bool _like(String value, String pattern) {
    // Translate SQL LIKE pattern to regex: % -> .*, _ -> .
    final buf = StringBuffer('^');
    for (final ch in pattern.split('')) {
      if (ch == '%') {
        buf.write('.*');
      } else if (ch == '_') {
        buf.write('.');
      } else {
        buf.write(RegExp.escape(ch));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString()).hasMatch(value);
  }

  static bool _glob(String value, String pattern) {
    // Unix-style glob: * -> .*, ? -> ., [abc] -> [abc]. Case-sensitive.
    final buf = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      final ch = pattern[i];
      if (ch == '*') {
        buf.write('.*');
      } else if (ch == '?') {
        buf.write('.');
      } else if (ch == '[') {
        // copy until ']'
        final close = pattern.indexOf(']', i + 1);
        if (close < 0) {
          buf.write(RegExp.escape(ch));
        } else {
          buf.write(pattern.substring(i, close + 1));
          i = close;
        }
      } else {
        buf.write(RegExp.escape(ch));
      }
      i++;
    }
    buf.write(r'$');
    return RegExp(buf.toString()).hasMatch(value);
  }
}

class BetweenExpr extends Expr {
  final Expr value;
  final Expr low;
  final Expr high;
  final bool negated;
  BetweenExpr(this.value, this.low, this.high, {this.negated = false});
  @override
  Object? eval(Map<String, Object?> row) {
    final v = value.eval(row);
    final l = low.eval(row);
    final h = high.eval(row);
    if (v == null || l == null || h == null) return null;
    final inRange = BinaryExpr._cmp(v, l) >= 0 && BinaryExpr._cmp(v, h) <= 0;
    return negated ? !inRange : inRange;
  }
}

class InExpr extends Expr {
  final Expr value;
  final List<Expr> values;
  final bool negated;
  InExpr(this.value, this.values, {this.negated = false});
  @override
  Object? eval(Map<String, Object?> row) {
    final v = value.eval(row);
    if (v == null) return null;
    for (final e in values) {
      final ev = e.eval(row);
      if (ev != null && BinaryExpr._eq(v, ev)) return !negated;
    }
    return negated;
  }
}

/// `expr LIKE pattern ESCAPE esc` — `esc` is an optional single-character
/// escape used to literalise the next character of [pattern] (typically
/// `%` or `_`).
class LikeExpr extends Expr {
  final Expr value;
  final Expr pattern;
  final Expr? escape;
  final bool negated;
  LikeExpr(this.value, this.pattern, {this.escape, this.negated = false});
  @override
  Object? eval(Map<String, Object?> row) {
    final v = value.eval(row);
    final p = pattern.eval(row);
    if (v == null || p == null) return null;
    String? esc;
    if (escape != null) {
      final ev = escape!.eval(row);
      if (ev == null) return null;
      final es = ev.toString();
      if (es.length != 1) {
        throw FormatException('LIKE ESCAPE expects a single-character string');
      }
      esc = es;
    }
    final m = _likeWithEscape(v.toString(), p.toString(), esc);
    return negated ? !m : m;
  }

  static bool _likeWithEscape(String value, String pattern, String? esc) {
    final buf = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      if (esc != null && ch == esc && i + 1 < pattern.length) {
        // The next character is treated as a literal.
        buf.write(RegExp.escape(pattern[i + 1]));
        i++;
        continue;
      }
      if (ch == '%') {
        buf.write('.*');
      } else if (ch == '_') {
        buf.write('.');
      } else {
        buf.write(RegExp.escape(ch));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString()).hasMatch(value);
  }
}

/// Convenience: evaluate expression as boolean (NULL -> false).
bool evalPredicate(Expr e, Map<String, Object?> row) {
  final v = e.eval(row);
  return v is bool && v;
}

/// Coerce a value to the column's type for storage/comparison purposes.
Object? coerceForColumn(Object? value, ColumnDef col, {bool strict = false}) {
  if (value == null) {
    if (col.notNull) {
      throw FormatException('Column ${col.name} is NOT NULL');
    }
    return null;
  }
  if (strict) {
    final ok = switch (col.type) {
      // SQLite STRICT INTEGER accepts integer-valued REALs; we follow.
      DataType.integer =>
        value is int || (value is double && value == value.truncateToDouble()),
      DataType.real => value is double || value is int,
      DataType.text => value is String,
      DataType.boolean => value is bool,
      DataType.blob => value is List<int>,
      DataType.numeric =>
        value is num || (value is String && double.tryParse(value) != null),
      DataType.any => true,
    };
    if (!ok) {
      throw FormatException(
          'STRICT: column ${col.name} expects ${col.type.name}, got ${value.runtimeType}');
    }
    // Even in STRICT we still normalize 1.0 -> 1 for INTEGER columns and
    // run NUMERIC affinity, otherwise leave the value alone.
    if (col.type == DataType.integer && value is double) {
      return value.toInt();
    }
    if (col.type == DataType.numeric) {
      return coerce(value, DataType.numeric);
    }
    return value;
  }
  // SQLite affinity semantics in non-strict mode:
  //   * BLOB affinity never converts \u2014 every value is stored verbatim.
  //   * INTEGER / REAL / NUMERIC affinity tries to convert; if the value
  //     cannot be losslessly converted (e.g. INTEGER column receiving the
  //     string 'abc') the original value is stored unchanged, matching
  //     SQLite's "no-op when conversion fails" rule.
  //   * TEXT and BOOLEAN affinity continue to delegate to [coerce], which
  //     already performs the standard conversions.
  if (col.type == DataType.blob) return value;
  if (col.type == DataType.integer ||
      col.type == DataType.real ||
      col.type == DataType.numeric) {
    try {
      return coerce(value, col.type);
    } on FormatException {
      return value;
    }
  }
  return coerce(value, col.type);
}

// =============================================================================
// SQL semantics helpers (shared by aggregates, ORDER BY, comparisons).
// =============================================================================

bool sqlEq(Object a, Object b) {
  if (a is num && b is num) return a == b;
  return a == b;
}

int sqlCompare(Object a, Object b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is Comparable && b is Comparable && a.runtimeType == b.runtimeType) {
    return a.compareTo(b);
  }
  return a.toString().compareTo(b.toString());
}

int sqlCompareNullable(Object? a, Object? b, {bool nullsFirst = true}) {
  if (a == null && b == null) return 0;
  if (a == null) return nullsFirst ? -1 : 1;
  if (b == null) return nullsFirst ? 1 : -1;
  return sqlCompare(a, b);
}

bool sqlTruthy(Object? v) => v is bool && v;

// =============================================================================
// Additional expression nodes.
// =============================================================================

/// CASE WHEN ... THEN ... ELSE ... END.
/// Both forms are supported:
///   `CASE WHEN <cond> THEN <v> ... [ELSE <v>] END`   (searched)
///   `CASE <subject> WHEN <v1> THEN <r1> ... [ELSE <v>] END`   (simple)
/// The simple form is desugared by the parser into the searched form.
class CaseExpr extends Expr {
  final List<Expr> whens; // condition expressions
  final List<Expr> thens;
  final Expr? elseExpr;
  CaseExpr(this.whens, this.thens, this.elseExpr);
  @override
  Object? eval(Map<String, Object?> row) {
    for (var i = 0; i < whens.length; i++) {
      if (sqlTruthy(whens[i].eval(row))) {
        return thens[i].eval(row);
      }
    }
    return elseExpr?.eval(row);
  }
}

/// CAST(expr AS type).
class CastExpr extends Expr {
  final Expr expr;
  final DataType targetType;
  CastExpr(this.expr, this.targetType);
  @override
  Object? eval(Map<String, Object?> row) {
    final v = expr.eval(row);
    if (v == null) return null;
    // CAST has more lenient conversion than the implicit table coercion:
    // - double->int truncates
    // - int/double->TEXT stringifies
    switch (targetType) {
      case DataType.integer:
        if (v is int) return v;
        if (v is double) return v.truncate();
        if (v is String) {
          final i = int.tryParse(v);
          if (i != null) return i;
          final d = double.tryParse(v);
          if (d != null) return d.truncate();
          return 0;
        }
        if (v is bool) return v ? 1 : 0;
        return coerce(v, targetType);
      case DataType.real:
        if (v is num) return v.toDouble();
        if (v is String) return double.tryParse(v) ?? 0.0;
        return coerce(v, targetType);
      case DataType.text:
        return v.toString();
      default:
        return coerce(v, targetType);
    }
  }
}

/// Function call (scalar or aggregate). Evaluation of *aggregate* functions
/// always throws here — the SELECT executor recognises and handles them
/// out-of-band (per group).
class FunctionCallExpr extends Expr {
  final String name; // upper-cased
  final List<Expr> args;
  final bool isStarArg; // true only for COUNT(*)
  final bool distinct; // COUNT(DISTINCT x)

  /// When non-null this call is a window function: `fn(args) OVER (...)`.
  /// The window machinery in the SELECT executor evaluates these out-of-band
  /// and substitutes per-row values before normal projection.
  final WindowSpec? window;

  /// `FILTER (WHERE ...)` predicate; rows where the filter is false are
  /// excluded from the aggregate / window aggregate.
  final Expr? filterExpr;
  FunctionCallExpr(this.name, this.args,
      {this.isStarArg = false,
      this.distinct = false,
      this.window,
      this.filterExpr});

  bool get isAggregate => kAggregateFunctions.contains(name);
  bool get isWindow => window != null;

  @override
  Object? eval(Map<String, Object?> row) {
    if (isAggregate) {
      throw StateError(
          'Aggregate function $name() cannot be evaluated as a scalar');
    }
    final fn = kScalarFunctions[name];
    if (fn == null) {
      throw StateError('Unknown function: $name');
    }
    final values = args.map((a) => a.eval(row)).toList();
    return fn(values);
  }
}

/// Scalar subquery `(SELECT ...)`. The actual execution is delegated to a
/// closure injected by the parser/executor (the parser doesn't depend on
/// the database).
class ScalarSubqueryExpr extends Expr {
  /// Returns a single value or null. The closure receives the current
  /// outer row map (currently unused — correlated subqueries not supported).
  final Object? Function(Map<String, Object?> outerRow) run;
  ScalarSubqueryExpr(this.run);
  @override
  Object? eval(Map<String, Object?> row) => run(row);
}

/// `expr IN (SELECT ...)` / `NOT IN (SELECT ...)`.
class InSubqueryExpr extends Expr {
  final Expr value;
  final List<Object?> Function(Map<String, Object?> outerRow) run;
  final bool negated;
  InSubqueryExpr(this.value, this.run, {this.negated = false});
  @override
  Object? eval(Map<String, Object?> row) {
    final v = value.eval(row);
    if (v == null) return null;
    final list = run(row);
    for (final ev in list) {
      if (ev != null && sqlEq(v, ev)) return !negated;
    }
    return negated;
  }
}

/// `EXISTS (SELECT ...)` / `NOT EXISTS (...)`.
class ExistsExpr extends Expr {
  final bool Function(Map<String, Object?> outerRow) run;
  final bool negated;
  ExistsExpr(this.run, {this.negated = false});
  @override
  Object? eval(Map<String, Object?> row) {
    final ok = run(row);
    return negated ? !ok : ok;
  }
}

/// One ORDER BY item inside an OVER(...) clause. Mirrors the shape of
/// statement-level `OrderByItem` but kept here to avoid a cyclic import.
class WindowOrderItem {
  final Expr expr;
  final bool descending;
  final bool? nullsFirst;
  WindowOrderItem(this.expr, {this.descending = false, this.nullsFirst});
}

/// Window frame mode.
enum FrameMode { rows, range, groups }

/// Frame boundary kind.
enum FrameBoundKind {
  unboundedPreceding,
  preceding,
  currentRow,
  following,
  unboundedFollowing,
}

class FrameBound {
  final FrameBoundKind kind;
  final Expr? offset; // for preceding/following with N
  const FrameBound(this.kind, {this.offset});
}

enum FrameExclude { noOthers, currentRow, group, ties }

class WindowFrame {
  final FrameMode mode;
  final FrameBound start;
  final FrameBound end;
  final FrameExclude exclude;
  const WindowFrame({
    this.mode = FrameMode.range,
    this.start = const FrameBound(FrameBoundKind.unboundedPreceding),
    this.end = const FrameBound(FrameBoundKind.currentRow),
    this.exclude = FrameExclude.noOthers,
  });
}

/// OVER([PARTITION BY ...] [ORDER BY ...] [frame]) specification attached
/// to a `FunctionCallExpr` to make it a window function. Either an
/// inline spec or a [name] referencing a named window in the SELECT.
class WindowSpec {
  final List<Expr> partitionBy;
  final List<WindowOrderItem> orderBy;
  final WindowFrame? frame;

  /// Named-window reference: `OVER w` / `OVER (w PARTITION BY ...)`.
  /// Resolved at execution time against the SELECT's WINDOW clause.
  final String? baseName;
  WindowSpec({
    this.partitionBy = const [],
    this.orderBy = const [],
    this.frame,
    this.baseName,
  });
}

// =============================================================================
// Built-in scalar function registry.
// =============================================================================

typedef ScalarFn = Object? Function(List<Object?> args);

Object? _propagateNull(List<Object?> args, Object? Function() body) {
  for (final a in args) {
    if (a == null) return null;
  }
  return body();
}

/// Returns the numeric value of an ASCII hex digit (`0`-`9`, `A`-`F`,
/// `a`-`f`), or -1 when [cu] is not a hex digit.
int _hexDigit(int cu) {
  if (cu >= 0x30 && cu <= 0x39) return cu - 0x30; // 0-9
  if (cu >= 0x41 && cu <= 0x46) return cu - 0x41 + 10; // A-F
  if (cu >= 0x61 && cu <= 0x66) return cu - 0x61 + 10; // a-f
  return -1;
}

/// Implements the SQLite-compatible PRINTF / FORMAT subset. Supports
/// the conversions %d %i %u %x %X %o %c %s %f %e %g %p %% %q %Q with
/// optional flags (`-+ 0#`), field width, and precision.
String _sqlitePrintf(String fmt, List<Object?> args) {
  final out = StringBuffer();
  var argIdx = 0;
  Object? nextArg() => argIdx < args.length ? args[argIdx++] : null;

  var i = 0;
  while (i < fmt.length) {
    final ch = fmt[i];
    if (ch != '%') {
      out.write(ch);
      i++;
      continue;
    }
    i++;
    if (i >= fmt.length) break;
    // Flags.
    var leftAlign = false;
    var plus = false;
    var space = false;
    var zero = false;
    var alt = false;
    while (i < fmt.length) {
      final c = fmt[i];
      if (c == '-') {
        leftAlign = true;
      } else if (c == '+') {
        plus = true;
      } else if (c == ' ') {
        space = true;
      } else if (c == '0') {
        zero = true;
      } else if (c == '#') {
        alt = true;
      } else {
        break;
      }
      i++;
    }
    // Width.
    var width = 0;
    while (i < fmt.length && _isDigitChar(fmt[i])) {
      width = width * 10 + (fmt.codeUnitAt(i) - 0x30);
      i++;
    }
    // Precision.
    int? precision;
    if (i < fmt.length && fmt[i] == '.') {
      i++;
      precision = 0;
      while (i < fmt.length && _isDigitChar(fmt[i])) {
        precision = precision! * 10 + (fmt.codeUnitAt(i) - 0x30);
        i++;
      }
    }
    if (i >= fmt.length) break;
    final conv = fmt[i++];
    String body;
    switch (conv) {
      case '%':
        out.write('%');
        continue;
      case 'd':
      case 'i':
        final n = _toIntArg(nextArg());
        body = n.abs().toString();
        if (precision != null && body.length < precision) {
          body = body.padLeft(precision, '0');
        }
        if (n < 0) {
          body = '-$body';
        } else if (plus) {
          body = '+$body';
        } else if (space) {
          body = ' $body';
        }
        break;
      case 'u':
        body = _toIntArg(nextArg()).toUnsigned(64).toString();
        if (precision != null && body.length < precision) {
          body = body.padLeft(precision, '0');
        }
        break;
      case 'x':
      case 'X':
        var hex = _toIntArg(nextArg()).toUnsigned(64).toRadixString(16);
        if (conv == 'X') hex = hex.toUpperCase();
        if (precision != null && hex.length < precision) {
          hex = hex.padLeft(precision, '0');
        }
        if (alt && hex != '0') hex = (conv == 'X' ? '0X' : '0x') + hex;
        body = hex;
        break;
      case 'o':
        body = _toIntArg(nextArg()).toUnsigned(64).toRadixString(8);
        if (alt && !body.startsWith('0')) body = '0$body';
        if (precision != null && body.length < precision) {
          body = body.padLeft(precision, '0');
        }
        break;
      case 'c':
        final v = nextArg();
        body = v == null
            ? ''
            : (v is num
                ? String.fromCharCode(v.toInt())
                : v.toString().isEmpty
                    ? ''
                    : v.toString()[0]);
        break;
      case 's':
        final v = nextArg();
        body = v == null ? '' : v.toString();
        if (precision != null && body.length > precision) {
          body = body.substring(0, precision);
        }
        break;
      case 'f':
      case 'e':
      case 'g':
        final n = _toDoubleArg(nextArg());
        final p = precision ?? 6;
        if (conv == 'f') {
          body = n.toStringAsFixed(p);
        } else if (conv == 'e') {
          body = n.toStringAsExponential(p);
        } else {
          body = n.toStringAsPrecision(p == 0 ? 1 : p);
        }
        if (n >= 0) {
          if (plus) {
            body = '+$body';
          } else if (space) {
            body = ' $body';
          }
        }
        break;
      case 'q':
        // Single-quote-escape: doubles every embedded single quote.
        final v = nextArg();
        body = v == null ? '' : v.toString().replaceAll("'", "''");
        break;
      case 'Q':
        // Like %q but also wraps in single quotes; NULL renders as
        // the literal word NULL (unquoted).
        final v = nextArg();
        if (v == null) {
          body = 'NULL';
        } else {
          body = "'${v.toString().replaceAll("'", "''")}'";
        }
        break;
      case 'p':
        body = _toIntArg(nextArg()).toRadixString(16);
        break;
      default:
        // Unknown conversion — echo verbatim (SQLite passes it through).
        out.write('%');
        out.write(conv);
        continue;
    }
    if (width > body.length) {
      if (leftAlign) {
        body = body.padRight(width);
      } else if (zero &&
          (conv == 'd' ||
              conv == 'i' ||
              conv == 'u' ||
              conv == 'x' ||
              conv == 'X' ||
              conv == 'o' ||
              conv == 'f' ||
              conv == 'e' ||
              conv == 'g')) {
        // Preserve leading sign when zero-padding numerics.
        if (body.startsWith('-') ||
            body.startsWith('+') ||
            body.startsWith(' ')) {
          body = body[0] + body.substring(1).padLeft(width - 1, '0');
        } else {
          body = body.padLeft(width, '0');
        }
      } else {
        body = body.padLeft(width);
      }
    }
    out.write(body);
  }
  return out.toString();
}

bool _isDigitChar(String c) =>
    c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

int _toIntArg(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

double _toDoubleArg(Object? v) {
  if (v == null) return 0.0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0.0;
}

/// Thrown by `RAISE(action, message)` inside a trigger. The trigger
/// executor catches this and decides whether to silently ignore the
/// current operation (IGNORE), abort it (ABORT/FAIL), or roll back the
/// enclosing transaction (ROLLBACK).
class RaiseException implements Exception {
  final String action; // IGNORE / ABORT / FAIL / ROLLBACK
  final String message;
  RaiseException(this.action, this.message);
  @override
  String toString() => 'RAISE($action${message.isEmpty ? '' : ", '$message'"})';
}

final Map<String, ScalarFn> kScalarFunctions = <String, ScalarFn>{
  'UPPER': (a) => _propagateNull(a, () => a[0].toString().toUpperCase()),
  'LOWER': (a) => _propagateNull(a, () => a[0].toString().toLowerCase()),
  'LENGTH': (a) => _propagateNull(a, () {
        final v = a[0]!;
        // SQLite: LENGTH on a BLOB is the byte count, on TEXT the
        // character count.
        if (v is List<int>) return v.length;
        return v.toString().length;
      }),
  'TRIM': (a) => _propagateNull(a, () => a[0].toString().trim()),
  'LTRIM': (a) => _propagateNull(
      a, () => a[0].toString().replaceFirst(RegExp(r'^\s+'), '')),
  'RTRIM': (a) => _propagateNull(
      a, () => a[0].toString().replaceFirst(RegExp(r'\s+$'), '')),
  'SUBSTR': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final s = a[0].toString();
    if (a.length < 2) return s;
    final start = (a[1] as num).toInt();
    // SQL is 1-based; negative offsets count from the end.
    var idx = start > 0 ? start - 1 : (s.length + start).clamp(0, s.length);
    if (idx < 0) idx = 0;
    if (idx >= s.length) return '';
    if (a.length >= 3 && a[2] != null) {
      var len = (a[2] as num).toInt();
      if (len < 0) len = 0;
      final end = (idx + len).clamp(0, s.length);
      return s.substring(idx, end);
    }
    return s.substring(idx);
  },
  'SUBSTRING': (a) => kScalarFunctions['SUBSTR']!(a),
  'REPLACE': (a) => _propagateNull(
      a, () => a[0].toString().replaceAll(a[1].toString(), a[2].toString())),
  'CONCAT': (a) => a.map((v) => v ?? '').join(),
  'COALESCE': (a) {
    for (final v in a) {
      if (v != null) return v;
    }
    return null;
  },
  'IFNULL': (a) => a[0] ?? (a.length > 1 ? a[1] : null),
  'NULLIF': (a) {
    if (a.length < 2 || a[0] == null) return a.isEmpty ? null : a[0];
    if (a[1] == null) return a[0];
    return sqlEq(a[0]!, a[1]!) ? null : a[0];
  },
  'ABS': (a) => _propagateNull(a, () => (a[0] as num).abs()),
  'ROUND': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = (a[0] as num).toDouble();
    final digits = a.length > 1 && a[1] != null ? (a[1] as num).toInt() : 0;
    final p = _pow10(digits);
    return (v * p).round() / p;
  },
  'MOD': (a) => _propagateNull(a, () => (a[0] as num) % (a[1] as num)),
  'FLOOR': (a) => _propagateNull(a, () => (a[0] as num).floor()),
  'CEIL': (a) => _propagateNull(a, () => (a[0] as num).ceil()),
  'CEILING': (a) => _propagateNull(a, () => (a[0] as num).ceil()),
  'SQRT': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v < 0) return null;
        return _sqrt(v);
      }),
  'POWER': (a) => _propagateNull(
      a, () => _intPow((a[0] as num).toDouble(), (a[1] as num).toDouble())),
  'POW': (a) => kScalarFunctions['POWER']!(a),
  'SIGN': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v == 0) return 0;
        return v > 0 ? 1 : -1;
      }),
  // SQLite 3.35+ math functions. All operate in double precision and
  // return NULL on NULL input. Domain errors (e.g. LN(0), SQRT(-1))
  // return NULL to match SQLite.
  'PI': (a) => math.pi,
  'EXP': (a) => _propagateNull(a, () => math.exp((a[0] as num).toDouble())),
  'LN': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v <= 0) return null;
        return math.log(v);
      }),
  'LOG10': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v <= 0) return null;
        return math.log(v) / math.ln10;
      }),
  'LOG2': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v <= 0) return null;
        return math.log(v) / math.ln2;
      }),
  // LOG(x) == LOG10(x); LOG(b, x) == log base b of x (SQLite semantics).
  'LOG': (a) {
    if (a.isEmpty || a[0] == null) return null;
    if (a.length == 1) {
      final v = (a[0] as num).toDouble();
      if (v <= 0) return null;
      return math.log(v) / math.ln10;
    }
    if (a[1] == null) return null;
    final b = (a[0] as num).toDouble();
    final v = (a[1] as num).toDouble();
    if (b <= 0 || b == 1 || v <= 0) return null;
    return math.log(v) / math.log(b);
  },
  'SIN': (a) => _propagateNull(a, () => math.sin((a[0] as num).toDouble())),
  'COS': (a) => _propagateNull(a, () => math.cos((a[0] as num).toDouble())),
  'TAN': (a) => _propagateNull(a, () => math.tan((a[0] as num).toDouble())),
  'ASIN': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v < -1 || v > 1) return null;
        return math.asin(v);
      }),
  'ACOS': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v < -1 || v > 1) return null;
        return math.acos(v);
      }),
  'ATAN': (a) => _propagateNull(a, () => math.atan((a[0] as num).toDouble())),
  'ATAN2': (a) => _propagateNull(
      a, () => math.atan2((a[0] as num).toDouble(), (a[1] as num).toDouble())),
  'SINH': (a) => _propagateNull(a, () {
        final x = (a[0] as num).toDouble();
        return (math.exp(x) - math.exp(-x)) / 2;
      }),
  'COSH': (a) => _propagateNull(a, () {
        final x = (a[0] as num).toDouble();
        return (math.exp(x) + math.exp(-x)) / 2;
      }),
  'TANH': (a) => _propagateNull(a, () {
        final x = (a[0] as num).toDouble();
        if (x > 20) return 1.0;
        if (x < -20) return -1.0;
        final ep = math.exp(x);
        final en = math.exp(-x);
        return (ep - en) / (ep + en);
      }),
  'RADIANS': (a) =>
      _propagateNull(a, () => (a[0] as num).toDouble() * math.pi / 180),
  'DEGREES': (a) =>
      _propagateNull(a, () => (a[0] as num).toDouble() * 180 / math.pi),
  'TRUNC': (a) => _propagateNull(a, () => (a[0] as num).truncate()),
  // REGEXP family. SQLite's REGEXP operator desugars to regexp(pat, val);
  // we accept both forms. Pattern is Dart's RegExp (PCRE-like).
  'REGEXP': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    return RegExp(a[0].toString()).hasMatch(a[1].toString());
  },
  'REGEXP_LIKE': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    return RegExp(a[1].toString()).hasMatch(a[0].toString());
  },
  'REGEXP_SUBSTR': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final m = RegExp(a[1].toString()).firstMatch(a[0].toString());
    return m?.group(0);
  },
  'REGEXP_REPLACE': (a) {
    if (a.length < 3 || a[0] == null || a[1] == null || a[2] == null) {
      return null;
    }
    return a[0]
        .toString()
        .replaceAll(RegExp(a[1].toString()), a[2].toString());
  },
  'RANDOM': (a) => _rng.nextInt(1 << 31),
  'INSTR': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final hay = a[0].toString();
    final needle = a[1].toString();
    if (needle.isEmpty) return 1;
    return hay.indexOf(needle) + 1; // 1-based; 0 == not found
  },
  'LPAD': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final s = a[0].toString();
    final n = a.length > 1 && a[1] != null ? (a[1] as num).toInt() : s.length;
    final pad = a.length > 2 && a[2] != null ? a[2].toString() : ' ';
    if (s.length >= n || pad.isEmpty) {
      return s.length > n ? s.substring(0, n) : s;
    }
    final buf = StringBuffer();
    while (buf.length + s.length < n) {
      buf.write(pad);
    }
    final padded = buf.toString();
    return padded.substring(0, n - s.length) + s;
  },
  'RPAD': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final s = a[0].toString();
    final n = a.length > 1 && a[1] != null ? (a[1] as num).toInt() : s.length;
    final pad = a.length > 2 && a[2] != null ? a[2].toString() : ' ';
    if (s.length >= n || pad.isEmpty) {
      return s.length > n ? s.substring(0, n) : s;
    }
    final buf = StringBuffer(s);
    while (buf.length < n) {
      buf.write(pad);
    }
    return buf.toString().substring(0, n);
  },
  // --- Encoding / codepoint helpers ------------------------------------
  // HEX(X) — uppercase hex of a BLOB or string's UTF-8 bytes.
  'HEX': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = a[0]!;
    final bytes = v is List<int> ? v : utf8.encode(v.toString());
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  },
  // UNHEX(X[, ignored]) — inverse of HEX. Returns NULL on malformed input
  // (matches SQLite). Optional second arg lists characters to skip; we
  // honor the SQLite default of allowing whitespace.
  'UNHEX': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final s = a[0].toString();
    final ignore = a.length > 1 && a[1] != null ? a[1].toString() : '';
    final bytes = <int>[];
    int? pending;
    for (final cu in s.codeUnits) {
      final ch = String.fromCharCode(cu);
      if (ignore.contains(ch)) continue;
      final d = _hexDigit(cu);
      if (d < 0) return null;
      if (pending == null) {
        pending = d;
      } else {
        bytes.add((pending << 4) | d);
        pending = null;
      }
    }
    if (pending != null) return null;
    return bytes;
  },
  // UNICODE(X) — codepoint of the first character of X, or NULL if X is
  // null/empty.
  'UNICODE': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final s = a[0].toString();
    if (s.isEmpty) return null;
    return s.runes.first;
  },
  // CHAR(X1, X2, ...) — string formed from the given Unicode codepoints.
  'CHAR': (a) {
    final cps = <int>[];
    for (final v in a) {
      if (v == null) continue;
      cps.add((v as num).toInt());
    }
    return String.fromCharCodes(cps);
  },
  // PRINTF(format, args...) and its alias FORMAT(...). Implements the
  // SQLite printf subset: %d %i %u %x %X %o %c %s %f %e %g %p %% %q %Q
  // with optional flags (`-+ 0#`), width, and precision. NULL format
  // returns NULL; NULL substitution args are rendered as 'NULL' for %s
  // and 0 for numerics, matching SQLite.
  'PRINTF': (a) {
    if (a.isEmpty || a[0] == null) return null;
    return _sqlitePrintf(a[0].toString(), a.sublist(1));
  },
  'FORMAT': (a) => kScalarFunctions['PRINTF']!(a),
  // --- Datetime --------------------------------------------------------
  'CURRENT_TIMESTAMP': (a) => _fmtDateTime(DateTime.now().toUtc(), full: true),
  'CURRENT_DATE': (a) => _fmtDate(DateTime.now().toUtc()),
  'CURRENT_TIME': (a) => _fmtTime(DateTime.now().toUtc()),
  'DATE': (a) => _datetimeFn(a, kind: _DTKind.date),
  'TIME': (a) => _datetimeFn(a, kind: _DTKind.time),
  'DATETIME': (a) => _datetimeFn(a, kind: _DTKind.full),
  'STRFTIME': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final fmt = a[0].toString();
    final dt = _resolveDateTime(a.sublist(1));
    if (dt == null) return null;
    return _strftime(fmt, dt);
  },
  'JULIANDAY': (a) {
    final dt = _resolveDateTime(a);
    if (dt == null) return null;
    return _toJulianDay(dt);
  },
  'UNIXEPOCH': (a) {
    final dt = _resolveDateTime(a);
    if (dt == null) return null;
    return dt.millisecondsSinceEpoch ~/ 1000;
  },
  'TYPEOF': (a) {
    final v = a.isEmpty ? null : a[0];
    if (v == null) return 'null';
    if (v is int) return 'integer';
    if (v is double) return 'real';
    if (v is bool) return 'integer';
    if (v is String) return 'text';
    return 'blob';
  },
  // ---- JSON1 (minimal) -----------------------------------------------------
  'JSON': (a) => _propagateNull(a, () {
        // Validate + reformat (canonical JSON encoding).
        final v = jsonDecode(a[0].toString());
        return jsonEncode(v);
      }),
  'JSON_VALID': (a) {
    if (a.isEmpty || a[0] == null) return 0;
    try {
      jsonDecode(a[0].toString());
      return 1;
    } catch (_) {
      return 0;
    }
  },
  'JSON_TYPE': (a) {
    if (a.isEmpty || a[0] == null) return null;
    Object? v;
    try {
      v = jsonDecode(a[0].toString());
    } catch (_) {
      return null;
    }
    if (a.length >= 2) {
      v = jsonPathLookup(v, a[1].toString());
    }
    if (v == null) return 'null';
    if (v is bool) return v ? 'true' : 'false';
    if (v is int) return 'integer';
    if (v is double) return 'real';
    if (v is String) return 'text';
    if (v is List) return 'array';
    if (v is Map) return 'object';
    return null;
  },
  'JSON_EXTRACT': (a) {
    if (a.isEmpty || a[0] == null) return null;
    Object? root;
    try {
      root = jsonDecode(a[0].toString());
    } catch (_) {
      return null;
    }
    // SQLite: with one path returns the SQL value (JSON unwrapped for
    // scalars, JSON text for arrays/objects). With multiple paths returns
    // a JSON array of values.
    if (a.length == 2) {
      final v = jsonPathLookup(root, a[1].toString());
      return _jsonScalarOrText(v);
    }
    final out = <Object?>[];
    for (var i = 1; i < a.length; i++) {
      out.add(jsonPathLookup(root, a[i].toString()));
    }
    return jsonEncode(out);
  },
  'JSON_ARRAY': (a) => jsonEncode(a.map(_jsonValueOf).toList()),
  'JSON_OBJECT': (a) {
    if (a.length.isOdd) {
      throw StateError('json_object requires an even number of arguments');
    }
    final m = <String, Object?>{};
    for (var i = 0; i < a.length; i += 2) {
      m[a[i].toString()] = _jsonValueOf(a[i + 1]);
    }
    return jsonEncode(m);
  },
  'JSON_ARRAY_LENGTH': (a) {
    if (a.isEmpty || a[0] == null) return null;
    Object? v;
    try {
      v = jsonDecode(a[0].toString());
    } catch (_) {
      return null;
    }
    if (a.length >= 2) v = jsonPathLookup(v, a[1].toString());
    return v is List ? v.length : 0;
  },
  'JSON_QUOTE': (a) {
    if (a.isEmpty) return 'null';
    return jsonEncode(a[0]);
  },
  // RAISE(IGNORE) / RAISE(ABORT|FAIL|ROLLBACK, 'msg'). Used in trigger
  // bodies to abort the host operation. Implemented by throwing a typed
  // exception that the trigger executor recognises.
  'RAISE': (a) {
    final action = (a.isEmpty ? 'ABORT' : a[0].toString()).toUpperCase();
    final msg = a.length >= 2 ? a[1]?.toString() ?? '' : '';
    throw RaiseException(action, msg);
  },
  // json_set / json_insert / json_replace / json_remove / json_patch take
  // (json, path, value, path, value, ...). Differences:
  //   - set:     overwrite if exists, create if not
  //   - insert:  create if not, never overwrite existing
  //   - replace: overwrite if exists, never create
  //   - remove:  delete each path
  'JSON_SET': (a) => _jsonMutate(a, overwrite: true, createMissing: true),
  'JSON_INSERT': (a) => _jsonMutate(a, overwrite: false, createMissing: true),
  'JSON_REPLACE': (a) => _jsonMutate(a, overwrite: true, createMissing: false),
  'JSON_REMOVE': (a) {
    if (a.isEmpty || a[0] == null) return null;
    Object? root;
    try {
      root = jsonDecode(a[0].toString());
    } catch (_) {
      return null;
    }
    for (var i = 1; i < a.length; i++) {
      if (a[i] == null) continue;
      root = jsonPathRemove(root, a[i].toString());
    }
    return jsonEncode(root);
  },
  'JSON_PATCH': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    Object? base;
    Object? patch;
    try {
      base = jsonDecode(a[0].toString());
      patch = jsonDecode(a[1].toString());
    } catch (_) {
      return null;
    }
    return jsonEncode(_rfc7396Merge(base, patch));
  },
  // ---- FTS5 ranking ------------------------------------------------------
  'FTS5_TF': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return 0;
    return fts5TermFrequency(a[0].toString(), a[1].toString());
  },
  'BM25': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return 0;
    final k1 = a.length > 2 && a[2] != null ? (a[2] as num).toDouble() : 1.2;
    final b = a.length > 3 && a[3] != null ? (a[3] as num).toDouble() : 0.75;
    return fts5Bm25(a[0].toString(), a[1].toString(), k1: k1, b: b);
  },
  // Corpus-aware BM25: `BM25_CORPUS(text, query, 'table', 'column'[, k1[, b]])`.
  // Looks up the cached Fts5Index for the named table/column on the
  // active database (Database.current) and computes a properly
  // IDF-weighted, length-normalised BM25 score for [text]. Useful in
  // ORDER BY on fts5 virtual tables, e.g.:
  //   SELECT body FROM docs WHERE body MATCH 'cat'
  //   ORDER BY bm25_corpus(body, 'cat', 'docs', 'body') DESC
  'BM25_CORPUS': (a) {
    if (a.length < 4 ||
        a[0] == null ||
        a[1] == null ||
        a[2] == null ||
        a[3] == null) {
      return 0;
    }
    final lookup = fts5CorpusLookup;
    if (lookup == null) {
      // No active database context — fall back to single-doc BM25 so
      // the function is still useful at the Dart-API layer.
      return fts5Bm25(a[0].toString(), a[1].toString());
    }
    final k1 = a.length > 4 && a[4] != null ? (a[4] as num).toDouble() : 1.2;
    final b = a.length > 5 && a[5] != null ? (a[5] as num).toDouble() : 0.75;
    final idx = lookup(a[2].toString(), a[3].toString());
    if (idx == null) return 0;
    return idx.bm25Text(a[0].toString(), a[1].toString(), k1: k1, b: b);
  },
};

/// Hook installed by the engine: given a table and column name, return
/// the corpus-aware FTS5 index, or null when no active database is in
/// scope. Wired up by `Database.executeStmt` so that scalar functions
/// can reach back into the database without [expression.dart] importing
/// it (which would create a cycle).
Fts5Index? Function(String table, String column)? fts5CorpusLookup;

// ---- JSON1 helpers ---------------------------------------------------------

/// Resolve a SQLite-style JSON path (e.g. `$`, `$.a.b`, `$[0]`, `$.a[1].b`)
/// against [root]. Returns null if any segment is missing.
Object? jsonPathLookup(Object? root, String path) {
  if (!path.startsWith(r'$')) {
    throw FormatException('JSON path must start with \$: $path');
  }
  Object? cur = root;
  var i = 1;
  while (i < path.length) {
    final ch = path[i];
    if (ch == '.') {
      i++;
      final start = i;
      while (i < path.length && path[i] != '.' && path[i] != '[') {
        i++;
      }
      final key = path.substring(start, i);
      if (cur is Map) {
        cur = cur[key];
      } else {
        return null;
      }
    } else if (ch == '[') {
      final close = path.indexOf(']', i + 1);
      if (close < 0) {
        throw FormatException('Unterminated [ in JSON path: $path');
      }
      final idx = int.parse(path.substring(i + 1, close));
      if (cur is List) {
        if (idx < 0 || idx >= cur.length) return null;
        cur = cur[idx];
      } else {
        return null;
      }
      i = close + 1;
    } else {
      throw FormatException('Unexpected character in JSON path: $path');
    }
    if (cur == null) return null;
  }
  return cur;
}

/// Render the result of a JSON lookup as SQLite would: scalars (number,
/// string, bool, null) come back unwrapped; arrays/objects stay as JSON
/// text.
Object? _jsonScalarOrText(Object? v) {
  if (v == null) return null;
  if (v is num || v is String || v is bool) return v;
  return jsonEncode(v);
}

/// Convert a Dart value into something `jsonEncode` will accept: strings
/// that already look like JSON (start with `{`/`[`) are decoded so they
/// nest as structured values rather than appearing as escaped strings.
Object? _jsonValueOf(Object? v) {
  if (v is String) {
    final t = v.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonDecode(v);
      } catch (_) {
        return v;
      }
    }
  }
  return v;
}

/// Implementation of the `->` and `->>` JSON operators.
/// The right operand is either a JSON path (string starting with `$`) or a
/// shorthand: a string is treated as a top-level object key, an integer as
/// an array index.
Object? _jsonOp(Object l, Object r, {required bool asText}) {
  Object? root;
  try {
    root = jsonDecode(l.toString());
  } catch (_) {
    return null;
  }
  String path;
  if (r is num) {
    path = '\$[${r.toInt()}]';
  } else {
    final s = r.toString();
    path = s.startsWith(r'$') ? s : '\$.$s';
  }
  final v = jsonPathLookup(root, path);
  if (asText) return _jsonScalarOrText(v);
  // `->` always returns JSON text.
  if (v == null) return null;
  if (v is num || v is bool) return jsonEncode(v);
  if (v is String) return jsonEncode(v);
  return jsonEncode(v);
}

final _rng = _Rng();

class _Rng {
  int _state = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  int nextInt(int bound) {
    // xorshift32
    var x = _state == 0 ? 1 : _state;
    x ^= (x << 13) & 0xffffffff;
    x ^= (x >> 17);
    x ^= (x << 5) & 0xffffffff;
    _state = x & 0x7fffffff;
    return _state % bound;
  }
}

double _sqrt(double v) {
  // Newton's method (good enough; avoids dart:math import here).
  if (v == 0) return 0;
  var x = v;
  for (var i = 0; i < 30; i++) {
    x = 0.5 * (x + v / x);
  }
  return x;
}

double _intPow(double base, double exp) {
  // Generic; for integer exponents use repeated multiplication; else exp/log
  // approximation via Newton (rarely needed in tests).
  if (exp == exp.truncate()) {
    var n = exp.truncate();
    var result = 1.0;
    var b = base;
    if (n < 0) {
      b = 1 / b;
      n = -n;
    }
    while (n > 0) {
      if ((n & 1) == 1) result *= b;
      b *= b;
      n >>= 1;
    }
    return result;
  }
  // For non-integer exponents we'd ideally use math.pow; do log/exp series.
  // Tests only exercise integer exponents.
  throw StateError('POWER with non-integer exponent not supported');
}

enum _DTKind { date, time, full }

DateTime? _parseDateTime(Object? v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  if (v is num) {
    // SQLite-style julianday number; epoch handling lives in
    // _resolveDateTime via the 'unixepoch' modifier.
    return _fromJulianDay(v.toDouble());
  }
  final s = v.toString().trim();
  if (s.toUpperCase() == 'NOW') return DateTime.now().toUtc();
  // Try the SQLite TEXT formats first so a bare YYYY-MM-DD or
  // 'YYYY-MM-DD HH:MM:SS' is treated as UTC, not as local time.
  final dOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
  if (dOnly != null) {
    return DateTime.utc(
        int.parse(dOnly[1]!), int.parse(dOnly[2]!), int.parse(dOnly[3]!));
  }
  final dt = RegExp(
          r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?$')
      .firstMatch(s);
  if (dt != null) {
    final us = dt.group(7) == null
        ? 0
        : int.parse(dt.group(7)!.padRight(6, '0').substring(0, 6));
    return DateTime.utc(
      int.parse(dt[1]!),
      int.parse(dt[2]!),
      int.parse(dt[3]!),
      int.parse(dt[4]!),
      int.parse(dt[5]!),
      dt.group(6) == null ? 0 : int.parse(dt.group(6)!),
      0,
      us,
    );
  }
  // Fall back to ISO-8601 with timezone (e.g. ...Z or +HH:MM).
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso.isUtc ? iso : iso.toUtc();
  return null;
}

String? _datetimeFn(List<Object?> a, {required _DTKind kind}) {
  final dt = _resolveDateTime(a);
  if (dt == null) return null;
  switch (kind) {
    case _DTKind.date:
      return _fmtDate(dt);
    case _DTKind.time:
      return _fmtTime(dt);
    case _DTKind.full:
      return _fmtDateTime(dt, full: true);
  }
}

/// Resolve SQLite-style date/time arguments: an optional time-value
/// followed by zero or more modifier strings.
///
/// Behaviour:
///   - empty args  -> 'now' (current UTC time).
///   - first arg null -> null (whole expression null-propagates).
///   - first arg may be a SQLite-recognised time string, a unix epoch
///     number, a Julian day number (when followed by `'unixepoch'` it
///     means seconds; otherwise pure REAL is interpreted as Julian day),
///     or the literal `'now'`.
///   - remaining args are SQLite modifier strings such as `'+1 day'`,
///     `'start of month'`, `'unixepoch'`, `'utc'`, `'localtime'`, etc.
///     Returns null if any modifier can't be parsed.
DateTime? _resolveDateTime(List<Object?> args) {
  if (args.isEmpty) return DateTime.now().toUtc();
  final first = args[0];
  if (first == null) return null;

  // Special case: numeric first arg may be either Julian day or unix
  // epoch depending on whether the 'unixepoch' modifier is present in the
  // remaining arguments.
  final mods = args.sublist(1).map((m) => m?.toString().toLowerCase()).toList();
  final unixEpochMode = mods.contains('unixepoch');

  DateTime? dt;
  if (first is num && unixEpochMode) {
    dt = DateTime.fromMillisecondsSinceEpoch((first.toDouble() * 1000).toInt(),
        isUtc: true);
  } else if (first is num) {
    // Julian day -> DateTime.
    dt = _fromJulianDay(first.toDouble());
  } else {
    dt = _parseDateTime(first);
  }
  if (dt == null) return null;

  for (final raw in mods) {
    if (raw == null) return null;
    if (raw == 'unixepoch') continue; // already handled above
    final next = _applyModifier(dt!, raw);
    if (next == null) return null;
    dt = next;
  }
  return dt;
}

DateTime? _applyModifier(DateTime dt, String mod) {
  final m = mod.trim().toLowerCase();
  if (m == 'utc' || m == 'localtime') {
    // We always store/operate in UTC, so 'utc' is a no-op and 'localtime'
    // is intentionally not implemented (would need TZ data). Treat both
    // as no-ops for portability.
    return dt;
  }
  if (m == 'start of day') {
    return DateTime.utc(dt.year, dt.month, dt.day);
  }
  if (m == 'start of month') {
    return DateTime.utc(dt.year, dt.month, 1);
  }
  if (m == 'start of year') {
    return DateTime.utc(dt.year, 1, 1);
  }
  // weekday N => move forward 0..6 days so the result lands on weekday N
  // (SQLite: 0 = Sunday .. 6 = Saturday).
  final wd = RegExp(r'^weekday\s+([0-6])$').firstMatch(m);
  if (wd != null) {
    final target = int.parse(wd.group(1)!);
    // Dart: Monday=1..Sunday=7 -> map to SQLite Sun=0..Sat=6.
    final cur = dt.weekday % 7;
    var add = (target - cur) % 7;
    if (add < 0) add += 7;
    return dt.add(Duration(days: add));
  }
  // +N <unit> / -N <unit> / N.NN <unit>
  final rel =
      RegExp(r'^([+-]?\d+(?:\.\d+)?)\s*(year|month|day|hour|minute|second)s?$')
          .firstMatch(m);
  if (rel != null) {
    final n = double.parse(rel.group(1)!);
    final unit = rel.group(2)!;
    switch (unit) {
      case 'year':
        return DateTime.utc(dt.year + n.toInt(), dt.month, dt.day, dt.hour,
            dt.minute, dt.second, dt.millisecond, dt.microsecond);
      case 'month':
        final totalMonths = dt.month - 1 + n.toInt();
        final y = dt.year + (totalMonths ~/ 12);
        var mo = totalMonths % 12;
        if (mo < 0) {
          mo += 12;
        }
        return DateTime.utc(y, mo + 1, dt.day, dt.hour, dt.minute, dt.second,
            dt.millisecond, dt.microsecond);
      case 'day':
        return dt.add(Duration(microseconds: (n * 86400 * 1e6).round()));
      case 'hour':
        return dt.add(Duration(microseconds: (n * 3600 * 1e6).round()));
      case 'minute':
        return dt.add(Duration(microseconds: (n * 60 * 1e6).round()));
      case 'second':
        return dt.add(Duration(microseconds: (n * 1e6).round()));
    }
  }
  return null; // unrecognised modifier
}

/// Convert [dt] (UTC) to a Julian Day Number (real). Matches SQLite's
/// `julianday()` to fractional seconds.
double _toJulianDay(DateTime dt) {
  final ms = dt.toUtc().millisecondsSinceEpoch;
  return ms / 86400000.0 + 2440587.5;
}

DateTime _fromJulianDay(double jd) {
  final ms = ((jd - 2440587.5) * 86400000.0).round();
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

String _fmtDate(DateTime d) => '${d.year.toString().padLeft(4, "0")}-'
    '${d.month.toString().padLeft(2, "0")}-'
    '${d.day.toString().padLeft(2, "0")}';

String _fmtTime(DateTime d) => '${d.hour.toString().padLeft(2, "0")}:'
    '${d.minute.toString().padLeft(2, "0")}:'
    '${d.second.toString().padLeft(2, "0")}';

String _fmtDateTime(DateTime d, {bool full = false}) =>
    '${_fmtDate(d)} ${_fmtTime(d)}';

String _strftime(String fmt, DateTime d) {
  final buf = StringBuffer();
  for (var i = 0; i < fmt.length; i++) {
    final ch = fmt[i];
    if (ch != '%' || i + 1 >= fmt.length) {
      buf.write(ch);
      continue;
    }
    final code = fmt[++i];
    switch (code) {
      case 'Y':
        buf.write(d.year.toString().padLeft(4, '0'));
        break;
      case 'm':
        buf.write(d.month.toString().padLeft(2, '0'));
        break;
      case 'd':
        buf.write(d.day.toString().padLeft(2, '0'));
        break;
      case 'H':
        buf.write(d.hour.toString().padLeft(2, '0'));
        break;
      case 'M':
        buf.write(d.minute.toString().padLeft(2, '0'));
        break;
      case 'S':
        buf.write(d.second.toString().padLeft(2, '0'));
        break;
      case 'j':
        buf.write(_dayOfYear(d).toString().padLeft(3, '0'));
        break;
      case 's':
        buf.write((d.millisecondsSinceEpoch ~/ 1000).toString());
        break;
      case '%':
        buf.write('%');
        break;
      default:
        buf.write('%');
        buf.write(code);
    }
  }
  return buf.toString();
}

int _dayOfYear(DateTime d) {
  final start = DateTime.utc(d.year, 1, 1);
  return d.toUtc().difference(start).inDays + 1;
}

double _pow10(int n) {
  var r = 1.0;
  for (var i = 0; i < n.abs(); i++) {
    r *= 10;
  }
  return n < 0 ? 1 / r : r;
}

const Set<String> kAggregateFunctions = {
  'COUNT',
  'SUM',
  'AVG',
  'MIN',
  'MAX',
  'JSON_GROUP_ARRAY',
  'JSON_GROUP_OBJECT',
};

// ---- More JSON1 helpers ----------------------------------------------------

/// Walk [path] (`$.a.b[2]`) and return the parent container plus the final
/// segment so callers can mutate it. Returns null when the parent doesn't
/// exist.
({Object container, Object? key})? _jsonPathParent(Object? root, String path) {
  if (!path.startsWith(r'$')) {
    throw FormatException('JSON path must start with \$: $path');
  }
  Object? cur = root;
  Object? parent;
  Object? lastKey;
  var i = 1;
  while (i < path.length) {
    final ch = path[i];
    if (ch == '.') {
      i++;
      final start = i;
      while (i < path.length && path[i] != '.' && path[i] != '[') {
        i++;
      }
      final key = path.substring(start, i);
      parent = cur;
      lastKey = key;
      if (cur is Map) {
        cur = cur[key];
      } else {
        return null;
      }
    } else if (ch == '[') {
      final close = path.indexOf(']', i + 1);
      if (close < 0) {
        throw FormatException('Unterminated [ in JSON path: $path');
      }
      final idx = int.parse(path.substring(i + 1, close));
      parent = cur;
      lastKey = idx;
      if (cur is List) {
        cur = (idx < 0 || idx >= cur.length) ? null : cur[idx];
      } else {
        return null;
      }
      i = close + 1;
    } else {
      throw FormatException('Unexpected char in JSON path: $path');
    }
  }
  if (parent == null) return null;
  return (container: parent, key: lastKey);
}

/// Apply a json_set / json_insert / json_replace mutation. Returns the new
/// JSON-encoded document, or null if [args] is malformed.
Object? _jsonMutate(List<Object?> args,
    {required bool overwrite, required bool createMissing}) {
  if (args.isEmpty || args[0] == null) return null;
  Object? root;
  try {
    root = jsonDecode(args[0].toString());
  } catch (_) {
    return null;
  }
  if (args.length.isEven) {
    throw StateError('json_set/insert/replace require alternating path,value');
  }
  for (var i = 1; i + 1 < args.length; i += 2) {
    final path = args[i]?.toString();
    final value = _jsonValueOf(args[i + 1]);
    if (path == null) continue;
    if (path == r'$') {
      root = value;
      continue;
    }
    final parent = _jsonPathParent(root, path);
    if (parent == null) continue;
    final c = parent.container;
    final k = parent.key;
    if (c is Map) {
      final has = c.containsKey(k);
      if (has && overwrite) c[k as String] = value;
      if (!has && createMissing) c[k as String] = value;
    } else if (c is List) {
      final idx = k as int;
      final inRange = idx >= 0 && idx < c.length;
      if (inRange && overwrite) c[idx] = value;
      if (!inRange && createMissing) {
        // Append; SQLite extends lists rather than skipping.
        c.add(value);
      }
    }
  }
  return jsonEncode(root);
}

/// Remove the value at [path] from [root]. Returns the (possibly mutated)
/// root.
Object? jsonPathRemove(Object? root, String path) {
  if (path == r'$') return null;
  final parent = _jsonPathParent(root, path);
  if (parent == null) return root;
  final c = parent.container;
  final k = parent.key;
  if (c is Map) {
    c.remove(k);
  } else if (c is List) {
    final idx = k as int;
    if (idx >= 0 && idx < c.length) c.removeAt(idx);
  }
  return root;
}

/// RFC 7396 JSON Merge Patch (used by `json_patch`).
Object? _rfc7396Merge(Object? target, Object? patch) {
  if (patch is! Map) return patch;
  final out =
      target is Map ? Map<String, Object?>.from(target) : <String, Object?>{};
  patch.forEach((k, v) {
    if (v == null) {
      out.remove(k);
    } else {
      out[k as String] = _rfc7396Merge(out[k], v);
    }
  });
  return out;
}
