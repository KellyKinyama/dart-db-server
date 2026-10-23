/// SQL expression AST and evaluator (used by WHERE, HAVING, ON clauses).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'fts5.dart';
import 'schema.dart';
import 'vector.dart';

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
      : assert(
          (index == null) != (name == null),
          'Exactly one of index/name must be set',
        );

  static final List<BindScope> scopeStack = <BindScope>[];

  /// Ambient per-connection MySQL session user-variable store, pushed by
  /// `Database` while dispatching. A `@name` reference reads from here when it
  /// is not shadowed by an explicit binding; an unset variable reads as NULL.
  static final List<Map<String, Object?>> userVarStack =
      <Map<String, Object?>>[];

  /// True for a MySQL session user-variable spelling (`@name`, not `@@sysvar`).
  bool get _isUserVar =>
      name != null && spelling.startsWith('@') && !spelling.startsWith('@@');

  @override
  Object? eval(Map<String, Object?> row) {
    if (_isUserVar) {
      // An explicit binding (rare for `@`) shadows the session variable.
      if (scopeStack.isNotEmpty && scopeStack.last.hasNamed(name!)) {
        return scopeStack.last.lookupNamed(name!, spelling);
      }
      return userVarStack.isEmpty ? null : userVarStack.last[name!];
    }
    if (scopeStack.isEmpty) {
      throw StateError(
        'Bind parameter $spelling used but no bindings are active. '
        'Use Database.prepare(sql).execute(params) to bind.',
      );
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

  bool hasNamed(String name) => named.containsKey(name);

  Object? lookupPositional(int index, String spelling) {
    if (index < 1 || index > positional.length) {
      throw StateError(
        'Positional parameter $spelling out of range '
        '(have ${positional.length} bindings)',
      );
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

/// Supplies sequence values to [SequenceExpr] during evaluation. Implemented
/// by `Database`, which pushes itself onto [SequenceExpr.providerStack] while
/// dispatching a statement (mirrors the bind-scope mechanism above).
abstract class SequenceProvider {
  int sequenceNextval(String name);
  int sequenceCurrval(String name);
}

/// `seq.NEXTVAL` / `seq.CURRVAL`. NEXTVAL advances the sequence each time it is
/// evaluated (i.e. once per row for a multi-row INSERT ... SELECT), matching
/// Oracle; CURRVAL returns the value last issued to the current session.
class SequenceExpr extends Expr {
  final String sequence;
  final bool isCurrval;
  SequenceExpr(this.sequence, {this.isCurrval = false});

  static final List<SequenceProvider> providerStack = <SequenceProvider>[];

  @override
  Object? eval(Map<String, Object?> row) {
    if (providerStack.isEmpty) {
      throw StateError(
        'Sequence ${isCurrval ? 'CURRVAL' : 'NEXTVAL'} on "$sequence" used '
        'outside an active database',
      );
    }
    final p = providerStack.last;
    return isCurrval
        ? p.sequenceCurrval(sequence)
        : p.sequenceNextval(sequence);
  }
}

class ColumnExpr extends Expr {
  final String? table; // optional qualifier (table.column)
  final String name;
  ColumnExpr(this.name, {this.table});

  /// Ambient fallback scopes for bare identifiers that aren't columns of the
  /// current row — the local variables of a running stored routine. Pushed by
  /// the routine interpreter around each embedded statement so an unqualified
  /// reference in value position (e.g. `VALUES (id)`) resolves to the variable,
  /// while the same name used as a column identifier is unaffected.
  static final List<Map<String, Object?>> routineScopes = [];

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
    if (table == null && routineScopes.isNotEmpty) {
      final scope = routineScopes.last;
      if (scope.containsKey(name)) return scope[name];
      if (scope.containsKey(lower)) return scope[lower];
    }
    // Qualified `rec.col` from a cursor FOR-loop record in the routine scope.
    if (table != null && routineScopes.isNotEmpty) {
      final scope = routineScopes.last;
      final q = '$table.$name';
      if (scope.containsKey(q)) return scope[q];
      final ql = q.toLowerCase();
      if (scope.containsKey(ql)) return scope[ql];
    }
    // A qualified `pkg.func` with no arguments: Oracle allows calling a
    // parameterless package function without parentheses. Fall back to the
    // stored-function resolver before failing.
    if (table != null) {
      final resolver = FunctionCallExpr.storedFunctionResolver;
      if (resolver != null) {
        try {
          return resolver('$table.$name', const []);
        } on StateError {
          // Not a known function — fall through to the column error.
        }
      }
    }
    throw StateError(
      'Unknown column: ${table == null ? name : '$table.$name'}',
    );
  }
}

/// Oracle legacy outer-join marker: `col(+)`. Transparent during evaluation
/// (returns the inner value); the SELECT parser's outer-join rewrite reads the
/// marker to turn a comma/CROSS join into a LEFT/RIGHT join, then unwraps it.
class OuterJoinExpr extends Expr {
  final ColumnExpr column;
  OuterJoinExpr(this.column);
  @override
  Object? eval(Map<String, Object?> row) => column.eval(row);
}

/// `PRIOR expr` inside a CONNECT BY condition: refers to the **parent** row.
/// The hierarchical executor publishes each candidate parent's columns under a
/// `PRIOR.` prefix while testing the CONNECT BY predicate.
class PriorExpr extends Expr {
  final Expr inner;
  PriorExpr(this.inner);
  @override
  Object? eval(Map<String, Object?> row) {
    final e = inner;
    if (e is ColumnExpr) {
      final key = 'PRIOR.${e.name}';
      if (row.containsKey(key)) return row[key];
      final up = 'PRIOR.${e.name.toUpperCase()}';
      if (row.containsKey(up)) return row[up];
      final lo = 'PRIOR.${e.name.toLowerCase()}';
      if (row.containsKey(lo)) return row[lo];
      return null;
    }
    return inner.eval(row);
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
        return -_sqlTextToNum(v);
      case '~':
        if (v == null) return null;
        return ~_sqlTextToNum(v).toInt();
      case 'IS NULL':
        return v == null;
      case 'IS NOT NULL':
        return v != null;
      case 'IS TRUE':
        return _truthy(v) == true;
      case 'IS NOT TRUE':
        return _truthy(v) != true;
      case 'IS FALSE':
        return _truthy(v) == false;
      case 'IS NOT FALSE':
        return _truthy(v) != false;
      case 'IS JSON':
        return _isValidJson(v);
      case 'IS NOT JSON':
        return !_isValidJson(v);
    }
    throw StateError('Unknown unary op: $op');
  }

  /// True when [v] is syntactically valid JSON. RAW/BLOB bytes are decoded as
  /// UTF-8 first (Oracle stores JSON in RAW/BLOB columns).
  static bool _isValidJson(Object? v) {
    if (v == null) return false;
    String s;
    if (v is List<int>) {
      try {
        s = utf8.decode(v);
      } catch (_) {
        return false;
      }
    } else {
      s = v.toString();
    }
    try {
      jsonDecode(s);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// SQL truthiness: NULL stays NULL; numeric zero is false; bool passes
  /// through; non-zero numerics and non-empty strings are true. Used by
  /// the IS [NOT] TRUE / FALSE predicates.
  static bool? _truthy(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty && v != '0';
    return true;
  }
}

class BinaryExpr extends Expr {
  final String op;
  final Expr left;
  final Expr right;
  BinaryExpr(this.op, this.left, this.right);

  @override
  Object? eval(Map<String, Object?> row) {
    // Short-circuit logical ops with full SQL three-valued (Kleene) logic:
    // AND -> false if either operand is false (even if the other is NULL);
    // OR  -> true  if either operand is true  (even if the other is NULL).
    // NULL results only when no operand is decisive.
    if (op == 'AND' || op == 'OR') {
      final l = left.eval(row);
      if (op == 'AND' && l == false) return false;
      if (op == 'OR' && l == true) return true;
      final r = right.eval(row);
      if (op == 'AND') {
        if (l == false || r == false) return false;
        if (l == null || r == null) return null;
        return (l as bool) && (r as bool);
      } else {
        if (l == true || r == true) return true;
        if (l == null || r == null) return null;
        return (l as bool) || (r as bool);
      }
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
    // Row-value (tuple) comparison: `(a, b) = (1, 2)` etc.
    if (l is List && r is List) {
      return _rowValueCompare(op, l, r);
    }
    if (l == null || r == null) {
      // SQL three-valued logic: comparisons with NULL yield NULL (treated as false).
      return null;
    }
    // NOCASE collation on either operand makes string (in)equality and ordering
    // case-insensitive; RTRIM ignores trailing spaces.
    final nocase = _isNoCase(left) || _isNoCase(right);
    final rtrim = _isRtrim(left) || _isRtrim(right);
    final lc = rtrim ? applyCollation(l, 'RTRIM') ?? l : l;
    final rc = rtrim ? applyCollation(r, 'RTRIM') ?? r : r;
    switch (op) {
      case '->':
        return _jsonOp(l, r, asText: false);
      case '->>':
        return _jsonOp(l, r, asText: true);
      case '=':
        return nocase ? _eqCI(lc, rc) : _eq(lc, rc);
      case '!=':
      case '<>':
        return !(nocase ? _eqCI(lc, rc) : _eq(lc, rc));
      case '<':
        return (nocase ? _cmpCI(lc, rc) : _cmp(lc, rc)) < 0;
      case '<=':
        return (nocase ? _cmpCI(lc, rc) : _cmp(lc, rc)) <= 0;
      case '>':
        return (nocase ? _cmpCI(lc, rc) : _cmp(lc, rc)) > 0;
      case '>=':
        return (nocase ? _cmpCI(lc, rc) : _cmp(lc, rc)) >= 0;
      case '+':
        {
          // Oracle date arithmetic: DATE + n (days) shifts the date; numbers
          // on both sides fall through to numeric addition.
          final ld = _asSqlDate(l);
          if (ld != null && r is num) return _shiftDate(ld, r.toDouble(), l);
          final rd = _asSqlDate(r);
          if (rd != null && l is num) return _shiftDate(rd, l.toDouble(), r);
          return _arith(_toNum(l)!, _toNum(r)!, '+');
        }
      case '-':
        {
          // Oracle date arithmetic: DATE - DATE = day count; DATE - n shifts.
          final ld = _asSqlDate(l);
          final rd = _asSqlDate(r);
          if (ld != null && rd != null) {
            final diff = ld.difference(rd).inSeconds / 86400.0;
            return diff == diff.roundToDouble() ? diff.toInt() : diff;
          }
          if (ld != null && r is num) return _shiftDate(ld, -r.toDouble(), l);
          return _arith(_toNum(l)!, _toNum(r)!, '-');
        }
      case '*':
        return _arith(_toNum(l)!, _toNum(r)!, '*');
      case '/':
        {
          final d = _toNum(r)!;
          if (d == 0) return null; // SQLite: division by zero yields NULL.
          return _toNum(l)! / d;
        }
      case '%':
        {
          final d = _toNum(r)!;
          if (d == 0) return null;
          // SQLite uses C-style truncated modulo (sign follows the dividend),
          // not Dart's Euclidean `%` which is always non-negative.
          return _toNum(l)!.remainder(d);
        }
      case '&':
        return _toNum(l)!.toInt() & _toNum(r)!.toInt();
      case '|':
        return _toNum(l)!.toInt() | _toNum(r)!.toInt();
      case '<<':
        return _toNum(l)!.toInt() << _toNum(r)!.toInt();
      case '>>':
        return _toNum(l)!.toInt() >> _toNum(r)!.toInt();
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

  static bool _isNoCase(Expr e) => e is CollateExpr && e.collation == 'NOCASE';
  static bool _isRtrim(Expr e) => e is CollateExpr && e.collation == 'RTRIM';
  static bool _eqCI(Object a, Object b) =>
      (a is String && b is String) ? a.toLowerCase() == b.toLowerCase() : _eq(a, b);
  static int _cmpCI(Object a, Object b) => (a is String && b is String)
      ? a.toLowerCase().compareTo(b.toLowerCase())
      : _cmp(a, b);

  /// SQL row-value comparison for `(a, …) <op> (b, …)`. Equality is the AND of
  /// element equalities (any decisive mismatch -> false, else a NULL -> NULL);
  /// ordering compares element-wise, the first difference deciding, with a NULL
  /// before any difference yielding NULL.
  static Object? _rowValueCompare(String op, List<Object?> a, List<Object?> b) {
    final n = a.length < b.length ? a.length : b.length;
    if (op == '=' || op == '!=' || op == '<>') {
      var sawNull = false;
      for (var i = 0; i < n; i++) {
        final x = a[i];
        final y = b[i];
        if (x == null || y == null) {
          sawNull = true;
          continue;
        }
        if (!_eq(x, y)) return op == '=' ? false : true;
      }
      if (a.length != b.length) return op == '=' ? false : true;
      if (sawNull) return null;
      return op == '=';
    }
    for (var i = 0; i < n; i++) {
      final x = a[i];
      final y = b[i];
      if (x == null || y == null) return null;
      final c = _cmp(x, y);
      if (c != 0) {
        switch (op) {
          case '<':
          case '<=':
            return c < 0;
          case '>':
          case '>=':
            return c > 0;
        }
      }
    }
    // All compared positions equal.
    return op == '<=' || op == '>=';
  }

  /// Coerce an arithmetic operand to a number (SQLite affinity rules):
  /// numbers pass through, booleans map to 1/0, numeric strings parse, and
  /// anything non-numeric becomes 0. NULL propagates (callers guard it).
  static num? _toNum(Object? v) {
    if (v == null) return null;
    if (v is num) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is String) return num.tryParse(v.trim()) ?? 0;
    return 0;
  }

  /// Apply an int-or-double arithmetic op ([o] is `+`, `-`, or `*`). When both
  /// operands are integers, detect 64-bit overflow via BigInt and promote to
  /// double, matching SQLite (which keeps the magnitude instead of wrapping).
  static final BigInt _maxInt64 = BigInt.parse('9223372036854775807');
  static final BigInt _minInt64 = BigInt.parse('-9223372036854775808');
  static num _arith(num a, num b, String o) {
    if (a is int && b is int) {
      final ba = BigInt.from(a);
      final bb = BigInt.from(b);
      final big = o == '+'
          ? ba + bb
          : o == '-'
              ? ba - bb
              : ba * bb;
      if (big < _minInt64 || big > _maxInt64) {
        final da = a.toDouble();
        final db = b.toDouble();
        return o == '+'
            ? da + db
            : o == '-'
                ? da - db
                : da * db;
      }
      return big.toInt();
    }
    return o == '+'
        ? a + b
        : o == '-'
            ? a - b
            : a * b;
  }

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

/// A parenthesized row value / tuple: `(a, b, …)`. Evaluates to a `List` so
/// `BinaryExpr` can do element-wise row comparison.
class RowValueExpr extends Expr {
  final List<Expr> items;
  RowValueExpr(this.items);
  @override
  Object? eval(Map<String, Object?> row) => [for (final e in items) e.eval(row)];
}

/// `expr COLLATE <name>`. The value is unchanged; the collation influences how
/// an enclosing comparison/sort treats it (only NOCASE is special-cased here).
class CollateExpr extends Expr {
  final Expr inner;
  final String collation; // uppercased, e.g. NOCASE / BINARY / RTRIM
  CollateExpr(this.inner, this.collation);
  @override
  Object? eval(Map<String, Object?> row) => inner.eval(row);
}

/// The explicit collation name carried by [e] (`expr COLLATE <name>`), or null.
String? collationOf(Expr e) => e is CollateExpr ? e.collation : null;

/// Normalizes [value] for collation-aware dedup / grouping: NOCASE folds case,
/// RTRIM strips trailing spaces. Non-strings and other collations pass through.
Object? applyCollation(Object? value, String? collation) {
  if (value is! String || collation == null) return value;
  switch (collation) {
    case 'NOCASE':
      return value.toLowerCase();
    case 'RTRIM':
      var end = value.length;
      while (end > 0 && value.codeUnitAt(end - 1) == 0x20) {
        end--;
      }
      return value.substring(0, end);
    default:
      return value;
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
    var sawNull = false;
    for (final e in values) {
      final ev = e.eval(row);
      if (ev == null) {
        sawNull = true;
        continue;
      }
      if (BinaryExpr._eq(v, ev)) return !negated;
    }
    // No match: a NULL in the list makes the result UNKNOWN (SQL 3VL), so
    // `NOT IN (…, NULL)` is also NULL — not TRUE.
    if (sawNull) return null;
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
bool evalPredicate(Expr e, Map<String, Object?> row) => sqlTruthy(e.eval(row));

/// Exact-decimal half-up rounding of [value] to [scale] fractional digits.
/// Recovers the intended decimal through a guard-digit string first so binary
/// floating-point noise (1.005 stored as 1.00499999…) rounds like Oracle.
num _roundHalfUpDecimal(num value, int scale) {
  if (value is int) return value;
  final neg = value < 0;
  final abs = value.abs();
  final str = abs.toStringAsFixed(scale + 3); // guard digits kill binary noise
  final dot = str.indexOf('.');
  final intPart = str.substring(0, dot);
  final fracPart = str.substring(dot + 1);
  final keep = scale == 0 ? '' : fracPart.substring(0, scale);
  final roundDigit = int.parse(fracPart[scale]);
  var n = BigInt.parse('$intPart$keep');
  if (roundDigit >= 5) n += BigInt.one;
  final result = n.toDouble() / _pow10(scale);
  return neg ? -result : result;
}

/// Coerce a value to the column's type for storage/comparison purposes.
Object? coerceForColumn(Object? value, ColumnDef col,
    {bool strict = false, bool tableHasRowid = true}) {
  if (value == null) {
    if (col.notNull) {
      throw FormatException('Column ${col.name} is NOT NULL');
    }
    return null;
  }
  // Oracle VARCHAR2(n)/CHAR(n) length enforcement (ORA-12899).
  if (col.charLength != null && value is String) {
    if (value.length > col.charLength!) {
      throw FormatException(
        'ORA-12899: value too large for column ${col.name} '
        '(actual: ${value.length}, maximum: ${col.charLength})',
      );
    }
  }
  // Oracle NUMBER(p[,s]) scale rounding (F110) + precision enforcement
  // (ORA-01438, F114). Applies to numeric values and numeric strings.
  if (col.numericPrecision != null || col.numericScale != null) {
    num? n;
    if (value is num) {
      n = value;
    } else if (value is String) {
      n = num.tryParse(value.trim());
    }
    if (n != null) {
      final scale = col.numericScale ?? 0;
      // Exact-decimal half-up rounding to the declared scale (Oracle NUMBER is
      // decimal, not binary — 1.005 -> 1.01, not the double's 1.00). A negative
      // scale rounds to the left of the decimal point (NUMBER(5,-2): 12345 ->
      // 12300).
      num rounded;
      if (scale >= 0) {
        rounded = _roundHalfUpDecimal(n, scale);
      } else {
        final factor = _pow10(-scale);
        rounded = (n / factor).roundToDouble() * factor;
      }
      // Normalize integral doubles back to int.
      if (rounded is double && rounded == rounded.truncateToDouble()) {
        rounded = rounded.toInt();
      }
      if (col.numericPrecision != null) {
        final maxDigits = col.numericPrecision! - scale;
        final limit = _pow10(maxDigits);
        if (rounded.abs() >= limit) {
          throw FormatException(
            'ORA-01438: value larger than specified precision allowed for '
            'column ${col.name}',
          );
        }
      }
      value = rounded;
    }
  }
  // Oracle CHAR(n) / NCHAR(n) are fixed-length: blank-pad a shorter string to
  // the declared length (LENGTH('ab') in a CHAR(5) column is 5).
  if (col.charLength != null && value is String) {
    final dt = col.declaredType?.toUpperCase();
    if ((dt == 'CHAR' || dt == 'NCHAR' || dt == 'CHARACTER') &&
        value.length < col.charLength!) {
      value = value.padRight(col.charLength!);
    }
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
        'STRICT: column ${col.name} expects ${col.type.name}, got ${value.runtimeType}',
      );
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
    // An INTEGER PRIMARY KEY is a rowid alias: SQLite requires an integer and
    // raises "datatype mismatch" for a non-integer value, unlike a regular
    // INTEGER column's loose affinity (which stores it unchanged). A WITHOUT
    // ROWID table's INTEGER PRIMARY KEY is not a rowid alias, so it keeps the
    // loose affinity.
    final rowidAlias =
        tableHasRowid && col.primaryKey && col.type == DataType.integer;
    final Object? converted;
    try {
      converted = coerce(value, col.type);
    } on FormatException {
      if (rowidAlias) throw const FormatException('datatype mismatch');
      return value;
    }
    if (rowidAlias && converted is! int) {
      throw const FormatException('datatype mismatch');
    }
    return converted;
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
  // IEEE equality first so -0.0 compares equal to 0.0 (Dart's num.compareTo is a
  // total order that ranks -0.0 below 0.0, which would make `0 > -0.0` true).
  if (a is num && b is num) return a == b ? 0 : a.compareTo(b);
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

/// SQL boolean truthiness: bool passes through; any non-zero number is true;
/// a string takes its numeric value (non-numeric -> 0 -> false); NULL/other
/// are false. Matches SQLite/MySQL `WHERE`/`CASE WHEN`/`iif` semantics.
bool sqlTruthy(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return (num.tryParse(v.trim()) ?? 0) != 0;
  return false;
}

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
          final i = int.tryParse(v.trim());
          if (i != null) return i;
          // SQLite parses the leading numeric prefix ('42abc' -> 42).
          return _sqlTextToNum(v).truncate();
        }
        if (v is bool) return v ? 1 : 0;
        return coerce(v, targetType);
      case DataType.real:
        if (v is num) return v.toDouble();
        if (v is String) return _sqlTextToNum(v).toDouble();
        return coerce(v, targetType);
      case DataType.text:
        // CAST(<blob> AS TEXT) decodes the bytes (SQLite), not list.toString().
        if (v is List<int>) {
          try {
            return utf8.decode(v);
          } catch (_) {
            return String.fromCharCodes(v);
          }
        }
        return v.toString();
      case DataType.blob:
        // SQLite yields the blob of the value's text representation.
        if (v is List<int>) return v;
        return utf8.encode(v.toString());
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

  /// Optional `ORDER BY ...` inside an aggregate call (SQL standard,
  /// SQLite ≥ 3.44). Currently honored by GROUP_CONCAT / STRING_AGG /
  /// LISTAGG / JSON_GROUP_ARRAY / JSON_GROUP_OBJECT.
  final List<WindowOrderItem>? aggOrderBy;
  FunctionCallExpr(
    this.name,
    this.args, {
    this.isStarArg = false,
    this.distinct = false,
    this.window,
    this.filterExpr,
    this.aggOrderBy,
    this.keepFirst,
    this.keepOrderBy,
    this.ignoreNulls = false,
  });

  /// Oracle `KEEP (DENSE_RANK FIRST|LAST ORDER BY …)` ordered-set modifier:
  /// true = FIRST, false = LAST, null = no KEEP. [keepOrderBy] ranks the group.
  final bool? keepFirst;
  final List<WindowOrderItem>? keepOrderBy;

  /// `IGNORE NULLS` modifier (FIRST_VALUE/LAST_VALUE/LAG/LEAD): skip NULLs when
  /// picking the value. Default false = RESPECT NULLS.
  final bool ignoreNulls;

  bool get isAggregate => kAggregateFunctions.contains(name);
  bool get isWindow => window != null;

  /// Per-row precomputed window values, set by the SELECT executor before it
  /// evaluates a projection row. Lets a window call nested inside a larger
  /// scalar expression (e.g. `'row ' || ROW_NUMBER() OVER ()`, which is how
  /// Oracle ROWNUM lowers) resolve to its row value instead of being treated
  /// as an unknown scalar function.
  static Map<FunctionCallExpr, Object?>? windowRowValues;

  /// Resolver for user-defined (stored) functions, set by the active Database
  /// while dispatching. Invoked synchronously when [name] is not a built-in
  /// scalar; it runs the stored function and returns its value, or throws if no
  /// such function exists.
  static Object? Function(String name, List<Object?> args)?
      storedFunctionResolver;

  @override
  Object? eval(Map<String, Object?> row) {
    if (isWindow) {
      final wv = windowRowValues;
      if (wv != null && wv.containsKey(this)) return wv[this];
      throw StateError(
        'Window function $name() OVER (...) is only valid in a query projection',
      );
    }
    if (isAggregate) {
      throw StateError(
        'Aggregate function $name() cannot be evaluated as a scalar',
      );
    }
    final fn = kScalarFunctions[name];
    if (fn == null) {
      // SYS_CONNECT_BY_PATH(col, sep): build the root→node path from the
      // ancestor chain the CONNECT BY executor stores under `__CBP`.
      if (name == 'SYS_CONNECT_BY_PATH') {
        final sep = args.length > 1 ? (args[1].eval(row)?.toString() ?? '') : '';
        final chain = row['__CBP'];
        final nodes = chain is List ? chain : <Object?>[row];
        final buf = StringBuffer();
        for (final n in nodes) {
          final v = args[0].eval(n is Map<String, Object?> ? n : row);
          buf..write(sep)..write(v ?? '');
        }
        return buf.toString();
      }
      // CONNECT_BY_ROOT expr: evaluate [expr] against the hierarchy root (the
      // first ancestor in the `__CBP` chain the CONNECT BY executor stores).
      if (name == 'CONNECT_BY_ROOT') {
        final chain = row['__CBP'];
        final rootRow = (chain is List && chain.isNotEmpty)
            ? chain.first
            : row;
        return args.isEmpty
            ? null
            : args[0].eval(rootRow is Map<String, Object?> ? rootRow : row);
      }
      final resolver = storedFunctionResolver;
      if (resolver != null) {
        return resolver(name, args.map((a) => a.eval(row)).toList());
      }
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
    var sawNull = false;
    for (final ev in list) {
      if (ev == null) {
        sawNull = true;
        continue;
      }
      if (sqlEq(v, ev)) return !negated;
    }
    // No match: a NULL in the result set makes it UNKNOWN (SQL 3VL), so
    // `NOT IN (… NULL …)` is NULL — never TRUE.
    if (sawNull) return null;
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

/// `OVER (PARTITION BY ... ORDER BY ... frame)` specification attached
/// to a `FunctionCallExpr` to make it a window function. Either an
/// inline spec or a `baseName` referencing a named window in the SELECT.
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

/// SQLite text→number coercion: a number passes through, a bool maps to 1/0,
/// and a string yields its leading numeric prefix (e.g. `'42abc'`→42,
/// `'3.14xyz'`→3.14, `'abc'`→0). Used by math scalars and CAST.
final RegExp _leadingNumRe =
    RegExp(r'^[ \t\n\r]*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)');
num _sqlTextToNum(Object? v) {
  if (v is num) return v;
  if (v is bool) return v ? 1 : 0;
  if (v is! String) return 0;
  final m = _leadingNumRe.firstMatch(v);
  if (m == null) return 0;
  return num.tryParse(m.group(1)!) ?? 0;
}
String _trimChars(String s, String chars, {required bool left, required bool right}) {
  if (chars.isEmpty) return s;
  final set = chars.split('').toSet();
  var start = 0;
  var end = s.length;
  if (left) {
    while (start < end && set.contains(s[start])) {
      start++;
    }
  }
  if (right) {
    while (end > start && set.contains(s[end - 1])) {
      end--;
    }
  }
  return s.substring(start, end);
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
          // C/SQLite use a >=2-digit exponent (`e+03`, not Dart's `e+3`).
          body = _fixExponentWidth(n.toStringAsExponential(p));
        } else {
          body = _formatG(n, p == 0 ? 1 : p, alt);
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

/// Pad a `toStringAsExponential` result's exponent to the C/SQLite minimum of
/// two digits: `1.5e+3` -> `1.5e+03`.
String _fixExponentWidth(String s) {
  final m = RegExp(r'^(.*[eE])([+-])(\d+)$').firstMatch(s);
  if (m == null) return s;
  return '${m.group(1)}${m.group(2)}${m.group(3)!.padLeft(2, '0')}';
}

/// C `printf('%g')`: choose `%e` or `%f` by magnitude and strip trailing
/// zeros (unless the `#`/alt flag is set).
String _formatG(double n, int p, bool alt) {
  if (n == 0) return '0';
  final probe = n.toStringAsExponential(p - 1);
  final x = int.parse(RegExp(r'[eE]([+-]?\d+)$').firstMatch(probe)!.group(1)!);
  String body;
  if (x < -4 || x >= p) {
    body = n.toStringAsExponential(p - 1);
    if (!alt) body = _stripExpTrailingZeros(body);
    body = _fixExponentWidth(body);
  } else {
    final prec = p - 1 - x;
    body = n.toStringAsFixed(prec < 0 ? 0 : prec);
    if (!alt) body = _stripFixedTrailingZeros(body);
  }
  return body;
}

String _stripFixedTrailingZeros(String s) {
  if (!s.contains('.')) return s;
  var r = s.replaceFirst(RegExp(r'0+$'), '');
  if (r.endsWith('.')) r = r.substring(0, r.length - 1);
  return r;
}

String _stripExpTrailingZeros(String s) {
  final m = RegExp(r'^([^eE]*)([eE].*)$').firstMatch(s);
  if (m == null) return s;
  var mant = m.group(1)!;
  if (mant.contains('.')) {
    mant = mant.replaceFirst(RegExp(r'0+$'), '');
    if (mant.endsWith('.')) mant = mant.substring(0, mant.length - 1);
  }
  return '$mant${m.group(2)}';
}

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
  'CHAR_LENGTH': (a) => kScalarFunctions['LENGTH']!(a),
  'CHARACTER_LENGTH': (a) => kScalarFunctions['LENGTH']!(a),
  // OCTET_LENGTH: UTF-8 byte length for text, byte length for blobs.
  'OCTET_LENGTH': (a) => _propagateNull(a, () {
        final v = a[0]!;
        if (v is List<int>) return v.length;
        return utf8.encode(v.toString()).length;
      }),
  // BIT_LENGTH: OCTET_LENGTH * 8.
  'BIT_LENGTH': (a) => _propagateNull(a, () {
        final v = a[0]!;
        if (v is List<int>) return v.length * 8;
        return utf8.encode(v.toString()).length * 8;
      }),
  // Oracle byte-semantics string functions (UTF-8 byte offsets/lengths).
  'LENGTHB': (a) =>
      _propagateNull(a, () => utf8.encode(a[0].toString()).length),
  'SUBSTRB': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final bytes = utf8.encode(a[0].toString());
    if (a.length < 2) return a[0].toString();
    final start = _sqlTextToNum(a[1]).toInt();
    var idx = start > 0
        ? start - 1
        : (start == 0 ? 0 : bytes.length + start);
    if (idx < 0) idx = 0;
    if (idx >= bytes.length) return '';
    var end = bytes.length;
    if (a.length >= 3 && a[2] != null) {
      final len = _sqlTextToNum(a[2]).toInt();
      end = (idx + (len < 0 ? 0 : len)).clamp(0, bytes.length);
    }
    return utf8.decode(bytes.sublist(idx, end), allowMalformed: true);
  },
  'INSTRB': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final hay = utf8.encode(a[0].toString());
    final needle = utf8.encode(a[1].toString());
    if (needle.isEmpty) return 1;
    for (var i = 0; i + needle.length <= hay.length; i++) {
      var match = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          match = false;
          break;
        }
      }
      if (match) return i + 1;
    }
    return 0;
  },
  // BITAND(a, b): bitwise AND of two integers.
  'BITAND': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    return _sqlTextToNum(a[0]).toInt() & _sqlTextToNum(a[1]).toInt();
  },
  // BIN_TO_NUM(bit, …): interpret the arguments as a binary vector (MSB first).
  'BIN_TO_NUM': (a) {
    if (a.isEmpty || a.any((x) => x == null)) return null;
    var result = 0;
    for (final x in a) {
      result = (result << 1) | (_sqlTextToNum(x).toInt() != 0 ? 1 : 0);
    }
    return result;
  },
  // ORA_HASH(expr [, max_bucket [, seed]]): deterministic bucket hash.
  'ORA_HASH': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final maxBucket = a.length > 1 && a[1] != null
        ? _sqlTextToNum(a[1]).toInt()
        : 4294967295;
    final seed = a.length > 2 && a[2] != null ? _sqlTextToNum(a[2]).toInt() : 0;
    var h = 0x811c9dc5; // FNV-1a 32-bit.
    for (final c in utf8.encode('${a[0]}|$seed')) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return maxBucket <= 0 ? 0 : h % (maxBucket + 1);
  },
  // LEAST(a, b, ...) -- smallest non-NULL value; returns NULL if all NULL.
  'LEAST': (a) {
    if (a.any((v) => v == null)) return null; // any NULL -> NULL (Oracle/SQLite)
    Object? best;
    for (final v in a) {
      if (best == null || sqlCompare(v!, best) < 0) best = v;
    }
    return best;
  },
  // GREATEST(a, b, ...) -- NULL when any argument is NULL, else the largest.
  'GREATEST': (a) {
    if (a.any((v) => v == null)) return null;
    Object? best;
    for (final v in a) {
      if (best == null || sqlCompare(v!, best) > 0) best = v;
    }
    return best;
  },
  'TRIM': (a) => _propagateNull(
        a,
        () => a.length >= 2
            ? _trimChars(a[0].toString(), a[1].toString(), left: true, right: true)
            : a[0].toString().trim(),
      ),
  'LTRIM': (a) => _propagateNull(
        a,
        () => a.length >= 2
            ? _trimChars(a[0].toString(), a[1].toString(), left: true, right: false)
            : a[0].toString().replaceFirst(RegExp(r'^\s+'), ''),
      ),
  'RTRIM': (a) => _propagateNull(
        a,
        () => a.length >= 2
            ? _trimChars(a[0].toString(), a[1].toString(), left: false, right: true)
            : a[0].toString().replaceFirst(RegExp(r'\s+$'), ''),
      ),
  'SUBSTR': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final s = a[0].toString();
    if (a.length < 2) return s;
    final start = _sqlTextToNum(a[1]).toInt();
    // SQL is 1-based. A start of 0 means "before position 1" and a negative
    // start counts from the end; either way the window begins at the string
    // start, but the part that falls before position 1 still consumes length.
    int idx;
    var consumed = 0;
    if (start > 0) {
      idx = start - 1;
    } else if (start == 0) {
      idx = 0;
      consumed = 1;
    } else {
      idx = s.length + start;
      if (idx < 0) {
        consumed = -idx;
        idx = 0;
      }
    }
    if (idx >= s.length) return '';
    if (a.length >= 3 && a[2] != null) {
      final len = _sqlTextToNum(a[2]).toInt();
      if (len < 0) {
        // SQLite: a negative length returns the |len| characters that
        // precede the start position (walking backward from `idx`).
        final back = (idx + len).clamp(0, s.length);
        return s.substring(back, idx);
      }
      final end = (idx + (len - consumed).clamp(0, s.length)).clamp(0, s.length);
      return s.substring(idx, end);
    }
    return s.substring(idx);
  },
  'SUBSTRING': (a) => kScalarFunctions['SUBSTR']!(a),
  // LEFT(s, n) -- first n characters.
  'LEFT': (a) => _propagateNull(a, () {
        final s = a[0].toString();
        final n = (a[1] as num).toInt();
        if (n <= 0) return '';
        return n >= s.length ? s : s.substring(0, n);
      }),
  // RIGHT(s, n) -- last n characters.
  'RIGHT': (a) => _propagateNull(a, () {
        final s = a[0].toString();
        final n = (a[1] as num).toInt();
        if (n <= 0) return '';
        return n >= s.length ? s : s.substring(s.length - n);
      }),
  // POSITION(needle IN haystack) is parsed as POSITION(needle, haystack)
  // here; returns 1-based index, 0 when not found, NULL on NULL input.
  'POSITION': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final needle = a[0].toString();
    final hay = a[1].toString();
    if (needle.isEmpty) return 1;
    return hay.indexOf(needle) + 1;
  },
  // OVERLAY(s, replacement, start [, length]) -- replace `length`
  // characters of `s` starting at 1-based `start` with `replacement`.
  // When length is omitted it defaults to the length of `replacement`.
  'OVERLAY': (a) {
    if (a.length < 3 || a[0] == null || a[1] == null || a[2] == null) {
      return null;
    }
    final s = a[0].toString();
    final repl = a[1].toString();
    final start = (a[2] as num).toInt();
    final length =
        a.length >= 4 && a[3] != null ? (a[3] as num).toInt() : repl.length;
    final idx = (start - 1).clamp(0, s.length);
    final endIdx = (idx + length).clamp(0, s.length);
    return s.substring(0, idx) + repl + s.substring(endIdx);
  },
  // REVERSE(s) -- reverses a string by Unicode code points.
  'REVERSE': (a) => _propagateNull(a, () {
        final s = a[0].toString();
        return String.fromCharCodes(s.runes.toList().reversed);
      }),
  // REPEAT(s, n) -- string repetition; negative or zero count returns ''.
  'REPEAT': (a) => _propagateNull(a, () {
        final s = a[0].toString();
        final n = (a[1] as num).toInt();
        if (n <= 0) return '';
        return s * n;
      }),
  // ASCII(s) -- code point of the first character. SQLite returns the
  // codepoint of the first UTF-8 byte in the input; we mirror Dart's
  // String.codeUnitAt(0) which is the UTF-16 code unit, equivalent for
  // ASCII inputs.
  'ASCII': (a) => _propagateNull(a, () {
        final s = a[0].toString();
        return s.isEmpty ? null : s.codeUnitAt(0);
      }),
  // CHR(n) -- single-character string from a Unicode codepoint.
  'CHR': (a) => _propagateNull(a, () {
        return String.fromCharCode((a[0] as num).toInt());
      }),
  // SPACE(n) -- string of n spaces.
  'SPACE': (a) => _propagateNull(a, () {
        final n = (a[0] as num).toInt();
        return n <= 0 ? '' : ' ' * n;
      }),
  // INITCAP(s) -- title-case each whitespace-separated word.
  'INITCAP': (a) => _propagateNull(a, () {
        final s = a[0].toString();
        if (s.isEmpty) return s;
        final out = StringBuffer();
        var nextUpper = true;
        for (var i = 0; i < s.length; i++) {
          final c = s[i];
          if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            out.write(c);
            nextUpper = true;
            continue;
          }
          out.write(nextUpper ? c.toUpperCase() : c.toLowerCase());
          nextUpper = false;
        }
        return out.toString();
      }),
  'REPLACE': (a) => _propagateNull(
        a,
        () {
          final search = a[1].toString();
          // An empty search string matches nothing (SQLite): return unchanged.
          if (search.isEmpty) return a[0].toString();
          // Oracle 2-arg REPLACE(s, sub) removes sub (replacement defaults to '').
          final repl = a.length > 2 && a[2] != null ? a[2].toString() : '';
          return a[0].toString().replaceAll(search, repl);
        },
      ),
  'CONCAT': (a) => a.map((v) => v ?? '').join(),
  // CONCAT_WS(sep, args...) — joins non-NULL args with the given separator.
  // If sep is NULL, returns NULL (matches MySQL/PostgreSQL semantics).
  'CONCAT_WS': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final sep = a[0].toString();
    final parts = <String>[];
    for (var i = 1; i < a.length; i++) {
      final v = a[i];
      if (v == null) continue;
      parts.add(v.toString());
    }
    return parts.join(sep);
  },
  'COALESCE': (a) {
    for (final v in a) {
      if (v != null) return v;
    }
    return null;
  },
  'IFNULL': (a) => a[0] ?? (a.length > 1 ? a[1] : null),
  'NVL': (a) => a[0] ?? (a.length > 1 ? a[1] : null),
  'NVL2': (a) {
    if (a.length < 3) return null;
    return a[0] != null ? a[1] : a[2];
  },
  'DECODE': (a) {
    // DECODE(expr, search1, result1, [search2, result2, ...] [, default])
    if (a.isEmpty) return null;
    final expr = a[0];
    var i = 1;
    while (i + 1 < a.length) {
      final s = a[i];
      if ((expr == null && s == null) ||
          (expr != null && s != null && sqlEq(expr, s))) {
        return a[i + 1];
      }
      i += 2;
    }
    return i < a.length ? a[i] : null;
  },
  'NULLIF': (a) {
    if (a.length < 2 || a[0] == null) return a.isEmpty ? null : a[0];
    if (a[1] == null) return a[0];
    return sqlEq(a[0]!, a[1]!) ? null : a[0];
  },
  'ABS': (a) => _propagateNull(a, () => _sqlTextToNum(a[0]).abs()),
  'ROUND': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v0 = a[0];
    // ROUND(date[, fmt]) rounds a date to the nearest unit (Oracle rounding
    // model). Default rounds to the nearest day (noon rounds up).
    if (v0 is String && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(v0.trim())) {
      final dt = _parseDateTime(v0);
      if (dt != null) {
        final fmt = a.length > 1 && a[1] != null
            ? a[1].toString().toUpperCase()
            : 'DD';
        DateTime out;
        switch (fmt) {
          case 'YYYY':
          case 'YYY':
          case 'YY':
          case 'Y':
          case 'YEAR':
          case 'SYYYY':
          case 'SYEAR':
            out = dt.month >= 7
                ? DateTime.utc(dt.year + 1, 1, 1)
                : DateTime.utc(dt.year, 1, 1);
            break;
          case 'MM':
          case 'MON':
          case 'MONTH':
          case 'RM':
            out = dt.day >= 16
                ? DateTime.utc(dt.year, dt.month + 1, 1)
                : DateTime.utc(dt.year, dt.month, 1);
            break;
          case 'HH':
          case 'HH12':
          case 'HH24':
            out = DateTime.utc(dt.year, dt.month, dt.day, dt.hour)
                .add(Duration(hours: dt.minute >= 30 ? 1 : 0));
            break;
          case 'MI':
            out = DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute)
                .add(Duration(minutes: dt.second >= 30 ? 1 : 0));
            break;
          default:
            final day = DateTime.utc(dt.year, dt.month, dt.day);
            out = dt.hour >= 12 ? day.add(const Duration(days: 1)) : day;
        }
        final hasTime = out.hour != 0 || out.minute != 0 || out.second != 0;
        return hasTime ? _fmtDateTime(out) : _fmtDate(out);
      }
    }
    final v = _sqlTextToNum(v0).toDouble();
    final digits = a.length > 1 && a[1] != null ? _sqlTextToNum(a[1]).toInt() : 0;
    final p = _pow10(digits);
    return (v * p).round() / p;
  },
  'MOD': (a) => _propagateNull(
      a, () => _sqlTextToNum(a[0]).remainder(_sqlTextToNum(a[1]))),
  // Oracle REMAINDER(n, m) = n - m * ROUND(n/m) — rounds the quotient (ties to
  // even) rather than flooring like MOD: REMAINDER(17, 6) = -1.
  'REMAINDER': (a) => _propagateNull(a, () {
        final n = _sqlTextToNum(a[0]).toDouble();
        final m = _sqlTextToNum(a[1]).toDouble();
        if (m == 0) return null;
        final q = (n / m).roundToDouble();
        final r = n - m * q;
        return r == r.truncateToDouble() ? r.toInt() : r;
      }),
  'FLOOR': (a) => _propagateNull(a, () => _sqlTextToNum(a[0]).floor()),
  'CEIL': (a) => _propagateNull(a, () => _sqlTextToNum(a[0]).ceil()),
  'CEILING': (a) => _propagateNull(a, () => _sqlTextToNum(a[0]).ceil()),
  'SQRT': (a) => _propagateNull(a, () {
        final v = _sqlTextToNum(a[0]).toDouble();
        if (v < 0) return null;
        return _sqrt(v);
      }),
  'POWER': (a) => _propagateNull(
        a,
        () => _intPow(_sqlTextToNum(a[0]).toDouble(), _sqlTextToNum(a[1]).toDouble()),
      ),
  'POW': (a) => kScalarFunctions['POWER']!(a),
  'SIGN': (a) => _propagateNull(a, () {
        final v = _sqlTextToNum(a[0]).toDouble();
        if (v == 0) return 0;
        return v > 0 ? 1 : -1;
      }),
  // SQLite 3.35+ math functions. All operate in double precision and
  // return NULL on NULL input. Domain errors (e.g. LN(0), SQRT(-1))
  // return NULL to match SQLite.
  'PI': (a) => math.pi,
  // GROUPING(expr) — context-sensitive. The select executor rewrites
  // results from GROUPING SETS / ROLLUP / CUBE so this default 0
  // applies only when the expression IS in the current grouping set.
  'GROUPING': (a) => 0,
  // Default 0; overwritten to the per-set bit vector by _selectGroupingSets.
  'GROUPING_ID': (a) => 0,
  // WIDTH_BUCKET(expr, min, max, buckets): equi-width histogram bucket.
  // 0 for below-range, buckets+1 for at/above max.
  'WIDTH_BUCKET': (a) {
    if (a.length < 4 || a[0] == null || a[1] == null || a[2] == null ||
        a[3] == null) {
      return null;
    }
    final e = _sqlTextToNum(a[0]).toDouble();
    final lo = _sqlTextToNum(a[1]).toDouble();
    final hi = _sqlTextToNum(a[2]).toDouble();
    final n = _sqlTextToNum(a[3]).toInt();
    if (lo == hi || n <= 0) return null;
    final asc = hi > lo;
    final mn = asc ? lo : hi;
    final mx = asc ? hi : lo;
    if (e < mn) return asc ? 0 : n + 1;
    if (e >= mx) return asc ? n + 1 : 0;
    final b = ((e - lo) / (hi - lo) * n).floor() + 1;
    return b.clamp(1, n);
  },
  'IIF': (a) {
    if (a.length < 3) return null;
    final c = a[0];
    final truthy = c is bool
        ? c
        : c is num
            ? c != 0
            : c != null;
    return truthy ? a[1] : a[2];
  },
  'CBRT': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v < 0) return -math.pow(-v, 1 / 3).toDouble();
        return math.pow(v, 1 / 3).toDouble();
      }),
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
  'COT': (a) => _propagateNull(a, () {
        final t = math.tan((a[0] as num).toDouble());
        if (t == 0) return null;
        return 1.0 / t;
      }),
  'ACOT': (a) => _propagateNull(a, () {
        final v = (a[0] as num).toDouble();
        if (v == 0) return math.pi / 2;
        return math.atan(1.0 / v);
      }),
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
        a,
        () => math.atan2((a[0] as num).toDouble(), (a[1] as num).toDouble()),
      ),
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
  'ASINH': (a) => _propagateNull(a, () {
        final x = (a[0] as num).toDouble();
        return math.log(x + math.sqrt(x * x + 1));
      }),
  'ACOSH': (a) => _propagateNull(a, () {
        final x = (a[0] as num).toDouble();
        if (x < 1) return null;
        return math.log(x + math.sqrt(x * x - 1));
      }),
  'ATANH': (a) => _propagateNull(a, () {
        final x = (a[0] as num).toDouble();
        if (x <= -1 || x >= 1) return null;
        return 0.5 * math.log((1 + x) / (1 - x));
      }),
  'RADIANS': (a) =>
      _propagateNull(a, () => (a[0] as num).toDouble() * math.pi / 180),
  'DEGREES': (a) =>
      _propagateNull(a, () => (a[0] as num).toDouble() * 180 / math.pi),
  'TRUNC': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v0 = a[0];
    // TRUNC(date[, fmt]) truncates a date to the unit implied by [fmt]
    // (default: start of day).
    if (v0 is String && RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(v0.trim())) {
      final dt = _parseDateTime(v0);
      if (dt != null) {
        final fmt = a.length > 1 && a[1] != null
            ? a[1].toString().toUpperCase()
            : 'DD';
        DateTime out;
        switch (fmt) {
          case 'YYYY':
          case 'YYY':
          case 'YY':
          case 'Y':
          case 'YEAR':
          case 'SYYYY':
          case 'SYEAR':
          case 'CC':
          case 'SCC':
            out = DateTime.utc(dt.year, 1, 1);
            break;
          case 'Q':
            out = DateTime.utc(dt.year, ((dt.month - 1) ~/ 3) * 3 + 1, 1);
            break;
          case 'MM':
          case 'MON':
          case 'MONTH':
          case 'RM':
            out = DateTime.utc(dt.year, dt.month, 1);
            break;
          case 'IW':
          case 'WW':
          case 'DAY':
          case 'DY':
          case 'D':
            final day = DateTime.utc(dt.year, dt.month, dt.day);
            out = day.subtract(Duration(days: day.weekday % 7)); // week start Sun
            break;
          case 'HH':
          case 'HH12':
          case 'HH24':
            out = DateTime.utc(dt.year, dt.month, dt.day, dt.hour);
            break;
          case 'MI':
            out = DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute);
            break;
          default:
            out = DateTime.utc(dt.year, dt.month, dt.day);
        }
        final hasTime = out.hour != 0 || out.minute != 0 || out.second != 0;
        return hasTime ? _fmtDateTime(out) : _fmtDate(out);
      }
    }
    final n = _sqlTextToNum(v0).toDouble();
    final places = a.length > 1 && a[1] != null ? _sqlTextToNum(a[1]).toInt() : 0;
    final p = _pow10(places);
    final t = (n * p).truncateToDouble() / p;
    return places <= 0 ? t.toInt() : t;
  },
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
    final src = a[0].toString();
    final re = RegExp(a[1].toString());
    // REGEXP_SUBSTR(src, pat [, position [, occurrence [, match_param
    // [, subexpr]]]]): 1-based position/occurrence.
    final position = a.length > 2 && a[2] != null ? _sqlTextToNum(a[2]).toInt() : 1;
    final occurrence = a.length > 3 && a[3] != null ? _sqlTextToNum(a[3]).toInt() : 1;
    if (position < 1 || occurrence < 1) return null;
    final start = (position - 1).clamp(0, src.length);
    final matches = re.allMatches(src, start).toList();
    if (occurrence > matches.length) return null;
    return matches[occurrence - 1].group(0);
  },
  'REGEXP_COUNT': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final src = a[0].toString();
    final re = RegExp(a[1].toString());
    final position = a.length > 2 && a[2] != null ? _sqlTextToNum(a[2]).toInt() : 1;
    final start = (position - 1).clamp(0, src.length);
    return re.allMatches(src, start).length;
  },
  'REGEXP_INSTR': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final src = a[0].toString();
    final re = RegExp(a[1].toString());
    // REGEXP_INSTR(src, pat [, position [, occurrence [, return_opt …]]]):
    // return_opt 0 => start of match, 1 => position after the match. 1-based.
    final position = a.length > 2 && a[2] != null ? _sqlTextToNum(a[2]).toInt() : 1;
    final occurrence = a.length > 3 && a[3] != null ? _sqlTextToNum(a[3]).toInt() : 1;
    final returnOpt = a.length > 4 && a[4] != null ? _sqlTextToNum(a[4]).toInt() : 0;
    if (position < 1 || occurrence < 1) return 0;
    final start = (position - 1).clamp(0, src.length);
    final matches = re.allMatches(src, start).toList();
    if (occurrence > matches.length) return 0;
    final m = matches[occurrence - 1];
    return (returnOpt == 0 ? m.start : m.end) + 1;
  },
  'REGEXP_REPLACE': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final src = a[0].toString();
    final re = RegExp(a[1].toString());
    // Replacement may be omitted (removes matches) and supports Oracle
    // backreferences \1..\9 (and \0 for the whole match).
    final repl = a.length > 2 && a[2] != null ? a[2].toString() : '';
    final position =
        a.length > 3 && a[3] != null ? _sqlTextToNum(a[3]).toInt() : 1;
    // Occurrence 0 (default) replaces every match; n replaces only the nth.
    final occurrence =
        a.length > 4 && a[4] != null ? _sqlTextToNum(a[4]).toInt() : 0;
    String expand(Match m) {
      final sb = StringBuffer();
      for (var i = 0; i < repl.length; i++) {
        final ch = repl[i];
        if (ch == r'\' && i + 1 < repl.length) {
          final nx = repl[i + 1];
          if (nx == r'\') {
            sb.write(r'\');
            i++;
            continue;
          }
          final d = int.tryParse(nx);
          if (d != null) {
            if (d == 0) {
              sb.write(m.group(0) ?? '');
            } else {
              sb.write(d <= m.groupCount ? (m.group(d) ?? '') : '');
            }
            i++;
            continue;
          }
        }
        sb.write(ch);
      }
      return sb.toString();
    }

    final cut = (position - 1).clamp(0, src.length);
    final prefix = src.substring(0, cut);
    final rest = src.substring(cut);
    String result;
    if (occurrence == 0) {
      result = rest.replaceAllMapped(re, expand);
    } else {
      var count = 0;
      result = rest.replaceAllMapped(re, (m) {
        count++;
        return count == occurrence ? expand(m) : m.group(0)!;
      });
    }
    return prefix + result;
  },
  'RANDOM': (a) => _rng.nextInt(1 << 31),
  'INSTR': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final hay = a[0].toString();
    final needle = a[1].toString();
    if (needle.isEmpty) return 1;
    if (a.length <= 2) return hay.indexOf(needle) + 1; // 1-based; 0 = not found
    // Oracle INSTR(str, sub, position, occurrence): 1-based; a negative
    // position searches backward from the end.
    final pos = a[2] == null ? 1 : _sqlTextToNum(a[2]).toInt();
    final occ = a.length > 3 && a[3] != null ? _sqlTextToNum(a[3]).toInt() : 1;
    if (pos == 0 || occ < 1) return 0;
    if (pos > 0) {
      var idx = pos - 1;
      var found = -1;
      for (var k = 0; k < occ; k++) {
        if (idx > hay.length) return 0;
        found = hay.indexOf(needle, idx);
        if (found < 0) return 0;
        idx = found + 1;
      }
      return found + 1;
    }
    var start = hay.length + pos;
    var found = -1;
    for (var k = 0; k < occ; k++) {
      if (start < 0) return 0;
      found = hay.lastIndexOf(needle, start);
      if (found < 0) return 0;
      start = found - 1;
    }
    return found + 1;
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
  // ZEROBLOB(n) -- BLOB of n zero bytes.
  'ZEROBLOB': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final n = (a[0] as num).toInt();
    if (n < 0) return Uint8List(0);
    return Uint8List(n);
  },
  // RANDOMBLOB(n) -- BLOB of n random bytes.
  'RANDOMBLOB': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final n = (a[0] as num).toInt();
    if (n <= 0) return <int>[];
    return List<int>.generate(n, (_) => _rng.nextInt(256));
  },
  // QUOTE(X) -- SQL literal form of X. Strings become 'escaped',
  // BLOBs become X'hex', NULL becomes 'NULL', numbers stringified.
  'QUOTE': (a) {
    if (a.isEmpty) return null;
    final v = a[0];
    if (v == null) return 'NULL';
    if (v is List<int>) {
      final sb = StringBuffer("X'");
      for (final b in v) {
        sb.write((b & 0xFF).toRadixString(16).padLeft(2, '0').toUpperCase());
      }
      sb.write("'");
      return sb.toString();
    }
    if (v is num || v is bool) return v.toString();
    return "'${v.toString().replaceAll("'", "''")}'";
  },
  // LIKELY(X), UNLIKELY(X), LIKELIHOOD(X, _) -- optimizer hints; we just
  // return X. The constant probability arg to LIKELIHOOD is ignored.
  'LIKELY': (a) => a.isEmpty ? null : a[0],
  'UNLIKELY': (a) => a.isEmpty ? null : a[0],
  'LIKELIHOOD': (a) => a.isEmpty ? null : a[0],
  // SOUNDEX(s) -- classic Soundex algorithm; returns 4-char code.
  // NULL or empty string returns '?000' (matches SQLite's odd convention).
  'SOUNDEX': (a) {
    if (a.isEmpty || a[0] == null) return '?000';
    final s = a[0].toString();
    if (s.isEmpty) return '?000';
    int upper(int cu) => (cu >= 0x61 && cu <= 0x7A) ? cu - 0x20 : cu;
    String code(int cu) {
      switch (upper(cu)) {
        case 0x42:
        case 0x46:
        case 0x50:
        case 0x56:
          return '1';
        case 0x43:
        case 0x47:
        case 0x4A:
        case 0x4B:
        case 0x51:
        case 0x53:
        case 0x58:
        case 0x5A:
          return '2';
        case 0x44:
        case 0x54:
          return '3';
        case 0x4C:
          return '4';
        case 0x4D:
        case 0x4E:
          return '5';
        case 0x52:
          return '6';
        default:
          return '';
      }
    }

    bool isHW(int cu) {
      final u = upper(cu);
      return u == 0x48 || u == 0x57; // H or W
    }

    final out = StringBuffer(String.fromCharCode(upper(s.codeUnitAt(0))));
    var prev = code(s.codeUnitAt(0));
    for (var i = 1; i < s.length && out.length < 4; i++) {
      final cu = s.codeUnitAt(i);
      if (isHW(cu)) {
        // H and W are transparent: skip without resetting prev.
        continue;
      }
      final c = code(cu);
      if (c.isEmpty) {
        // Vowel or other separator -- don't emit, but reset prev so the
        // next consonant can repeat its code.
        prev = '';
        continue;
      }
      if (c != prev) out.write(c);
      prev = c;
    }
    while (out.length < 4) {
      out.write('0');
    }
    return out.toString();
  },
  // BASE64(blob_or_text) -- standard Base64 encoding.
  'BASE64': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = a[0]!;
    final bytes = v is List<int> ? v : utf8.encode(v.toString());
    return base64.encode(bytes);
  },
  // UNBASE64(text) -- decodes Base64 string back to BLOB; returns NULL
  // on malformed input.
  'UNBASE64': (a) {
    if (a.isEmpty || a[0] == null) return null;
    try {
      return base64.decode(a[0].toString());
    } catch (_) {
      return null;
    }
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
  // TIMEDIFF(a, b) -- SQLite 3.43+. Returns the difference (a - b) as a
  // datetime string with leading sign: '+/-YYYY-MM-DD HH:MM:SS.SSS'.
  'TIMEDIFF': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final da = _resolveDateTime([a[0]]);
    final db = _resolveDateTime([a[1]]);
    if (da == null || db == null) return null;
    final diffMicros = da.difference(db).inMicroseconds;
    final neg = diffMicros < 0;
    var abs = diffMicros.abs();
    final days = abs ~/ Duration.microsecondsPerDay;
    abs -= days * Duration.microsecondsPerDay;
    final hours = abs ~/ Duration.microsecondsPerHour;
    abs -= hours * Duration.microsecondsPerHour;
    final mins = abs ~/ Duration.microsecondsPerMinute;
    abs -= mins * Duration.microsecondsPerMinute;
    final secs = abs ~/ Duration.microsecondsPerSecond;
    abs -= secs * Duration.microsecondsPerSecond;
    final ms = abs ~/ 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    final yearDays = days; // expressed as days only; year/month not split.
    return '${neg ? '-' : '+'}0000-00-${two(yearDays)} '
        '${two(hours)}:${two(mins)}:${two(secs)}.${three(ms)}';
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
      if (v == null) return null; // missing path -> SQL NULL (not 'null')
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
  // Oracle JSON_VALUE(json, path): the scalar at [path] (NULL for object/array
  // results, matching Oracle). JSON_QUERY returns the object/array fragment.
  'JSON_VALUE': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final root = _decodeJsonSource(a[0]);
    if (root == null) return null;
    final v = jsonPathLookup(root, a[1].toString());
    return (v is List || v is Map) ? null : v;
  },
  'JSON_QUERY': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final root = _decodeJsonSource(a[0]);
    if (root == null) return null;
    final v = jsonPathLookup(root, a[1].toString());
    return (v is List || v is Map) ? jsonEncode(v) : null;
  },
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
    if (a.length >= 2) {
      v = jsonPathLookup(v, a[1].toString());
      if (v == null) return null; // missing path -> SQL NULL
    }
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
  // Pretty-print JSON with 2-space indent (or a caller-supplied indent
  // string). Returns NULL on invalid JSON. SQLite 3.46+.
  'JSON_PRETTY': (a) {
    if (a.isEmpty || a[0] == null) return null;
    Object? v;
    try {
      v = jsonDecode(a[0].toString());
    } catch (_) {
      return null;
    }
    final indent = a.length >= 2 && a[1] != null ? a[1].toString() : '  ';
    return JsonEncoder.withIndent(indent).convert(v);
  },
  // -- JSONB family (SQLite 3.45+). The reference engine returns a
  // compact binary representation; our pure-Dart engine has no separate
  // JSONB encoder, so jsonb(x) returns canonical text JSON. Functions
  // that consume "JSONB" accept text JSON transparently because every
  // JSON parser here uses jsonDecode. This keeps round-trips identical
  // to SQLite for all values that are valid in either form.
  'JSONB': (a) {
    if (a.isEmpty || a[0] == null) return null;
    try {
      return jsonEncode(jsonDecode(a[0].toString()));
    } catch (_) {
      return jsonEncode(_jsonValueOf(a[0]));
    }
  },
  'JSONB_EXTRACT': (a) => kScalarFunctions['JSON_EXTRACT']!(a),
  'JSONB_ARRAY': (a) => kScalarFunctions['JSON_ARRAY']!(a),
  'JSONB_OBJECT': (a) => kScalarFunctions['JSON_OBJECT']!(a),
  'JSONB_SET': (a) => kScalarFunctions['JSON_SET']!(a),
  'JSONB_INSERT': (a) => kScalarFunctions['JSON_INSERT']!(a),
  'JSONB_REPLACE': (a) => kScalarFunctions['JSON_REPLACE']!(a),
  'JSONB_REMOVE': (a) => kScalarFunctions['JSON_REMOVE']!(a),
  'JSONB_PATCH': (a) => kScalarFunctions['JSON_PATCH']!(a),
  'JSONB_QUOTE': (a) => kScalarFunctions['JSON_QUOTE']!(a),
  'JSONB_TYPE': (a) => kScalarFunctions['JSON_TYPE']!(a),
  'JSONB_VALID': (a) => kScalarFunctions['JSON_VALID']!(a),
  'JSONB_ARRAY_LENGTH': (a) => kScalarFunctions['JSON_ARRAY_LENGTH']!(a),
  // ---- SQLite introspection / connection-state scalars -----------------
  // last_insert_rowid(): the ROWID of the most recent successful INSERT.
  // Returns 0 before any insert has occurred.
  'LAST_INSERT_ROWID': (a) => connStateLookup?.call('last_insert_rowid') ?? 0,
  // changes(): number of rows modified by the most recently completed
  // INSERT, UPDATE or DELETE statement.
  'CHANGES': (a) => connStateLookup?.call('changes') ?? 0,
  // total_changes(): total rows modified since the connection opened.
  'TOTAL_CHANGES': (a) => connStateLookup?.call('total_changes') ?? 0,
  // bit_count(x): population count (number of set bits in integer x).
  'BIT_COUNT': (a) => _propagateNull(a, () {
        var v = (a[0] as num).toInt();
        var c = 0;
        while (v != 0) {
          c += v & 1;
          v = v >>> 1;
        }
        return c;
      }),
  // load_extension/sqlite_log: present for compatibility but no-op.
  'LOAD_EXTENSION': (a) => null,
  'SQLITE_LOG': (a) => null,
  // database()/schema(): SQLite always reports 'main' for the default
  // schema; we don't track ATTACH-time DB names through statements yet.
  'DATABASE': (a) => 'main',
  'SCHEMA': (a) => 'main',
  // sqlite_version(): version string of the SQLite release this engine
  // targets for feature parity.
  'SQLITE_VERSION': (a) => kSqliteVersionString,
  // sqlite_source_id(): in real SQLite this is a build/source hash. We
  // return a stable identifier that names this engine.
  'SQLITE_SOURCE_ID': (a) =>
      'dart-db-server (parity target $kSqliteVersionString)',
  // sqlite_compileoption_used(opt): always 0 — no compile options.
  'SQLITE_COMPILEOPTION_USED': (a) => 0,
  // sqlite_compileoption_get(n): always NULL — no compile options.
  'SQLITE_COMPILEOPTION_GET': (a) => null,
  // sqlite_offset(col): SQLite returns the byte offset of the column's
  // value in the DB file, or NULL when not on disk. We have no stable
  // mapping for the in-memory engine; return NULL unconditionally.
  'SQLITE_OFFSET': (a) => null,
  // subtype(value): SQLite 3.45+. Returns the application-defined
  // subtype of an SQL value. We have no subtype machinery, so 0.
  'SUBTYPE': (a) => 0,
  // json_error_position(json): SQLite 3.42+. Returns 0 when the input
  // is a valid JSON value, otherwise the 1-based character position of
  // the first parse error. NULL input yields NULL.
  'JSON_ERROR_POSITION': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final s = a[0].toString();
    try {
      jsonDecode(s);
      return 0;
    } on FormatException catch (e) {
      final off = e.offset;
      return (off == null || off < 0) ? 1 : off + 1;
    }
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
  // --- MySQL datetime aliases ----------------------------------------
  'NOW': (a) => _fmtDateTime(DateTime.now().toUtc(), full: true),
  'SYSDATE': (a) => _fmtDateTime(DateTime.now().toUtc(), full: true),
  'SYSTIMESTAMP': (a) => _fmtDateTime(DateTime.now().toUtc(), full: true),
  // Oracle conversion functions. TO_CHAR returns a value's canonical text; a
  // format model (second arg) is accepted but not interpreted. TO_NUMBER
  // parses a numeric string.
  'TO_CHAR': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = a[0];
    final fmt = a.length > 1 && a[1] != null ? a[1].toString() : null;
    if (fmt != null && fmt.isNotEmpty) {
      // Date/datetime value with a date format model.
      if (v is String) {
        final dt = DateTime.tryParse(v.replaceFirst(' ', 'T'));
        if (dt != null && _looksLikeDateFormat(fmt)) {
          return _formatOracleDate(dt, fmt);
        }
      }
      // Numeric value with a number format model.
      num? n;
      if (v is num) {
        n = v;
      } else if (v is String) {
        n = num.tryParse(v.trim());
      }
      if (n != null) {
        // Hexadecimal format model (FMXXX / XXXX): emit uppercase hex.
        final hexFmt = RegExp(r'^(FM)?X+$', caseSensitive: false);
        if (hexFmt.hasMatch(fmt)) {
          final hex = n.toInt().toRadixString(16).toUpperCase();
          final width = fmt.toUpperCase().replaceAll('FM', '').length;
          final padded = hex.padLeft(width, '0');
          return fmt.toUpperCase().startsWith('FM') ? hex : ' $padded';
        }
        if (_looksLikeNumberFormat(fmt)) {
          return _formatOracleNumber(n, fmt);
        }
      }
    }
    return v is String ? v : v.toString();
  },
  'TO_NUMBER': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = a[0];
    if (v is num) return v;
    if (v is String) return num.tryParse(v.trim());
    return null;
  },
  // Oracle RAW hex round-trip: HEXTORAW('DEADBEEF') -> bytes, RAWTOHEX -> hex.
  'HEXTORAW': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final hex = a[0].toString();
    if (hex.isEmpty || hex.length.isOdd) return null;
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      out.add(b);
    }
    return out;
  },
  'RAWTOHEX': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = a[0];
    final bytes = v is List<int> ? v : utf8.encode(v.toString());
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join();
  },
  // Oracle UTL_RAW package: byte/RAW conversions.
  'UTL_RAW.CAST_TO_RAW': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = a[0];
    return v is List<int> ? v : utf8.encode(v.toString());
  },
  'UTL_RAW.CAST_TO_VARCHAR2': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = a[0];
    return v is List<int> ? utf8.decode(v, allowMalformed: true) : v.toString();
  },
  // Oracle interval constructors, modelled as a day count so they compose with
  // DATE arithmetic (DATE + NUMTODSINTERVAL(5,'DAY')).
  'NUMTODSINTERVAL': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final n = _sqlTextToNum(a[0]).toDouble();
    const per = {
      'DAY': 1.0, 'HOUR': 1 / 24, 'MINUTE': 1 / 1440, 'SECOND': 1 / 86400,
    };
    final days = n * (per[a[1].toString().toUpperCase()] ?? 1);
    return days == days.roundToDouble() ? days.toInt() : days;
  },
  'NUMTOYMINTERVAL': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final n = _sqlTextToNum(a[0]).toDouble();
    const per = {'YEAR': 365.0, 'MONTH': 30.0};
    final days = n * (per[a[1].toString().toUpperCase()] ?? 30);
    return days == days.roundToDouble() ? days.toInt() : days;
  },
  // TO_DATE(text [, fmt]) parses [text] by the Oracle format model [fmt] (a
  // useful subset) and returns the engine's ISO text date/datetime.
  'TO_DATE': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final dt = _parseOracleDate(
        a[0].toString(), a.length > 1 ? a[1]?.toString() : null);
    if (dt == null) return null;
    final hasTime = dt.hour != 0 || dt.minute != 0 || dt.second != 0;
    return hasTime ? _fmtDateTime(dt) : _fmtDate(dt);
  },
  'TO_TIMESTAMP': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final dt = _parseOracleDate(
        a[0].toString(), a.length > 1 ? a[1]?.toString() : null);
    return dt == null ? null : _fmtDateTime(dt);
  },
  // TRANSLATE(str, from, to): maps each char in [from] to the char at the same
  // position in [to]; chars past [to]'s length are removed.
  'TRANSLATE': (a) {
    if (a.length < 3 || a[0] == null || a[1] == null || a[2] == null) {
      return null;
    }
    final src = a[0].toString();
    final from = a[1].toString();
    final to = a[2].toString();
    final map = <String, String?>{};
    for (var i = 0; i < from.length; i++) {
      map.putIfAbsent(from[i], () => i < to.length ? to[i] : null);
    }
    final buf = StringBuffer();
    for (var i = 0; i < src.length; i++) {
      final ch = src[i];
      if (!map.containsKey(ch)) {
        buf.write(ch);
      } else if (map[ch] != null) {
        buf.write(map[ch]);
      }
    }
    return buf.toString();
  },
  // ADD_MONTHS(date, n): add n months, clamping the day to the target month's
  // last day (Oracle semantics: Jan 31 + 1 -> Feb 28/29).
  'ADD_MONTHS': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final dt = _parseDateTime(a[0].toString());
    if (dt == null) return null;
    final total = dt.year * 12 + (dt.month - 1) + _sqlTextToNum(a[1]).toInt();
    final y = total ~/ 12;
    final mo = total % 12 + 1;
    final lastDay = DateTime.utc(y, mo + 1, 0).day;
    final day = dt.day > lastDay ? lastDay : dt.day;
    final r = DateTime.utc(y, mo, day, dt.hour, dt.minute, dt.second);
    final hasTime = dt.hour != 0 || dt.minute != 0 || dt.second != 0;
    return hasTime ? _fmtDateTime(r) : _fmtDate(r);
  },
  // MONTHS_BETWEEN(d1, d2): months between the dates (fractional on a 31-day
  // basis); a whole-number result is returned as an integer.
  'MONTHS_BETWEEN': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final d1 = _parseDateTime(a[0].toString());
    final d2 = _parseDateTime(a[1].toString());
    if (d1 == null || d2 == null) return null;
    final months = (d1.year - d2.year) * 12 + (d1.month - d2.month);
    final result = months + (d1.day - d2.day) / 31.0;
    return result == result.truncateToDouble() ? result.toInt() : result;
  },
  // NEXT_DAY(date, weekday): the first [weekday] strictly after [date].
  'NEXT_DAY': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final dt = _parseDateTime(a[0].toString());
    final target = _weekdayFromName(a[1].toString());
    if (dt == null || target == null) return null;
    var d = DateTime.utc(dt.year, dt.month, dt.day);
    do {
      d = d.add(const Duration(days: 1));
    } while (d.weekday % 7 != target % 7);
    return _fmtDate(d);
  },
  'CURDATE': (a) => _fmtDate(DateTime.now().toUtc()),
  'CURTIME': (a) => _fmtTime(DateTime.now().toUtc()),
  'UTC_TIMESTAMP': (a) => _fmtDateTime(DateTime.now().toUtc(), full: true),
  'UTC_DATE': (a) => _fmtDate(DateTime.now().toUtc()),
  'UTC_TIME': (a) => _fmtTime(DateTime.now().toUtc()),
  'UNIX_TIMESTAMP': (a) {
    final dt = a.isEmpty ? DateTime.now().toUtc() : _resolveDateTime(a);
    if (dt == null) return null;
    return dt.millisecondsSinceEpoch ~/ 1000;
  },
  'FROM_UNIXTIME': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final secs = (a[0] as num).toInt();
    final dt = DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
    if (a.length > 1 && a[1] != null) {
      return _strftime(_mysqlFmtToStrftime(a[1].toString()), dt);
    }
    return _fmtDateTime(dt, full: true);
  },
  // SQL-standard EXTRACT(field FROM source). The parser rewrites the special
  // `field FROM expr` grammar into EXTRACT(<field-name-literal>, expr).
  'EXTRACT': (a) {
    if (a.length != 2 || a[0] == null) return null;
    final field = a[0].toString().toUpperCase();
    // A numeric operand is a day-to-second INTERVAL (e.g. TIMESTAMP - TIMESTAMP
    // yields a day count). Extract its day/hour/minute/second components.
    if (a[1] is num) {
      final totalDays = (a[1] as num).toDouble();
      final days = totalDays.truncate();
      final hoursF = (totalDays - days) * 24;
      final hours = hoursF.truncate();
      final minsF = (hoursF - hours) * 60;
      final mins = minsF.truncate();
      final secs = ((minsF - mins) * 60).round();
      switch (field) {
        case 'DAY':
          return days;
        case 'HOUR':
          return hours;
        case 'MINUTE':
          return mins;
        case 'SECOND':
          return secs;
        default:
          return 0;
      }
    }
    final dt = _resolveDateTime([a[1]]);
    if (dt == null) return null;
    switch (field) {
      case 'YEAR':
        return dt.year;
      case 'MONTH':
        return dt.month;
      case 'DAY':
        return dt.day;
      case 'HOUR':
        return dt.hour;
      case 'MINUTE':
        return dt.minute;
      case 'SECOND':
        // Oracle EXTRACT(SECOND ...) includes fractional seconds.
        final frac = dt.millisecond / 1000 + dt.microsecond / 1000000;
        return frac == 0 ? dt.second : dt.second + frac;
      default:
        return null;
    }
  },
  'YEAR': (a) {
    final dt = _resolveDateTime(a);
    return dt?.year;
  },
  'MONTH': (a) {
    final dt = _resolveDateTime(a);
    return dt?.month;
  },
  'DAY': (a) {
    final dt = _resolveDateTime(a);
    return dt?.day;
  },
  'DAYOFMONTH': (a) {
    final dt = _resolveDateTime(a);
    return dt?.day;
  },
  'HOUR': (a) {
    final dt = _resolveDateTime(a);
    return dt?.hour;
  },
  'MINUTE': (a) {
    final dt = _resolveDateTime(a);
    return dt?.minute;
  },
  'SECOND': (a) {
    final dt = _resolveDateTime(a);
    return dt?.second;
  },
  'MICROSECOND': (a) {
    final dt = _resolveDateTime(a);
    return dt == null ? null : dt.millisecond * 1000 + dt.microsecond;
  },
  'DAYOFWEEK': (a) {
    // MySQL: 1=Sunday..7=Saturday.
    final dt = _resolveDateTime(a);
    if (dt == null) return null;
    return (dt.weekday % 7) + 1;
  },
  'WEEKDAY': (a) {
    // MySQL: 0=Monday..6=Sunday.
    final dt = _resolveDateTime(a);
    if (dt == null) return null;
    return dt.weekday - 1;
  },
  'DAYOFYEAR': (a) {
    final dt = _resolveDateTime(a);
    return dt == null ? null : _dayOfYear(dt);
  },
  'DAYNAME': (a) {
    final dt = _resolveDateTime(a);
    if (dt == null) return null;
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[dt.weekday - 1];
  },
  'MONTHNAME': (a) {
    final dt = _resolveDateTime(a);
    if (dt == null) return null;
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return names[dt.month - 1];
  },
  'LAST_DAY': (a) {
    final dt = _resolveDateTime(a);
    if (dt == null) return null;
    final nextMonth = dt.month == 12
        ? DateTime.utc(dt.year + 1, 1, 1)
        : DateTime.utc(dt.year, dt.month + 1, 1);
    final last = nextMonth.subtract(const Duration(days: 1));
    return _fmtDate(last);
  },
  'DATEDIFF': (a) {
    if (a.length < 2) return null;
    final da = _resolveDateTime([a[0]]);
    final db = _resolveDateTime([a[1]]);
    if (da == null || db == null) return null;
    final aMid = DateTime.utc(da.year, da.month, da.day);
    final bMid = DateTime.utc(db.year, db.month, db.day);
    return aMid.difference(bMid).inDays;
  },
  'DATE_FORMAT': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final dt = _resolveDateTime([a[0]]);
    if (dt == null) return null;
    return _mysqlDateFormat(a[1].toString(), dt);
  },
  'TIME_FORMAT': (a) {
    if (a.length < 2 || a[0] == null || a[1] == null) return null;
    final dt = _resolveDateTime([a[0]]);
    if (dt == null) return null;
    return _mysqlDateFormat(a[1].toString(), dt);
  },
  'STR_TO_DATE': (a) {
    if (a.length < 2 || a[0] == null) return null;
    // We do not implement a full MySQL parser; defer to ISO parsing of
    // the input string and ignore the format. Good enough for typical
    // 'YYYY-MM-DD' / 'YYYY-MM-DD HH:MM:SS' inputs.
    return _resolveDateTime([a[0]]) == null
        ? null
        : _fmtDateTime(_resolveDateTime([a[0]])!, full: true);
  },
  // ---- Vector / embedding functions (FAISS-style) -----------------------
  // Constructor: TEXT '[1,2,3]' or BLOB / List -> canonical vector BLOB.
  'VEC': (a) {
    if (a.isEmpty || a[0] == null) return null;
    final v = coerceVector(a[0]);
    return v == null ? null : encodeVectorBlob(v);
  },
  'VEC_F32': (a) => kScalarFunctions['VEC']!(a),
  // VEC_DIM(v) -> INTEGER dimension.
  'VEC_DIM': (a) {
    if (a.isEmpty || a[0] == null) return null;
    return coerceVector(a[0])!.dim;
  },
  // V32 sqlite-vec compat: vec_length returns BYTES, not dimensions.
  // Matches sqlite-vec: `vec_length(v) = dim * 4` for float32 vectors.
  'VEC_LENGTH': (a) {
    if (a.isEmpty || a[0] == null) return null;
    return coerceVector(a[0])!.dim * 4;
  },
  // V32 sqlite-vec compat: vec_type always returns 'float32' — the
  // only vector element type we support.
  'VEC_TYPE': (a) {
    if (a.isEmpty || a[0] == null) return null;
    return 'float32';
  },
  // V32 sqlite-vec compat: vec_slice(v, start, end) returns a new
  // vector containing elements [start, end). Negative or out-of-range
  // indices are clamped.
  'VEC_SLICE': (a) => _propagateNull(a, () {
        final v = coerceVector(a[0])!;
        final start = (a[1] as num).toInt().clamp(0, v.dim);
        final end = (a[2] as num).toInt().clamp(start, v.dim);
        return encodeVectorBlob(
          Vector.fromList(v.values.sublist(start, end)),
        );
      }),
  // VEC_TO_JSON(v) -> TEXT '[...]' for debug / export.
  'VEC_TO_JSON': (a) {
    if (a.isEmpty || a[0] == null) return null;
    return coerceVector(a[0])!.toString();
  },
  // Distance metrics.
  'VEC_L2SQ': (a) => _propagateNull(
        a,
        () => vecL2Sq(coerceVector(a[0])!, coerceVector(a[1])!),
      ),
  'VEC_L2': (a) => _propagateNull(
        a,
        () => vecL2(coerceVector(a[0])!, coerceVector(a[1])!),
      ),
  'VEC_DISTANCE_L2': (a) => kScalarFunctions['VEC_L2']!(a),
  'VEC_IP': (a) => _propagateNull(
        a,
        () => vecInnerProduct(coerceVector(a[0])!, coerceVector(a[1])!),
      ),
  'VEC_DOT': (a) => kScalarFunctions['VEC_IP']!(a),
  'VEC_COSINE': (a) => _propagateNull(
        a,
        () => vecCosineDistance(coerceVector(a[0])!, coerceVector(a[1])!),
      ),
  'VEC_DISTANCE_COSINE': (a) => kScalarFunctions['VEC_COSINE']!(a),
  'VEC_COSINE_SIM': (a) => _propagateNull(
        a,
        () => vecCosineSimilarity(coerceVector(a[0])!, coerceVector(a[1])!),
      ),
  // Norm and normalization.
  'VEC_NORM': (a) {
    if (a.isEmpty || a[0] == null) return null;
    return vecNorm(coerceVector(a[0])!);
  },
  'VEC_NORMALIZE': (a) {
    if (a.isEmpty || a[0] == null) return null;
    return encodeVectorBlob(vecNormalize(coerceVector(a[0])!));
  },
  // Element-wise arithmetic (useful for centroid math and tests).
  'VEC_ADD': (a) => _propagateNull(
        a,
        () =>
            encodeVectorBlob(vecAdd(coerceVector(a[0])!, coerceVector(a[1])!)),
      ),
  'VEC_SUB': (a) => _propagateNull(
        a,
        () =>
            encodeVectorBlob(vecSub(coerceVector(a[0])!, coerceVector(a[1])!)),
      ),
  // ---- Hybrid retrieval / rank fusion ----------------------------------
  // RRF_SCORE(rank[, k]) — one term of Reciprocal Rank Fusion. Returns
  // `1 / (k + rank)` for a non-NULL rank, or 0 when the row didn't
  // appear in the ranker's list. `k` defaults to 60 (the FAISS /
  // Cormack & Buettcher canonical value).
  'RRF_SCORE': (a) {
    if (a.isEmpty || a[0] == null) return 0.0;
    final rank = (a[0] as num).toDouble();
    final k = a.length >= 2 && a[1] != null ? (a[1] as num).toDouble() : 60.0;
    return 1.0 / (k + rank);
  },
  // RRF(rank1, rank2, ...) — sum of `1 / (60 + rank_i)` over non-NULL
  // ranks. Missing / NULL ranks contribute 0. Convenience for the
  // canonical two- or three-way fusion `RRF(fts_rank, vec_rank)`.
  'RRF': (a) {
    var s = 0.0;
    for (final v in a) {
      if (v == null) continue;
      s += 1.0 / (60.0 + (v as num).toDouble());
    }
    return s;
  },
  // HYBRID_SCORE(vec_distance, fts_score, alpha) — convex-combination
  // hybrid score. Higher = more relevant.
  //   result = alpha * (1 / (1 + vec_distance)) + (1 - alpha) * fts_score
  // Vector distance is converted to a similarity in [0, 1] via
  // `1 / (1 + d)` (works for L2, L2SQ, and cosine distance). NULLs on
  // either side contribute 0 for that term. `alpha` in [0, 1] controls
  // the mix (0 = FTS only, 1 = vector only).
  'HYBRID_SCORE': (a) {
    if (a.length < 3) return null;
    final vec = a[0];
    final fts = a[1];
    final alpha = a[2] == null ? 0.5 : (a[2] as num).toDouble();
    final vecSim = vec == null ? 0.0 : 1.0 / (1.0 + (vec as num).toDouble());
    final ftsScore = fts == null ? 0.0 : (fts as num).toDouble();
    return alpha * vecSim + (1.0 - alpha) * ftsScore;
  },
};

/// Hook installed by the engine: given a table and column name, return
/// the corpus-aware FTS5 index, or null when no active database is in
/// scope. Wired up by `Database.executeStmt` so that scalar functions
/// can reach back into the database without `expression.dart` importing
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
/// Decodes a JSON source value into its parsed tree. BLOB/RAW bytes (List<int>)
/// are UTF-8 decoded first (Oracle stores JSON in BLOB columns); returns null
/// when the payload is not valid JSON.
Object? _decodeJsonSource(Object? v) {
  if (v == null) return null;
  String s;
  if (v is List<int>) {
    try {
      s = utf8.decode(v);
    } catch (_) {
      return null;
    }
  } else {
    s = v.toString();
  }
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

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

/// Per-connection state hook for `last_insert_rowid()`, `changes()` and
/// `total_changes()`. The active [Database.executeStmt] installs this so
/// the scalar functions can read connection-scoped counters without
/// `expression.dart` depending on `database.dart`. Returns 0 when no
/// connection context is active.
int Function(String which)? connStateLookup;

/// Reported by `sqlite_version()`. Mirrors a recent SQLite release we
/// aim to be feature-compatible with.
const String kSqliteVersionString = '3.45.0';

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
  // Non-integer exponents: use the platform pow (Oracle computes these).
  return math.pow(base, exp).toDouble();
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
      int.parse(dOnly[1]!),
      int.parse(dOnly[2]!),
      int.parse(dOnly[3]!),
    );
  }
  final dt = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?$',
  ).firstMatch(s);
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
    dt = DateTime.fromMillisecondsSinceEpoch(
      (first.toDouble() * 1000).toInt(),
      isUtc: true,
    );
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
  if (m == 'start of hour') {
    return DateTime.utc(dt.year, dt.month, dt.day, dt.hour);
  }
  if (m == 'start of minute') {
    return DateTime.utc(dt.year, dt.month, dt.day, dt.hour, dt.minute);
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
  final rel = RegExp(
    r'^([+-]?\d+(?:\.\d+)?)\s*(year|month|day|hour|minute|second)s?$',
  ).firstMatch(m);
  if (rel != null) {
    final n = double.parse(rel.group(1)!);
    final unit = rel.group(2)!;
    switch (unit) {
      case 'year':
        return DateTime.utc(
          dt.year + n.toInt(),
          dt.month,
          dt.day,
          dt.hour,
          dt.minute,
          dt.second,
          dt.millisecond,
          dt.microsecond,
        );
      case 'month':
        final totalMonths = dt.month - 1 + n.toInt();
        // Floor division carries the year on underflow (e.g. Jan - 1 month ->
        // previous Dec); `~/` truncates toward zero and would keep the year.
        final y = dt.year + (totalMonths / 12).floor();
        final mo = totalMonths % 12; // Dart's % is Euclidean -> 0..11.
        return DateTime.utc(
          y,
          mo + 1,
          dt.day,
          dt.hour,
          dt.minute,
          dt.second,
          dt.millisecond,
          dt.microsecond,
        );
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

const Map<String, int> _oracleMonthAbbr = {
  'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6, //
  'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
};

final RegExp _isoDateRe =
    RegExp(r'^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$');

/// Returns the [DateTime] for an ISO date / datetime string, or null for any
/// other value (including bare numbers). Used to drive Oracle date arithmetic.
DateTime? _asSqlDate(Object? v) {
  if (v is! String) return null;
  if (!_isoDateRe.hasMatch(v.trim())) return null;
  return DateTime.tryParse(v.trim().replaceFirst(' ', 'T'));
}

/// Shifts [d] by [days] (fractional days become hours/seconds) and formats the
/// result as ISO date or datetime depending on whether a time component is
/// present in [original] or the shifted value.
Object _shiftDate(DateTime d, double days, Object? original) {
  final wholeDays = days.truncate();
  final fracSeconds = ((days - wholeDays) * 86400).round();
  final shifted = d.add(Duration(days: wholeDays, seconds: fracSeconds));
  final hadTime = original is String && original.contains(RegExp(r'\d:\d'));
  final hasTime =
      shifted.hour != 0 || shifted.minute != 0 || shifted.second != 0;
  return (hadTime || hasTime) ? _fmtDateTime(shifted) : _fmtDate(shifted);
}

/// Maps a day name (full or 3-letter, any case) to a Dart weekday (Mon=1..Sun=7).
int? _weekdayFromName(String name) {
  const days = {
    'MON': 1, 'TUE': 2, 'WED': 3, 'THU': 4, 'FRI': 5, 'SAT': 6, 'SUN': 7,  };
  final k = name.trim().toUpperCase();
  return k.length >= 3 ? days[k.substring(0, 3)] : null;
}

/// Parses [text] by an Oracle date format model [fmt] (a common subset: YYYY,
/// RRRR, YY, MM, MON, MONTH, DD, HH24/HH, MI, SS). Falls back to ISO parsing
/// when [fmt] is absent or does not match.
DateTime? _parseOracleDate(String text, String? fmt) {
  final t = text.trim();
  if (fmt == null || fmt.trim().isEmpty) {
    return _parseDateTime(t) ?? DateTime.tryParse(t);
  }
  final f = fmt.trim().toUpperCase();
  // Longest-first so YYYY beats YY, MONTH beats MON, HH24 beats HH.
  const order = [
    'YYYY', 'RRRR', 'YYY', 'MONTH', 'MON', 'HH24', 'HH12', 'YY', 'RR', 'MM',
    'DD', 'HH', 'MI', 'SS',
  ];
  final pattern = StringBuffer('^');
  final captured = <String>[];
  var i = 0;
  while (i < f.length) {
    // Fractional seconds FF[1-9]: match the digit run as microseconds.
    if (f.startsWith('FF', i)) {
      i += 2;
      if (i < f.length && RegExp(r'\d').hasMatch(f[i])) i++; // FFn precision
      pattern.write(r'(\d{1,9})');
      captured.add('FF');
      continue;
    }
    var matched = false;
    for (final tok in order) {
      if (!f.startsWith(tok, i)) continue;
      switch (tok) {
        case 'YYYY':
        case 'RRRR':
          pattern.write(r'(\d{4})');
          captured.add('Y4');
        case 'YYY':
          pattern.write(r'(\d{3})');
          captured.add('Y3');
        case 'YY':
        case 'RR':
          pattern.write(r'(\d{2})');
          captured.add('Y2');
        case 'MONTH':
          pattern.write(r'([A-Za-z]+)');
          captured.add('MON');
        case 'MON':
          pattern.write(r'([A-Za-z]{3,})');
          captured.add('MON');
        case 'MM':
          pattern.write(r'(\d{1,2})');
          captured.add('MM');
        case 'DD':
          pattern.write(r'(\d{1,2})');
          captured.add('DD');
        case 'HH24':
        case 'HH12':
        case 'HH':
          pattern.write(r'(\d{1,2})');
          captured.add('HH');
        case 'MI':
          pattern.write(r'(\d{1,2})');
          captured.add('MI');
        case 'SS':
          pattern.write(r'(\d{1,2})');
          captured.add('SS');
      }
      i += tok.length;
      matched = true;
      break;
    }
    if (!matched) {
      pattern.write(RegExp.escape(f[i]));
      i++;
    }
  }
  pattern.write(r'$');
  final m =
      RegExp(pattern.toString(), caseSensitive: false).firstMatch(t);
  if (m == null) return _parseDateTime(t) ?? DateTime.tryParse(t);
  var year = 2000, month = 1, day = 1, hour = 0, minute = 0, second = 0;
  var millis = 0, micros = 0;
  for (var g = 0; g < captured.length; g++) {
    final v = m.group(g + 1);
    if (v == null) continue;
    switch (captured[g]) {
      case 'Y4':
        year = int.parse(v);
      case 'Y3':
        year = 2000 + int.parse(v);
      case 'Y2':
        final yy = int.parse(v);
        year = yy < 50 ? 2000 + yy : 1900 + yy;
      case 'MON':
        month = _oracleMonthAbbr[v.substring(0, 3).toUpperCase()] ?? month;
      case 'MM':
        month = int.parse(v);
      case 'DD':
        day = int.parse(v);
      case 'HH':
        hour = int.parse(v);
      case 'MI':
        minute = int.parse(v);
      case 'SS':
        second = int.parse(v);
      case 'FF':
        final frac = v.padRight(6, '0').substring(0, 6);
        millis = int.parse(frac.substring(0, 3));
        micros = int.parse(frac.substring(3, 6));
    }
  }
  try {
    return DateTime.utc(year, month, day, hour, minute, second, millis, micros);
  } catch (_) {
    return null;
  }
}

String _fmtDateTime(DateTime d, {bool full = false}) =>
    '${_fmtDate(d)} ${_fmtTime(d)}';

const List<String> _monthFullNames = [
  'JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', //
  'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER',
];
const List<String> _monthAbbrNames = [
  'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', //
  'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
];
// Indexed by Dart weekday (Mon=1..Sun=7).
const List<String> _weekdayFullNames = [
  '', 'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY',
  'SUNDAY',
];
const List<String> _weekdayAbbrNames = [
  '', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN',
];

/// Re-cases [value] (an all-uppercase name) to mirror [token]'s case style:
/// all-caps -> caps, all-lower -> lower, otherwise title-case.
String _applyNameCase(String value, String token) {
  if (token == token.toUpperCase()) return value;
  if (token == token.toLowerCase()) return value.toLowerCase();
  return value.isEmpty
      ? value
      : value[0].toUpperCase() + value.substring(1).toLowerCase();
}

bool _looksLikeDateFormat(String fmt) =>
    RegExp(r'Y{2,4}|MON|MM|DD|DAY|DY|HH|MI|SS|FF|\bQ\b', caseSensitive: false)
        .hasMatch(fmt);

bool _looksLikeNumberFormat(String fmt) =>
    RegExp(r'[90]').hasMatch(fmt) &&
    !RegExp(r'Y{2,4}|MON|DD|DAY|DY|HH|MI|SS', caseSensitive: false)
        .hasMatch(fmt);

/// Formats [d] by an Oracle date format model [fmt] (a common subset). Honours
/// token case for alphabetic names (MON -> JUN, Mon -> Jun, mon -> jun).
String _formatOracleDate(DateTime d, String fmt) {
  // Longest tokens first so e.g. MONTH wins over MON over MM.
  const tokens = [
    'YYYY', 'MONTH', 'HH24', 'HH12', 'MON', 'DAY', 'YY', 'MM', 'DD', 'DY',
    'HH', 'MI', 'SS', 'AM', 'PM', 'Q', 'D',
  ];
  final sb = StringBuffer();
  var i = 0;
  while (i < fmt.length) {
    // Fractional seconds FF[1-9]: emit that many leading fraction digits.
    if (i + 1 < fmt.length &&
        fmt.substring(i, i + 2).toUpperCase() == 'FF') {
      i += 2;
      var n = 6;
      if (i < fmt.length && '0123456789'.contains(fmt[i])) {
        n = int.parse(fmt[i]);
        i++;
      }
      final micros = d.millisecond * 1000 + d.microsecond;
      final frac = micros.toString().padLeft(6, '0');
      sb.write(frac.substring(0, n.clamp(0, 6)));
      continue;
    }
    String? matched;
    for (final t in tokens) {
      if (i + t.length <= fmt.length &&
          fmt.substring(i, i + t.length).toUpperCase() == t) {
        matched = fmt.substring(i, i + t.length);
        break;
      }
    }
    if (matched == null) {
      sb.write(fmt[i]);
      i++;
      continue;
    }
    final up = matched.toUpperCase();
    switch (up) {
      case 'YYYY':
        sb.write(d.year.toString().padLeft(4, '0'));
        break;
      case 'YY':
        sb.write((d.year % 100).toString().padLeft(2, '0'));
        break;
      case 'MM':
        sb.write(d.month.toString().padLeft(2, '0'));
        break;
      case 'MON':
        sb.write(_applyNameCase(_monthAbbrNames[d.month - 1], matched));
        break;
      case 'MONTH':
        sb.write(_applyNameCase(_monthFullNames[d.month - 1], matched));
        break;
      case 'DD':
        sb.write(d.day.toString().padLeft(2, '0'));
        break;
      case 'DY':
        sb.write(_applyNameCase(_weekdayAbbrNames[d.weekday], matched));
        break;
      case 'DAY':
        sb.write(_applyNameCase(_weekdayFullNames[d.weekday], matched));
        break;
      case 'HH24':
        sb.write(d.hour.toString().padLeft(2, '0'));
        break;
      case 'HH':
      case 'HH12':
        final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
        sb.write(h.toString().padLeft(2, '0'));
        break;
      case 'MI':
        sb.write(d.minute.toString().padLeft(2, '0'));
        break;
      case 'SS':
        sb.write(d.second.toString().padLeft(2, '0'));
        break;
      case 'AM':
      case 'PM':
        sb.write(d.hour < 12 ? 'AM' : 'PM');
        break;
      case 'Q':
        sb.write(((d.month - 1) ~/ 3 + 1).toString());
        break;
      case 'D':
        // Oracle day-of-week: 1=Sunday..7=Saturday.
        sb.write((d.weekday % 7 + 1).toString());
        break;
    }
    i += matched.length;
  }
  return sb.toString();
}

/// Formats [n] by an Oracle number format model [fmt] (9/0 digits, comma
/// grouping, decimal point, optional leading FM to drop the sign blank).
String _formatOracleNumber(num n, String fmt) {
  var f = fmt;
  final fm = f.toUpperCase().startsWith('FM');
  if (fm) f = f.substring(2);
  final grouping = f.contains(',');
  final dotIdx = f.indexOf('.');
  final decimals = dotIdx >= 0
      ? f.substring(dotIdx + 1).replaceAll(RegExp('[^90]'), '').length
      : 0;
  final neg = n < 0;
  final fixed = n.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  var intPart = parts[0];
  final decPart = parts.length > 1 ? parts[1] : '';
  if (grouping) {
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    intPart = buf.toString();
  }
  var out = intPart;
  if (decimals > 0) out = '$out.$decPart';
  if (neg) {
    out = '-$out';
  } else if (!fm) {
    out = ' $out';
  }
  return out;
}

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
      case 'w':
        // SQLite: 0=Sunday..6=Saturday.
        buf.write((d.weekday % 7).toString());
        break;
      case 'W':
        {
          // ISO-ish week of year, week starting Monday, range 00-53.
          final start = DateTime.utc(d.year, 1, 1);
          final firstMonday =
              start.weekday == DateTime.monday ? 1 : (9 - start.weekday) % 7;
          final doy = _dayOfYear(d);
          final w = doy < firstMonday ? 0 : ((doy - firstMonday) ~/ 7) + 1;
          buf.write(w.toString().padLeft(2, '0'));
          break;
        }
      case 'f':
        {
          final secs = d.second + d.millisecond / 1000.0 + d.microsecond / 1e6;
          buf.write(secs.toStringAsFixed(3).padLeft(6, '0'));
          break;
        }
      case 'J':
        buf.write(_toJulianDay(d).toStringAsFixed(7));
        break;
      case 'e':
        buf.write(d.day.toString().padLeft(2, ' '));
        break;
      case 'I':
        {
          final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
          buf.write(h.toString().padLeft(2, '0'));
          break;
        }
      case 'p':
        buf.write(d.hour < 12 ? 'AM' : 'PM');
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

/// Render [d] using MySQL's DATE_FORMAT specifiers. Implements the
/// commonly used subset; unrecognised `%X` sequences are passed through
/// unchanged so callers can spot omissions.
String _mysqlDateFormat(String fmt, DateTime d) {
  const monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  const monthAbbr = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  const dayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const dayAbbr = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
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
      case 'y':
        buf.write((d.year % 100).toString().padLeft(2, '0'));
        break;
      case 'm':
        buf.write(two(d.month));
        break;
      case 'c':
        buf.write(d.month.toString());
        break;
      case 'M':
        buf.write(monthNames[d.month - 1]);
        break;
      case 'b':
        buf.write(monthAbbr[d.month - 1]);
        break;
      case 'd':
        buf.write(two(d.day));
        break;
      case 'e':
        buf.write(d.day.toString());
        break;
      case 'H':
      case 'k':
        buf.write(two(d.hour));
        break;
      case 'h':
      case 'I':
      case 'l':
        {
          final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
          buf.write(two(h));
          break;
        }
      case 'i':
        buf.write(two(d.minute));
        break;
      case 'S':
      case 's':
        buf.write(two(d.second));
        break;
      case 'f':
        buf.write(
          ((d.millisecond * 1000) + d.microsecond).toString().padLeft(6, '0'),
        );
        break;
      case 'p':
        buf.write(d.hour < 12 ? 'AM' : 'PM');
        break;
      case 'T':
        buf.write('${two(d.hour)}:${two(d.minute)}:${two(d.second)}');
        break;
      case 'r':
        {
          final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
          buf.write(
            '${two(h)}:${two(d.minute)}:${two(d.second)} ${d.hour < 12 ? 'AM' : 'PM'}',
          );
          break;
        }
      case 'W':
        buf.write(dayNames[d.weekday - 1]);
        break;
      case 'a':
        buf.write(dayAbbr[d.weekday - 1]);
        break;
      case 'w':
        // MySQL: 0=Sunday..6=Saturday.
        buf.write((d.weekday % 7).toString());
        break;
      case 'j':
        buf.write(three(_dayOfYear(d)));
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

/// Translate MySQL DATE_FORMAT specifiers to the strftime subset that
/// [_strftime] understands. Used by [FROM_UNIXTIME] when a format is
/// supplied; DATE_FORMAT itself uses [_mysqlDateFormat] directly.
String _mysqlFmtToStrftime(String mysqlFmt) {
  final buf = StringBuffer();
  for (var i = 0; i < mysqlFmt.length; i++) {
    final ch = mysqlFmt[i];
    if (ch != '%' || i + 1 >= mysqlFmt.length) {
      buf.write(ch);
      continue;
    }
    final code = mysqlFmt[++i];
    switch (code) {
      case 'Y':
      case 'm':
      case 'd':
      case 'H':
      case 'S':
      case 'p':
      case 'j':
      case 'W':
      case 'w':
      case '%':
        buf.write('%');
        buf.write(code);
        break;
      case 's':
        buf.write('%S');
        break;
      case 'i':
        buf.write('%M');
        break;
      case 'h':
      case 'I':
      case 'l':
        buf.write('%I');
        break;
      case 'T':
        buf.write('%H:%M:%S');
        break;
      case 'r':
        buf.write('%I:%M:%S %p');
        break;
      case 'k':
        buf.write('%H');
        break;
      case 'f':
        buf.write('%f');
        break;
      default:
        buf.write('%');
        buf.write(code);
    }
  }
  return buf.toString();
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
  'TOTAL',
  'AVG',
  'MIN',
  'MAX',
  'GROUP_CONCAT',
  'STRING_AGG',
  'LISTAGG',
  'JSON_GROUP_ARRAY',
  'JSON_GROUP_OBJECT',
  'JSONB_GROUP_ARRAY',
  'JSONB_GROUP_OBJECT',
  'BIT_AND',
  'BIT_OR',
  'BIT_XOR',
  'ANY_VALUE',
  'MEDIAN',
  'STDDEV',
  'STDDEV_POP',
  'STDDEV_SAMP',
  'VARIANCE',
  'VAR_POP',
  'VAR_SAMP',
  'COVAR_POP',
  'COVAR_SAMP',
  'CORR',
  'PERCENTILE_CONT',
  'PERCENTILE_DISC',
  'STATS_MODE',
  // Vector aggregates — batch-oriented centroid / sum operations.
  // See _aggregateValue in database.dart for implementation.
  'VEC_AVG',
  'VEC_SUM',
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
Object? _jsonMutate(
  List<Object?> args, {
  required bool overwrite,
  required bool createMissing,
}) {
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
