/// Procedural routine core (roadmap Phase 3a).
///
/// A small block interpreter that underpins both Oracle PL/SQL and MySQL stored
/// routines (added in later phases). The AST is deliberately dialect-neutral:
/// control flow is modelled directly, while every value/condition and every
/// embedded statement is a SQL string evaluated through the host [Database].
/// Local variables are exposed to that SQL as named binds (`:name`), so an
/// expression like `:i <= :n` or a statement like
/// `INSERT INTO t VALUES (:id, :name)` reads and writes the routine's scope
/// without the interpreter needing to re-implement expression evaluation.
library;

import 'database.dart';
import 'expression.dart' show ColumnExpr;
import 'result.dart';

/// Base type for a procedural statement. Sealed so the interpreter's dispatch
/// is exhaustively checked.
sealed class RoutineStmt {}

/// A nested block with its own local declarations.
class RoutineBlock extends RoutineStmt {
  final List<RoutineDecl> declarations;
  final List<RoutineStmt> body;

  /// `EXCEPTION WHEN … THEN …` handlers; empty when the block has none.
  final List<RoutineExceptionHandler> handlers;
  RoutineBlock(this.body,
      {this.declarations = const [], this.handlers = const []});
}

/// One `WHEN exc [OR exc…] THEN <stmts>` arm of an EXCEPTION section. [names]
/// are upper-cased; `OTHERS` matches any exception.
class RoutineExceptionHandler {
  final List<String> names;
  final List<RoutineStmt> body;
  RoutineExceptionHandler(this.names, this.body);
}

/// `DECLARE name [:= <expr>]` — a local variable, optionally initialised.
class RoutineDecl {
  final String name;
  final String? initSql;
  RoutineDecl(this.name, {this.initSql});
}

/// `name := <expr>` — assign an expression's value to a local variable.
class RoutineAssign extends RoutineStmt {
  final String target;
  final String valueSql;
  RoutineAssign(this.target, this.valueSql);
}

/// `IF … THEN … [ELSIF … THEN …] [ELSE …] END IF`.
class RoutineIf extends RoutineStmt {
  final List<RoutineBranch> branches; // IF + ELSIF arms, in order
  final List<RoutineStmt> elseBody;
  RoutineIf(this.branches, {this.elseBody = const []});
}

class RoutineBranch {
  final String condSql;
  final List<RoutineStmt> body;
  RoutineBranch(this.condSql, this.body);
}

/// `WHILE <cond> LOOP … END LOOP`.
class RoutineWhile extends RoutineStmt {
  final String condSql;
  final List<RoutineStmt> body;
  RoutineWhile(this.condSql, this.body);
}

/// `LOOP … END LOOP` — an unconditional loop exited via [RoutineExit].
class RoutineLoop extends RoutineStmt {
  final List<RoutineStmt> body;
  RoutineLoop(this.body);
}

/// `FOR i IN [REVERSE] lo..hi LOOP … END LOOP`.
class RoutineForNumeric extends RoutineStmt {
  final String varName;
  final String lowerSql;
  final String upperSql;
  final bool reverse;
  final List<RoutineStmt> body;
  RoutineForNumeric(this.varName, this.lowerSql, this.upperSql, this.body,
      {this.reverse = false});
}

/// `EXIT [WHEN <cond>]` — break the innermost loop.
class RoutineExit extends RoutineStmt {
  final String? whenSql;
  RoutineExit({this.whenSql});
}

/// `RETURN [<expr>]` — unwind the whole routine, optionally with a value.
class RoutineReturn extends RoutineStmt {
  final String? exprSql;
  RoutineReturn({this.exprSql});
}

/// An embedded non-query statement (INSERT/UPDATE/DELETE/DDL/…). Local
/// variables are bound as `:name` named parameters.
class RoutineSql extends RoutineStmt {
  final String sql;
  RoutineSql(this.sql);
}

/// `SELECT … INTO v1, v2 …` — run [sql] and assign the first row's columns to
/// [intoVars] in order (NULLs when there is no row).
class RoutineSelectInto extends RoutineStmt {
  final String sql;
  final List<String> intoVars;
  RoutineSelectInto(this.sql, this.intoVars);
}

/// Append an expression's value to the routine's output buffer (the generic
/// backing for `DBMS_OUTPUT.PUT_LINE` / a MySQL `SELECT`-to-client later).
class RoutinePrint extends RoutineStmt {
  final String exprSql;
  RoutinePrint(this.exprSql);
}

/// A bare `SELECT …` in a routine body (no `INTO`): its result set is collected
/// and returned to the caller (MySQL procedures can return result sets).
class RoutineSelect extends RoutineStmt {
  final String sql;
  RoutineSelect(this.sql);
}

/// `OPEN cur FOR <select>` — runs the SELECT and binds its result set to the
/// cursor variable [varName] as a [CursorValue] (Oracle `SYS_REFCURSOR`).
class RoutineOpen extends RoutineStmt {
  final String varName;
  final String sql;
  RoutineOpen(this.varName, this.sql);
}

/// `RAISE [exc]` — raise a named exception, or (bare `RAISE`) re-raise the
/// exception currently being handled.
class RoutineRaise extends RoutineStmt {
  final String? name; // upper-cased; null = re-raise
  RoutineRaise(this.name);
}

/// Direction of a stored-routine parameter.
enum RoutineParamMode { inParam, outParam, inOutParam }

/// One stored-routine parameter: `[IN|OUT|INOUT] name <type>`.
class RoutineParam {
  final String name;
  final RoutineParamMode mode;
  final String typeText;
  RoutineParam(this.name, this.mode, this.typeText);
}

/// A named stored routine (MySQL `CREATE PROCEDURE` / `CREATE FUNCTION`).
class StoredRoutine {
  final String name;
  final List<RoutineParam> params;
  final RoutineBlock block;
  final bool isFunction;
  final String? returnType;
  StoredRoutine(this.name, this.params, this.block,
      {this.isFunction = false, this.returnType});
}

/// The outcome of running a routine: its RETURN value (for functions), the
/// collected output lines, the final local-variable scope, and any result sets
/// produced by bare `SELECT`s in the body.
class RoutineResult {
  final Object? returnValue;
  final List<String> output;
  final Map<String, Object?> variables;
  final List<QueryResult> resultSets;
  RoutineResult(this.returnValue, this.output, this.variables, this.resultSets);
}

/// Control-flow signals, thrown to unwind nested statement lists.
class _ReturnSignal {
  final Object? value;
  _ReturnSignal(this.value);
}

class _ExitSignal {}

/// A PL/SQL exception propagating through the interpreter. [name] is the
/// upper-cased exception name (`OTHERS` for a wrapped host error); [original]
/// preserves the underlying error for diagnostics / re-raise.
class _PlsqlError implements Exception {
  final String name;
  final Object? original;
  _PlsqlError(this.name, {this.original});
  @override
  String toString() => original?.toString() ?? 'PL/SQL exception: $name';
}

/// True when [name] (an exception name) matches one of the handler [names].
bool _handlerMatches(List<String> names, String name) =>
    names.contains('OTHERS') || names.contains(name);

/// Executes a [RoutineBlock] against a [Database]. Not re-entrant under the
/// database write lock — run routines at the top level (each embedded SQL
/// statement takes the lock on its own).
class RoutineInterpreter {
  final Database db;
  final Map<String, Object?> vars;
  final List<String> output = [];
  final List<QueryResult> resultSets = [];

  /// The exception currently being handled, for a bare `RAISE` re-raise.
  _PlsqlError? _currentException;

  RoutineInterpreter(this.db, {Map<String, Object?>? initialVars})
      : vars = {...?initialVars};

  Future<RoutineResult> run(RoutineBlock block) async {
    Object? returnValue;
    try {
      await _runBlock(block);
    } on _ReturnSignal catch (s) {
      returnValue = s.value;
    }
    return RoutineResult(returnValue, output, vars, resultSets);
  }

  Future<void> _runBlock(RoutineBlock b) async {
    for (final d in b.declarations) {
      vars[d.name] = d.initSql == null ? null : await _eval(d.initSql!);
    }
    if (b.handlers.isEmpty) {
      await _runStmts(b.body);
      return;
    }
    try {
      await _runStmts(b.body);
    } on _ReturnSignal {
      rethrow;
    } on _ExitSignal {
      rethrow;
    } catch (e) {
      final exc = e is _PlsqlError ? e : _PlsqlError('OTHERS', original: e);
      RoutineExceptionHandler? handler;
      for (final h in b.handlers) {
        if (_handlerMatches(h.names, exc.name)) {
          handler = h;
          break;
        }
      }
      if (handler == null) rethrow;
      final prev = _currentException;
      _currentException = exc;
      try {
        await _runStmts(handler.body);
      } finally {
        _currentException = prev;
      }
    }
  }

  Future<void> _runStmts(List<RoutineStmt> stmts) async {
    for (final s in stmts) {
      await _runStmt(s);
    }
  }

  Future<void> _runStmt(RoutineStmt s) async {
    switch (s) {
      case RoutineBlock b:
        await _runBlock(b);
      case RoutineAssign a:
        vars[a.target] = await _eval(a.valueSql);
      case RoutineIf f:
        for (final br in f.branches) {
          if (_truthy(await _eval(br.condSql))) {
            await _runStmts(br.body);
            return;
          }
        }
        await _runStmts(f.elseBody);
      case RoutineWhile w:
        try {
          while (_truthy(await _eval(w.condSql))) {
            await _runStmts(w.body);
          }
        } on _ExitSignal {
          // loop exited
        }
      case RoutineLoop l:
        try {
          while (true) {
            await _runStmts(l.body);
          }
        } on _ExitSignal {
          // loop exited
        }
      case RoutineForNumeric fr:
        final lo = ((await _eval(fr.lowerSql)) as num).toInt();
        final hi = ((await _eval(fr.upperSql)) as num).toInt();
        try {
          if (fr.reverse) {
            for (var i = hi; i >= lo; i--) {
              vars[fr.varName] = i;
              await _runStmts(fr.body);
            }
          } else {
            for (var i = lo; i <= hi; i++) {
              vars[fr.varName] = i;
              await _runStmts(fr.body);
            }
          }
        } on _ExitSignal {
          // loop exited
        }
      case RoutineExit e:
        if (e.whenSql == null || _truthy(await _eval(e.whenSql!))) {
          throw _ExitSignal();
        }
      case RoutineReturn r:
        throw _ReturnSignal(r.exprSql == null ? null : await _eval(r.exprSql!));
      case RoutineSql q:
        await _exec(q.sql);
      case RoutineSelectInto si:
        final res = await _exec(si.sql);
        final row = res.rows.isEmpty ? null : res.rows.first;
        for (var i = 0; i < si.intoVars.length; i++) {
          vars[si.intoVars[i]] =
              (row != null && i < row.length) ? row[i] : null;
        }
      case RoutinePrint p:
        output.add((await _eval(p.exprSql))?.toString() ?? '');
      case RoutineSelect q:
        resultSets.add(await _exec(q.sql));
      case RoutineOpen o:
        vars[o.varName] = CursorValue(await _exec(o.sql));
      case RoutineRaise r:
        if (r.name == null) {
          throw _currentException ?? _PlsqlError('OTHERS');
        }
        throw _PlsqlError(r.name!.toUpperCase());
    }
  }

  /// Evaluate a SQL scalar expression against the current scope.
  Future<Object?> _eval(String exprSql) async {
    final res = await _exec('SELECT $exprSql');
    return res.rows.isEmpty ? null : res.rows.first.first;
  }

  /// Run an embedded SQL statement. Local variables are available two ways:
  /// `:name` named binds (used by the dialect-neutral AST) and bare identifiers
  /// in value position (used by MySQL routine bodies), the latter resolved via
  /// [ColumnExpr.routineScopes]. Only the named binds the SQL actually
  /// references are supplied (the prepared-statement layer rejects extras).
  Future<QueryResult> _exec(String sql) async {
    final ps = db.prepare(sql);
    final named = <String, Object?>{};
    for (final spelling in ps.namedParams) {
      final name = spelling.replaceFirst(RegExp(r'^[:@$]'), '');
      if (vars.containsKey(name)) named[name] = vars[name];
    }
    ColumnExpr.routineScopes.add(vars);
    try {
      return await ps.execute(named: named);
    } finally {
      ColumnExpr.routineScopes.removeLast();
    }
  }

  static bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) return v.isNotEmpty && v != '0';
    return true;
  }
}

/// Synchronous runner for a stored FUNCTION invoked inside expression
/// evaluation. The caller is already executing inside the database lock, so
/// embedded SQL runs through [exec] (a synchronous dispatch) rather than the
/// async, re-locking path used by [RoutineInterpreter]. Returns the function's
/// RETURN value.
class SyncRoutineRunner {
  /// Runs `sql` with [scope] visible as the routine's local variables and
  /// returns its result set.
  final QueryResult Function(String sql, Map<String, Object?> scope) exec;
  final Map<String, Object?> vars;

  /// The exception currently being handled, for a bare `RAISE` re-raise.
  _PlsqlError? _currentException;

  SyncRoutineRunner(this.exec, {Map<String, Object?>? initialVars})
      : vars = {...?initialVars};

  Object? run(RoutineBlock block) {
    try {
      _runBlock(block);
    } on _ReturnSignal catch (s) {
      return s.value;
    }
    return null;
  }

  void _runBlock(RoutineBlock b) {
    for (final d in b.declarations) {
      vars[d.name] = d.initSql == null ? null : _eval(d.initSql!);
    }
    if (b.handlers.isEmpty) {
      _runStmts(b.body);
      return;
    }
    try {
      _runStmts(b.body);
    } on _ReturnSignal {
      rethrow;
    } on _ExitSignal {
      rethrow;
    } catch (e) {
      final exc = e is _PlsqlError ? e : _PlsqlError('OTHERS', original: e);
      RoutineExceptionHandler? handler;
      for (final h in b.handlers) {
        if (_handlerMatches(h.names, exc.name)) {
          handler = h;
          break;
        }
      }
      if (handler == null) rethrow;
      final prev = _currentException;
      _currentException = exc;
      try {
        _runStmts(handler.body);
      } finally {
        _currentException = prev;
      }
    }
  }

  void _runStmts(List<RoutineStmt> stmts) {
    for (final s in stmts) {
      _runStmt(s);
    }
  }

  void _runStmt(RoutineStmt s) {
    switch (s) {
      case RoutineBlock b:
        _runBlock(b);
      case RoutineAssign a:
        vars[a.target] = _eval(a.valueSql);
      case RoutineIf f:
        for (final br in f.branches) {
          if (RoutineInterpreter._truthy(_eval(br.condSql))) {
            _runStmts(br.body);
            return;
          }
        }
        _runStmts(f.elseBody);
      case RoutineWhile w:
        try {
          while (RoutineInterpreter._truthy(_eval(w.condSql))) {
            _runStmts(w.body);
          }
        } on _ExitSignal {
          // loop exited
        }
      case RoutineLoop l:
        try {
          while (true) {
            _runStmts(l.body);
          }
        } on _ExitSignal {
          // loop exited
        }
      case RoutineForNumeric fr:
        final lo = (_eval(fr.lowerSql) as num).toInt();
        final hi = (_eval(fr.upperSql) as num).toInt();
        try {
          if (fr.reverse) {
            for (var i = hi; i >= lo; i--) {
              vars[fr.varName] = i;
              _runStmts(fr.body);
            }
          } else {
            for (var i = lo; i <= hi; i++) {
              vars[fr.varName] = i;
              _runStmts(fr.body);
            }
          }
        } on _ExitSignal {
          // loop exited
        }
      case RoutineExit e:
        if (e.whenSql == null || RoutineInterpreter._truthy(_eval(e.whenSql!))) {
          throw _ExitSignal();
        }
      case RoutineReturn r:
        throw _ReturnSignal(r.exprSql == null ? null : _eval(r.exprSql!));
      case RoutineSql q:
        exec(q.sql, vars);
      case RoutineSelectInto si:
        final res = exec(si.sql, vars);
        final row = res.rows.isEmpty ? null : res.rows.first;
        for (var i = 0; i < si.intoVars.length; i++) {
          vars[si.intoVars[i]] =
              (row != null && i < row.length) ? row[i] : null;
        }
      case RoutinePrint _:
        break; // DBMS_OUTPUT inside a function is ignored
      case RoutineSelect q:
        exec(q.sql, vars);
      case RoutineOpen o:
        vars[o.varName] = CursorValue(exec(o.sql, vars));
      case RoutineRaise r:
        if (r.name == null) {
          throw _currentException ?? _PlsqlError('OTHERS');
        }
        throw _PlsqlError(r.name!.toUpperCase());
    }
  }

  Object? _eval(String exprSql) {
    final res = exec('SELECT $exprSql', vars);
    return res.rows.isEmpty ? null : res.rows.first.first;
  }
}
