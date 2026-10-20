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
  RoutineBlock(this.body, {this.declarations = const []});
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

/// Executes a [RoutineBlock] against a [Database]. Not re-entrant under the
/// database write lock — run routines at the top level (each embedded SQL
/// statement takes the lock on its own).
class RoutineInterpreter {
  final Database db;
  final Map<String, Object?> vars;
  final List<String> output = [];
  final List<QueryResult> resultSets = [];

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
    await _runStmts(b.body);
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
