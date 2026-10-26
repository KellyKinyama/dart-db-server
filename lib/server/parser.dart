/// Recursive-descent SQL parser. Consumes tokens from [Lexer] and produces
/// [Statement] AST nodes. Supports the SQL subset documented in README.
library;

import 'dart:convert';

import 'expression.dart';
import 'lexer.dart';
import 'routine.dart';
import 'schema.dart';
import 'statement.dart';

class Parser {
  final List<Token> _tokens;
  int _pos = 0;
  // Side channel: raw type token text seen by the most recent
  // _parseColumnDef() call. Used by CREATE TABLE to validate STRICT.
  String _lastColumnRawType = '';

  /// Highest 1-based positional parameter index seen while parsing.
  /// Used by [Database.prepare] to know how many positional values to
  /// expect at execute time.
  int paramCount = 0;

  /// Set of named parameters (sigil + name, e.g. ':foo') seen while
  /// parsing. Populated by [_parsePrimary]; surfaced by
  /// [Database.prepare] so callers can validate their bindings map.
  final Set<String> namedParams = <String>{};

  Parser(this._tokens);

  factory Parser.fromString(String sql) => Parser(Lexer(sql).tokenize());

  Statement parseStatement() {
    final stmt = _parseStatement();
    _match(TokType.punct, ';');
    if (!_isAtEnd()) {
      throw FormatException(
        'Unexpected token after statement: ${_peek().text}',
      );
    }
    return stmt;
  }

  List<Statement> parseScript() {
    final out = <Statement>[];
    while (!_isAtEnd()) {
      out.add(_parseStatement());
      _match(TokType.punct, ';');
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Token helpers
  // ---------------------------------------------------------------------------
  Token _peek([int offset = 0]) => _tokens[_pos + offset];
  bool _isAtEnd() => _peek().type == TokType.eof;
  Token _advance() => _tokens[_pos++];

  bool _check(TokType t, [String? text]) {
    final tok = _peek();
    if (tok.type != t) return false;
    if (text != null && tok.upper != text.toUpperCase()) return false;
    return true;
  }

  bool _match(TokType t, [String? text]) {
    if (_check(t, text)) {
      _advance();
      return true;
    }
    return false;
  }

  bool _matchKw(String kw) => _match(TokType.keyword, kw);
  bool _checkKw(String kw, [int offset = 0]) =>
      _peek(offset).type == TokType.keyword && _peek(offset).upper == kw;

  /// Matches a bareword by its uppercased text whether it lexed as a keyword or
  /// an identifier — for non-reserved words (FETCH, NEXT, ONLY) used only in
  /// specific clauses, so they stay usable as identifiers elsewhere.
  bool _checkWord(String upper) {
    final t = _peek();
    return (t.type == TokType.keyword || t.type == TokType.ident) &&
        t.upper == upper;
  }

  bool _matchWord(String upper) {
    if (_checkWord(upper)) {
      _advance();
      return true;
    }
    return false;
  }

  /// True when the current token is a non-reserved word that introduces a
  /// trailing clause (e.g. `FETCH`, or Oracle `START` / `CONNECT`) and so must
  /// not be mistaken for a table alias in `FROM t FETCH ...` / `FROM t START
  /// WITH ...`.
  bool _isClauseStartWord() =>
      _checkWord('FETCH') ||
      _checkWord('START') ||
      _checkWord('CONNECT') ||
      _checkWord('MINUS');

  /// Like [_expect] but for a bareword matched by uppercased text (keyword or
  /// identifier), e.g. the non-reserved words in MERGE (USING, MATCHED, ...).
  Token _expectWord(String upper) {
    if (_checkWord(upper)) return _advance();
    final got = _peek();
    throw FormatException(
      'Expected $upper but got "${got.text}" at offset ${got.offset}',
    );
  }

  Token _expect(TokType t, [String? text]) {
    if (_check(t, text)) return _advance();
    final got = _peek();
    throw FormatException(
      'Expected ${text ?? t.name} but got "${got.text}" at offset ${got.offset}',
    );
  }

  Token _expectKw(String kw) => _expect(TokType.keyword, kw);

  Token _expectIdent() {
    final t = _peek();
    if (t.type == TokType.ident) return _advance();
    throw FormatException(
      'Expected identifier but got "${t.text}" at offset ${t.offset}',
    );
  }

  /// Accept an identifier OR a keyword (used where keywords like `name`
  /// or `text` may legitimately appear as a column / alias name).
  String _expectName() {
    final t = _peek();
    if (t.type == TokType.ident) return _advance().text;
    if (t.type == TokType.keyword) return _advance().text;
    throw FormatException(
      'Expected name but got "${t.text}" at offset ${t.offset}',
    );
  }

  /// Parse a (possibly schema-qualified) table name like `users` or
  /// `aux.users`. The result is the raw text key used to look up the
  /// table in the database (qualified tables are stored under their
  /// dotted name).
  String _parseQualifiedTableName() {
    final first = _expectIdent().text;
    if (_check(TokType.punct, '.')) {
      _advance();
      final second = _expectName();
      return '$first.$second';
    }
    return first;
  }

  /// Consume an optional `INDEXED BY name` or `NOT INDEXED` hint and
  /// return it for the planner. Returns `null` when no hint is present.
  IndexHint? _consumeIndexedHint() {
    if (_matchKw('INDEXED')) {
      _expectKw('BY');
      final name = _expectIdent().text;
      return IndexHint.byName(name);
    } else if (_matchKw('NOT')) {
      _expectKw('INDEXED');
      return const IndexHint.notIndexed();
    }
    return null;
  }

  /// Consumes Oracle flashback (`AS OF SCN|TIMESTAMP …`, `VERSIONS BETWEEN …
  /// AND …`) and `SAMPLE [BLOCK] (n) [SEED (n)]` clauses after a FROM table.
  /// Accepted and ignored — the engine queries the current, full table.
  void _consumeFlashbackAndSample() {
    if (_checkWord('VERSIONS')) {
      _advance(); // VERSIONS
      _matchWord('BETWEEN');
      // SCN|TIMESTAMP <lo> AND <hi> — tokens up to a clause boundary.
      while (!_isAtEnd() &&
          !_isClauseStartWord() &&
          !_check(TokType.punct, ';') &&
          !_check(TokType.punct, ')') &&
          !_check(TokType.punct, ',')) {
        _advance();
      }
    }
    if (_checkWord('AS') && _peek(1).upper == 'OF') {
      _advance(); // AS
      _advance(); // OF
      _matchWord('SCN');
      _matchWord('TIMESTAMP');
      _parseExpr(); // the SCN / timestamp value
    }
    if (_matchWord('SAMPLE')) {
      _matchWord('BLOCK');
      if (_match(TokType.punct, '(')) {
        while (!_isAtEnd() && !_check(TokType.punct, ')')) {
          _advance();
        }
        _expect(TokType.punct, ')');
      }
      if (_matchWord('SEED')) {
        if (_match(TokType.punct, '(')) {
          while (!_isAtEnd() && !_check(TokType.punct, ')')) {
            _advance();
          }
          _expect(TokType.punct, ')');
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Statements
  // ---------------------------------------------------------------------------
  Statement _parseStatement() {
    final t = _peek();
    if (t.type == TokType.keyword && t.upper == 'WITH') {
      return _parseWith();
    }
    if (t.type == TokType.keyword) {
      switch (t.upper) {
        case 'SELECT':
          return _parseSelect();
        case 'VALUES':
          return _parseValuesAsSelect();
        case 'INSERT':
          if (_peek(1).upper == 'ALL' || _peek(1).upper == 'FIRST') {
            return _parseInsertAll();
          }
          return _parseInsert();
        case 'REPLACE':
          return _parseReplace();
        case 'UPDATE':
          return _parseUpdate();
        case 'DELETE':
          return _parseDelete();
        case 'CREATE':
          return _parseCreate();
        case 'DROP':
          return _parseDrop();
        case 'ALTER':
          return _parseAlter();
        case 'TRUNCATE':
          return _parseTruncate();
        case 'BEGIN':
          {
            // `BEGIN` / `BEGIN TRANSACTION` starts a transaction; `BEGIN <stmt>
            // … END` is a PL/SQL anonymous block.
            final nxt = _peek(1);
            final isTxn = nxt.type == TokType.eof ||
                (nxt.type == TokType.punct && nxt.text == ';') ||
                (nxt.type == TokType.keyword && nxt.upper == 'TRANSACTION');
            if (isTxn) {
              _advance();
              _matchKw('TRANSACTION');
              return BeginStmt();
            }
            return _parsePlsqlBlock();
          }
        case 'COMMIT':
          _advance();
          _matchKw('TRANSACTION');
          return CommitStmt();
        case 'ROLLBACK':
          _advance();
          if (_matchKw('TO')) {
            _matchKw('SAVEPOINT');
            return RollbackToSavepointStmt(_expectName());
          }
          _matchKw('TRANSACTION');
          return RollbackStmt();
        case 'SAVEPOINT':
          _advance();
          return SavepointStmt(_expectName());
        case 'RELEASE':
          _advance();
          _matchKw('SAVEPOINT');
          return ReleaseSavepointStmt(_expectName());
        case 'SHOW':
          return _parseShow();
        case 'USE':
          _advance();
          return UseDatabaseStmt(_expectName());
        case 'SET':
          return _parseSetSession();
        case 'DESCRIBE':
          _advance();
          return DescribeStmt(_expectIdent().text);
        case 'EXPLAIN':
          _advance();
          // SQLite syntax: `EXPLAIN [QUERY PLAN] <stmt>`. We support
          // both forms; QUERY PLAN routes to a tree-shaped result while
          // bare EXPLAIN emits synthesized bytecode rows.
          {
            var queryPlan = false;
            final p0 = _peek();
            final p1 = _peek(1);
            if (p0.type == TokType.ident &&
                p0.upper == 'QUERY' &&
                p1.type == TokType.ident &&
                p1.upper == 'PLAN') {
              _advance();
              _advance();
              queryPlan = true;
            }
            return ExplainStmt(_parseStatement(), isQueryPlan: queryPlan);
          }
        case 'PRAGMA':
          return _parsePragma();
        case 'VACUUM':
          _advance();
          String? schema;
          if (_check(TokType.ident)) schema = _advance().text;
          String? intoPath;
          if (_matchKw('INTO')) {
            // "VACUUM INTO 'file'" copies a consistent SQLite-format image
            // of the current database to the given path. The string
            // literal is the only accepted form (matches sqlite).
            final tok = _peek();
            if (tok.type != TokType.string) {
              throw FormatException(
                'VACUUM INTO requires a string literal path',
              );
            }
            intoPath = _advance().text;
          }
          return VacuumStmt(schema: schema, intoPath: intoPath);
        case 'ANALYZE':
          _advance();
          String? target;
          if (_check(TokType.ident)) target = _parseQualifiedTableName();
          return AnalyzeStmt(target: target);
        case 'REINDEX':
          _advance();
          String? rTarget;
          if (_check(TokType.ident)) rTarget = _parseQualifiedTableName();
          return ReindexStmt(target: rTarget);
        case 'ATTACH':
          _advance();
          _matchKw('DATABASE');
          final pathTok = _advance();
          if (pathTok.type != TokType.string) {
            throw FormatException(
              'ATTACH DATABASE expects a string path at ${pathTok.offset}',
            );
          }
          _expectKw('AS');
          return AttachDatabaseStmt(pathTok.text, _expectName());
        case 'DETACH':
          _advance();
          _matchKw('DATABASE');
          return DetachDatabaseStmt(_expectName());
      }
    }
    if (_checkWord('MERGE')) return _parseMerge();
    if (_checkWord('CALL')) return _parseCall();
    if (_checkWord('COMMENT')) return _parseComment();
    if (_checkWord('DECLARE')) return _parsePlsqlBlock();
    if (_checkWord('DELIMITER')) {
      // Client-side framing directive; accept and ignore the rest of the line.
      while (!_isAtEnd()) {
        _advance();
      }
      return SetSessionStmt('DELIMITER');
    }
    throw FormatException('Unsupported statement starting with "${t.text}"');
  }

  // ---- SHOW / USE / SET (MySQL connection-management surface) ----------
  Statement _parseShow() {
    _expectKw('SHOW');
    // Optional SESSION/GLOBAL scope is ignored.
    final scope = _peek();
    if (scope.type == TokType.ident &&
        (scope.upper == 'SESSION' || scope.upper == 'GLOBAL')) {
      _advance();
    }
    if (_matchKw('TABLES')) {
      // Eat optional MySQL trailing clauses like `FROM db` / `LIKE 'pat'`.
      if (_matchKw('FROM') || _matchKw('IN')) _expectName();
      if (_matchKw('LIKE')) _parsePrimary();
      return ShowTablesStmt();
    }
    if (_matchKw('DATABASES') || _matchKw('SCHEMAS')) {
      if (_matchKw('LIKE')) _parsePrimary();
      return ShowDatabasesStmt();
    }
    if (_matchKw('COLUMNS')) {
      if (!_matchKw('FROM')) _expectKw('IN');
      final name = _expectName();
      // Optional `FROM db`.
      if (_matchKw('FROM') || _matchKw('IN')) _expectName();
      return ShowColumnsStmt(name);
    }
    if (_matchKw('CREATE')) {
      _expectKw('TABLE');
      return ShowCreateTableStmt(_expectName());
    }
    if (_matchKw('VARIABLES')) {
      String? like;
      if (_matchKw('LIKE')) {
        final t = _expect(TokType.string);
        like = t.text;
      }
      return ShowVariablesStmt(likePattern: like);
    }
    if (_matchKw('STATUS')) {
      String? like;
      if (_matchKw('LIKE')) {
        final t = _expect(TokType.string);
        like = t.text;
      }
      return ShowStatusStmt(likePattern: like);
    }
    final got = _peek();
    throw FormatException('Unsupported SHOW form at "${got.text}"');
  }

  /// Parse a top-level `SET ...` and return a [SetSessionStmt] that the
  /// executor treats as a no-op. We do not interpret the assignment(s)
  /// because the engine has no MySQL system-variable backing store.
  Statement _parseSetSession() {
    final start = _peek().offset;
    _expectKw('SET');
    // MySQL user-variable assignment: `SET @x = expr [, @y = expr]`. Only when
    // every comma item is an `@var` assignment; otherwise fall through to the
    // generic no-op (SET SESSION/GLOBAL/NAMES/autocommit/...).
    final first = _peek();
    if (first.type == TokType.param &&
        first.text.startsWith('@') &&
        !first.text.startsWith('@@')) {
      final assignments = <(String, Expr)>[];
      var allUserVars = true;
      do {
        final t = _peek();
        if (t.type != TokType.param ||
            !t.text.startsWith('@') ||
            t.text.startsWith('@@')) {
          allUserVars = false;
          break;
        }
        _advance();
        final varName = t.text.substring(1);
        if (!_match(TokType.op, ':=')) _expect(TokType.op, '=');
        assignments.add((varName, _parseExpr()));
      } while (_match(TokType.punct, ','));
      if (allUserVars && assignments.isNotEmpty) {
        return SetUserVarStmt(assignments);
      }
    }
    // Consume tokens until end of statement / semicolon to stay in sync.
    while (!_isAtEnd() && !(_check(TokType.punct, ';'))) {
      _advance();
    }
    final end = _peek().offset;
    return SetSessionStmt(_sliceSource(start, end));
  }

  /// Look up a MySQL `@@var` system variable; unknown names return null
  /// (which becomes SQL NULL).
  Object? _mysqlSystemVar(String name) {
    final n = name.toLowerCase().replaceFirst(
          RegExp(r'^(global|session)\.'),
          '',
        );
    switch (n) {
      case 'version':
      case 'version_comment':
        return '8.0.0-dart_db_server';
      case 'version_compile_machine':
        return 'x86_64';
      case 'version_compile_os':
        return 'dart';
      case 'character_set_client':
      case 'character_set_connection':
      case 'character_set_results':
      case 'character_set_server':
      case 'character_set_database':
        return 'utf8mb4';
      case 'collation_connection':
      case 'collation_server':
      case 'collation_database':
        return 'utf8mb4_0900_ai_ci';
      case 'sql_mode':
        return '';
      case 'autocommit':
      case 'auto_increment_increment':
        return 1;
      case 'tx_isolation':
      case 'transaction_isolation':
        return 'REPEATABLE-READ';
      case 'time_zone':
      case 'system_time_zone':
        return 'UTC';
      case 'lower_case_table_names':
        return 0;
      case 'max_allowed_packet':
        return 67108864;
      case 'wait_timeout':
      case 'interactive_timeout':
        return 28800;
      case 'init_connect':
        return '';
      case 'license':
        return 'GPL';
    }
    return null;
  }

  // ---- CREATE -------------------------------------------------------------
  Statement _parseCreate() {
    _expectKw('CREATE');
    // Oracle `CREATE OR REPLACE PROCEDURE|FUNCTION …`.
    var orReplace = false;
    if (_matchKw('OR')) {
      _expectWord('REPLACE');
      orReplace = true;
    }
    // Accept [GLOBAL|PRIVATE] TEMP / TEMPORARY before TABLE/VIEW/TRIGGER/INDEX.
    // We don't model temp scope; the modifiers are parsed and ignored so the
    // CREATE statement is recognised.
    {
      if (_checkWord('GLOBAL') || _checkWord('PRIVATE')) {
        if (_peek(1).upper == 'TEMPORARY' || _peek(1).upper == 'TEMP') {
          _advance();
        }
      }
      final p = _peek();
      if (p.type == TokType.ident &&
          (p.upper == 'TEMP' || p.upper == 'TEMPORARY')) {
        _advance();
      }
    }
    if (_matchKw('TABLE')) return _parseCreateTableTail();
    if (_matchWord('MATERIALIZED')) {
      _expectKw('VIEW');
      return _parseCreateMaterializedViewTail();
    }
    if (_matchWord('PUBLIC')) {
      _expectWord('SYNONYM');
      return _parseCreateSynonymTail();
    }
    if (_matchWord('SYNONYM')) return _parseCreateSynonymTail();
    if (_matchWord('TYPE')) return _parseCreateType();
    if (_matchWord('DIMENSION')) {
      // Oracle OLAP CREATE DIMENSION — accepted and ignored.
      while (!_isAtEnd() && !_check(TokType.punct, ';')) {
        _advance();
      }
      return DdlNoopStmt('DIMENSION');
    }
    if (_matchKw('VIRTUAL')) {
      _expectKw('TABLE');
      return _parseCreateVirtualTableTail();
    }
    _matchWord('BITMAP'); // Oracle bitmap index — treated as a regular index
    final isUnique = _matchKw('UNIQUE');
    if (_matchKw('INDEX')) return _parseCreateIndexTail(unique: isUnique);
    if (_matchKw('VIEW')) return _parseCreateViewTail();
    if (_matchKw('TRIGGER')) return _parseCreateTriggerTail();
    if (_matchWord('SEQUENCE')) return _parseCreateSequenceTail();
    if (_matchWord('PROCEDURE')) {
      return _parseCreateRoutine(false, orReplace: orReplace);
    }
    if (_matchWord('FUNCTION')) {
      return _parseCreateRoutine(true, orReplace: orReplace);
    }
    if (_matchWord('PACKAGE')) {
      return _parseCreatePackage(orReplace: orReplace);
    }
    throw FormatException(
      'Expected TABLE, INDEX, VIEW or TRIGGER after CREATE',
    );
  }

  CreateVirtualTableStmt _parseCreateVirtualTableTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _expectIdent().text;
    _expectKw('USING');
    final module = _expectIdent().text;
    final args = <String>[];
    if (_match(TokType.punct, '(')) {
      // Parse comma-separated module args. Each arg can be a bare identifier,
      // an identifier followed by extra tokens up to the next comma / `)`.
      var depth = 1;
      final buf = StringBuffer();
      while (depth > 0) {
        final t = _peek();
        if (t.type == TokType.punct && t.text == '(') {
          depth++;
          buf.write(t.text);
          _advance();
        } else if (t.type == TokType.punct && t.text == ')') {
          depth--;
          if (depth == 0) {
            if (buf.isNotEmpty) args.add(buf.toString().trim());
            _advance();
            break;
          }
          buf.write(t.text);
          _advance();
        } else if (depth == 1 && t.type == TokType.punct && t.text == ',') {
          if (buf.isNotEmpty) args.add(buf.toString().trim());
          buf.clear();
          _advance();
        } else {
          if (buf.isNotEmpty) buf.write(' ');
          buf.write(t.type == TokType.string ? "'${t.text}'" : t.text);
          _advance();
        }
      }
    }
    return CreateVirtualTableStmt(name, module, args, ifNotExists: ifNotExists);
  }

  /// Parses an Oracle `PIVOT (agg(measure) [alias] FOR col IN (v1 [alias], …))`
  /// and rewrites it into a grouped CASE-aggregate SELECT over [src].
  SelectStmt _parsePivotClause(SelectStmt src) {
    _expect(TokType.punct, '(');
    final measure = _parseExpr();
    final aggName =
        measure is FunctionCallExpr ? measure.name.toUpperCase() : 'MAX';
    // COUNT(*) has no measure column; the per-value CASE yields a constant 1 so
    // COUNT counts the matching rows (not a nested COUNT(COUNT(*))).
    final measureArg = measure is FunctionCallExpr && measure.isStarArg
        ? LiteralExpr(1)
        : measure is FunctionCallExpr && measure.args.isNotEmpty
            ? measure.args.first
            : measure;
    if (_matchKw('AS')) {
      _expectName();
    } else if (_check(TokType.ident) && !_checkWord('FOR')) {
      _advance();
    }
    _expectWord('FOR');
    final pivotCol = _expectName();
    _expectKw('IN');
    _expect(TokType.punct, '(');
    final values = <(Expr, String)>[];
    do {
      final startOff = _peek().offset;
      final v = _parseExpr();
      final endOff = _peek().offset;
      String label;
      if (_matchKw('AS')) {
        label = _expectName();
      } else if (_check(TokType.ident)) {
        label = _advance().text;
      } else {
        label = _sliceSource(startOff, endOff).trim().replaceAll("'", '');
      }
      values.add((v, label));
    } while (_match(TokType.punct, ','));
    _expect(TokType.punct, ')'); // IN list
    _expect(TokType.punct, ')'); // PIVOT

    final measureCols = <String>{};
    _columnNamesInto(measureArg, measureCols);
    final srcCols = <String>[];
    for (final it in src.projection) {
      if (it.alias != null) {
        srcCols.add(it.alias!);
      } else if (it.expr is ColumnExpr) {
        srcCols.add((it.expr as ColumnExpr).name);
      }
    }
    final groupCols = srcCols
        .where((c) =>
            c.toLowerCase() != pivotCol.toLowerCase() &&
            !measureCols.contains(c.toLowerCase()))
        .toList();
    final proj = <SelectItem>[
      for (final g in groupCols) SelectItem.expr(ColumnExpr(g)),
    ];
    for (final (v, label) in values) {
      final cond = BinaryExpr('=', ColumnExpr(pivotCol), v);
      proj.add(SelectItem.expr(
        FunctionCallExpr(aggName, [CaseExpr([cond], [measureArg], null)]),
        alias: label,
      ));
    }
    return SelectStmt(
      projection: proj,
      fromSubquery: src,
      groupBy: [for (final g in groupCols) ColumnExpr(g)],
      orderBy: const [],
    );
  }

  /// Parses an Oracle `PIVOT XML (agg(measure) FOR col IN (ANY | subquery |
  /// value-list))`. Unlike relational PIVOT, the pivot values aren't known at
  /// parse time, so the result has one row per distinct grouping-column
  /// combination plus a single aggregated XML column. We model that as a
  /// GROUP BY over the implicit grouping columns.
  SelectStmt _parsePivotXmlClause(SelectStmt src) {
    _expect(TokType.punct, '(');
    final measure = _parseExpr();
    final measureCols = <String>{};
    if (measure is FunctionCallExpr && measure.args.isNotEmpty) {
      _columnNamesInto(measure.args.first, measureCols);
    }
    if (_matchKw('AS')) {
      _expectName();
    } else if (_check(TokType.ident) && !_checkWord('FOR')) {
      _advance();
    }
    _expectWord('FOR');
    final pivotCol = _expectName();
    _expectKw('IN');
    _expect(TokType.punct, '(');
    // IN (ANY) | IN (subquery) | IN (v1, v2, …) — the contents don't affect the
    // output cardinality (one row per group), so skip to the matching ')'.
    var depth = 1;
    while (depth > 0 && !_isAtEnd()) {
      if (_check(TokType.punct, '(')) {
        depth++;
      } else if (_check(TokType.punct, ')')) {
        depth--;
        if (depth == 0) break;
      }
      _advance();
    }
    _expect(TokType.punct, ')'); // IN list
    _expect(TokType.punct, ')'); // PIVOT XML

    final srcCols = <String>[];
    for (final it in src.projection) {
      if (it.alias != null) {
        srcCols.add(it.alias!);
      } else if (it.expr is ColumnExpr) {
        srcCols.add((it.expr as ColumnExpr).name);
      }
    }
    final groupCols = srcCols
        .where((c) =>
            c.toLowerCase() != pivotCol.toLowerCase() &&
            !measureCols.contains(c.toLowerCase()))
        .toList();
    final proj = <SelectItem>[
      for (final g in groupCols) SelectItem.expr(ColumnExpr(g)),
      SelectItem.expr(
        FunctionCallExpr('MAX', [LiteralExpr('<PivotSet></PivotSet>')]),
        alias: '${pivotCol}_XML',
      ),
    ];
    return SelectStmt(
      projection: proj,
      fromSubquery: src,
      groupBy: [for (final g in groupCols) ColumnExpr(g)],
      orderBy: const [],
    );
  }

  /// Parses an Oracle `MATCH_RECOGNIZE ( [PARTITION BY …] [ORDER BY …]
  /// [MEASURES …] [ONE ROW|ALL ROWS PER MATCH] [AFTER MATCH SKIP …]
  /// PATTERN ( … ) DEFINE var AS cond, … )` clause into a structured
  /// [MatchRecognizeClause]. Pattern support is a flat sequence of quantified
  /// variables (`+ * ?`); unsupported constructs are skipped where possible.
  MatchRecognizeClause _parseMatchRecognize() {
    _expect(TokType.punct, '(');
    final partitionBy = <Expr>[];
    if (_matchWord('PARTITION')) {
      _expectKw('BY');
      partitionBy.add(_parseExpr());
      while (_match(TokType.punct, ',')) {
        partitionBy.add(_parseExpr());
      }
    }
    final orderBy = <OrderByItem>[];
    if (_matchKw('ORDER')) {
      _expectKw('BY');
      orderBy.add(_parseOrderByItem());
      while (_match(TokType.punct, ',')) {
        orderBy.add(_parseOrderByItem());
      }
    }
    final measures = <SelectItem>[];
    if (_matchWord('MEASURES')) {
      do {
        final e = _parseExpr();
        String? alias;
        if (_matchKw('AS')) {
          alias = _expectName();
        } else if (_check(TokType.ident) &&
            !_checkWord('ONE') &&
            !_checkWord('ALL') &&
            !_checkWord('AFTER') &&
            !_checkWord('PATTERN')) {
          alias = _advance().text;
        }
        measures.add(SelectItem.expr(e, alias: alias));
      } while (_match(TokType.punct, ','));
    }
    var allRows = false;
    if (_matchWord('ALL')) {
      _expectWord('ROWS');
      _expectWord('PER');
      _expectWord('MATCH');
      allRows = true;
    } else if (_matchWord('ONE')) {
      _expectWord('ROW');
      _expectWord('PER');
      _expectWord('MATCH');
    }
    if (_matchWord('AFTER')) {
      _expectWord('MATCH');
      _expectWord('SKIP');
      // SKIP PAST LAST ROW | SKIP TO NEXT ROW | SKIP TO [FIRST|LAST] var
      while (!_checkWord('PATTERN') && !_isAtEnd()) {
        _advance();
      }
    }
    final pattern = <MatchPatternElem>[];
    _expectWord('PATTERN');
    _expect(TokType.punct, '(');
    var depth = 1;
    while (depth > 0 && !_isAtEnd()) {
      if (_check(TokType.punct, '(')) {
        depth++;
        _advance();
        continue;
      }
      if (_check(TokType.punct, ')')) {
        depth--;
        _advance();
        continue;
      }
      // Skip anchors/alternation we don't model: ^ $ |
      if (_check(TokType.op, '|') ||
          _check(TokType.op, '^') ||
          _check(TokType.op, r'$')) {
        _advance();
        continue;
      }
      if (!_check(TokType.ident)) {
        _advance();
        continue;
      }
      final v = _advance().text;
      var minRep = 1;
      var maxRep = 1;
      if (_match(TokType.op, '+')) {
        minRep = 1;
        maxRep = -1;
      } else if (_match(TokType.op, '*')) {
        minRep = 0;
        maxRep = -1;
      } else if (_match(TokType.op, '?') || _match(TokType.param, '?')) {
        minRep = 0;
        maxRep = 1;
      } else if (_check(TokType.punct, '{') || _check(TokType.op, '{')) {
        // {n} or {n,m} — consume and best-effort parse.
        _advance(); // {
        final lo = _check(TokType.number) ? int.parse(_advance().text) : 0;
        var hi = lo;
        if (_match(TokType.punct, ',')) {
          hi = _check(TokType.number) ? int.parse(_advance().text) : -1;
        }
        _match(TokType.punct, '}');
        _match(TokType.op, '}');
        minRep = lo;
        maxRep = hi;
      }
      pattern.add(MatchPatternElem(v, minRep, maxRep));
    }
    // SUBSET clause (ignored) up to DEFINE / ')'.
    if (_matchWord('SUBSET')) {
      while (!_checkWord('DEFINE') &&
          !_check(TokType.punct, ')') &&
          !_isAtEnd()) {
        _advance();
      }
    }
    final defines = <String, Expr>{};
    if (_matchWord('DEFINE')) {
      do {
        final v = _expectName();
        _expectKw('AS');
        defines[v.toUpperCase()] = _parseExpr();
      } while (_match(TokType.punct, ','));
    }
    _expect(TokType.punct, ')'); // MATCH_RECOGNIZE
    return MatchRecognizeClause(
      partitionBy: partitionBy,
      orderBy: orderBy,
      measures: measures,
      allRowsPerMatch: allRows,
      pattern: pattern,
      defines: defines,
    );
  }

  /// Parses an Oracle `UNPIVOT [INCLUDE|EXCLUDE NULLS] (valueCol FOR labelCol
  /// IN (c1 [AS label], …))` over table [tableName] and rewrites it into a
  /// UNION ALL subquery with one arm per unpivoted column.
  SelectStmt _parseUnpivotClause(String tableName) {
    var includeNulls = false;
    if (_matchWord('INCLUDE')) {
      _matchWord('NULLS');
      includeNulls = true;
    } else if (_matchWord('EXCLUDE')) {
      _matchWord('NULLS');
    }
    _expect(TokType.punct, '(');
    final valueCol = _expectName();
    _expectWord('FOR');
    final labelCol = _expectName();
    _expectKw('IN');
    _expect(TokType.punct, '(');
    final cols = <(String, String)>[];
    do {
      final colName = _expectName();
      var label = colName;
      if (_matchKw('AS')) {
        label = _check(TokType.string)
            ? _advance().text
            : _expectName();
      }
      cols.add((colName, label));
    } while (_match(TokType.punct, ','));
    _expect(TokType.punct, ')'); // IN list
    _expect(TokType.punct, ')'); // UNPIVOT
    final arms = cols
        .map((c) =>
            "SELECT $tableName.*, '${c.$2}' AS $labelCol, ${c.$1} AS $valueCol "
            "FROM $tableName"
            '${includeNulls ? '' : ' WHERE ${c.$1} IS NOT NULL'}')
        .join(' UNION ALL ');
    return Parser.fromString(arms).parseStatement() as SelectStmt;
  }

  /// Parses `JSON_TABLE(src, 'path' COLUMNS (col …))` (the opening JSON_TABLE
  /// word is already consumed) into a derived table whose FROM is a JSON_TABLE
  /// table-function call the executor materialises: args are
  /// `[src, rowPath, jsonEncode(columnSpecs)]`.
  SelectStmt _parseJsonTableClause() {
    _expect(TokType.punct, '(');
    final src = _parseExpr(); // JSON source expression
    var rowPath = r'$';
    if (_match(TokType.punct, ',')) {
      if (_check(TokType.string)) rowPath = _advance().text; // row path
    }
    final names = <String>[];
    final specs = <Map<String, Object?>>[];
    if (_matchWord('COLUMNS')) {
      _parseJsonTableColumns(names, specs);
    }
    _expect(TokType.punct, ')'); // JSON_TABLE
    return SelectStmt(
      projection: [for (final c in names) SelectItem.expr(ColumnExpr(c))],
      fromFunction: FunctionCallExpr(
        'JSON_TABLE',
        [src, LiteralExpr(rowPath), LiteralExpr(jsonEncode(specs))],
      ),
      orderBy: const [],
    );
  }

  /// Parses `XMLTABLE('xpath' PASSING xmldoc COLUMNS col type PATH 'p', …)`
  /// into a derived table whose FROM is an `XMLTABLE` table-function call:
  /// args are `[xmldoc, rowXPath, jsonEncode(columnSpecs)]`.
  SelectStmt _parseXmlTableClause() {
    _expect(TokType.punct, '(');
    final rowXPath = _check(TokType.string) ? _advance().text : '/';
    Expr doc = LiteralExpr('');
    if (_matchWord('PASSING')) {
      _matchWord('BY');
      _matchWord('VALUE');
      doc = _parseExpr();
    }
    final names = <String>[];
    final specs = <Map<String, Object?>>[];
    if (_matchWord('COLUMNS')) {
      do {
        final name = _expectName();
        if (_matchWord('FOR')) {
          _matchWord('ORDINALITY');
          names.add(name);
          specs.add({'kind': 'ord', 'name': name});
          continue;
        }
        final typeName = _advance().text.toUpperCase();
        if (_check(TokType.punct, '(')) {
          while (!_check(TokType.punct, ')') && !_isAtEnd()) {
            _advance();
          }
          _match(TokType.punct, ')');
        }
        var path = name;
        if (_matchWord('PATH') && _check(TokType.string)) {
          path = _advance().text;
        }
        names.add(name);
        specs.add(
            {'kind': 'path', 'name': name, 'path': path, 'type': typeName});
      } while (_match(TokType.punct, ','));
    }
    _expect(TokType.punct, ')'); // XMLTABLE
    return SelectStmt(
      projection: [for (final c in names) SelectItem.expr(ColumnExpr(c))],
      fromFunction: FunctionCallExpr(
        'XMLTABLE',
        [doc, LiteralExpr(rowXPath), LiteralExpr(jsonEncode(specs))],
      ),
      orderBy: const [],
    );
  }

  /// Parses a JSON_TABLE `COLUMNS ( … )` list into [names] (projection order)
  /// and [specs] (per-column descriptors: FOR ORDINALITY, EXISTS PATH, a typed
  /// PATH column with optional DEFAULT … ON ERROR, or a NESTED PATH subtree).
  void _parseJsonTableColumns(
      List<String> names, List<Map<String, Object?>> specs) {
    _expect(TokType.punct, '(');
    do {
      if (_matchWord('NESTED')) {
        _matchWord('PATH');
        final p = _check(TokType.string) ? _advance().text : r'$';
        _expectWord('COLUMNS');
        final innerNames = <String>[];
        final innerSpecs = <Map<String, Object?>>[];
        _parseJsonTableColumns(innerNames, innerSpecs);
        names.addAll(innerNames);
        specs.add({'kind': 'nested', 'path': p, 'cols': innerSpecs});
        continue;
      }
      final name = _expectName();
      if (_matchWord('FOR')) {
        _matchWord('ORDINALITY');
        names.add(name);
        specs.add({'kind': 'ord', 'name': name});
        continue;
      }
      final typeName = _advance().text.toUpperCase();
      if (_check(TokType.punct, '(')) {
        while (!_check(TokType.punct, ')') && !_isAtEnd()) {
          _advance();
        }
        _match(TokType.punct, ')');
      }
      if (_matchWord('EXISTS')) {
        _matchWord('PATH');
        final p = _check(TokType.string) ? _advance().text : '\$.$name';
        names.add(name);
        specs.add({'kind': 'exists', 'name': name, 'path': p});
        continue;
      }
      var path = '\$.$name';
      if (_matchWord('PATH')) {
        if (_check(TokType.string)) path = _advance().text;
      }
      Object? defaultVal;
      var hasDefault = false;
      // Trailing `[DEFAULT expr] ON {ERROR|EMPTY}` clauses.
      while (true) {
        if (_matchWord('DEFAULT')) {
          final d = _parsePrimary();
          if (!hasDefault && d is LiteralExpr) {
            defaultVal = d.value;
            hasDefault = true;
          }
          continue;
        }
        if (_matchWord('NULL') ||
            _matchWord('ERROR') ||
            _matchWord('EMPTY') ||
            _matchWord('ON')) {
          continue;
        }
        break;
      }
      names.add(name);
      specs.add({
        'kind': 'path',
        'name': name,
        'path': path,
        'type': typeName,
        if (hasDefault) 'default': defaultVal,
      });
    } while (_match(TokType.punct, ','));
    _expect(TokType.punct, ')');
  }

  void _columnNamesInto(Expr e, Set<String> out) {
    if (e is ColumnExpr) {
      out.add(e.name.toLowerCase());
    } else if (e is FunctionCallExpr) {
      for (final a in e.args) {
        _columnNamesInto(a, out);
      }
    } else if (e is BinaryExpr) {
      _columnNamesInto(e.left, out);
      _columnNamesInto(e.right, out);
    } else if (e is UnaryExpr) {
      _columnNamesInto(e.operand, out);
    }
  }

  Statement _parseCreateTableTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _parseQualifiedTableName();
    // Object table: `CREATE TABLE <name> OF <object_type>` (columns from type).
    if (_matchWord('OF')) {
      final typeName = _parseQualifiedTableName();
      while (!_isAtEnd() && !_check(TokType.punct, ';')) {
        _advance(); // trailing object-table storage clauses
      }
      return CreateObjectTableStmt(name, typeName, ifNotExists: ifNotExists);
    }
    // CREATE TABLE <name> [AS] SELECT … (CTAS): schema + data from a query.
    if (_checkKw('AS') || _checkKw('SELECT')) {
      _matchKw('AS');
      final sel = _parseSelect();
      return CreateTableStmt(name, const [],
          ifNotExists: ifNotExists, asSelect: sel);
    }
    _expect(TokType.punct, '(');
    final cols = <ColumnDef>[];
    final rawTypes = <String>[]; // parallel to cols; for STRICT validation
    final constraints = <TableConstraint>[];
    do {
      if (_isTableLevelConstraintStart()) {
        final c = _parseTableConstraint();
        _skipConstraintState();
        constraints.add(c);
      } else {
        _lastColumnRawType = '';
        cols.add(_parseColumnDef());
        rawTypes.add(_lastColumnRawType);
      }
    } while (_match(TokType.punct, ','));
    _expect(TokType.punct, ')');
    // Optional table-options trailer: WITHOUT ROWID and/or STRICT, in
    // any order, optionally separated by commas. Then an optional
    // engine selector `USING paged` (this engine's extension; routes
    // the table to the out-of-core PagedTable backend).
    bool strict = false;
    bool withoutRowid = false;
    bool usingPaged = false;
    while (true) {
      if (_matchKw('WITHOUT')) {
        _expectKw('ROWID');
        withoutRowid = true;
      } else if (_matchKw('STRICT')) {
        strict = true;
      } else if (_matchKw('USING')) {
        final mod = _expectIdent().text;
        if (mod.toLowerCase() != 'paged') {
          throw FormatException(
            'CREATE TABLE $name USING $mod: only "paged" is supported',
          );
        }
        usingPaged = true;
      } else if (_matchWord('ORGANIZATION')) {
        // Oracle index-organized / heap table storage clause: accept + ignore.
        if (!_matchWord('INDEX')) _matchWord('HEAP');
      } else if (_matchWord('ON')) {
        // Oracle GLOBAL TEMPORARY `ON COMMIT {PRESERVE|DELETE} ROWS` — accept.
        _matchWord('COMMIT');
        if (!_matchWord('PRESERVE')) _matchWord('DELETE');
        _matchWord('ROWS');
      } else if (_matchWord('PARTITION') || _matchWord('PARTITIONS')) {
        // Oracle partitioning clause (PARTITION BY …): accept and ignore the
        // remainder of the statement.
        while (!_isAtEnd() && !_check(TokType.punct, ';')) {
          _advance();
        }
        break;
      } else if (_matchWord('NESTED')) {
        // NESTED TABLE <col> STORE AS <name> storage clause: accept + ignore.
        while (!_isAtEnd() && !_check(TokType.punct, ';')) {
          _advance();
        }
        break;
      } else if (_isMysqlTableOptionStart()) {
        _skipMysqlTableOption();
        // MySQL allows space- or comma-separated options; eat an optional
        // comma but do not require it.
        _match(TokType.punct, ',');
        continue;
      } else {
        break;
      }
      if (!_match(TokType.punct, ',')) break;
    }
    if (strict) {
      for (var i = 0; i < cols.length; i++) {
        final raw = rawTypes[i].toLowerCase();
        if (!kStrictAllowedTypeNames.contains(raw)) {
          throw FormatException(
            'STRICT table $name: column ${cols[i].name} has unsupported '
            'type "${rawTypes[i]}". STRICT only allows '
            'INT, INTEGER, REAL, TEXT, BLOB, ANY.',
          );
        }
      }
    }
    return CreateTableStmt(
      name,
      cols,
      constraints: constraints,
      ifNotExists: ifNotExists,
      strict: strict,
      withoutRowid: withoutRowid,
      usingPaged: usingPaged,
    );
  }

  /// MySQL trailing CREATE TABLE options like
  /// `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  ///  AUTO_INCREMENT=100 ROW_FORMAT=DYNAMIC COMMENT='hi'`.
  /// Parsed for compatibility and dropped on the floor.
  static const _kMysqlTableOptionKws = <String>{
    'ENGINE',
    'CHARSET',
    'COLLATE',
    'AUTO_INCREMENT',
    'COMMENT',
    'DEFAULT',
    'CHARACTER',
    'ROW_FORMAT',
    'MIN_ROWS',
    'MAX_ROWS',
    'AVG_ROW_LENGTH',
    'PACK_KEYS',
    'CHECKSUM',
    'DELAY_KEY_WRITE',
    'KEY_BLOCK_SIZE',
    'STATS_AUTO_RECALC',
    'STATS_PERSISTENT',
    'STATS_SAMPLE_PAGES',
    'TABLESPACE',
    'COMPRESSION',
    'ENCRYPTION',
  };

  bool _isMysqlTableOptionStart() {
    final t = _peek();
    if (t.type == TokType.keyword) {
      return _kMysqlTableOptionKws.contains(t.upper);
    }
    if (t.type == TokType.ident) {
      return _kMysqlTableOptionKws.contains(t.upper);
    }
    return false;
  }

  void _skipMysqlTableOption() {
    // Accept any sequence of: NAME [DEFAULT? NAME]* [=] (NAME|string|number).
    // Eat tokens until we hit a comma at table-option depth, the end of
    // the statement, or another known trailing keyword.
    _advance();
    if (_matchKw('DEFAULT')) {
      // `DEFAULT CHARSET=...` / `DEFAULT CHARACTER SET=...`
    }
    // Optional secondary word: e.g. `CHARACTER SET`.
    if (_check(TokType.ident) || _check(TokType.keyword)) {
      final p = _peek();
      if (p.upper == 'SET' || p.upper == 'CHARSET') {
        _advance();
      }
    }
    _match(TokType.op, '=');
    // Value: string, number, or ident/keyword.
    final v = _peek();
    if (v.type == TokType.string ||
        v.type == TokType.number ||
        v.type == TokType.ident ||
        v.type == TokType.keyword) {
      _advance();
    }
  }

  bool _isTableLevelConstraintStart() {
    // A leading `CONSTRAINT <name>` always introduces a named table-level
    // constraint when it appears at the start of a CREATE TABLE item.
    if (_checkWord('CONSTRAINT')) return true;
    final t = _peek();
    if (t.type != TokType.keyword) return false;
    if (t.upper == 'PRIMARY' || t.upper == 'UNIQUE' || t.upper == 'CHECK') {
      // Could also be a column named "check" — disambiguate by next token
      // being '(' for table-level constraints.
      return _peek(1).type == TokType.punct && _peek(1).text == '(' ||
          (t.upper == 'PRIMARY' && _checkKw('KEY', 1));
    }
    return t.upper == 'FOREIGN';
  }

  TableConstraint _parseTableConstraint() {
    // Optional `CONSTRAINT <name>` prefix (the name is accepted but not
    // retained) before PRIMARY KEY / UNIQUE / CHECK / FOREIGN KEY.
    if (_matchWord('CONSTRAINT')) {
      _advance();
    }
    if (_matchKw('PRIMARY')) {
      _expectKw('KEY');
      _expect(TokType.punct, '(');
      final cols = <String>[_expectIdent().text];
      while (_match(TokType.punct, ',')) {
        cols.add(_expectIdent().text);
      }
      _expect(TokType.punct, ')');
      return PrimaryKeyConstraint(cols);
    }
    if (_matchKw('UNIQUE')) {
      _expect(TokType.punct, '(');
      final cols = <String>[_expectIdent().text];
      while (_match(TokType.punct, ',')) {
        cols.add(_expectIdent().text);
      }
      _expect(TokType.punct, ')');
      return UniqueConstraint(cols);
    }
    if (_matchKw('CHECK')) {
      _expect(TokType.punct, '(');
      final start = _peek().offset;
      _parseExpr();
      final end = _peek().offset;
      _expect(TokType.punct, ')');
      return CheckConstraint(_sliceSource(start, end));
    }
    if (_matchKw('FOREIGN')) {
      _expectKw('KEY');
      _expect(TokType.punct, '(');
      final cols = <String>[_expectIdent().text];
      while (_match(TokType.punct, ',')) {
        cols.add(_expectIdent().text);
      }
      _expect(TokType.punct, ')');
      return ForeignKeyConstraint(cols, _parseReferencesClause());
    }
    throw FormatException('Expected table-level constraint');
  }

  ForeignKeyRef _parseReferencesClause() {
    _expectKw('REFERENCES');
    var tbl = _expectIdent().text;
    // Schema-qualified target `owner.table` — the engine is single-schema, so
    // keep the table name and drop the owner.
    if (_match(TokType.punct, '.')) {
      tbl = _expectIdent().text;
    }
    String? col;
    if (_match(TokType.punct, '(')) {
      col = _expectIdent().text;
      _expect(TokType.punct, ')');
    }
    var onDelete = 'NO ACTION';
    var onUpdate = 'NO ACTION';
    while (_matchKw('ON')) {
      final which = _peek().upper;
      if (which == 'DELETE') {
        _advance();
        onDelete = _parseRefAction();
      } else if (which == 'UPDATE') {
        _advance();
        onUpdate = _parseRefAction();
      } else {
        throw FormatException('Expected DELETE or UPDATE after ON');
      }
    }
    return ForeignKeyRef(
      tbl,
      column: col,
      onDelete: onDelete,
      onUpdate: onUpdate,
    );
  }

  String _parseRefAction() {
    if (_matchKw('CASCADE')) return 'CASCADE';
    if (_matchKw('RESTRICT')) return 'RESTRICT';
    if (_matchKw('SET')) {
      if (_matchKw('NULL')) return 'SET NULL';
      if (_matchKw('DEFAULT')) return 'SET DEFAULT';
      throw FormatException('Expected NULL or DEFAULT after SET');
    }
    if (_matchKw('NO')) {
      _expectKw('ACTION');
      return 'NO ACTION';
    }
    throw FormatException('Expected reference action');
  }

  ColumnDef _parseColumnDef() {
    final name = _expectName();
    final typeTok = _advance();
    _lastColumnRawType = typeTok.text;
    final type = parseDataType(typeTok.text);
    // Oracle REF column: `col REF <object_type>` — model the opaque reference as
    // its declared type and consume the referenced type name.
    if (typeTok.text.toUpperCase() == 'REF' &&
        (_check(TokType.ident) || _peek().type == TokType.keyword)) {
      _advance();
    }
    // Optional size/precision qualifier: VARCHAR(10), DECIMAL(10,2), etc.
    // Captured for VARCHAR2(n) length and NUMBER(p[,s]) precision/scale
    // enforcement; it does not affect affinity.
    int? charLength;
    int? numericPrecision;
    int? numericScale;
    if (_match(TokType.punct, '(')) {
      final rawType = typeTok.text.toUpperCase();
      const charTypes = {
        'VARCHAR', 'VARCHAR2', 'CHAR', 'NCHAR', 'NVARCHAR', 'NVARCHAR2',
        'CHARACTER',
      };
      final firstTok = _advance(); // first number
      final firstN = int.tryParse(firstTok.text);
      // Optional CHAR / BYTE length semantics keyword (VARCHAR2(10 CHAR)).
      if (_check(TokType.ident) || _peek().type == TokType.keyword) {
        if (_checkWord('CHAR') || _checkWord('BYTE')) _advance();
      }
      if (_match(TokType.punct, ',')) {
        // Negative scale is allowed: NUMBER(5,-2).
        var scaleNeg = false;
        if (_check(TokType.op, '-')) {
          scaleNeg = true;
          _advance();
        }
        final secondTok = _advance(); // scale
        numericPrecision = firstN;
        final sc = int.tryParse(secondTok.text);
        numericScale = sc == null ? null : (scaleNeg ? -sc : sc);
      } else if (charTypes.contains(rawType)) {
        charLength = firstN;
      } else {
        numericPrecision = firstN;
      }
      _expect(TokType.punct, ')');
    }
    // Oracle INTERVAL YEAR [(p)] TO MONTH / INTERVAL DAY [(p)] TO SECOND [(p)]
    // column types. Consumed (the engine stores intervals as text/number).
    if (typeTok.text.toUpperCase() == 'INTERVAL') {
      void consumeParen() {
        if (_check(TokType.punct, '(')) {
          var depth = 0;
          do {
            final tk = _advance();
            if (tk.type == TokType.punct && tk.text == '(') depth++;
            if (tk.type == TokType.punct && tk.text == ')') depth--;
          } while (depth > 0 && !_isAtEnd());
        }
      }

      if (_matchWord('YEAR') ||
          _matchWord('MONTH') ||
          _matchWord('DAY') ||
          _matchWord('HOUR') ||
          _matchWord('MINUTE') ||
          _matchWord('SECOND')) {
        consumeParen();
        if (_matchWord('TO')) {
          if (_check(TokType.ident) || _peek().type == TokType.keyword) {
            _advance(); // trailing unit
          }
          consumeParen();
        }
      }
    }
    // Oracle TIMESTAMP / TIME [WITH [LOCAL] TIME ZONE]. The zone qualifier is
    // consumed (the engine stores timestamps as text); the column keeps its
    // TIMESTAMP affinity.
    if (_checkWord('WITH') &&
        (typeTok.text.toUpperCase() == 'TIMESTAMP' ||
            typeTok.text.toUpperCase() == 'TIME')) {
      _advance(); // WITH
      _matchWord('LOCAL');
      _expectWord('TIME');
      _expectWord('ZONE');
    }
    bool primaryKey = false;
    bool notNull = false;
    bool unique = false;
    bool autoInc = false;
    Object? defaultValue;
    String? defaultExprSql;
    String? checkSql;
    ForeignKeyRef? references;
    String? generatedSql;
    bool generatedStored = false;
    Map<String, String>? vectorSpec;
    String? collate;
    String? pendingConstraintName;
    String? checkName;
    while (true) {
      // Inline named constraint prefix: `CONSTRAINT <name> <constraint>`. The
      // name is remembered so a following CHECK can be dropped by name later.
      if (_matchWord('CONSTRAINT')) {
        pendingConstraintName = _expectName();
        continue;
      }
      if (_matchKw('COLLATE')) {
        collate = _expectIdent().text;
        continue;
      }
      if (_matchKw('PRIMARY')) {
        _expectKw('KEY');
        primaryKey = true;
        notNull = true;
        unique = true;
        if (_matchKw('AUTOINCREMENT') || _matchKw('AUTO_INCREMENT')) {
          autoInc = true;
        }
        continue;
      }
      if (_matchKw('AUTOINCREMENT') || _matchKw('AUTO_INCREMENT')) {
        autoInc = true;
        continue;
      }
      if (_matchKw('NOT')) {
        _expectKw('NULL');
        notNull = true;
        continue;
      }
      if (_matchKw('UNIQUE')) {
        unique = true;
        continue;
      }
      if (_matchKw('DEFAULT')) {
        // Oracle `DEFAULT ON NULL <expr>`: also applies the default when NULL
        // is explicitly supplied. Consume the modifier; the expression that
        // follows is parsed by the branches below.
        if (_matchWord('ON')) {
          if (!_matchWord('NULL')) _expectKw('NULL');
        }
        // 1) DEFAULT (<expr>) — parenthesized expression.
        if (_check(TokType.punct, '(')) {
          _advance(); // consume '('
          final start = _peek().offset;
          _parseExpr();
          final end = _peek().offset;
          _expect(TokType.punct, ')');
          defaultExprSql = _sliceSource(start, end);
          continue;
        }
        // 2) DEFAULT CURRENT_TIMESTAMP | CURRENT_DATE | CURRENT_TIME.
        if (_checkKw('CURRENT_TIMESTAMP') ||
            _checkKw('CURRENT_DATE') ||
            _checkKw('CURRENT_TIME') ||
            (_check(TokType.ident) &&
                const {
                  'CURRENT_TIMESTAMP',
                  'CURRENT_DATE',
                  'CURRENT_TIME',
                }.contains(_peek().upper))) {
          defaultExprSql = _advance().text;
          continue;
        }
        // 3) Bare literal (possibly signed numeric), else a scalar expression
        //    default (e.g. `seq.NEXTVAL`, a function call) captured as SQL and
        //    evaluated per INSERT.
        final exprStart = _peek().offset;
        Expr lit;
        if (_check(TokType.op, '-') || _check(TokType.op, '+')) {
          final sign = _advance().text;
          final next = _parsePrimary();
          if (next is LiteralExpr && next.value is num) {
            lit =
                LiteralExpr(sign == '-' ? -(next.value as num) : next.value);
          } else {
            defaultExprSql = _sliceSource(exprStart, _peek().offset);
            continue;
          }
        } else {
          lit = _parsePrimary();
        }
        if (lit is! LiteralExpr) {
          defaultExprSql = _sliceSource(exprStart, _peek().offset);
          continue;
        }
        defaultValue = lit.value;
        continue;
      }
      if (_matchKw('CHECK')) {
        _expect(TokType.punct, '(');
        final start = _peek().offset;
        _parseExpr();
        final end = _peek().offset;
        _expect(TokType.punct, ')');
        checkSql = _sliceSource(start, end);
        checkName = pendingConstraintName;
        continue;
      }
      if (_checkKw('REFERENCES')) {
        references = _parseReferencesClause();
        continue;
      }
      // Constraint-state attributes (DEFERRABLE / INITIALLY DEFERRED|IMMEDIATE,
      // ENABLE/DISABLE, RELY/NORELY, VALIDATE/NOVALIDATE) — accepted + ignored.
      if (_matchWord('DEFERRABLE')) {
        if (_matchWord('INITIALLY')) {
          if (!_matchWord('DEFERRED')) _matchWord('IMMEDIATE');
        }
        continue;
      }
      if (_checkWord('NOT') && _peek(1).upper == 'DEFERRABLE') {
        _advance();
        _advance();
        continue;
      }
      // Oracle column visibility: VISIBLE / INVISIBLE — accepted (the column is
      // still addressable by name).
      if (_matchWord('VISIBLE') || _matchWord('INVISIBLE')) {
        continue;
      }
      if (_matchKw('GENERATED')) {
        // Oracle identity: GENERATED [ALWAYS | BY DEFAULT [ON NULL]] AS IDENTITY
        //   [ ( sequence options ) ].  Mapped onto the AUTOINCREMENT engine.
        if (_matchWord('BY')) {
          _expectKw('DEFAULT');
          if (_matchWord('ON')) {
            if (!_matchWord('NULL')) _expectKw('NULL');
          }
        } else {
          _expectKw('ALWAYS');
        }
        _expectKw('AS');
        if (_matchWord('IDENTITY')) {
          autoInc = true;
          notNull = true;
          // Optional "( START WITH n INCREMENT BY n … )" sequence options.
          if (_check(TokType.punct, '(')) {
            var depth = 0;
            do {
              final tk = _advance();
              if (tk.type == TokType.punct && tk.text == '(') depth++;
              if (tk.type == TokType.punct && tk.text == ')') depth--;
            } while (depth > 0 && !_isAtEnd());
          }
          continue;
        }
        _expect(TokType.punct, '(');
        final start = _peek().offset;
        _parseExpr();
        final end = _peek().offset;
        _expect(TokType.punct, ')');
        generatedSql = _sliceSource(start, end);
        if (_matchKw('STORED')) {
          generatedStored = true;
        } else {
          _matchKw('VIRTUAL');
        }
        continue;
      }
      if (_matchKw('AS')) {
        // SQLite shorthand: `<col> <type> AS (<expr>) [STORED|VIRTUAL]`
        _expect(TokType.punct, '(');
        final start = _peek().offset;
        _parseExpr();
        final end = _peek().offset;
        _expect(TokType.punct, ')');
        generatedSql = _sliceSource(start, end);
        if (_matchKw('STORED')) {
          generatedStored = true;
        } else {
          _matchKw('VIRTUAL');
        }
        continue;
      }
      if (_check(TokType.ident) && _peek().upper == 'VECTOR') {
        _advance();
        _expect(TokType.punct, '(');
        vectorSpec = <String, String>{};
        while (!_check(TokType.punct, ')')) {
          final key = _expectIdent().text.toLowerCase();
          _expect(TokType.op, '=');
          final valTok = _advance();
          vectorSpec[key] = valTok.text.replaceAll("'", '');
          if (_check(TokType.punct, ',')) {
            _advance();
          }
        }
        _expect(TokType.punct, ')');
        continue;
      }
      break;
    }
    return ColumnDef(
      name,
      type,
      declaredType: typeTok.text,
      primaryKey: primaryKey,
      notNull: notNull,
      unique: unique,
      autoIncrement: autoInc,
      defaultValue: defaultValue,
      defaultExprSql: defaultExprSql,
      checkExprSql: checkSql,
      checkName: checkName,
      references: references,
      generatedExprSql: generatedSql,
      generatedStored: generatedStored,
      vectorSpec: vectorSpec,
      collate: collate,
      charLength: charLength,
      numericPrecision: numericPrecision,
      numericScale: numericScale,
    );
  }

  CreateIndexStmt _parseCreateIndexTail({bool unique = false}) {
    final indexName = _expectIdent().text;
    _expectKw('ON');
    final table = _expectIdent().text;
    _expect(TokType.punct, '(');
    // Either a single column name or an arbitrary expression.
    String? col;
    String? exprSql;
    List<String>? extraCols;
    final collations = <String>[];
    final saved = _pos;
    if (_check(TokType.ident) &&
        (_peek(1).type == TokType.punct &&
                (_peek(1).text == ')' || _peek(1).text == ',') ||
            _peek(1).type == TokType.keyword &&
                (_peek(1).text.toUpperCase() == 'COLLATE' ||
                    _peek(1).text.toUpperCase() == 'ASC' ||
                    _peek(1).text.toUpperCase() == 'DESC'))) {
      col = _expectIdent().text;
      // Optional COLLATE/ASC/DESC on the first column.
      String coll = 'BINARY';
      if (_matchKw('COLLATE')) coll = _expectIdent().text;
      if (_matchKw('ASC') || _matchKw('DESC')) {}
      collations.add(coll);
      // Multi-column indexes: collect the rest of the column list and
      // keep them on the statement for round-tripping (the in-memory
      // engine still indexes only on `col`, but the format layer needs
      // all columns to write a faithful CREATE INDEX/index B-tree).
      while (_match(TokType.punct, ',')) {
        (extraCols ??= <String>[]).add(_expectIdent().text);
        // Tolerate `ASC`/`DESC` and `COLLATE foo` qualifiers per column.
        String c2 = 'BINARY';
        if (_matchKw('COLLATE')) c2 = _expectIdent().text;
        if (_matchKw('ASC') || _matchKw('DESC')) {}
        collations.add(c2);
      }
    } else {
      // Expression index.
      _pos = saved;
      final start = _peek().offset;
      _parseExpr();
      final end = _peek().offset;
      exprSql = _sliceSource(start, end);
      col = exprSql;
      collations.add('BINARY');
    }
    _expect(TokType.punct, ')');
    String? whereSql;
    if (_matchKw('WHERE')) {
      final start = _peek().offset;
      _parseExpr();
      final end = _peek().offset;
      whereSql = _sliceSource(start, end);
    }
    // Trailing Oracle storage/physical clauses (NOLOGGING, LOCAL, PARALLEL,
    // TABLESPACE …, COMPUTE STATISTICS …) — accepted and ignored.
    while (!_isAtEnd() && !_check(TokType.punct, ';')) {
      _advance();
    }
    return CreateIndexStmt(
      indexName,
      table,
      col,
      unique: unique,
      whereSql: whereSql,
      exprSql: exprSql,
      columns: extraCols == null ? null : [col, ...extraCols],
      collations: collations,
    );
  }

  CreateViewStmt _parseCreateViewTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _expectIdent().text;
    // Optional explicit column list: `CREATE VIEW v (a, b) AS …`.
    List<String>? viewCols;
    if (_match(TokType.punct, '(')) {
      viewCols = <String>[_expectName()];
      while (_match(TokType.punct, ',')) {
        viewCols.add(_expectName());
      }
      _expect(TokType.punct, ')');
    }
    _expectKw('AS');
    final selStart = _peek().offset;
    final sel = _parseSelect();
    final selEnd = _peek().offset;
    final selSql = _sliceSource(selStart, selEnd).trim();
    return CreateViewStmt(
      name,
      sel,
      ifNotExists: ifNotExists,
      selectSql: selSql,
      columns: viewCols,
    );
  }

  /// `CREATE MATERIALIZED VIEW <name> [build/refresh clauses] AS <select>` —
  /// modeled as a plain view; the Oracle storage/refresh clauses before AS are
  /// accepted and ignored.
  CreateViewStmt _parseCreateMaterializedViewTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _expectIdent().text;
    while (!_isAtEnd() && !_checkKw('AS') && !_check(TokType.punct, ';')) {
      _advance();
    }
    _expectKw('AS');
    final selStart = _peek().offset;
    final sel = _parseSelect();
    final selEnd = _peek().offset;
    final selSql = _sliceSource(selStart, selEnd).trim();
    return CreateViewStmt(name, sel,
        ifNotExists: ifNotExists, selectSql: selSql);
  }

  /// `CREATE [PUBLIC] SYNONYM <name> FOR <target>`.
  CreateSynonymStmt _parseCreateSynonymTail() {
    final name = _parseQualifiedTableName();
    _expectWord('FOR');
    final target = _parseQualifiedTableName();
    return CreateSynonymStmt(name, target);
  }

  /// `CREATE TYPE <name> AS OBJECT (attrs)` records the attribute columns so an
  /// object table can resolve them; VARRAY / TABLE OF and method members are
  /// accepted and ignored.
  Statement _parseCreateType() {
    final name = _check(TokType.ident) ? _parseQualifiedTableName() : '';
    final isObject =
        (_matchWord('AS') || _matchWord('IS')) && _matchWord('OBJECT');
    if (isObject && _match(TokType.punct, '(')) {
      final cols = <ColumnDef>[];
      if (!_check(TokType.punct, ')')) {
        cols.add(_parseColumnDef());
        while (_match(TokType.punct, ',')) {
          // Stop at a method/member clause (not a plain attribute).
          if (_checkWord('MEMBER') ||
              _checkWord('MAP') ||
              _checkWord('STATIC') ||
              _checkWord('CONSTRUCTOR') ||
              _checkWord('FINAL') ||
              _checkWord('ORDER')) {
            break;
          }
          cols.add(_parseColumnDef());
        }
      }
      while (!_isAtEnd() && !_check(TokType.punct, ';')) {
        _advance();
      }
      return CreateTypeStmt(name, cols);
    }
    while (!_isAtEnd() && !_check(TokType.punct, ';')) {
      _advance();
    }
    return DdlNoopStmt('TYPE');
  }

  /// Consumes Oracle constraint-state clauses (`ENABLE`, `DISABLE`, `VALIDATE`,
  /// `NOVALIDATE`, `RELY`, `DEFERRABLE`, `INITIALLY …`) that trail a constraint.
  void _skipConstraintState() {
    while (true) {
      if (_matchWord('ENABLE') ||
          _matchWord('DISABLE') ||
          _matchWord('VALIDATE') ||
          _matchWord('NOVALIDATE') ||
          _matchWord('RELY') ||
          _matchWord('NORELY') ||
          _matchWord('DEFERRABLE')) {
        continue;
      }
      if (_matchWord('NOT')) {
        _matchWord('DEFERRABLE') || _matchWord('NULL');
        continue;
      }
      if (_matchWord('INITIALLY')) {
        _matchWord('IMMEDIATE') || _matchWord('DEFERRED');
        continue;
      }
      break;
    }
  }

  CreateTriggerStmt _parseCreateTriggerTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _expectIdent().text;
    String timing = 'AFTER';
    if (_matchKw('BEFORE')) {
      timing = 'BEFORE';
    } else if (_matchKw('AFTER')) {
      timing = 'AFTER';
    } else if (_matchKw('INSTEAD')) {
      _expectKw('OF');
      timing = 'INSTEAD OF';
    }
    String event;
    if (_matchKw('INSERT')) {
      event = 'INSERT';
    } else if (_matchKw('UPDATE')) {
      event = 'UPDATE';
      // Optional `OF col, ...` — accept and ignore.
      if (_matchKw('OF')) {
        _expectIdent();
        while (_match(TokType.punct, ',')) {
          _expectIdent();
        }
      }
    } else if (_matchKw('DELETE')) {
      event = 'DELETE';
    } else {
      throw FormatException('Expected INSERT, UPDATE or DELETE');
    }
    _expectKw('ON');
    final table = _expectIdent().text;
    if (_matchKw('FOR')) {
      _expectKw('EACH');
      _expectKw('ROW');
    }
    Expr? when;
    if (_matchKw('WHEN')) {
      when = _parseExpr();
    }
    // A PL/SQL trigger body (DECLARE … / `:new.x := …` procedural assignments)
    // is not a SQL-statement body; recover the `:new.col := expr` assignments
    // (applied to the NEW row of a BEFORE row trigger) and accept the rest.
    if (_looksLikePlsqlTriggerBody()) {
      final assigns = _parsePlsqlTriggerBody();
      return CreateTriggerStmt(
        name,
        timing,
        event,
        table,
        when,
        const <Statement>[],
        ifNotExists: ifNotExists,
        newAssignments: assigns,
      );
    }
    _expectKw('BEGIN');
    final body = <Statement>[];
    while (!_checkKw('END')) {
      body.add(_parseStatement());
      _match(TokType.punct, ';');
    }
    _expectKw('END');
    return CreateTriggerStmt(
      name,
      timing,
      event,
      table,
      when,
      body,
      ifNotExists: ifNotExists,
    );
  }

  /// Whether the trigger body is a PL/SQL block (a `DECLARE` section, or a
  /// `BEGIN` whose first statement is a `:new`/`:old` or `ident :=` assignment)
  /// rather than the SQL-statement body the engine executes directly.
  bool _looksLikePlsqlTriggerBody() {
    if (_checkWord('DECLARE')) return true;
    if (_checkKw('BEGIN')) {
      final n = _peek(1);
      if (n.type == TokType.param) return true;
      if ((n.type == TokType.ident || n.type == TokType.keyword) &&
          _peek(2).type == TokType.op &&
          _peek(2).text == ':=') {
        return true;
      }
    }
    return false;
  }

  /// Consumes a PL/SQL trigger body (`DECLARE … BEGIN … END;`, tracking nesting)
  /// and returns its `:new.col := expr` assignments; other procedural
  /// statements are accepted and ignored.
  List<TriggerNewAssign> _parsePlsqlTriggerBody() {
    final out = <TriggerNewAssign>[];
    var depth = 0;
    var sawBegin = false;
    while (!_isAtEnd()) {
      final p = _peek();
      // `:new . col := <rhs> ;`
      if (p.type == TokType.param &&
          p.text.toUpperCase() == ':NEW' &&
          _peek(1).type == TokType.punct &&
          _peek(1).text == '.' &&
          _peek(3).type == TokType.op &&
          _peek(3).text == ':=') {
        _advance(); // :new
        _advance(); // .
        final col = _advance().text; // column
        _advance(); // :=
        final start = _peek().offset;
        var pd = 0;
        while (!_isAtEnd()) {
          final t = _peek();
          if (t.type == TokType.punct && t.text == '(') {
            pd++;
          } else if (t.type == TokType.punct && t.text == ')') {
            if (pd == 0) break;
            pd--;
          } else if (t.type == TokType.punct && t.text == ';' && pd == 0) {
            break;
          }
          _advance();
        }
        final rhs = _sliceSource(start, _peek().offset).trim();
        final expr = _parseTriggerRhs(rhs);
        if (expr != null) out.add(TriggerNewAssign(col, expr));
        _match(TokType.punct, ';');
        continue;
      }
      if (_matchWord('BEGIN')) {
        depth++;
        sawBegin = true;
        continue;
      }
      if (_checkWord('END')) {
        _advance();
        if (_matchWord('IF') || _matchWord('LOOP') || _matchWord('CASE')) {
          continue; // inner construct closed by keyword, not the block
        }
        depth--;
        if (sawBegin && depth <= 0) {
          if (_check(TokType.ident)) _advance(); // optional trigger name
          _match(TokType.punct, ';');
          break;
        }
        continue;
      }
      _advance();
    }
    return out;
  }

  /// Parses a PL/SQL assignment RHS into an [Expr], mapping `:new.x`/`:old.x`
  /// column references onto the engine's `NEW.x`/`OLD.x` trigger scope. Returns
  /// null when the RHS cannot be parsed (the assignment is then ignored).
  Expr? _parseTriggerRhs(String rhs) {
    final mapped = rhs
        .replaceAll(RegExp(r':new\s*\.\s*', caseSensitive: false), 'NEW.')
        .replaceAll(RegExp(r':old\s*\.\s*', caseSensitive: false), 'OLD.');
    try {
      final stmt = Parser.fromString('SELECT $mapped').parseStatement();
      if (stmt is SelectStmt && stmt.projection.isNotEmpty) {
        return stmt.projection.first.expr;
      }
    } catch (_) {}
    return null;
  }

  // ---- DROP ---------------------------------------------------------------
  Statement _parseDrop() {
    _expectKw('DROP');
    if (_matchKw('TABLE')) {
      bool ifExists = false;
      if (_matchKw('IF')) {
        _expectKw('EXISTS');
        ifExists = true;
      }
      return DropTableStmt(_parseQualifiedTableName(), ifExists: ifExists);
    }
    if (_matchKw('INDEX')) {
      bool ifExists = false;
      if (_matchKw('IF')) {
        _expectKw('EXISTS');
        ifExists = true;
      }
      return DropIndexStmt(_expectIdent().text, ifExists: ifExists);
    }
    if (_matchKw('VIEW')) {
      bool ifExists = false;
      if (_matchKw('IF')) {
        _expectKw('EXISTS');
        ifExists = true;
      }
      return DropViewStmt(_expectIdent().text, ifExists: ifExists);
    }
    if (_matchKw('TRIGGER')) {
      bool ifExists = false;
      if (_matchKw('IF')) {
        _expectKw('EXISTS');
        ifExists = true;
      }
      return DropTriggerStmt(_expectIdent().text, ifExists: ifExists);
    }
    if (_matchWord('SEQUENCE')) {
      bool ifExists = false;
      if (_matchKw('IF')) {
        _expectKw('EXISTS');
        ifExists = true;
      }
      return DropSequenceStmt(_expectIdent().text, ifExists: ifExists);
    }
    if (_matchWord('PROCEDURE') || _matchWord('FUNCTION')) {
      final isFunction = _tokens[_pos - 1].upper == 'FUNCTION';
      bool ifExists = false;
      if (_matchKw('IF')) {
        _expectKw('EXISTS');
        ifExists = true;
      }
      return DropProcedureStmt(_expectIdent().text,
          isFunction: isFunction, ifExists: ifExists);
    }
    if (_matchWord('PACKAGE')) {
      _matchWord('BODY'); // DROP PACKAGE BODY drops the same member set
      bool ifExists = false;
      if (_matchKw('IF')) {
        _expectKw('EXISTS');
        ifExists = true;
      }
      return DropPackageStmt(_expectIdent().text, ifExists: ifExists);
    }
    throw FormatException('Expected TABLE, INDEX, VIEW or TRIGGER after DROP');
  }

  // ---- CREATE SEQUENCE ----------------------------------------------------
  CreateSequenceStmt _parseCreateSequenceTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _expectIdent().text;
    int startWith = 1;
    int incrementBy = 1;
    int? minValue;
    int? maxValue;
    bool cycle = false;
    // Options may appear in any order and repeat; last one wins (Oracle-ish).
    while (true) {
      if (_matchWord('START')) {
        _matchKw('WITH');
        startWith = _parseSignedInt();
      } else if (_matchWord('INCREMENT')) {
        _matchKw('BY');
        incrementBy = _parseSignedInt();
      } else if (_matchWord('MINVALUE')) {
        minValue = _parseSignedInt();
      } else if (_matchWord('NOMINVALUE')) {
        minValue = null;
      } else if (_matchWord('MAXVALUE')) {
        maxValue = _parseSignedInt();
      } else if (_matchWord('NOMAXVALUE')) {
        maxValue = null;
      } else if (_matchWord('CYCLE')) {
        cycle = true;
      } else if (_matchWord('NOCYCLE')) {
        cycle = false;
      } else if (_matchWord('CACHE')) {
        _parseSignedInt(); // accepted and ignored
      } else if (_matchWord('NOCACHE') ||
          _matchWord('ORDER') ||
          _matchWord('NOORDER')) {
        // accepted and ignored
      } else {
        break;
      }
    }
    return CreateSequenceStmt(
      name,
      startWith: startWith,
      incrementBy: incrementBy,
      minValue: minValue,
      maxValue: maxValue,
      cycle: cycle,
      ifNotExists: ifNotExists,
    );
  }

  int _parseSignedInt() {
    var negative = false;
    if (_check(TokType.op, '-')) {
      _advance();
      negative = true;
    } else if (_check(TokType.op, '+')) {
      _advance();
    }
    final n = int.parse(_expect(TokType.number).text);
    return negative ? -n : n;
  }

  // ---- CREATE PROCEDURE / FUNCTION (MySQL + Oracle stored routines) -------
  CreateProcedureStmt _parseCreateRoutine(bool isFunction,
      {bool orReplace = false}) {
    final name = _expectIdent().text;
    final params = _parseRoutineParams();
    String? returnType;
    if (isFunction) {
      // MySQL `RETURNS t`; Oracle `RETURN t`.
      if (!_matchWord('RETURNS')) _matchWord('RETURN');
      returnType = _consumeRoutineType();
    }
    // Oracle function options before IS/AS: DETERMINISTIC, PARALLEL_ENABLE,
    // PIPELINED, RESULT_CACHE, AUTHID …. Accepted and ignored.
    while (_matchWord('DETERMINISTIC') ||
        _matchWord('PARALLEL_ENABLE') ||
        _matchWord('PIPELINED') ||
        _matchWord('RESULT_CACHE')) {}
    if (_matchWord('AUTHID')) {
      _advance(); // CURRENT_USER / DEFINER
    }
    final RoutineBlock block;
    if (_matchWord('IS') || _matchWord('AS')) {
      // Oracle PL/SQL: declarations between IS/AS and BEGIN, then the body.
      final decls = _parsePlsqlDeclarations();
      block = _parsePlsqlBody(decls);
    } else {
      // MySQL: optional characteristics, then a BEGIN … END block.
      _consumeRoutineCharacteristics();
      block = _parseRoutineBody();
    }
    return CreateProcedureStmt(
      StoredRoutine(name, params, block,
          isFunction: isFunction, returnType: returnType),
      orReplace: orReplace,
    );
  }

  /// Parse an optional `(param [, param]*)` list shared by `CREATE
  /// PROCEDURE/FUNCTION` and package members. Each param is
  /// `[IN|OUT|INOUT] name type` (MySQL) or `name [IN|OUT|INOUT] type` (Oracle).
  List<RoutineParam> _parseRoutineParams() {
    final params = <RoutineParam>[];
    if (_match(TokType.punct, '(')) {
      if (!_check(TokType.punct, ')')) {
        do {
          var mode = RoutineParamMode.inParam;
          final String pname;
          // MySQL writes the mode before the name (`IN x INT`); Oracle writes
          // it after (`x IN NUMBER`). Detect a leading mode keyword only when a
          // parameter name follows it.
          if ((_checkWord('IN') || _checkWord('OUT') || _checkWord('INOUT')) &&
              _peek(1).type == TokType.ident) {
            if (_matchWord('INOUT')) {
              mode = RoutineParamMode.inOutParam;
            } else if (_matchWord('OUT')) {
              mode = RoutineParamMode.outParam;
            } else {
              _matchWord('IN');
            }
            pname = _expectIdent().text;
          } else {
            pname = _expectIdent().text;
            if (_matchWord('INOUT')) {
              mode = RoutineParamMode.inOutParam;
            } else if (_matchWord('OUT')) {
              mode = RoutineParamMode.outParam;
            } else {
              _matchWord('IN');
            }
          }
          final type = _consumeRoutineType();
          // Optional parameter default: `DEFAULT <expr>` or `:= <expr>`.
          String? defaultSql;
          if (_matchWord('DEFAULT') || _match(TokType.op, ':=')) {
            final start = _peek().offset;
            _parseExpr();
            defaultSql = _sliceSource(start, _peek().offset).trim();
          }
          params.add(RoutineParam(pname, mode, type, defaultSql: defaultSql));
        } while (_match(TokType.punct, ','));
      }
      _expect(TokType.punct, ')');
    }
    return params;
  }

  // ---- CREATE PACKAGE / PACKAGE BODY (Oracle) -----------------------------
  Statement _parseCreatePackage({bool orReplace = false}) {
    final isBody = _matchWord('BODY');
    final pkgName = _expectIdent().text;
    // Tolerate AUTHID / other clauses before the opening IS/AS.
    while (!_isAtEnd() && !_checkWord('IS') && !_checkWord('AS')) {
      _advance();
    }
    if (!_matchWord('IS')) _expectWord('AS');
    if (!isBody) {
      // Package spec: declarations only (no executable bodies). Skip to the
      // matching END; members live in the body.
      _skipPackageSpec();
      return CreatePackageStmt(pkgName, const [],
          isBody: false, orReplace: orReplace);
    }
    final packageVars = <RoutineDecl>[];
    final routines = _parsePackageBodyMembers(pkgName, packageVars);
    return CreatePackageStmt(pkgName, routines,
        isBody: true, orReplace: orReplace, packageVars: packageVars);
  }

  /// Skip a package spec body (procedure/function/variable declarations) up to
  /// and including its terminating `END [name];`.
  void _skipPackageSpec() {
    var depth = 0;
    while (!_isAtEnd()) {
      if (_check(TokType.punct, '(')) {
        depth++;
      } else if (_check(TokType.punct, ')')) {
        if (depth > 0) depth--;
      } else if (depth == 0 && _checkWord('END')) {
        break;
      }
      _advance();
    }
    _expectWord('END');
    if (_check(TokType.ident)) _advance(); // optional package name
    _match(TokType.punct, ';');
  }

  /// Parse the member routines of a package body, returning them with
  /// qualified `pkg.member` names. Package-level variable/constant declarations
  /// are collected into [packageVars] (for persistent package state); types,
  /// cursors and an optional init block are tolerated (parsed and discarded).
  List<StoredRoutine> _parsePackageBodyMembers(
      String pkgName, List<RoutineDecl> packageVars) {
    final members = <StoredRoutine>[];
    while (!_checkWord('END') && !_isAtEnd()) {
      if (_matchWord('PROCEDURE')) {
        members.add(_parsePackageRoutine(pkgName, false));
      } else if (_matchWord('FUNCTION')) {
        members.add(_parsePackageRoutine(pkgName, true));
      } else if (_checkWord('BEGIN')) {
        // Package initialization block — not executed; parse and discard.
        _parsePlsqlBody(const []);
      } else if (_checkWord('TYPE') ||
          _checkWord('SUBTYPE') ||
          _checkWord('CURSOR') ||
          _checkWord('PRAGMA')) {
        // Non-variable declaration — not modelled; skip to ';'.
        _skipToSemicolon();
      } else {
        // Package-level variable/constant: `name [CONSTANT] type [:= expr];`.
        final name = _expectIdent().text;
        _matchWord('CONSTANT');
        _consumeRoutineType();
        _matchKw('NOT') && _matchKw('NULL');
        String? init;
        if (_check(TokType.op, ':=')) {
          _advance();
          init = _captureRoutineExpr(const {});
        } else if (_matchKw('DEFAULT')) {
          init = _captureRoutineExpr(const {});
        }
        _match(TokType.punct, ';');
        packageVars.add(RoutineDecl(name, initSql: init));
      }
    }
    _expectWord('END');
    if (_check(TokType.ident)) _advance(); // optional package name
    _match(TokType.punct, ';');
    return members;
  }

  StoredRoutine _parsePackageRoutine(String pkgName, bool isFunction) {
    final memberName = _expectIdent().text;
    final params = _parseRoutineParams();
    String? returnType;
    if (isFunction) {
      if (!_matchWord('RETURNS')) _matchWord('RETURN');
      returnType = _consumeRoutineType();
    }
    if (!_matchWord('IS')) _expectWord('AS');
    final decls = _parsePlsqlDeclarations();
    final block = _parsePlsqlBody(decls);
    return StoredRoutine('$pkgName.$memberName', params, block,
        isFunction: isFunction, returnType: returnType);
  }

  void _skipToSemicolon() {
    var depth = 0;
    while (!_isAtEnd()) {
      if (_check(TokType.punct, '(')) {
        depth++;
      } else if (_check(TokType.punct, ')')) {
        if (depth > 0) depth--;
      } else if (depth == 0 && _check(TokType.punct, ';')) {
        _advance();
        return;
      }
      _advance();
    }
  }

  /// Consume a SQL type (`INT`, `VARCHAR(50)`, `DECIMAL(10,2)` …) and return its
  /// text. Only used for metadata; the engine does not enforce routine types.
  String _consumeRoutineType() {
    final start = _peek().offset;
    _advance(); // base type word
    // Anchored declarations: table.column%TYPE / var%ROWTYPE. Consume any
    // dotted name parts followed by the %TYPE / %ROWTYPE suffix.
    while (_check(TokType.punct, '.')) {
      _advance(); // .
      if (!_isAtEnd()) _advance(); // name part
    }
    if (_peek().text == '%') {
      _advance(); // %
      if (!_isAtEnd()) _advance(); // TYPE / ROWTYPE
    }
    if (_check(TokType.punct, '(')) {
      var depth = 0;
      do {
        final t = _advance();
        if (t.type == TokType.punct && t.text == '(') depth++;
        if (t.type == TokType.punct && t.text == ')') depth--;
      } while (depth > 0 && !_isAtEnd());
    }
    while (_matchWord('UNSIGNED') ||
        _matchWord('ZEROFILL') ||
        _matchWord('PRECISION')) {}
    return _sliceSource(start, _peek().offset).trim();
  }

  /// Skip MySQL routine characteristics (DETERMINISTIC, SQL SECURITY, …) that
  /// may appear between the signature and the body.
  void _consumeRoutineCharacteristics() {
    while (true) {
      if (_matchKw('NOT')) {
        _matchWord('DETERMINISTIC');
        continue;
      }
      if (_matchWord('DETERMINISTIC')) continue;
      if (_matchWord('CONTAINS') || _matchWord('LANGUAGE')) {
        _matchWord('SQL');
        continue;
      }
      if (_matchWord('NO')) {
        _matchWord('SQL');
        continue;
      }
      if (_matchWord('READS') || _matchWord('MODIFIES')) {
        _matchWord('SQL');
        _matchWord('DATA');
        continue;
      }
      if (_matchWord('SQL')) {
        _matchWord('SECURITY');
        _matchWord('DEFINER') || _matchWord('INVOKER');
        continue;
      }
      if (_matchWord('COMMENT')) {
        _expect(TokType.string);
        continue;
      }
      break;
    }
  }

  RoutineBlock _parseRoutineBody() {
    if (_matchWord('BEGIN')) {
      final decls = <RoutineDecl>[];
      final body = <RoutineStmt>[];
      while (!_checkWord('END') && !_isAtEnd()) {
        final s = _parseRoutineStmt(decls);
        if (s != null) body.add(s);
      }
      _expectWord('END');
      if (_check(TokType.ident)) _advance(); // optional end label
      _match(TokType.punct, ';');
      return RoutineBlock(body, declarations: decls);
    }
    final decls = <RoutineDecl>[];
    final s = _parseRoutineStmt(decls);
    return RoutineBlock(s == null ? const [] : [s], declarations: decls);
  }

  RoutineStmt? _parseRoutineStmt(List<RoutineDecl> decls) {
    // Optional statement label: `name: LOOP|WHILE|REPEAT`.
    if (_check(TokType.ident) &&
        _peek(1).type == TokType.punct &&
        _peek(1).text == ':') {
      _advance();
      _advance();
    }
    if (_checkWord('BEGIN')) return _parseRoutineBody();
    if (_matchWord('DECLARE')) {
      _parseRoutineDeclare(decls);
      return null;
    }
    if (_matchWord('SET')) return _parseRoutineSet();
    if (_checkWord('IF')) return _parseRoutineIf();
    if (_checkWord('WHILE')) return _parseRoutineWhile();
    if (_checkWord('LOOP')) return _parseRoutineLoop();
    if (_checkWord('REPEAT')) return _parseRoutineRepeat();
    if (_matchWord('LEAVE')) {
      if (_check(TokType.ident)) _advance(); // label
      _match(TokType.punct, ';');
      return RoutineExit();
    }
    if (_matchWord('ITERATE')) {
      if (_check(TokType.ident)) _advance();
      _match(TokType.punct, ';');
      return null; // ITERATE not yet supported — treated as a no-op
    }
    if (_matchWord('RETURN')) {
      if (_match(TokType.punct, ';')) return RoutineReturn();
      final e = _captureRoutineExpr(const {});
      _match(TokType.punct, ';');
      return RoutineReturn(exprSql: e);
    }
    return _parseRoutineEmbedded();
  }

  void _parseRoutineDeclare(List<RoutineDecl> decls) {
    final names = <String>[_expectIdent().text];
    while (_match(TokType.punct, ',')) {
      names.add(_expectIdent().text);
    }
    _consumeRoutineType();
    String? init;
    if (_matchKw('DEFAULT')) {
      init = _captureRoutineExpr(const {});
    }
    _match(TokType.punct, ';');
    for (final n in names) {
      decls.add(RoutineDecl(n, initSql: init));
    }
  }

  RoutineStmt _parseRoutineSet() {
    final assigns = <RoutineStmt>[];
    do {
      final target = _expectIdent().text;
      _expect(TokType.op, '=');
      assigns.add(RoutineAssign(target, _captureRoutineExpr(const {})));
    } while (_match(TokType.punct, ','));
    _match(TokType.punct, ';');
    return assigns.length == 1 ? assigns.first : RoutineBlock(assigns);
  }

  RoutineStmt _parseRoutineIf() {
    _expectWord('IF');
    final branches = <RoutineBranch>[
      RoutineBranch(_captureRoutineExpr({'THEN'}), _thenBody())
    ];
    while (_matchWord('ELSEIF')) {
      branches.add(RoutineBranch(_captureRoutineExpr({'THEN'}), _thenBody()));
    }
    var elseBody = const <RoutineStmt>[];
    if (_matchWord('ELSE')) {
      elseBody = _parseRoutineStmtsUntil({'END'});
    }
    _expectWord('END');
    _expectWord('IF');
    _match(TokType.punct, ';');
    return RoutineIf(branches, elseBody: elseBody);
  }

  List<RoutineStmt> _thenBody() {
    _expectWord('THEN');
    return _parseRoutineStmtsUntil({'ELSEIF', 'ELSE', 'END'});
  }

  RoutineStmt _parseRoutineWhile() {
    _expectWord('WHILE');
    final cond = _captureRoutineExpr({'DO'});
    _expectWord('DO');
    final body = _parseRoutineStmtsUntil({'END'});
    _expectWord('END');
    _expectWord('WHILE');
    if (_check(TokType.ident)) _advance();
    _match(TokType.punct, ';');
    return RoutineWhile(cond, body);
  }

  RoutineStmt _parseRoutineLoop() {
    _expectWord('LOOP');
    final body = _parseRoutineStmtsUntil({'END'});
    _expectWord('END');
    _expectWord('LOOP');
    if (_check(TokType.ident)) _advance();
    _match(TokType.punct, ';');
    return RoutineLoop(body);
  }

  RoutineStmt _parseRoutineRepeat() {
    _expectWord('REPEAT');
    final body = _parseRoutineStmtsUntil({'UNTIL'});
    _expectWord('UNTIL');
    final cond = _captureRoutineExpr({'END'});
    _expectWord('END');
    _expectWord('REPEAT');
    if (_check(TokType.ident)) _advance();
    _match(TokType.punct, ';');
    // REPEAT runs the body then exits once UNTIL is true.
    return RoutineLoop([...body, RoutineExit(whenSql: cond)]);
  }

  List<RoutineStmt> _parseRoutineStmtsUntil(Set<String> stops) {
    final out = <RoutineStmt>[];
    final decls = <RoutineDecl>[];
    while (!_isAtEnd() && !stops.contains(_peek().upper)) {
      final s = _parseRoutineStmt(decls);
      if (s != null) out.add(s);
    }
    return out;
  }

  /// Parse an embedded SQL statement inside a routine, up to the next top-level
  /// `;`. A `SELECT … INTO vars …` becomes a [RoutineSelectInto]; a bare SELECT
  /// becomes a result-producing [RoutineSelect]; anything else is [RoutineSql].
  RoutineStmt _parseRoutineEmbedded() {
    final startOff = _peek().offset;
    final isSelect = _checkWord('SELECT');
    var depth = 0;
    int? intoTokIdx;
    int? fromTokIdx;
    int? bulkTokIdx;
    while (!_isAtEnd() && !(depth == 0 && _check(TokType.punct, ';'))) {
      final t = _peek();
      if (t.type == TokType.punct && t.text == '(') {
        depth++;
      } else if (t.type == TokType.punct && t.text == ')') {
        depth--;
      } else if (depth == 0 && isSelect) {
        if (bulkTokIdx == null && t.upper == 'BULK') bulkTokIdx = _pos;
        if (intoTokIdx == null && t.upper == 'INTO') intoTokIdx = _pos;
        if (fromTokIdx == null && t.upper == 'FROM') fromTokIdx = _pos;
      }
      _advance();
    }
    final endOff = _peek().offset;
    _match(TokType.punct, ';');

    if (isSelect && intoTokIdx != null) {
      final intoTok = _tokens[intoTokIdx];
      final fromTok = fromTokIdx != null ? _tokens[fromTokIdx] : null;
      // `SELECT … BULK COLLECT INTO coll …`: the query text stops before the
      // BULK COLLECT marker (the selected column(s) land in the collection).
      final qEndTok = bulkTokIdx != null ? _tokens[bulkTokIdx] : intoTok;
      final q1 = _sliceRoutine(startOff, qEndTok.offset);
      final q2 =
          fromTok != null ? ' ${_sliceRoutine(fromTok.offset, endOff)}' : '';
      final intoVars = <String>[];
      final varEnd = fromTokIdx ?? _tokenIndexAtOffset(endOff);
      for (var i = intoTokIdx + 1; i < varEnd; i++) {
        final t = _tokens[i];
        if (t.type == TokType.ident) intoVars.add(t.text);
      }
      return RoutineSelectInto('$q1$q2', intoVars);
    }
    final sql = _sliceRoutine(startOff, endOff);
    return isSelect ? RoutineSelect(sql) : RoutineSql(sql);
  }

  int _tokenIndexAtOffset(int offset) {
    for (var i = 0; i < _tokens.length; i++) {
      if (_tokens[i].offset >= offset) return i;
    }
    return _tokens.length;
  }

  /// Capture a routine expression (with locals rewritten to `:name`) from the
  /// current position up to a top-level `;`, `,`, or any word in [stopUpper].
  String _captureRoutineExpr(Set<String> stopUpper) {
    final startOff = _peek().offset;
    var depth = 0;
    while (!_isAtEnd()) {
      final t = _peek();
      if (t.type == TokType.punct && t.text == '(') {
        depth++;
      } else if (t.type == TokType.punct && t.text == ')') {
        if (depth == 0) break;
        depth--;
      } else if (depth == 0) {
        if (t.type == TokType.punct && (t.text == ';' || t.text == ',')) break;
        if (t.type == TokType.op && t.text == '..') break; // PL/SQL FOR range
        if ((t.type == TokType.keyword || t.type == TokType.ident) &&
            stopUpper.contains(t.upper)) {
          break;
        }
      }
      _advance();
    }
    return _sliceRoutine(startOff, _peek().offset);
  }

  /// Reconstruct a routine SQL fragment from its tokens, verbatim. Local
  /// variables are left as bare identifiers; the interpreter resolves them at
  /// run time via [ColumnExpr.routineScopes], so value-position references
  /// become variables while column-position identifiers stay columns.
  String _sliceRoutine(int startOffset, int endOffset) =>
      _sliceSource(startOffset, endOffset);

  // ---- CALL ---------------------------------------------------------------
  CallStmt _parseCall() {
    _expectWord('CALL');
    var name = _expectIdent().text;
    // Qualified `CALL pkg.proc(args)`.
    if (_match(TokType.punct, '.')) {
      name = '$name.${_expectName()}';
    }
    final args = <Expr>[];
    if (_match(TokType.punct, '(')) {
      if (!_check(TokType.punct, ')')) {
        args.add(_parseCallArg());
        while (_match(TokType.punct, ',')) {
          args.add(_parseCallArg());
        }
      }
      _expect(TokType.punct, ')');
    }
    return CallStmt(name, args);
  }

  /// A call argument: a positional `expr` or an Oracle named argument
  /// `name => expr` (the name is dropped; the value is kept positionally).
  Expr _parseCallArg() {
    // The arg name may be an ident or a keyword (e.g. `cascade => TRUE`).
    if (_peek(1).type == TokType.op && _peek(1).text == '=>') {
      _advance(); // argument name
      _advance(); // =>
    }
    return _parseExpr();
  }

  // ---- PL/SQL (Oracle anonymous blocks & routine bodies) ------------------
  PlsqlBlockStmt _parsePlsqlBlock() {
    final decls = <RoutineDecl>[];
    if (_matchWord('DECLARE')) decls.addAll(_parsePlsqlDeclarations());
    final block = _parsePlsqlBody(decls);
    return PlsqlBlockStmt(block);
  }

  /// Parse PL/SQL declarations (`name [CONSTANT] type [:= expr | DEFAULT expr];`)
  /// up to the `BEGIN` that opens the executable section.
  List<RoutineDecl> _parsePlsqlDeclarations() {
    final decls = <RoutineDecl>[];
    while (!_checkWord('BEGIN') && !_isAtEnd()) {
      // PL/SQL type declarations (TYPE … IS TABLE OF / RECORD / REF CURSOR /
      // VARRAY, and SUBTYPE / CURSOR / PRAGMA) are parsed and discarded.
      if (_matchWord('TYPE') ||
          _matchWord('SUBTYPE') ||
          _matchWord('CURSOR') ||
          _matchWord('PRAGMA')) {
        _skipToSemicolon();
        continue;
      }
      final name = _expectIdent().text;
      _matchWord('CONSTANT');
      _consumeRoutineType();
      _matchKw('NOT') && _matchKw('NULL'); // tolerated, not enforced
      String? init;
      if (_check(TokType.op, ':=')) {
        _advance();
        init = _captureRoutineExpr(const {});
      } else if (_matchKw('DEFAULT')) {
        init = _captureRoutineExpr(const {});
      }
      _match(TokType.punct, ';');
      decls.add(RoutineDecl(name, initSql: init));
    }
    return decls;
  }

  RoutineBlock _parsePlsqlBody(List<RoutineDecl> decls) {
    _expectWord('BEGIN');
    final body = <RoutineStmt>[];
    while (!_checkWord('END') && !_checkWord('EXCEPTION') && !_isAtEnd()) {
      final s = _parsePlsqlStmt();
      if (s != null) body.add(s);
    }
    final handlers = <RoutineExceptionHandler>[];
    if (_matchWord('EXCEPTION')) {
      while (_matchWord('WHEN')) {
        final names = <String>[_expectName().toUpperCase()];
        while (_matchWord('OR')) {
          names.add(_expectName().toUpperCase());
        }
        _expectWord('THEN');
        final hbody = _parsePlsqlStmtsUntil({'WHEN', 'END'});
        handlers.add(RoutineExceptionHandler(names, hbody));
      }
    }
    _expectWord('END');
    if (_check(TokType.ident)) _advance(); // optional end name
    _match(TokType.punct, ';');
    return RoutineBlock(body, declarations: decls, handlers: handlers);
  }

  RoutineStmt? _parsePlsqlStmt() {
    if (_checkWord('DECLARE') || _checkWord('BEGIN')) {
      final nested = <RoutineDecl>[];
      if (_matchWord('DECLARE')) nested.addAll(_parsePlsqlDeclarations());
      return _parsePlsqlBody(nested);
    }
    if (_matchWord('NULL')) {
      _match(TokType.punct, ';');
      return null;
    }
    if (_matchWord('IF')) return _parsePlsqlIf();
    if (_matchWord('CASE')) return _parsePlsqlCase();
    if (_matchWord('WHILE')) return _parsePlsqlWhile();
    if (_matchWord('FOR')) return _parsePlsqlFor();
    if (_matchWord('LOOP')) {
      final body = _parsePlsqlStmtsUntil({'END'});
      _expectWord('END');
      _expectWord('LOOP');
      if (_check(TokType.ident)) _advance();
      _match(TokType.punct, ';');
      return RoutineLoop(body);
    }
    if (_matchWord('EXIT')) {
      if (_check(TokType.ident) && !_checkWord('WHEN')) _advance(); // label
      String? when;
      if (_matchWord('WHEN')) when = _captureRoutineExpr(const {});
      _match(TokType.punct, ';');
      return RoutineExit(whenSql: when);
    }
    if (_matchWord('RETURN')) {
      if (_match(TokType.punct, ';')) return RoutineReturn();
      final e = _captureRoutineExpr(const {});
      _match(TokType.punct, ';');
      return RoutineReturn(exprSql: e);
    }
    if (_matchWord('OPEN')) return _parsePlsqlOpen();
    // RAISE exc; or bare RAISE; (re-raise). The SQLite `RAISE(action,...)`
    // function form has a '(' and is left to expression parsing.
    if (_checkWord('RAISE') &&
        !(_peek(1).type == TokType.punct && _peek(1).text == '(')) {
      _advance();
      String? name;
      if (_check(TokType.ident)) name = _advance().text;
      _match(TokType.punct, ';');
      return RoutineRaise(name);
    }
    // Assignment: `name := expr;`.
    if (_check(TokType.ident) &&
        _peek(1).type == TokType.op &&
        _peek(1).text == ':=') {
      final target = _advance().text;
      _advance(); // :=
      final e = _captureRoutineExpr(const {});
      _match(TokType.punct, ';');
      return RoutineAssign(target, e);
    }
    // DBMS_OUTPUT.PUT_LINE(expr);
    if (_check(TokType.ident) &&
        _peek().upper == 'DBMS_OUTPUT' &&
        _peek(1).type == TokType.punct &&
        _peek(1).text == '.') {
      _advance(); // DBMS_OUTPUT
      _advance(); // .
      _advance(); // PUT_LINE (or PUT)
      _expect(TokType.punct, '(');
      final arg = _captureRoutineExpr(const {});
      _expect(TokType.punct, ')');
      _match(TokType.punct, ';');
      return RoutinePrint(arg);
    }
    if (_checkWord('SELECT') ||
        _checkWord('INSERT') ||
        _checkWord('UPDATE') ||
        _checkWord('DELETE') ||
        _checkWord('MERGE')) {
      return _parseRoutineEmbedded();
    }
    // Otherwise a procedure call: `proc(args);` or `proc;`.
    return _parsePlsqlCall();
  }

  /// `OPEN cur FOR <select>;` — bind a ref cursor to the query's result set.
  RoutineStmt _parsePlsqlOpen() {
    final name = _expectIdent().text;
    _expectWord('FOR');
    final startOff = _peek().offset;
    var depth = 0;
    while (!_isAtEnd() && !(depth == 0 && _check(TokType.punct, ';'))) {
      final t = _peek();
      if (t.type == TokType.punct && t.text == '(') {
        depth++;
      } else if (t.type == TokType.punct && t.text == ')') {
        depth--;
      }
      _advance();
    }
    final sql = _sliceRoutine(startOff, _peek().offset);
    _match(TokType.punct, ';');
    return RoutineOpen(name, sql);
  }

  RoutineStmt _parsePlsqlIf() {
    final branches = <RoutineBranch>[
      RoutineBranch(_captureRoutineExpr({'THEN'}), _plsqlThen())
    ];
    while (_matchWord('ELSIF')) {
      branches.add(RoutineBranch(_captureRoutineExpr({'THEN'}), _plsqlThen()));
    }
    var elseBody = const <RoutineStmt>[];
    if (_matchWord('ELSE')) {
      elseBody = _parsePlsqlStmtsUntil({'END'});
    }
    _expectWord('END');
    _expectWord('IF');
    _match(TokType.punct, ';');
    return RoutineIf(branches, elseBody: elseBody);
  }

  List<RoutineStmt> _plsqlThen() {
    _expectWord('THEN');
    return _parsePlsqlStmtsUntil({'ELSIF', 'ELSE', 'END'});
  }

  /// PL/SQL `CASE [selector] WHEN … THEN … [ELSE …] END CASE;` statement.
  /// Simple CASE (with a selector) is lowered to searched branches of the
  /// form `(selector) = (value)`. Reuses [RoutineIf] semantics.
  RoutineStmt _parsePlsqlCase() {
    String? selector;
    if (!_checkWord('WHEN')) {
      selector = _captureRoutineExpr({'WHEN'});
    }
    final branches = <RoutineBranch>[];
    while (_matchWord('WHEN')) {
      String cond;
      if (selector != null) {
        final val = _captureRoutineExpr({'THEN'});
        cond = '($selector) = ($val)';
      } else {
        cond = _captureRoutineExpr({'THEN'});
      }
      _expectWord('THEN');
      branches
          .add(RoutineBranch(cond, _parsePlsqlStmtsUntil({'WHEN', 'ELSE', 'END'})));
    }
    var elseBody = const <RoutineStmt>[];
    if (_matchWord('ELSE')) {
      elseBody = _parsePlsqlStmtsUntil({'END'});
    }
    _expectWord('END');
    _expectWord('CASE');
    _match(TokType.punct, ';');
    return RoutineIf(branches, elseBody: elseBody);
  }

  RoutineStmt _parsePlsqlWhile() {
    final cond = _captureRoutineExpr({'LOOP'});
    _expectWord('LOOP');
    final body = _parsePlsqlStmtsUntil({'END'});
    _expectWord('END');
    _expectWord('LOOP');
    if (_check(TokType.ident)) _advance();
    _match(TokType.punct, ';');
    return RoutineWhile(cond, body);
  }

  RoutineStmt _parsePlsqlFor() {
    final varName = _expectIdent().text;
    _expectWord('IN');
    // Cursor FOR loop over a subquery: `FOR rec IN (SELECT …) LOOP`.
    if (_check(TokType.punct, '(')) {
      _advance(); // (
      final startOff = _peek().offset;
      var depth = 1;
      while (!_isAtEnd() && depth > 0) {
        final t = _peek();
        if (t.type == TokType.punct && t.text == '(') {
          depth++;
        } else if (t.type == TokType.punct && t.text == ')') {
          depth--;
          if (depth == 0) break;
        }
        _advance();
      }
      final sql = _sliceRoutine(startOff, _peek().offset);
      _expect(TokType.punct, ')');
      _expectWord('LOOP');
      final body = _parsePlsqlStmtsUntil({'END'});
      _expectWord('END');
      _expectWord('LOOP');
      if (_check(TokType.ident)) _advance();
      _match(TokType.punct, ';');
      return RoutineForCursor(varName, sql, body);
    }
    final reverse = _matchWord('REVERSE');
    final lower = _captureRoutineExpr(const {}); // stops at the `..` op
    _expect(TokType.op, '..');
    final upper = _captureRoutineExpr({'LOOP'});
    _expectWord('LOOP');
    final body = _parsePlsqlStmtsUntil({'END'});
    _expectWord('END');
    _expectWord('LOOP');
    if (_check(TokType.ident)) _advance();
    _match(TokType.punct, ';');
    return RoutineForNumeric(varName, lower, upper, body, reverse: reverse);
  }

  RoutineStmt _parsePlsqlCall() {
    final startOff = _peek().offset;
    var depth = 0;
    while (!_isAtEnd() && !(depth == 0 && _check(TokType.punct, ';'))) {
      final t = _peek();
      if (t.type == TokType.punct && t.text == '(') depth++;
      if (t.type == TokType.punct && t.text == ')') depth--;
      _advance();
    }
    final sql = _sliceRoutine(startOff, _peek().offset);
    _match(TokType.punct, ';');
    return RoutineSql('CALL $sql');
  }

  List<RoutineStmt> _parsePlsqlStmtsUntil(Set<String> stops) {
    final out = <RoutineStmt>[];
    while (!_isAtEnd() && !stops.contains(_peek().upper)) {
      final s = _parsePlsqlStmt();
      if (s != null) out.add(s);
    }
    return out;
  }

  // ---- ALTER --------------------------------------------------------------
  Statement _parseAlter() {
    _expectKw('ALTER');
    if (_matchWord('SESSION')) {
      // ALTER SESSION SET … — accepted and ignored.
      while (!_isAtEnd() && !_check(TokType.punct, ';')) {
        _advance();
      }
      return DdlNoopStmt('ALTER SESSION');
    }
    _expectKw('TABLE');
    final table = _expectIdent().text;
    if (_matchKw('RENAME')) {
      if (_matchKw('TO')) {
        return AlterTableRenameStmt(table, _expectIdent().text);
      }
      _matchKw('COLUMN');
      final oldName = _expectIdent().text;
      _expectKw('TO');
      final newName = _expectIdent().text;
      return AlterTableRenameColumnStmt(table, oldName, newName);
    }
    if (_matchWord('MODIFY')) {
      // MODIFY CONSTRAINT <name> ENABLE/DISABLE … toggles constraint state;
      // MODIFY (col …) / MODIFY col … changes column attributes.
      if (_matchWord('CONSTRAINT')) {
        final cname = _expectName();
        bool? enable;
        while (!_isAtEnd() && !_check(TokType.punct, ';')) {
          final u = _peek().upper;
          if (u == 'ENABLE') enable = true;
          if (u == 'DISABLE') enable = false;
          _advance();
        }
        if (enable != null) {
          return AlterTableSetConstraintStmt(table, cname, enable);
        }
        return DdlNoopStmt('ALTER TABLE MODIFY');
      }
      final mparen = _match(TokType.punct, '(');
      final mcols = <ColumnDef>[_parseColumnDef()];
      while (_match(TokType.punct, ',')) {
        mcols.add(_parseColumnDef());
      }
      if (mparen) _expect(TokType.punct, ')');
      return AlterTableModifyColumnStmt(table, mcols);
    }
    if (_checkWord('DISABLE') || _checkWord('ENABLE')) {
      final enable = _peek().upper == 'ENABLE';
      _advance();
      _matchWord('VALIDATE');
      _matchWord('NOVALIDATE');
      if (_matchWord('CONSTRAINT')) {
        final cname = _expectName();
        while (!_isAtEnd() && !_check(TokType.punct, ';')) {
          _advance();
        }
        return AlterTableSetConstraintStmt(table, cname, enable);
      }
      // DISABLE/ENABLE ROW MOVEMENT / etc. — accept and ignore.
      while (!_isAtEnd() && !_check(TokType.punct, ';')) {
        _advance();
      }
      return DdlNoopStmt('ALTER TABLE');
    }
    if (_matchKw('DROP')) {
      if (_matchWord('CONSTRAINT')) {
        return AlterTableDropConstraintStmt(table, _expectName());
      }
      // DROP PRIMARY KEY — remove the table's primary-key constraint.
      if (_matchKw('PRIMARY')) {
        _expectKw('KEY');
        return AlterTableDropConstraintStmt(table, '__PRIMARY__');
      }
      _matchKw('COLUMN');
      return AlterTableDropColumnStmt(table, _expectIdent().text);
    }
    _expectKw('ADD');
    // Oracle/standard `ADD [(] <constraint>[, …] [)]` — distinguished from an
    // `ADD [COLUMN] <coldef>` by a leading constraint keyword.
    final paren = _match(TokType.punct, '(');
    bool atConstraint() =>
        _checkWord('CONSTRAINT') ||
        _checkKw('PRIMARY') ||
        _checkKw('UNIQUE') ||
        _checkKw('CHECK') ||
        _checkKw('FOREIGN');
    if (atConstraint()) {
      final cons = <TableConstraint>[_parseTableConstraint()];
      _skipConstraintState();
      while (_match(TokType.punct, ',') && atConstraint()) {
        cons.add(_parseTableConstraint());
        _skipConstraintState();
      }
      if (paren) _expect(TokType.punct, ')');
      return AlterTableAddConstraintStmt(table, cons);
    }
    _matchKw('COLUMN');
    final cols = <ColumnDef>[_parseColumnDef()];
    // `ADD (a …, b …)` adds every column in the parenthesised list.
    while (paren && _match(TokType.punct, ',')) {
      cols.add(_parseColumnDef());
    }
    if (paren) _expect(TokType.punct, ')');
    return AlterTableAddColumnStmt(table, cols);
  }

  /// `COMMENT ON TABLE/COLUMN <name> IS '<text>'` — accepted as a no-op.
  CommentStmt _parseComment() {
    _expectWord('COMMENT');
    _expectWord('ON');
    // TABLE <name> | COLUMN <table.col> | any object-type keyword then a name.
    _advance(); // object type (TABLE / COLUMN / INDEX / …)
    _parseQualifiedTableName(); // object name (possibly dotted)
    _expectWord('IS');
    _advance(); // the comment string literal (or NULL)
    return CommentStmt();
  }

  TruncateTableStmt _parseTruncate() {
    _expectKw('TRUNCATE');
    _matchKw('TABLE');
    return TruncateTableStmt(_expectIdent().text);
  }

  PragmaStmt _parsePragma() {
    _expectKw('PRAGMA');
    final name = _expectName();
    Object? value;
    if (_match(TokType.op, '=')) {
      value = _parsePragmaValue();
    } else if (_match(TokType.punct, '(')) {
      value = _parsePragmaValue();
      _expect(TokType.punct, ')');
    }
    return PragmaStmt(name, value);
  }

  Object? _parsePragmaValue() {
    final t = _peek();
    if (t.type == TokType.keyword || t.type == TokType.ident) {
      _advance();
      return t.text;
    }
    // Allow signed numeric literals (e.g. `PRAGMA cache_size = -2000`).
    // SQLite accepts negative cache_size as a KiB hint; positive values
    // are page counts.
    if (t.type == TokType.op && (t.text == '-' || t.text == '+')) {
      final sign = t.text;
      _advance();
      final inner = _parsePrimary();
      if (inner is LiteralExpr) {
        final v = inner.value;
        if (v is num) return sign == '-' ? -v : v;
      }
      throw FormatException('Expected numeric literal after $sign in PRAGMA');
    }
    final e = _parsePrimary();
    if (e is LiteralExpr) return e.value;
    throw FormatException('Expected literal in PRAGMA value');
  }

  // ---- INSERT / REPLACE ---------------------------------------------------
  InsertStmt _parseInsert() {
    _expectKw('INSERT');
    var mode = InsertMode.normal;
    if (_matchKw('OR')) {
      if (_matchKw('REPLACE')) {
        mode = InsertMode.orReplace;
      } else if (_matchKw('IGNORE')) {
        mode = InsertMode.orIgnore;
      } else if (_matchKw('ROLLBACK')) {
        mode = InsertMode.normal;
      } else {
        final p = _peek();
        if (p.type == TokType.ident &&
            (p.upper == 'ABORT' || p.upper == 'FAIL')) {
          // SQLite conflict resolution modifier; treat the same as the
          // default abort-on-conflict behaviour for now.
          _advance();
          mode = InsertMode.normal;
        } else {
          throw FormatException(
            'Expected REPLACE/IGNORE/ABORT/FAIL/ROLLBACK after INSERT OR',
          );
        }
      }
    }
    return _parseInsertTail(mode);
  }

  InsertStmt _parseReplace() {
    _expectKw('REPLACE');
    return _parseInsertTail(InsertMode.orReplace);
  }

  // ---- INSERT ALL / INSERT FIRST (Oracle multi-table insert) --------------
  InsertAllStmt _parseInsertAll() {
    _expectKw('INSERT');
    final first = _matchWord('FIRST');
    if (!first) _expectWord('ALL');
    final clauses = <InsertAllClause>[];
    if (_checkKw('WHEN')) {
      while (_matchKw('WHEN')) {
        final cond = _parseExpr();
        _expectKw('THEN');
        clauses.add(InsertAllClause(cond, false, _parseInsertAllIntos()));
      }
      if (_matchKw('ELSE')) {
        clauses.add(InsertAllClause(null, true, _parseInsertAllIntos()));
      }
    } else {
      clauses.add(InsertAllClause(null, false, _parseInsertAllIntos()));
    }
    final select = _parseSelect();
    return InsertAllStmt(first, clauses, select);
  }

  List<InsertAllInto> _parseInsertAllIntos() {
    final intos = <InsertAllInto>[];
    while (_matchKw('INTO')) {
      final table = _parseQualifiedTableName();
      List<String>? cols;
      if (_match(TokType.punct, '(')) {
        cols = <String>[_expectName()];
        while (_match(TokType.punct, ',')) {
          cols.add(_expectName());
        }
        _expect(TokType.punct, ')');
      }
      List<Expr>? values;
      if (_matchKw('VALUES')) {
        _expect(TokType.punct, '(');
        values = <Expr>[_parseExpr()];
        while (_match(TokType.punct, ',')) {
          values.add(_parseExpr());
        }
        _expect(TokType.punct, ')');
      }
      intos.add(InsertAllInto(table, cols, values));
    }
    if (intos.isEmpty) {
      throw const FormatException('Expected INTO in INSERT ALL/FIRST');
    }
    return intos;
  }

  InsertStmt _parseInsertTail(InsertMode mode) {
    _expectKw('INTO');
    final table = _parseQualifiedTableName();
    List<String>? cols;
    if (_match(TokType.punct, '(')) {
      cols = [_expectIdent().text];
      while (_match(TokType.punct, ',')) {
        cols.add(_expectIdent().text);
      }
      _expect(TokType.punct, ')');
    }
    List<List<Expr>>? rows;
    SelectStmt? srcSelect;
    if (_matchKw('DEFAULT')) {
      // INSERT INTO t DEFAULT VALUES — single all-NULL row, the engine
      // fills in column defaults / AUTOINCREMENT / GENERATED columns.
      _expectKw('VALUES');
      rows = <List<Expr>>[<Expr>[]];
    } else if (_matchKw('VALUES')) {
      rows = <List<Expr>>[];
      do {
        _expect(TokType.punct, '(');
        final values = <Expr>[_parseExpr()];
        while (_match(TokType.punct, ',')) {
          values.add(_parseExpr());
        }
        _expect(TokType.punct, ')');
        rows.add(values);
      } while (_match(TokType.punct, ','));
    } else if (_checkKw('SELECT') || _checkKw('WITH')) {
      srcSelect = _parseSelect();
    } else {
      throw FormatException('Expected VALUES or SELECT after INSERT INTO');
    }
    final onConflict = _parseOnConflictClause();
    final ret = _parseReturning();
    return InsertStmt(
      table,
      cols,
      rows,
      mode: mode,
      select: srcSelect,
      returning: ret,
      onConflict: onConflict,
    );
  }

  /// Parse an optional `ON CONFLICT [(col, ...)] DO {NOTHING|UPDATE SET ...}`
  /// clause, or the MySQL equivalent `ON DUPLICATE KEY UPDATE col = expr,...`.
  /// Returns null if neither form is present.
  OnConflictClause? _parseOnConflictClause() {
    if (!_matchKw('ON')) return null;
    // MySQL: ON DUPLICATE KEY UPDATE col = expr [, ...]
    if (_matchKw('DUPLICATE')) {
      _expectKw('KEY');
      _expectKw('UPDATE');
      final assigns = <String, Expr>{};
      do {
        final col = _expectName();
        _expect(TokType.op, '=');
        assigns[col] = _rewriteValuesRefs(_parseExpr());
      } while (_match(TokType.punct, ','));
      return OnConflictClause(
        targetColumns: const <String>[],
        assignments: assigns,
      );
    }
    _expectKw('CONFLICT');
    final cols = <String>[];
    if (_match(TokType.punct, '(')) {
      cols.add(_expectName());
      while (_match(TokType.punct, ',')) {
        cols.add(_expectName());
      }
      _expect(TokType.punct, ')');
    }
    _expectKw('DO');
    if (_matchKw('NOTHING')) {
      return OnConflictClause(targetColumns: cols, doNothing: true);
    }
    _expectKw('UPDATE');
    _expectKw('SET');
    final assigns = <String, Expr>{};
    do {
      final col = _expectName();
      _expect(TokType.op, '=');
      assigns[col] = _parseExpr();
    } while (_match(TokType.punct, ','));
    Expr? where;
    if (_matchKw('WHERE')) where = _parseExpr();
    return OnConflictClause(
      targetColumns: cols,
      assignments: assigns,
      where: where,
    );
  }

  /// Translate MySQL `VALUES(col)` references inside `ON DUPLICATE KEY UPDATE`
  /// expressions into `excluded.col` column references, which the executor
  /// already understands as "the row that would have been inserted".
  Expr _rewriteValuesRefs(Expr e) {
    if (e is FunctionCallExpr &&
        e.name.toUpperCase() == 'VALUES' &&
        e.args.length == 1 &&
        e.args.first is ColumnExpr) {
      final c = e.args.first as ColumnExpr;
      return ColumnExpr(c.name, table: 'excluded');
    }
    if (e is BinaryExpr) {
      return BinaryExpr(
        e.op,
        _rewriteValuesRefs(e.left),
        _rewriteValuesRefs(e.right),
      );
    }
    if (e is UnaryExpr) {
      return UnaryExpr(e.op, _rewriteValuesRefs(e.operand));
    }
    if (e is FunctionCallExpr) {
      return FunctionCallExpr(
        e.name,
        e.args.map(_rewriteValuesRefs).toList(),
        isStarArg: e.isStarArg,
        distinct: e.distinct,
        window: e.window,
        filterExpr:
            e.filterExpr == null ? null : _rewriteValuesRefs(e.filterExpr!),
        aggOrderBy: e.aggOrderBy,
      );
    }
    return e;
  }

  // ---- UPDATE -------------------------------------------------------------
  // ---- MERGE --------------------------------------------------------------
  MergeStmt _parseMerge() {
    _expectWord('MERGE');
    _expectKw('INTO');
    final target = _expectIdent().text;
    String? targetAlias;
    if (_matchKw('AS')) {
      targetAlias = _expectName();
    } else if (_check(TokType.ident) && !_checkKw('USING')) {
      targetAlias = _advance().text;
    }
    _expectWord('USING');
    String? sourceTable;
    SelectStmt? sourceSub;
    if (_match(TokType.punct, '(')) {
      sourceSub = _parseSelect();
      _expect(TokType.punct, ')');
    } else {
      sourceTable = _parseQualifiedTableName();
    }
    String? sourceAlias;
    if (_matchKw('AS')) {
      sourceAlias = _expectName();
    } else if (_check(TokType.ident) && !_checkKw('ON')) {
      sourceAlias = _advance().text;
    }
    _expectKw('ON');
    // ON condition is typically parenthesised; accept both.
    final Expr on;
    if (_match(TokType.punct, '(')) {
      on = _parseExpr();
      _expect(TokType.punct, ')');
    } else {
      on = _parseExpr();
    }

    Map<String, Expr>? matchedAssignments;
    Expr? matchedWhere;
    Expr? matchedDeleteWhere;
    List<String>? insertColumns;
    List<Expr>? insertValues;
    Expr? notMatchedWhere;

    while (_matchKw('WHEN')) {
      final notMatched = _matchKw('NOT');
      _expectWord('MATCHED');
      _expectKw('THEN');
      if (notMatched) {
        _expectWord('INSERT');
        if (_match(TokType.punct, '(')) {
          insertColumns = <String>[_expectName()];
          while (_match(TokType.punct, ',')) {
            insertColumns.add(_expectName());
          }
          _expect(TokType.punct, ')');
        }
        _expectKw('VALUES');
        _expect(TokType.punct, '(');
        insertValues = <Expr>[_parseExpr()];
        while (_match(TokType.punct, ',')) {
          insertValues.add(_parseExpr());
        }
        _expect(TokType.punct, ')');
        if (_matchKw('WHERE')) notMatchedWhere = _parseExpr();
      } else {
        _expectKw('UPDATE');
        _expectKw('SET');
        matchedAssignments = <String, Expr>{};
        do {
          var col = _expectIdent().text;
          // Accept an alias-qualified target column (`SET t.v = …`); the alias
          // refers to the target table, so drop it.
          if (_match(TokType.punct, '.')) {
            col = _expectIdent().text;
          }
          _expect(TokType.op, '=');
          matchedAssignments[col] = _parseExpr();
        } while (_match(TokType.punct, ','));
        if (_matchKw('WHERE')) matchedWhere = _parseExpr();
        // Oracle `... UPDATE SET … [WHERE …] DELETE WHERE <cond>`: the DELETE
        // sub-clause removes matched rows that satisfy its predicate.
        if (_matchKw('DELETE')) {
          _expectKw('WHERE');
          matchedDeleteWhere = _parseExpr();
        }
      }
    }
    if (matchedAssignments == null && insertValues == null) {
      throw const FormatException(
        'MERGE requires at least one WHEN MATCHED or WHEN NOT MATCHED clause',
      );
    }
    return MergeStmt(
      targetTable: target,
      targetAlias: targetAlias,
      sourceTable: sourceTable,
      sourceSubquery: sourceSub,
      sourceAlias: sourceAlias,
      onCondition: on,
      matchedAssignments: matchedAssignments,
      matchedWhere: matchedWhere,
      matchedDeleteWhere: matchedDeleteWhere,
      insertColumns: insertColumns,
      insertValues: insertValues,
      notMatchedWhere: notMatchedWhere,
    );
  }

  UpdateStmt _parseUpdate() {
    _expectKw('UPDATE');
    final table = _parseQualifiedTableName();
    final hint = _consumeIndexedHint();
    _expectKw('SET');
    final assignments = <String, Expr>{};
    do {
      // Oracle multi-column form: `SET (a, b) = (SELECT …)` assigns each column
      // from the matching element of a single-row subquery.
      if (_check(TokType.punct, '(')) {
        _advance(); // (
        final cols = <String>[_expectIdent().text];
        while (_match(TokType.punct, ',')) {
          cols.add(_expectIdent().text);
        }
        _expect(TokType.punct, ')');
        _expect(TokType.op, '=');
        _expect(TokType.punct, '(');
        final sub = SubquerySelectExpr(_parseSelect());
        _expect(TokType.punct, ')');
        for (var i = 0; i < cols.length; i++) {
          assignments[cols[i]] = RowElementExpr(sub, i);
        }
        continue;
      }
      final col = _expectIdent().text;
      _expect(TokType.op, '=');
      assignments[col] = _parseExpr();
    } while (_match(TokType.punct, ','));
    String? fromTable;
    String? fromAlias;
    if (_matchKw('FROM')) {
      fromTable = _expectIdent().text;
      if (_matchKw('AS')) {
        fromAlias = _expectName();
      } else if (_check(TokType.ident)) {
        fromAlias = _advance().text;
      }
    }
    Expr? where;
    if (_matchKw('WHERE')) where = _parseExpr();
    final ret = _parseReturning();
    Expr? limit;
    Expr? offset;
    if (_matchKw('LIMIT')) {
      limit = _parseExpr();
      if (_matchKw('OFFSET')) {
        offset = _parseExpr();
      } else if (_match(TokType.punct, ',')) {
        offset = limit;
        limit = _parseExpr();
      }
    }
    return UpdateStmt(
      table,
      assignments,
      where,
      returning: ret,
      indexedBy: hint,
      fromTable: fromTable,
      fromAlias: fromAlias,
      limit: limit,
      offset: offset,
    );
  }

  // ---- DELETE -------------------------------------------------------------
  DeleteStmt _parseDelete() {
    _expectKw('DELETE');
    _expectKw('FROM');
    final table = _parseQualifiedTableName();
    final hint = _consumeIndexedHint();
    Expr? where;
    if (_matchKw('WHERE')) where = _parseExpr();
    final ret = _parseReturning();
    Expr? limit;
    Expr? offset;
    if (_matchKw('LIMIT')) {
      limit = _parseExpr();
      if (_matchKw('OFFSET')) {
        offset = _parseExpr();
      } else if (_match(TokType.punct, ',')) {
        offset = limit;
        limit = _parseExpr();
      }
    }
    return DeleteStmt(
      table,
      where,
      returning: ret,
      indexedBy: hint,
      limit: limit,
      offset: offset,
    );
  }

  // ---- WITH (CTEs) --------------------------------------------------------
  Statement _parseWith() {
    _expectKw('WITH');
    final recursive = _matchKw('RECURSIVE');
    final ctes = <String, SelectStmt>{};
    final cteColumns = <String, List<String>>{};
    final cteMaterialized = <String, bool>{};
    // Oracle inline PL/SQL: `WITH FUNCTION f(...) RETURN t IS ... END; … SELECT`.
    final withFns = <StoredRoutine>[];
    while (_checkWord('FUNCTION') || _checkWord('PROCEDURE')) {
      final isFn = _matchWord('FUNCTION');
      if (!isFn) _matchWord('PROCEDURE');
      final fname = _expectIdent().text;
      final params = _parseRoutineParams();
      String? returnType;
      if (isFn) {
        if (!_matchWord('RETURNS')) _matchWord('RETURN');
        returnType = _consumeRoutineType();
      }
      RoutineBlock block;
      if (_matchWord('IS') || _matchWord('AS')) {
        final decls = _parsePlsqlDeclarations();
        block = _parsePlsqlBody(decls);
      } else {
        _consumeRoutineCharacteristics();
        block = _parseRoutineBody();
      }
      withFns.add(StoredRoutine(fname, params, block,
          isFunction: isFn, returnType: returnType));
      _match(TokType.punct, ';');
      _match(TokType.punct, ',');
    }
    // Named CTEs (optional when only inline functions precede the query).
    if (_check(TokType.ident)) {
      do {
        final name = _expectIdent().text;
      // Optional column list. When present, used to rename the CTE's
      // projected columns (necessary for WITH RECURSIVE so the recursive
      // arm can reference them by name).
      if (_match(TokType.punct, '(')) {
        final cols = <String>[_expectName()];
        while (_match(TokType.punct, ',')) {
          cols.add(_expectName());
        }
        _expect(TokType.punct, ')');
        cteColumns[name] = cols;
      }
      _expectKw('AS');
      // Optional MATERIALIZED / NOT MATERIALIZED hint.
      if (_matchKw('NOT')) {
        _expectKw('MATERIALIZED');
        cteMaterialized[name] = false;
      } else if (_matchKw('MATERIALIZED')) {
        cteMaterialized[name] = true;
      }
      _expect(TokType.punct, '(');
      final body = _parseSelect();
      _expect(TokType.punct, ')');
      ctes[name] = body;
      // Oracle recursive-WITH SEARCH / CYCLE clauses — parsed and ignored (the
      // ordering/cycle-mark columns are not materialised).
      if (_matchWord('SEARCH')) {
        if (!_matchWord('DEPTH')) _matchWord('BREADTH');
        _matchWord('FIRST');
        _matchWord('BY');
        _parseOrderByItem();
        while (_match(TokType.punct, ',')) {
          _parseOrderByItem();
        }
        _matchWord('SET');
        _expectName();
      }
      if (_matchWord('CYCLE')) {
        _expectName();
        while (_match(TokType.punct, ',')) {
          _expectName();
        }
        _matchWord('SET');
        _expectName();
        _matchWord('TO');
        _parsePrimary();
        _matchWord('DEFAULT');
        _parsePrimary();
      }
      } while (_match(TokType.punct, ','));
    }

    final t = _peek();
    if (t.type != TokType.keyword) {
      throw FormatException('Expected SELECT/INSERT/UPDATE/DELETE after WITH');
    }
    switch (t.upper) {
      case 'SELECT':
        final s = _parseSelect();
        return SelectStmt(
          projection: s.projection,
          fromTable: s.fromTable,
          fromSubquery: s.fromSubquery,
          fromAlias: s.fromAlias,
          joins: s.joins,
          where: s.where,
          groupBy: s.groupBy,
          having: s.having,
          orderBy: s.orderBy,
          limit: s.limit,
          offset: s.offset,
          distinct: s.distinct,
          setOp: s.setOp,
          setOpRight: s.setOpRight,
          ctes: ctes,
          cteColumns: cteColumns,
          ctesRecursive: recursive,
          cteMaterialized: cteMaterialized,
          withFunctions: withFns,
        );
      case 'INSERT':
        final s = _parseInsert();
        return InsertStmt(
          s.table,
          s.columns,
          s.rows,
          mode: s.mode,
          select: s.select,
          returning: s.returning,
          ctes: ctes,
          cteColumns: cteColumns,
          ctesRecursive: recursive,
        );
      case 'UPDATE':
        final s = _parseUpdate();
        return UpdateStmt(
          s.table,
          s.assignments,
          s.where,
          returning: s.returning,
          ctes: ctes,
          cteColumns: cteColumns,
          ctesRecursive: recursive,
          indexedBy: s.indexedBy,
          fromTable: s.fromTable,
          fromAlias: s.fromAlias,
          limit: s.limit,
          offset: s.offset,
        );
      case 'DELETE':
        final s = _parseDelete();
        return DeleteStmt(
          s.table,
          s.where,
          returning: s.returning,
          ctes: ctes,
          cteColumns: cteColumns,
          ctesRecursive: recursive,
          indexedBy: s.indexedBy,
          limit: s.limit,
          offset: s.offset,
        );
    }
    throw FormatException('Unexpected statement after WITH: ${t.text}');
  }

  // ---- RETURNING ----------------------------------------------------------
  List<SelectItem>? _parseReturning() {
    if (!_matchKw('RETURNING')) return null;
    final items = <SelectItem>[_parseSelectItem()];
    while (_match(TokType.punct, ',')) {
      items.add(_parseSelectItem());
    }
    // PL/SQL `RETURNING ... INTO var[, var]`: consume the bind-variable
    // targets (the values are surfaced via the statement's RETURNING result).
    if (_matchWord('INTO')) {
      _parseExpr();
      while (_match(TokType.punct, ',')) {
        _parseExpr();
      }
    }
    return items;
  }

  // ---- SELECT -------------------------------------------------------------
  SelectStmt _parseSelect() {
    if (_checkKw('VALUES')) {
      return _parseValuesAsSelect();
    }
    // A subquery / derived table may itself start with a WITH clause
    // (`FROM (WITH x AS (...) SELECT ... FROM x)`). Delegate to the WITH parser
    // and keep the resulting SELECT (with its CTE bindings attached).
    if (_checkKw('WITH')) {
      final w = _parseWith();
      if (w is SelectStmt) return w;
      throw FormatException('Expected SELECT after WITH in subquery');
    }
    final base = _parseSimpleSelect();
    String? setOp;
    SelectStmt? right;
    if (_matchKw('UNION')) {
      setOp = _matchKw('ALL') ? 'UNION ALL' : 'UNION';
      right = _parseSelect();
    } else if (_matchKw('INTERSECT')) {
      setOp = _matchKw('ALL') ? 'INTERSECT ALL' : 'INTERSECT';
      right = _parseSelect();
    } else if (_matchKw('EXCEPT')) {
      setOp = _matchKw('ALL') ? 'EXCEPT ALL' : 'EXCEPT';
      right = _parseSelect();
    } else if (_matchWord('MINUS')) {
      // Oracle MINUS is a synonym for EXCEPT (distinct set difference).
      setOp = _matchKw('ALL') ? 'EXCEPT ALL' : 'EXCEPT';
      right = _parseSelect();
    }
    if (setOp == null) return base;
    return SelectStmt(
      projection: base.projection,
      fromTable: base.fromTable,
      fromSubquery: base.fromSubquery,
      fromAlias: base.fromAlias,
      joins: base.joins,
      where: base.where,
      groupBy: base.groupBy,
      having: base.having,
      orderBy: base.orderBy,
      limit: base.limit,
      offset: base.offset,
      distinct: base.distinct,
      ctes: base.ctes,
      setOp: setOp,
      setOpRight: right,
    );
  }

  /// Parse standalone `VALUES (e1, e2, ...), (...), ...` and desugar
  /// into a UNION ALL chain of single-row SELECTs. The head arm names
  /// its columns `column1`, `column2`, ... matching SQLite's
  /// convention. Optional trailing ORDER BY / LIMIT / OFFSET attach to
  /// the head arm so the compound-clause logic finds them.
  SelectStmt _parseValuesAsSelect() {
    _expectKw('VALUES');
    final rows = <List<Expr>>[];
    _expect(TokType.punct, '(');
    final first = <Expr>[_parseExpr()];
    while (_match(TokType.punct, ',')) {
      first.add(_parseExpr());
    }
    _expect(TokType.punct, ')');
    rows.add(first);
    while (_match(TokType.punct, ',')) {
      _expect(TokType.punct, '(');
      final r = <Expr>[_parseExpr()];
      while (_match(TokType.punct, ',')) {
        r.add(_parseExpr());
      }
      _expect(TokType.punct, ')');
      if (r.length != first.length) {
        throw FormatException(
          'VALUES rows must all have the same number of columns',
        );
      }
      rows.add(r);
    }
    final orderBy = <OrderByItem>[];
    if (_matchKw('ORDER')) {
      _expectKw('BY');
      orderBy.add(_parseOrderByItem());
      while (_match(TokType.punct, ',')) {
        orderBy.add(_parseOrderByItem());
      }
    }
    int? limit;
    int? offset;
    if (_matchKw('LIMIT')) {
      final lim = _parseSignedInt();
      if (_match(TokType.punct, ',')) {
        offset = lim < 0 ? 0 : lim;
        final cnt = _parseSignedInt();
        limit = cnt < 0 ? null : cnt;
      } else {
        limit = lim < 0 ? null : lim;
      }
    }
    if (_matchKw('OFFSET')) {
      final off = _parseSignedInt();
      offset = off < 0 ? 0 : off;
    }
    SelectStmt makeArm(List<Expr> vals, {bool nameCols = false}) {
      final proj = <SelectItem>[];
      for (var i = 0; i < vals.length; i++) {
        proj.add(
          SelectItem.expr(vals[i], alias: nameCols ? 'column${i + 1}' : null),
        );
      }
      return SelectStmt(projection: proj, orderBy: const []);
    }

    // Build a right-recursive UNION ALL tail from rows[1..].
    SelectStmt? tail;
    for (var i = rows.length - 1; i >= 1; i--) {
      final arm = makeArm(rows[i]);
      tail = SelectStmt(
        projection: arm.projection,
        orderBy: const [],
        setOp: tail == null ? null : 'UNION ALL',
        setOpRight: tail,
      );
    }
    final headProj = makeArm(rows.first, nameCols: true).projection;
    if (rows.length == 1) {
      return SelectStmt(
        projection: headProj,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );
    }
    return SelectStmt(
      projection: headProj,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      setOp: 'UNION ALL',
      setOpRight: tail,
    );
  }

  /// Shreds a `TABLE(collection)` operand into a derived table with one
  /// `COLUMN_VALUE` row per collection element (the constructor's arguments).
  SelectStmt _parseTableCollection() {
    final inner = _parseExpr();
    final elems = inner is FunctionCallExpr ? inner.args : <Expr>[inner];
    List<SelectItem> arm(Expr e) =>
        [SelectItem.expr(e, alias: 'COLUMN_VALUE')];
    if (elems.isEmpty) {
      return SelectStmt(
        projection: [SelectItem.expr(LiteralExpr(null), alias: 'COLUMN_VALUE')],
        where: LiteralExpr(0),
        orderBy: const [],
      );
    }
    SelectStmt? tail;
    for (var i = elems.length - 1; i >= 1; i--) {
      tail = SelectStmt(
        projection: arm(elems[i]),
        orderBy: const [],
        setOp: tail == null ? null : 'UNION ALL',
        setOpRight: tail,
      );
    }
    return SelectStmt(
      projection: arm(elems.first),
      orderBy: const [],
      setOp: elems.length == 1 ? null : 'UNION ALL',
      setOpRight: tail,
    );
  }

  SelectStmt _parseSimpleSelect() {
    _expectKw('SELECT');
    final distinct = _matchKw('DISTINCT');
    final projection = <SelectItem>[_parseSelectItem()];
    while (_match(TokType.punct, ',')) {
      projection.add(_parseSelectItem());
    }
    String? fromTable;
    SelectStmt? fromSub;
    String? fromAlias;
    FunctionCallExpr? fromFunc;
    IndexHint? fromIndexHint;
    MatchRecognizeClause? fromMatchRecognize;
    final joins = <JoinClause>[];
    if (_matchKw('FROM')) {
      if (_match(TokType.punct, '(')) {
        fromSub = _parseSelect();
        _expect(TokType.punct, ')');
      } else if (_checkWord('TABLE') &&
          _peek(1).type == TokType.punct &&
          _peek(1).text == '(') {
        // Oracle `TABLE(collection)` unnesting: shred a collection constructor
        // (e.g. SYS.ODCINUMBERLIST(10,20,30)) into one COLUMN_VALUE row each.
        _advance(); // TABLE
        _expect(TokType.punct, '(');
        fromSub = _parseTableCollection();
        _expect(TokType.punct, ')');
      } else if (_checkWord('JSON_TABLE') &&
          _peek(1).type == TokType.punct &&
          _peek(1).text == '(') {
        _advance(); // JSON_TABLE
        fromSub = _parseJsonTableClause();
      } else if (_checkWord('XMLTABLE') &&
          _peek(1).type == TokType.punct &&
          _peek(1).text == '(') {
        _advance(); // XMLTABLE
        fromSub = _parseXmlTableClause();
      } else {
        // Look ahead: an identifier immediately followed by `(` is a
        // table-valued function call (e.g. `json_each('[1,2]')`).
        final saved = _pos;
        final name = _parseQualifiedTableName();
        if (_check(TokType.punct, '(') && !name.contains('.')) {
          fromFunc = _parseFunctionCall(name) as FunctionCallExpr;
        } else {
          // Roll back the qualified-name parse; we got a regular table.
          _pos = saved;
          fromTable = _parseQualifiedTableName();
        }
      }
      // Oracle flashback (`AS OF SCN|TIMESTAMP …`, `VERSIONS BETWEEN … AND …`)
      // and `SAMPLE [BLOCK] (n) [SEED (n)]` — accepted and ignored (we query
      // the current rows / the full table).
      _consumeFlashbackAndSample();
      if (_matchKw('AS')) {
        fromAlias = _expectName();
      } else if (_check(TokType.ident) &&
          !_isClauseStartWord() &&
          !_checkWord('PIVOT') &&
          !_checkWord('UNPIVOT') &&
          !_checkWord('MATCH_RECOGNIZE') &&
          !_checkWord('MODEL')) {
        fromAlias = _advance().text;
      }
      fromIndexHint = _consumeIndexedHint();
      // Oracle PIVOT: rewrite `FROM src PIVOT (agg FOR col IN (vals))` into a
      // grouped CASE-aggregate subquery the outer SELECT reads from.
      if (_checkWord('PIVOT') && (fromSub != null || fromTable != null)) {
        _advance(); // PIVOT
        final srcSel = fromSub ??
            SelectStmt(
              projection: [SelectItem.star()],
              fromTable: fromTable,
              orderBy: const [],
            );
        fromSub =
            _matchWord('XML') ? _parsePivotXmlClause(srcSel) : _parsePivotClause(srcSel);
        fromTable = null;
        fromFunc = null;
      }
      // Oracle UNPIVOT: rewrite `FROM tbl UNPIVOT (val FOR col IN (c1, c2))`
      // into a UNION ALL subquery (one arm per unpivoted column).
      if (_checkWord('UNPIVOT') && fromTable != null) {
        _advance(); // UNPIVOT
        fromSub = _parseUnpivotClause(fromTable);
        fromTable = null;
        fromFunc = null;
      }
      // Oracle MATCH_RECOGNIZE row-pattern recognition clause.
      if (_checkWord('MATCH_RECOGNIZE') &&
          (fromTable != null || fromSub != null)) {
        _advance(); // MATCH_RECOGNIZE
        fromMatchRecognize = _parseMatchRecognize();
        if (_matchKw('AS')) {
          fromAlias = _expectName();
        } else if (_check(TokType.ident) &&
            !_isClauseStartWord() &&
            !_checkWord('PIVOT') &&
            !_checkWord('UNPIVOT')) {
          fromAlias = _advance().text;
        }
      }
      while (true) {
        // Comma join: `FROM a, b` is a CROSS JOIN; any join predicate lives
        // in the WHERE clause (and Oracle (+) markers there turn it outer).
        if (_match(TokType.punct, ',')) {
          String? ctbl;
          SelectStmt? csub;
          var clateral = false;
          // Oracle/ANSI `, LATERAL (subquery)` — a correlated derived table.
          if (_matchWord('LATERAL')) {
            clateral = true;
            _expect(TokType.punct, '(');
            csub = _parseSelect();
            _expect(TokType.punct, ')');
          } else if (_match(TokType.punct, '(')) {
            csub = _parseSelect();
            _expect(TokType.punct, ')');
          } else if (_checkWord('JSON_TABLE') &&
              _peek(1).type == TokType.punct &&
              _peek(1).text == '(') {
            _advance(); // JSON_TABLE
            csub = _parseJsonTableClause();
          } else {
            ctbl = _parseQualifiedTableName();
          }
          String? calias;
          if (_matchKw('AS')) {
            calias = _expectName();
          } else if (_check(TokType.ident) && !_isClauseStartWord()) {
            calias = _advance().text;
          }
          joins.add(JoinClause('CROSS', ctbl, calias, null,
              subquery: csub, lateral: clateral));
          continue;
        }
        String? joinType;
        bool natural = false;
        var lateral = false;
        if (_matchKw('NATURAL')) {
          natural = true;
        }
        if (_matchKw('INNER')) {
          _expectKw('JOIN');
          joinType = 'INNER';
        } else if (_matchKw('LEFT')) {
          _matchKw('OUTER');
          _expectKw('JOIN');
          joinType = 'LEFT';
        } else if (_matchKw('RIGHT')) {
          _matchKw('OUTER');
          _expectKw('JOIN');
          joinType = 'RIGHT';
        } else if (_matchKw('FULL')) {
          _matchKw('OUTER');
          _expectKw('JOIN');
          joinType = 'FULL';
        } else if (_matchKw('CROSS')) {
          // `CROSS APPLY (…)` is a correlated inner join; `CROSS JOIN` is plain.
          if (_matchWord('APPLY')) {
            joinType = 'CROSS';
            lateral = true;
          } else {
            _expectKw('JOIN');
            joinType = 'CROSS';
          }
        } else if (_checkWord('OUTER') && _peek(1).upper == 'APPLY') {
          // `OUTER APPLY (…)` is a correlated left join.
          _advance(); // OUTER
          _advance(); // APPLY
          joinType = 'LEFT';
          lateral = true;
        } else if (_matchKw('JOIN')) {
          joinType = 'INNER';
        }
        if (joinType == null) {
          if (natural) {
            throw FormatException('Expected JOIN after NATURAL');
          }
          break;
        }
        String? tbl;
        SelectStmt? sub;
        if (_match(TokType.punct, '(')) {
          sub = _parseSelect();
          _expect(TokType.punct, ')');
        } else {
          tbl = _parseQualifiedTableName();
        }
        String? alias;
        if (_check(TokType.ident)) {
          alias = _advance().text;
        } else if (_matchKw('AS')) {
          alias = _expectName();
        }
        final joinHint = _consumeIndexedHint();
        Expr? on;
        List<String>? usingCols;
        if (!natural && joinType != 'CROSS' && !lateral) {
          if (_matchKw('USING')) {
            _expect(TokType.punct, '(');
            usingCols = [_expectName()];
            while (_match(TokType.punct, ',')) {
              usingCols.add(_expectName());
            }
            _expect(TokType.punct, ')');
          } else {
            _expectKw('ON');
            on = _parseExpr();
          }
        }
        joins.add(
          JoinClause(
            joinType,
            tbl,
            alias,
            on,
            subquery: sub,
            using: usingCols,
            natural: natural,
            indexedBy: joinHint,
            lateral: lateral,
          ),
        );
      }
    }
    Expr? where;
    if (_matchKw('WHERE')) where = _parseExpr();
    // Oracle legacy (+) outer joins: rewrite comma/CROSS joins into LEFT/RIGHT
    // joins, moving the marked equality predicate(s) from WHERE into the ON.
    if (where != null && joins.isNotEmpty) {
      where = _rewriteOracleOuterJoins(fromTable, fromAlias, joins, where);
    }
    // Oracle MODEL clause (spreadsheet-style RULES): advanced and rare — it is
    // consumed and discarded so the underlying query still runs.
    if (_matchWord('MODEL')) {
      var depth = 0;
      while (!_isAtEnd()) {
        final t = _peek();
        if (t.type == TokType.punct && t.text == '(') {
          depth++;
          _advance();
          continue;
        }
        if (t.type == TokType.punct && t.text == ')') {
          if (depth == 0) break;
          depth--;
          _advance();
          continue;
        }
        if (depth == 0 &&
            ((t.type == TokType.punct && t.text == ';') ||
                t.upper == 'ORDER' ||
                t.upper == 'UNION' ||
                t.upper == 'INTERSECT' ||
                t.upper == 'EXCEPT' ||
                t.upper == 'MINUS')) {
          break;
        }
        _advance();
      }
    }
    // Oracle hierarchical query: [START WITH ...] CONNECT BY [NOCYCLE] ...
    // (START WITH and CONNECT BY may appear in either order).
    final connectBy = _parseConnectBy();
    final groupBy = <Expr>[];
    List<List<Expr>>? groupingSets;
    Expr? having;
    if (_matchKw('GROUP')) {
      _expectKw('BY');
      // A GROUP BY is a comma-separated list of factors; each factor is either
      // a plain key or a ROLLUP / CUBE / GROUPING SETS / () set-generator. The
      // effective grouping sets are the cross-product (concatenation) of every
      // factor's alternative key-sets, so `GROUP BY a, ROLLUP(b)` yields
      // {a,b} and {a}.
      final factors = <List<List<Expr>>>[];
      var sawSetFn = false;
      do {
        if (_check(TokType.punct, '(') && _peek(1).text == ')') {
          // Explicit empty grouping `()` — a single grand-total group.
          _advance(); // (
          _advance(); // )
          factors.add(<List<Expr>>[<Expr>[]]);
          sawSetFn = true;
        } else if (_matchKw('ROLLUP')) {
          _expect(TokType.punct, '(');
          final keys = <Expr>[_parseExpr()];
          while (_match(TokType.punct, ',')) {
            keys.add(_parseExpr());
          }
          _expect(TokType.punct, ')');
          factors.add(<List<Expr>>[
            for (var i = keys.length; i >= 0; i--) keys.sublist(0, i),
          ]);
          groupBy.addAll(keys);
          sawSetFn = true;
        } else if (_matchKw('CUBE')) {
          _expect(TokType.punct, '(');
          final keys = <Expr>[_parseExpr()];
          while (_match(TokType.punct, ',')) {
            keys.add(_parseExpr());
          }
          _expect(TokType.punct, ')');
          final sets = <List<Expr>>[];
          for (var mask = (1 << keys.length) - 1; mask >= 0; mask--) {
            sets.add(<Expr>[
              for (var i = 0; i < keys.length; i++)
                if ((mask >> i) & 1 == 1) keys[i],
            ]);
          }
          factors.add(sets);
          groupBy.addAll(keys);
          sawSetFn = true;
        } else if (_matchKw('GROUPING')) {
          _expectKw('SETS');
          _expect(TokType.punct, '(');
          final sets = <List<Expr>>[];
          do {
            if (_match(TokType.punct, '(')) {
              final set = <Expr>[];
              if (!_check(TokType.punct, ')')) {
                set.add(_parseExpr());
                while (_match(TokType.punct, ',')) {
                  set.add(_parseExpr());
                }
              }
              _expect(TokType.punct, ')');
              sets.add(set);
              groupBy.addAll(set);
            } else {
              final k = _parseExpr();
              sets.add([k]);
              groupBy.add(k);
            }
          } while (_match(TokType.punct, ','));
          _expect(TokType.punct, ')');
          factors.add(sets);
          sawSetFn = true;
        } else {
          final k = _parseExpr();
          factors.add(<List<Expr>>[
            [k]
          ]);
          groupBy.add(k);
        }
      } while (_match(TokType.punct, ','));
      // Only materialise groupingSets when a set-generator was present; a plain
      // key list stays a normal GROUP BY (groupBy already holds the keys).
      if (sawSetFn) {
        var combined = <List<Expr>>[<Expr>[]];
        for (final factor in factors) {
          final next = <List<Expr>>[];
          for (final acc in combined) {
            for (final set in factor) {
              next.add(<Expr>[...acc, ...set]);
            }
          }
          combined = next;
        }
        groupingSets = combined;
      }
    }
    // HAVING is accepted with or without GROUP BY (SQLite/MySQL apply it to the
    // implicit single group when there is no GROUP BY).
    if (_matchKw('HAVING')) having = _parseExpr();
    final namedWindows = <String, WindowSpec>{};
    if (_matchKw('WINDOW')) {
      do {
        final n = _advance();
        _expectKw('AS');
        final spec = _parseWindowSpec();
        namedWindows[n.text] = spec;
      } while (_match(TokType.punct, ','));
    }
    final orderBy = <OrderByItem>[];
    if (_matchKw('ORDER')) {
      _expectKw('BY');
      orderBy.add(_parseOrderByItem());
      while (_match(TokType.punct, ',')) {
        orderBy.add(_parseOrderByItem());
      }
    }
    int? limit;
    int? offset;
    var limitPercent = false;
    if (_matchKw('LIMIT')) {
      final lim = _parseSignedInt();
      // MySQL form: `LIMIT offset, count` swaps the meaning of the
      // first integer.
      if (_match(TokType.punct, ',')) {
        offset = lim < 0 ? 0 : lim;
        final cnt = _parseSignedInt();
        limit = cnt < 0 ? null : cnt; // SQLite: a negative LIMIT is unlimited
      } else {
        limit = lim < 0 ? null : lim; // SQLite: a negative LIMIT is unlimited
      }
    }
    if (_matchKw('OFFSET')) {
      final off = _parseSignedInt();
      offset = off < 0 ? 0 : off; // SQLite clamps a negative OFFSET to 0
      // Oracle / SQL-standard: OFFSET n { ROW | ROWS }.
      if (_matchKw('ROW') || _matchKw('ROWS')) {}
    }
    // Oracle / SQL-standard row-limiting clause:
    //   FETCH { FIRST | NEXT } [ n ] { ROW | ROWS } { ONLY | WITH TIES }
    // n defaults to 1; WITH TIES is accepted but behaves like ONLY here.
    if (_matchWord('FETCH')) {
      if (!_matchKw('FIRST') && !_matchWord('NEXT')) {
        final got = _peek();
        throw FormatException(
          'Expected FIRST or NEXT after FETCH but got "${got.text}" at '
          'offset ${got.offset}',
        );
      }
      var count = 1;
      if (_check(TokType.number)) count = int.parse(_advance().text);
      final percent = _matchWord('PERCENT');
      if (_matchKw('ROW') || _matchWord('ROWS')) {}
      if (!_matchWord('ONLY')) {
        if (_matchKw('WITH')) _expectKw('TIES');
      }
      limit = count;
      limitPercent = percent;
    }
    // Oracle ROWNUM pseudo-column used as a row limiter in the WHERE clause,
    // e.g. `WHERE ROWNUM <= 10`. Rewrite such top-level conjuncts into an
    // equivalent LIMIT so they flow through the normal row-limit machinery
    // (which, combined with ORDER BY / a subquery, matches the common
    // top-N / pagination idioms).
    int? rownumLimit;
    if (where != null) {
      final rr = _rewriteRownumWhere(where, limit);
      where = rr.$1;
      limit = rr.$2;
      rownumLimit = rr.$3;
    }
    return SelectStmt(
      projection: projection,
      fromTable: fromTable,
      fromSubquery: fromSub,
      fromAlias: fromAlias,
      joins: joins,
      where: where,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      distinct: distinct,
      limitPercent: limitPercent,
      fromFunction: fromFunc,
      namedWindows: namedWindows,
      indexedBy: fromIndexHint,
      groupingSets: groupingSets,
      connectBy: connectBy,
      rownumLimit: rownumLimit,
      matchRecognize: fromMatchRecognize,
    );
  }

  /// Parse an Oracle hierarchical clause: `START WITH expr` /
  /// `CONNECT BY [NOCYCLE] expr`, accepting the two parts in either order.
  /// Returns null when no CONNECT BY is present.
  ConnectByClause? _parseConnectBy() {
    Expr? startWith;
    Expr? connectByExpr;
    var nocycle = false;
    var sawOrderSiblings = false;
    final orderSiblings = <OrderByItem>[];
    while (true) {
      if (_checkWord('START') && _peek(1).upper == 'WITH') {
        _advance(); // START
        _advance(); // WITH
        startWith = _parseExpr();
      } else if (_checkWord('CONNECT') && _peek(1).upper == 'BY') {
        _advance(); // CONNECT
        _advance(); // BY
        nocycle = _matchWord('NOCYCLE');
        connectByExpr = _parseExpr();
      } else if (!sawOrderSiblings &&
          _checkWord('ORDER') &&
          _peek(1).upper == 'SIBLINGS') {
        _advance(); // ORDER
        _advance(); // SIBLINGS
        _expectKw('BY');
        orderSiblings.add(_parseOrderByItem());
        while (_match(TokType.punct, ',')) {
          orderSiblings.add(_parseOrderByItem());
        }
        sawOrderSiblings = true;
      } else {
        break;
      }
    }
    if (connectByExpr == null) return null;
    return ConnectByClause(
      startWith,
      connectByExpr,
      nocycle: nocycle,
      orderSiblings: orderSiblings,
    );
  }

  /// Extracts top-level `ROWNUM <op> n` conjuncts from a WHERE expression and
  /// folds them into an equivalent row limit. Returns the residual WHERE (with
  /// the ROWNUM conjuncts removed, or null if none remain) and the effective
  /// limit (the tightest of [existingLimit] and any ROWNUM-implied limit).
  (Expr?, int?, int?) _rewriteRownumWhere(Expr where, int? existingLimit) {
    var limit = existingLimit;
    int? rownumLimit;
    void tighten(int implied) {
      final v = implied < 0 ? 0 : implied;
      limit = (limit == null) ? v : (v < limit! ? v : limit);
      rownumLimit = (rownumLimit == null) ? v : (v < rownumLimit! ? v : rownumLimit);
    }

    // Returns the replacement for a single (sub)expression, or `_keep` if it
    // is not a ROWNUM predicate and should be preserved unchanged.
    Expr? visit(Expr e) {
      if (e is BinaryExpr && e.op == 'AND') {
        final l = visit(e.left);
        final r = visit(e.right);
        if (l == null) return r;
        if (r == null) return l;
        return BinaryExpr('AND', l, r);
      }
      if (e is BinaryExpr) {
        // Normalise `n <op> ROWNUM` to `ROWNUM <flip> n`.
        String op = e.op;
        Expr lhs = e.left, rhs = e.right;
        if (_isRownum(rhs) && _intLiteral(lhs) != null) {
          final tmp = lhs;
          lhs = rhs;
          rhs = tmp;
          op = _flipComparison(op);
        }
        if (_isRownum(lhs)) {
          final n = _intLiteral(rhs);
          if (n != null) {
            switch (op) {
              case '<=':
                tighten(n);
                return null;
              case '<':
                tighten(n - 1);
                return null;
              case '=':
                tighten(n == 1 ? 1 : 0);
                return null;
              case '>':
              case '>=':
                // ROWNUM > n (n >= 1) is unsatisfiable; ROWNUM >= 1 / > 0 is
                // always true and simply drops out.
                final alwaysTrue =
                    (op == '>=' && n <= 1) || (op == '>' && n < 1);
                if (!alwaysTrue) tighten(0);
                return null;
            }
          }
        }
      }
      return e;
    }

    final residual = visit(where);
    return (residual, limit, rownumLimit);
  }

  bool _isRownum(Expr e) {
    // ROWNUM is lowered to `ROW_NUMBER() OVER ()` by _parsePrimary; recognise
    // that exact node (empty window, no args/filter) as the pseudo-column.
    if (e is! FunctionCallExpr) return false;
    final w = e.window;
    return e.name == 'ROW_NUMBER' &&
        e.args.isEmpty &&
        !e.isStarArg &&
        !e.distinct &&
        e.filterExpr == null &&
        (e.aggOrderBy == null || e.aggOrderBy!.isEmpty) &&
        w != null &&
        w.partitionBy.isEmpty &&
        w.orderBy.isEmpty &&
        w.frame == null &&
        w.baseName == null;
  }

  int? _intLiteral(Expr e) {
    if (e is LiteralExpr) {
      final v = e.value;
      if (v is int) return v;
      if (v is num && v == v.toInt()) return v.toInt();
    }
    return null;
  }

  String _flipComparison(String op) {
    switch (op) {
      case '<':
        return '>';
      case '<=':
        return '>=';
      case '>':
        return '<';
      case '>=':
        return '<=';
      default:
        return op; // '=' is symmetric
    }
  }

  /// Flatten a top-level AND chain into its conjuncts.
  List<Expr> _andConjuncts(Expr e) {
    if (e is BinaryExpr && e.op == 'AND') {
      return [..._andConjuncts(e.left), ..._andConjuncts(e.right)];
    }
    return [e];
  }

  Expr? _combineAnd(List<Expr> parts) {
    if (parts.isEmpty) return null;
    var e = parts.first;
    for (var i = 1; i < parts.length; i++) {
      e = BinaryExpr('AND', e, parts[i]);
    }
    return e;
  }

  /// Rewrite Oracle legacy `(+)` outer joins. Comma/CROSS joins whose join
  /// predicate carries a `(+)` marker in WHERE become LEFT/RIGHT joins with
  /// that predicate relocated to their ON clause. Returns the residual WHERE.
  Expr? _rewriteOracleOuterJoins(
    String? baseTable,
    String? baseAlias,
    List<JoinClause> joins,
    Expr where,
  ) {
    // Chain position of a table name/alias: base is 0, joins[i] is i+1.
    int? posOf(String? name) {
      if (name == null) return null;
      final n = name.toUpperCase();
      if (baseTable != null && baseTable.toUpperCase() == n) return 0;
      if (baseAlias != null && baseAlias.toUpperCase() == n) return 0;
      for (var i = 0; i < joins.length; i++) {
        if (joins[i].table != null && joins[i].table!.toUpperCase() == n) {
          return i + 1;
        }
        if (joins[i].alias != null && joins[i].alias!.toUpperCase() == n) {
          return i + 1;
        }
      }
      return null;
    }

    // (table, isMarked) for a column-ish operand, else null.
    (String?, bool)? operandTable(Expr e) {
      if (e is OuterJoinExpr) return (e.column.table, true);
      if (e is ColumnExpr) return (e.table, false);
      return null;
    }

    final conjuncts = _andConjuncts(where);
    final residual = <Expr>[];
    // joinIndex (into `joins`) -> ON predicates and the implied join type.
    final onByJoin = <int, List<Expr>>{};
    final typeByJoin = <int, String>{};

    for (final c in conjuncts) {
      if (c is! BinaryExpr || c.op == 'AND' || c.op == 'OR') {
        residual.add(c);
        continue;
      }
      final l = operandTable(c.left);
      final r = operandTable(c.right);
      if (l == null || r == null || (!l.$2 && !r.$2)) {
        residual.add(c); // no (+) marker involved
        continue;
      }
      final lp = posOf(l.$1);
      final rp = posOf(r.$1);
      if (lp == null || rp == null || lp == rp) {
        residual.add(c);
        continue;
      }
      final later = lp > rp ? lp : rp;
      final joinIdx = later - 1; // index into `joins`
      if (joins[joinIdx].type != 'CROSS') {
        residual.add(c);
        continue;
      }
      // The marked side is the null-supplying table. If it is the later table
      // in the chain, the right side of this join is optional -> LEFT; if it is
      // the earlier table, the accumulated left is optional -> RIGHT.
      final markedPos = l.$2 ? lp : rp;
      typeByJoin[joinIdx] = markedPos == later ? 'LEFT' : 'RIGHT';
      (onByJoin[joinIdx] ??= <Expr>[]).add(c);
    }

    if (onByJoin.isEmpty) return where; // nothing rewritten

    onByJoin.forEach((idx, preds) {
      final j = joins[idx];
      joins[idx] = JoinClause(
        typeByJoin[idx]!,
        j.table,
        j.alias,
        _combineAnd(preds),
        subquery: j.subquery,
        indexedBy: j.indexedBy,
      );
    });
    return _combineAnd(residual);
  }

  SelectItem _parseSelectItem() {
    if (_check(TokType.op, '*')) {
      _advance();
      return SelectItem.star();
    }
    // qualified t.*
    if (_check(TokType.ident) &&
        _peek(1).type == TokType.punct &&
        _peek(1).text == '.' &&
        _peek(2).type == TokType.op &&
        _peek(2).text == '*') {
      final tbl = _advance().text;
      _advance(); // '.'
      _advance(); // '*'
      return SelectItem.star(starTable: tbl);
    }
    final e = _parseExpr();
    String? alias;
    if (_matchKw('AS')) {
      alias = _expectName();
    } else if (_check(TokType.ident)) {
      alias = _advance().text;
    }
    return SelectItem.expr(e, alias: alias);
  }

  OrderByItem _parseOrderByItem() {
    final e = _parseExpr();
    bool desc = false;
    if (_matchKw('ASC')) {
      desc = false;
    } else if (_matchKw('DESC')) {
      desc = true;
    }
    bool? nullsFirst;
    if (_matchKw('NULLS')) {
      if (_matchKw('FIRST')) {
        nullsFirst = true;
      } else if (_matchKw('LAST')) {
        nullsFirst = false;
      } else {
        throw FormatException('Expected FIRST or LAST after NULLS');
      }
    }
    return OrderByItem(e, descending: desc, nullsFirst: nullsFirst);
  }

  // ---------------------------------------------------------------------------
  // Expressions
  // ---------------------------------------------------------------------------
  Expr _parseExpr() => _parseOr();

  Expr _parseOr() {
    var left = _parseAnd();
    while (_matchKw('OR')) {
      left = BinaryExpr('OR', left, _parseAnd());
    }
    return left;
  }

  Expr _parseAnd() {
    var left = _parseNot();
    while (_matchKw('AND')) {
      left = BinaryExpr('AND', left, _parseNot());
    }
    return left;
  }

  Expr _parseNot() {
    if (_matchKw('NOT')) return UnaryExpr('NOT', _parseNot());
    return _parseComparison();
  }

  Expr _parseComparison() {
    var left = _parseConcat();
    if (_matchKw('IS')) {
      final negated = _matchKw('NOT');
      // IS [NOT] DISTINCT FROM <expr> — NULL-safe (in)equality.
      if (_matchKw('DISTINCT')) {
        _expectKw('FROM');
        final right = _parseConcat();
        return BinaryExpr(
          negated ? 'IS NOT DISTINCT FROM' : 'IS DISTINCT FROM',
          left,
          right,
        );
      }
      // IS [NOT] NULL.
      if (_matchKw('NULL')) {
        return UnaryExpr(negated ? 'IS NOT NULL' : 'IS NULL', left);
      }
      // IS [NOT] TRUE / FALSE -- SQL boolean predicates with three-
      // valued truthiness: numeric 0 / empty string / NULL are not
      // TRUE; everything else is TRUE.
      if (_matchKw('TRUE')) {
        return UnaryExpr(negated ? 'IS NOT TRUE' : 'IS TRUE', left);
      }
      if (_matchKw('FALSE')) {
        return UnaryExpr(negated ? 'IS NOT FALSE' : 'IS FALSE', left);
      }
      // IS [NOT] JSON — Oracle validity predicate. Optional FORMAT/semantics
      // keywords after JSON are consumed and ignored.
      if (_matchWord('JSON')) {
        while (_matchWord('FORMAT') ||
            _matchWord('STRICT') ||
            _matchWord('LAX') ||
            _matchWord('WITH') ||
            _matchWord('WITHOUT') ||
            _matchWord('UNIQUE') ||
            _matchWord('KEYS') ||
            _matchWord('JSON')) {}
        return UnaryExpr(negated ? 'IS NOT JSON' : 'IS JSON', left);
      }
      // Bare IS / IS NOT <expr> — NULL-safe (in)equality (SQLite extension).
      final right = _parseConcat();
      return BinaryExpr(negated ? 'IS NOT' : 'IS', left, right);
    }
    bool negated = false;
    if (_matchKw('NOT')) negated = true;
    if (_matchKw('BETWEEN')) {
      final lo = _parseConcat();
      _expectKw('AND');
      final hi = _parseConcat();
      return BetweenExpr(left, lo, hi, negated: negated);
    }
    if (_matchKw('IN')) {
      _expect(TokType.punct, '(');
      if (_checkKw('SELECT')) {
        final sel = _parseSelect();
        _expect(TokType.punct, ')');
        return SubqueryInExpr(left, sel, negated: negated);
      }
      final values = <Expr>[_parseExpr()];
      while (_match(TokType.punct, ',')) {
        values.add(_parseExpr());
      }
      _expect(TokType.punct, ')');
      return InExpr(left, values, negated: negated);
    }
    if (_matchKw('LIKE')) {
      final pat = _parseConcat();
      if (_matchKw('ESCAPE')) {
        final esc = _parseConcat();
        return LikeExpr(left, pat, escape: esc, negated: negated);
      }
      Expr like = BinaryExpr('LIKE', left, pat);
      if (negated) like = UnaryExpr('NOT', like);
      return like;
    }
    if (_matchKw('GLOB')) {
      Expr g = BinaryExpr('GLOB', left, _parseConcat());
      if (negated) g = UnaryExpr('NOT', g);
      return g;
    }
    if (_matchKw('MATCH')) {
      Expr m = BinaryExpr('MATCH', left, _parseConcat());
      if (negated) m = UnaryExpr('NOT', m);
      return m;
    }
    if (_matchKw('REGEXP')) {
      Expr r = BinaryExpr('REGEXP', left, _parseConcat());
      if (negated) r = UnaryExpr('NOT', r);
      return r;
    }
    // Oracle period predicate `(s1, e1) OVERLAPS (s2, e2)`.
    if (_matchWord('OVERLAPS')) {
      final right = _parseConcat();
      return FunctionCallExpr('__OVERLAPS', [left, right]);
    }
    if (negated) {
      throw FormatException('Unexpected NOT before "${_peek().text}"');
    }
    while (_check(TokType.op) &&
        const {'=', '!=', '<>', '<', '<=', '>', '>='}.contains(_peek().text)) {
      final op = _advance().text;
      // Quantified comparison `op {ALL|ANY|SOME} (subquery)`.
      if (const {'=', '!=', '<>', '<', '<=', '>', '>='}.contains(op) &&
          (_checkWord('ALL') || _checkWord('ANY') || _checkWord('SOME')) &&
          _peek(1).type == TokType.punct &&
          _peek(1).text == '(') {
        final quant = _advance().text.toUpperCase();
        _expect(TokType.punct, '(');
        // The operand may be a subquery or a parenthesised value list
        // (`= ANY ('a', 'b')`), which behaves like IN / a quantified OR/AND.
        if (!_checkKw('SELECT') && !_checkKw('WITH')) {
          final items = <Expr>[_parseExpr()];
          while (_match(TokType.punct, ',')) {
            items.add(_parseExpr());
          }
          _expect(TokType.punct, ')');
          final all = quant == 'ALL';
          final eq = op == '=';
          final ne = op == '!=' || op == '<>';
          if (eq && !all) {
            left = InExpr(left, items, negated: false);
            continue;
          }
          if (ne && all) {
            left = InExpr(left, items, negated: true);
            continue;
          }
          // Other operators: ANY -> OR chain, ALL -> AND chain.
          Expr chain = BinaryExpr(op, left, items.first);
          for (var i = 1; i < items.length; i++) {
            chain = BinaryExpr(
                all ? 'AND' : 'OR', chain, BinaryExpr(op, left, items[i]));
          }
          left = chain;
          continue;
        }
        final sub = _parseSelect();
        _expect(TokType.punct, ')');
        final all = quant == 'ALL';
        final eq = op == '=';
        final ne = op == '!=' || op == '<>';
        // Equality quantifiers map onto IN / NOT IN or MIN=MAX bounds.
        if (eq && !all) {
          left = SubqueryInExpr(left, sub, negated: false);
          continue;
        }
        if (ne && all) {
          left = SubqueryInExpr(left, sub, negated: true);
          continue;
        }
        SelectStmt aggSel(String aggName) {
          final first = sub.projection.first;
          final label = first.alias ??
              (first.expr is ColumnExpr
                  ? (first.expr as ColumnExpr).name
                  : 'c');
          return SelectStmt(
            projection: [
              SelectItem.expr(FunctionCallExpr(aggName, [ColumnExpr(label)]))
            ],
            fromSubquery: sub,
          );
        }

        if (eq && all) {
          // x = ALL (S) iff x = MIN(S) and x = MAX(S).
          left = BinaryExpr(
            'AND',
            BinaryExpr('=', left, SubquerySelectExpr(aggSel('MIN'))),
            BinaryExpr('=', left, SubquerySelectExpr(aggSel('MAX'))),
          );
          continue;
        }
        final gt = op == '>' || op == '>=';
        final aggName = all ? (gt ? 'MAX' : 'MIN') : (gt ? 'MIN' : 'MAX');
        left = BinaryExpr(op, left, SubquerySelectExpr(aggSel(aggName)));
        continue;
      }
      left = BinaryExpr(op, left, _parseConcat());
    }
    return left;
  }

  Expr _parseConcat() {
    var left = _parseJsonExtract();
    while (_check(TokType.op, '||')) {
      _advance();
      left = BinaryExpr('||', left, _parseJsonExtract());
    }
    return left;
  }

  /// JSON extract operators (`->` returns JSON text, `->>` returns SQL value).
  Expr _parseJsonExtract() {
    var left = _parseBitwise();
    while (_check(TokType.op, '->') || _check(TokType.op, '->>')) {
      final op = _advance().text;
      left = BinaryExpr(op, left, _parseBitwise());
    }
    return left;
  }

  /// Bitwise binary operators: `&`, `|`, `<<`, `>>`. Bind tighter than
  /// comparisons but looser than `+`/`-`, matching SQLite precedence.
  Expr _parseBitwise() {
    var left = _parseAddSub();
    while (_check(TokType.op) &&
        const {'&', '|', '<<', '>>'}.contains(_peek().text)) {
      final op = _advance().text;
      left = BinaryExpr(op, left, _parseAddSub());
    }
    return left;
  }

  Expr _parseAddSub() {
    var left = _parseMulDiv();
    while (_check(TokType.op) && (_peek().text == '+' || _peek().text == '-')) {
      final op = _advance().text;
      left = BinaryExpr(op, left, _parseMulDiv());
    }
    return left;
  }

  Expr _parseMulDiv() {
    var left = _parseUnary();
    while (_check(TokType.op) &&
        (_peek().text == '*' || _peek().text == '/' || _peek().text == '%')) {
      final op = _advance().text;
      left = BinaryExpr(op, left, _parseUnary());
    }
    return left;
  }

  Expr _parseUnary() {
    if (_check(TokType.op, '-')) {
      _advance();
      // Fold a unary minus directly onto a numeric literal so int64-min
      // (`-9223372036854775808`) parses — its positive magnitude overflows a
      // signed 64-bit int, but the negated value is in range.
      if (_check(TokType.number)) {
        final txt = '-${_advance().text}';
        if (txt.contains('.') || txt.contains('e') || txt.contains('E')) {
          return LiteralExpr(double.parse(txt));
        }
        return LiteralExpr(int.tryParse(txt) ?? double.parse(txt));
      }
      return UnaryExpr('-', _parseUnary());
    }
    if (_check(TokType.op, '+')) {
      _advance();
      return _parseUnary();
    }
    if (_check(TokType.op, '~')) {
      _advance();
      return UnaryExpr('~', _parseUnary());
    }
    var e = _parsePrimary();
    // Postfix object method calls — `XMLELEMENT(...).getStringVal()`,
    // `.getClobVal()`, etc. The value is already the underlying text, so the
    // method call is transparent (consumed and ignored).
    while (_check(TokType.punct, '.') &&
        _peek(1).type == TokType.ident &&
        _peek(2).type == TokType.punct &&
        _peek(2).text == '(') {
      _advance(); // .
      _advance(); // method name
      _expect(TokType.punct, '(');
      while (!_check(TokType.punct, ')') && !_isAtEnd()) {
        _advance();
      }
      _expect(TokType.punct, ')');
    }
    // Postfix `COLLATE <name>` binds tightly to its operand.
    while (_matchKw('COLLATE')) {
      e = CollateExpr(e, _expectName().toUpperCase());
    }
    // Postfix `AT TIME ZONE <tz>` shifts a timestamp to the given zone.
    while (_checkWord('AT') && _peek(1).upper == 'TIME') {
      _advance(); // AT
      _expectWord('TIME');
      _expectWord('ZONE');
      e = FunctionCallExpr('__AT_TIME_ZONE', [e, _parsePrimary()]);
    }
    // Postfix interval-cast qualifier: `<expr> DAY[(p)] TO SECOND[(p)]` /
    // `YEAR[(p)] TO MONTH`. A no-op — the engine already models the value as a
    // day/second (or month) magnitude. Only consumed when a `TO <field>` tail
    // follows so a bare trailing identifier (a column alias) is left alone.
    const intervalFields = {
      'DAY', 'YEAR', 'HOUR', 'MINUTE', 'SECOND', 'MONTH',
    };
    while (intervalFields.contains(_peek().upper) && _peek(1).upper == 'TO') {
      _advance(); // leading field
      _advance(); // TO
      if (_check(TokType.ident) || _peek().type == TokType.keyword) {
        _advance(); // trailing field
      }
      if (_check(TokType.punct, '(')) {
        while (!_check(TokType.punct, ')') && !_isAtEnd()) {
          _advance();
        }
        _match(TokType.punct, ')');
      }
    }
    return e;
  }

  Expr _parsePrimary() {
    final t = _peek();
    // CONNECT BY `PRIOR expr` — a high-precedence prefix referring to the
    // parent row. Only treated as the operator when followed by a column /
    // parenthesised expression (so a stray identifier named PRIOR still works).
    if (_checkWord('PRIOR') &&
        (_peek(1).type == TokType.ident ||
            _peek(1).type == TokType.keyword ||
            (_peek(1).type == TokType.punct && _peek(1).text == '('))) {
      _advance();
      return PriorExpr(_parsePrimary());
    }
    // CONNECT_BY_ROOT <expr> — hierarchical prefix returning the expression's
    // value at the root of the current row's tree.
    if (_checkWord('CONNECT_BY_ROOT') &&
        (_peek(1).type == TokType.ident ||
            _peek(1).type == TokType.keyword ||
            (_peek(1).type == TokType.punct && _peek(1).text == '('))) {
      _advance();
      return FunctionCallExpr('CONNECT_BY_ROOT', [_parsePrimary()]);
    }
    // ANSI/Oracle typed datetime literals: DATE '...', TIMESTAMP '...',
    // TIME '...'. The type keyword directly precedes a string literal. We
    // keep the string value (the engine represents dates as text), so it
    // flows through EXTRACT and the date scalar functions unchanged.
    if ((t.type == TokType.keyword || t.type == TokType.ident) &&
        (t.upper == 'DATE' || t.upper == 'TIMESTAMP' || t.upper == 'TIME') &&
        _peek(1).type == TokType.string) {
      _advance(); // type keyword
      final lit = _advance(); // string literal
      return LiteralExpr(lit.text);
    }
    // Oracle INTERVAL literal: INTERVAL '<n>' <unit> [(prec)] [TO <unit>].
    // Modelled as a number of days so it composes with DATE arithmetic
    // (DATE + INTERVAL '5' DAY). Year/month units use calendar approximations.
    if ((t.type == TokType.keyword || t.type == TokType.ident) &&
        t.upper == 'INTERVAL' &&
        (_peek(1).type == TokType.string ||
            (_peek(1).type == TokType.op &&
                (_peek(1).text == '-' || _peek(1).text == '+')))) {
      _advance(); // INTERVAL
      var sign = 1;
      if (_check(TokType.op, '-')) {
        sign = -1;
        _advance();
      } else if (_check(TokType.op, '+')) {
        _advance();
      }
      final valTok = _advance(); // string literal e.g. '5' or '1-6'
      final raw = valTok.text;
      // Leading field value (the part before any '-' / ' ' separator).
      final leadStr = RegExp(r'^\d+').firstMatch(raw)?.group(0) ?? '0';
      final lead = int.tryParse(leadStr) ?? 0;
      final unit =
          (_check(TokType.ident) || _peek().type == TokType.keyword)
              ? _advance().text.toUpperCase()
              : 'DAY';
      // Optional precision qualifier and TO <unit> tail — consumed, ignored.
      if (_check(TokType.punct, '(')) {
        while (!_isAtEnd() && !_check(TokType.punct, ')')) {
          _advance();
        }
        _match(TokType.punct, ')');
      }
      if (_matchWord('TO')) {
        if (_check(TokType.ident) || _peek().type == TokType.keyword) {
          _advance();
        }
        if (_check(TokType.punct, '(')) {
          while (!_isAtEnd() && !_check(TokType.punct, ')')) {
            _advance();
          }
          _match(TokType.punct, ')');
        }
      }
      const daysPerUnit = <String, double>{
        'YEAR': 365,
        'MONTH': 30,
        'DAY': 1,
        'HOUR': 1 / 24,
        'MINUTE': 1 / 1440,
        'SECOND': 1 / 86400,
      };
      // Compute the interval magnitude in days. A compound literal carries its
      // own fields: 'D HH:MI:SS[.ff]' (day-to-second) or 'Y-M' (year-to-month).
      double magnitude;
      final body = raw.trim();
      if (body.contains(':')) {
        var dayPart = 0;
        var timePart = body;
        if (body.contains(' ')) {
          final sp = body.split(RegExp(r'\s+'));
          dayPart = int.tryParse(sp[0]) ?? 0;
          timePart = sp[1];
        }
        final tp = timePart.split(':');
        final h = tp.isNotEmpty ? (int.tryParse(tp[0]) ?? 0) : 0;
        final mi = tp.length > 1 ? (int.tryParse(tp[1]) ?? 0) : 0;
        final s = tp.length > 2 ? (double.tryParse(tp[2]) ?? 0) : 0;
        magnitude = dayPart + h / 24 + mi / 1440 + s / 86400;
      } else if (body.contains('-')) {
        // 'Y-M' year-to-month: a calendar-month interval (keep the day).
        final ym = body.split('-');
        final y = int.tryParse(ym[0]) ?? 0;
        final mo = ym.length > 1 ? (int.tryParse(ym[1]) ?? 0) : 0;
        return LiteralExpr(YmInterval(sign * (y * 12 + mo)));
      } else if (unit == 'YEAR' || unit == 'MONTH') {
        // Single-field YEAR / MONTH: also a calendar-month interval.
        final months = unit == 'YEAR' ? lead * 12 : lead;
        return LiteralExpr(YmInterval(sign * months));
      } else {
        magnitude = lead * (daysPerUnit[unit] ?? 1);
      }
      final days = sign * magnitude;
      return LiteralExpr(days == days.roundToDouble() ? days.toInt() : days);
    }
    if (t.type == TokType.param) {
      _advance();
      // Trigger pseudo-records `:NEW.col` / `:OLD.col` — resolve to the trigger
      // scope's NEW/OLD columns rather than a bind parameter.
      final upper = t.text.toUpperCase();
      if ((upper == ':NEW' || upper == ':OLD') &&
          _check(TokType.punct, '.')) {
        _advance(); // .
        final col = _expectName();
        return ColumnExpr(col, table: upper.substring(1)); // NEW / OLD
      }
      // Anonymous '?' — auto-number sequentially.
      if (t.text == '?') {
        paramCount++;
        return BindParamExpr(index: paramCount, spelling: t.text);
      }
      // Numbered '?<digits>'.
      if (t.text.startsWith('?')) {
        final n = int.parse(t.text.substring(1));
        if (n < 1) {
          throw FormatException('Bind parameter $t must use a 1-based index');
        }
        if (n > paramCount) paramCount = n;
        return BindParamExpr(index: n, spelling: t.text);
      }
      // Named ':foo' / '@foo' / '\$foo' — strip the leading sigil.
      final name = t.text.substring(1);
      namedParams.add(t.text);
      return BindParamExpr(name: name, spelling: t.text);
    }
    if (t.type == TokType.number) {
      _advance();
      final txt = t.text;
      if (txt.contains('.') || txt.contains('e') || txt.contains('E')) {
        return LiteralExpr(double.parse(txt));
      }
      // An integer literal beyond int64 range promotes to double (SQLite).
      return LiteralExpr(int.tryParse(txt) ?? double.parse(txt));
    }
    if (t.type == TokType.string) {
      _advance();
      return LiteralExpr(t.text);
    }
    if (t.type == TokType.blob) {
      _advance();
      final hex = t.text;
      final bytes = <int>[];
      for (var i = 0; i < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      return LiteralExpr(bytes);
    }
    if (t.type == TokType.keyword) {
      switch (t.upper) {
        case 'TRUE':
          _advance();
          return LiteralExpr(true);
        case 'FALSE':
          _advance();
          return LiteralExpr(false);
        case 'NULL':
          _advance();
          return LiteralExpr(null);
        case 'CASE':
          return _parseCaseExpr();
        case 'CAST':
          return _parseCastExpr();
        case 'EXISTS':
          return _parseExistsExpr();
        case 'NEW':
        case 'OLD':
          // Trigger pseudo-table: NEW.col / OLD.col.
          _advance();
          if (_check(TokType.punct, '.')) {
            _advance();
            final col = _expectName();
            return ColumnExpr(col, table: t.upper);
          }
          return ColumnExpr(t.text);
        case 'COUNT':
        case 'SUM':
        case 'AVG':
        case 'MIN':
        case 'MAX':
        case 'REPLACE':
          return _parseFunctionCall(_advance().text);
      }
    }
    if (t.type == TokType.punct && t.text == '(') {
      _advance();
      if (_checkKw('SELECT')) {
        final sel = _parseSelect();
        _expect(TokType.punct, ')');
        return SubquerySelectExpr(sel);
      }
      final e = _parseExpr();
      // Row value / tuple: `(a, b, …)`.
      if (_check(TokType.punct, ',')) {
        final items = <Expr>[e];
        while (_match(TokType.punct, ',')) {
          items.add(_parseExpr());
        }
        _expect(TokType.punct, ')');
        return RowValueExpr(items);
      }
      _expect(TokType.punct, ')');
      return e;
    }
    if (t.type == TokType.ident) {
      // MySQL system variable: @@var / @@session.var / @@global.var.
      // Resolve to a literal here so callers don't need a runtime
      // variable store; unknown variables surface as NULL.
      if (t.text.startsWith('@@')) {
        _advance();
        return LiteralExpr(_mysqlSystemVar(t.text.substring(2)));
      }
      _advance();
      if (_check(TokType.punct, '(')) {
        return _parseFunctionCall(t.text);
      }
      if (_check(TokType.punct, '.')) {
        _advance();
        final col = _expectName();
        // Oracle sequence pseudo-columns seq.NEXTVAL / seq.CURRVAL.
        final cu = col.toUpperCase();
        if (cu == 'NEXTVAL' || cu == 'CURRVAL') {
          return SequenceExpr(t.text, isCurrval: cu == 'CURRVAL');
        }
        // Qualified call `pkg.func(args)` — an Oracle package function. Guard
        // against the Oracle `(+)` outer-join marker, which also starts with
        // `(` but is handled by _maybeOuterJoin.
        if (_check(TokType.punct, '(') &&
            !(_peek(1).type == TokType.op &&
                _peek(1).text == '+' &&
                _peek(2).type == TokType.punct &&
                _peek(2).text == ')')) {
          return _parseFunctionCall('${t.text}.$col');
        }
        // Object-attribute navigation `alias.col.attr[.attr…][.string()]`: the
        // column holds a JSON object; extract the nested attribute path. A
        // trailing type accessor (`.string()`, `.number()`, …) is consumed.
        if (_check(TokType.punct, '.')) {
          final path = StringBuffer(r'$');
          while (_check(TokType.punct, '.') &&
              (_peek(1).type == TokType.ident ||
                  _peek(1).type == TokType.keyword)) {
            // A `.method()` accessor terminates the path.
            if (_peek(2).type == TokType.punct && _peek(2).text == '(') {
              _advance(); // .
              _advance(); // accessor name
              _expect(TokType.punct, '(');
              while (!_check(TokType.punct, ')') && !_isAtEnd()) {
                _advance();
              }
              _expect(TokType.punct, ')');
              break;
            }
            _advance(); // .
            path.write('.');
            path.write(_advance().text);
          }
          return FunctionCallExpr('JSON_VALUE', [
            ColumnExpr(col, table: t.text),
            LiteralExpr(path.toString()),
          ]);
        }
        return _maybeOuterJoin(ColumnExpr(col, table: t.text));
      }
      // Special bare-word datetime literals (no parentheses).
      const bareFns = {
        'CURRENT_TIMESTAMP',
        'CURRENT_DATE',
        'CURRENT_TIME',
        'SYSDATE',
        'SYSTIMESTAMP',
        'LOCALTIMESTAMP',
        'ROWID',
        'SESSIONTIMEZONE',
        'DBTIMEZONE',
        'SYS_GUID',
      };
      if (bareFns.contains(t.upper)) {
        return FunctionCallExpr(t.upper, const []);
      }
      // Oracle ROWNUM pseudo-column. Lower it to ROW_NUMBER() OVER () so it
      // works anywhere an expression is allowed (projection, ORDER BY, ...),
      // numbering rows in result order. A top-level `ROWNUM <op> n` in WHERE
      // is separately folded into a LIMIT by _rewriteRownumWhere (which
      // recognises this same lowered node).
      if (t.upper == 'ROWNUM') {
        return FunctionCallExpr('ROW_NUMBER', const [], window: WindowSpec());
      }
      return _maybeOuterJoin(ColumnExpr(t.text));
    }
    // Fall back: a keyword used in expression position becomes a column
    // reference. Allows e.g. `SELECT before FROM t` even though BEFORE is a
    // keyword used by CREATE TRIGGER syntax.
    if (t.type == TokType.keyword) {
      _advance();
      // A keyword immediately followed by `(` is a function call. This
      // lets type-name keywords like CHAR / TEXT double as function
      // names (e.g. CHAR(65) -> 'A').
      if (_check(TokType.punct, '(')) {
        return _parseFunctionCall(t.text);
      }
      if (_check(TokType.punct, '.')) {
        _advance();
        final col = _expectName();
        return ColumnExpr(col, table: t.text);
      }
      // Oracle ROWID pseudo-column: map to the engine's lowercase `rowid`
      // pseudo-column so `WHERE ROWID IS NOT NULL` resolves like `rowid`.
      if (t.upper == 'ROWID') {
        return ColumnExpr('rowid');
      }
      return ColumnExpr(t.text);
    }
    throw FormatException('Unexpected token "${t.text}" at offset ${t.offset}');
  }

  /// If the current tokens are the Oracle legacy outer-join marker `( + )`,
  /// consume them and wrap [col]; otherwise return [col] unchanged.
  Expr _maybeOuterJoin(ColumnExpr col) {
    if (_check(TokType.punct, '(') &&
        _peek(1).type == TokType.op &&
        _peek(1).text == '+' &&
        _peek(2).type == TokType.punct &&
        _peek(2).text == ')') {
      _advance();
      _advance();
      _advance();
      return OuterJoinExpr(col);
    }
    return col;
  }

  Expr _parseFunctionCall(String name) {
    final upper = name.toUpperCase();
    _expect(TokType.punct, '(');
    // SQL-standard EXTRACT(field FROM source): the field is a bareword
    // (YEAR, MONTH, DAY, HOUR, MINUTE, SECOND) followed by FROM. Rewrite into
    // EXTRACT(<field-name-literal>, source) for the scalar implementation.
    if (upper == 'EXTRACT' &&
        (_peek().type == TokType.ident || _peek().type == TokType.keyword) &&
        _peek(1).type == TokType.keyword &&
        _peek(1).upper == 'FROM') {
      final field = _advance().text.toUpperCase();
      _expectKw('FROM');
      final source = _parseExpr();
      _expect(TokType.punct, ')');
      return FunctionCallExpr('EXTRACT', [LiteralExpr(field), source]);
    }
    // ANSI TRIM([LEADING|TRAILING|BOTH] [chars] FROM string), detected by a
    // top-level FROM inside the parens.
    if (upper == 'TRIM') {
      var depth = 0;
      var ansi = false;
      for (var i = 0;; i++) {
        final tk = _peek(i);
        if (tk.type == TokType.eof) break;
        if (tk.type == TokType.punct && tk.text == '(') {
          depth++;
        } else if (tk.type == TokType.punct && tk.text == ')') {
          if (depth == 0) break;
          depth--;
        } else if (depth == 0 &&
            tk.type == TokType.keyword &&
            tk.upper == 'FROM') {
          ansi = true;
          break;
        }
      }
      if (ansi) {
        var side = 'BOTH';
        if (_matchWord('LEADING')) {
          side = 'LEADING';
        } else if (_matchWord('TRAILING')) {
          side = 'TRAILING';
        } else {
          _matchWord('BOTH');
        }
        final chars = _checkKw('FROM') ? null : _parseExpr();
        _expectKw('FROM');
        final str = _parseExpr();
        _expect(TokType.punct, ')');
        final fn = side == 'LEADING'
            ? 'LTRIM'
            : side == 'TRAILING'
                ? 'RTRIM'
                : 'TRIM';
        return FunctionCallExpr(fn, chars == null ? [str] : [str, chars]);
      }
    }
    // Oracle XMLCAST(value AS type): convert an XML/content value to a SQL
    // type. Modelled as a plain CAST (the XQuery content is already a scalar).
    if (upper == 'XMLCAST') {
      final e = _parseExpr();
      _expectKw('AS');
      final typeTok = _advance();
      final type = parseDataType(typeTok.text);
      if (_check(TokType.punct, '(')) {
        var depth = 0;
        do {
          final tk = _advance();
          if (tk.type == TokType.punct && tk.text == '(') depth++;
          if (tk.type == TokType.punct && tk.text == ')') depth--;
        } while (depth > 0 && !_isAtEnd());
      }
      _expect(TokType.punct, ')');
      return CastExpr(e, type);
    }
    // Oracle XMLSERIALIZE([DOCUMENT|CONTENT] expr [AS type] …): serialise an
    // XML value to text. We keep the inner expression and ignore the options.
    if (upper == 'XMLSERIALIZE') {
      _matchWord('DOCUMENT');
      _matchWord('CONTENT');
      final e = _parseExpr();
      while (!_check(TokType.punct, ')') && !_isAtEnd()) {
        _advance();
      }
      _expect(TokType.punct, ')');
      return FunctionCallExpr('XMLSERIALIZE', [e]);
    }
    bool isStar = false;
    bool distinct = false;
    final args = <Expr>[];
    if (_check(TokType.op, '*')) {
      _advance();
      isStar = true;
    } else if (!_check(TokType.punct, ')')) {
      // RAISE(action[, msg]) — first arg is a bareword action keyword.
      if (upper == 'RAISE' &&
          (_checkKw('IGNORE') ||
              _checkKw('ABORT') ||
              _checkKw('ROLLBACK') ||
              _checkKw('FAIL') ||
              _peek().type == TokType.ident)) {
        final actionTok = _advance();
        args.add(LiteralExpr(actionTok.text.toUpperCase()));
        while (_match(TokType.punct, ',')) {
          args.add(_parseExpr());
        }
      } else if (upper == 'XMLELEMENT') {
        // XMLELEMENT([NAME] ename, content…): the element name is an
        // identifier/string treated as a literal.
        _matchWord('NAME');
        args.add(LiteralExpr(
            _check(TokType.string) ? _advance().text : _expectName()));
        while (_match(TokType.punct, ',')) {
          args.add(_parseExpr());
        }
      } else if (upper == 'XMLFOREST') {
        // XMLFOREST(value [AS "name"], …): collect (name, value) pairs, the
        // name defaulting to the value expression's column identifier.
        do {
          final v = _parseExpr();
          String name;
          if (_matchKw('AS')) {
            name = _check(TokType.string) ? _advance().text : _expectName();
          } else if (v is ColumnExpr) {
            name = v.name;
          } else {
            name = 'C';
          }
          args.add(LiteralExpr(name));
          args.add(v);
        } while (_match(TokType.punct, ','));
      } else if (upper == 'JSON_OBJECT' || upper == 'JSON_OBJECTAGG') {
        // Oracle key/value syntax: JSON_OBJECT([KEY] k VALUE v, …) and the
        // colon form JSON_OBJECT(k : v) map onto the (key, value, …) arg list.
        do {
          _matchWord('KEY');
          args.add(_parseExpr());
          if (_matchWord('VALUE') || _match(TokType.punct, ':')) {
            args.add(_parseExpr());
          }
        } while (_match(TokType.punct, ','));
        // Trailing output clauses (FORMAT JSON, [NULL|ABSENT] ON NULL, …).
        var absentOnNull = false;
        while (true) {
          if (_matchWord('ABSENT')) {
            absentOnNull = true;
            continue;
          }
          if (_matchWord('FORMAT') ||
              _matchWord('JSON') ||
              _matchWord('NULL') ||
              _matchWord('ON') ||
              _matchWord('RETURNING') ||
              _matchWord('STRICT') ||
              _matchWord('WITH') ||
              _matchWord('WITHOUT') ||
              _matchWord('UNIQUE') ||
              _matchWord('KEYS')) {
            continue;
          }
          break;
        }
        if (absentOnNull && upper == 'JSON_OBJECT') {
          args.add(LiteralExpr('\u0001ABSENT'));
        }
      } else {
        if (_matchKw('DISTINCT')) distinct = true;
        args.add(_parseExpr());
        while (_match(TokType.punct, ',')) {
          args.add(_parseExpr());
        }
      }
    }
    // Oracle LISTAGG overflow clause: `ON OVERFLOW {TRUNCATE ['txt'] | ERROR}
    // [WITH|WITHOUT COUNT]`. Consumed (overflow truncation is not modelled).
    if (_matchWord('ON')) {
      _expectWord('OVERFLOW');
      if (!_matchWord('TRUNCATE')) _matchWord('ERROR');
      if (_check(TokType.string)) _advance();
      if (_matchWord('WITH') || _matchWord('WITHOUT')) _matchWord('COUNT');
    }
    // Oracle JSON_VALUE/JSON_QUERY `RETURNING <type>` and ON ERROR/EMPTY
    // clauses. For JSON_VALUE the type + DEFAULT … ON ERROR drive coercion;
    // for JSON_QUERY, WITH WRAPPER wraps a scalar result in an array.
    String? jsonRetType;
    Object? jsonDefault;
    var jsonHasDefault = false;
    var jsonWrapper = false;
    if (_matchWord('RETURNING')) {
      final rt = _advance(); // return type word
      jsonRetType = rt.text.toUpperCase();
      if (_check(TokType.punct, '(')) {
        var depth = 0;
        do {
          final tk = _advance();
          if (tk.type == TokType.punct && tk.text == '(') depth++;
          if (tk.type == TokType.punct && tk.text == ')') depth--;
        } while (depth > 0 && !_isAtEnd());
      }
    }
    // JSON_QUERY wrapper clause.
    if (_matchWord('WITH')) {
      _matchWord('UNCONDITIONAL');
      _matchWord('CONDITIONAL');
      if (_matchWord('WRAPPER') || _matchWord('ARRAY')) {
        jsonWrapper = true;
        _matchWord('WRAPPER');
      }
    } else if (_matchWord('WITHOUT')) {
      _matchWord('WRAPPER');
      _matchWord('ARRAY');
    }
    while (_checkWord('ERROR') ||
        _checkWord('NULL') ||
        _checkWord('DEFAULT') ||
        _checkWord('EMPTY') ||
        _checkWord('TRUE') ||
        _checkWord('FALSE') ||
        (_checkWord('ON') &&
            (_peek(1).upper == 'ERROR' || _peek(1).upper == 'EMPTY'))) {
      if (_matchWord('DEFAULT')) {
        var neg = false;
        if (_check(TokType.op, '-')) {
          neg = true;
          _advance();
        } else if (_check(TokType.op, '+')) {
          _advance();
        }
        final d = _parsePrimary();
        if (!jsonHasDefault && d is LiteralExpr) {
          final val = d.value;
          jsonDefault = neg && val is num ? -val : val;
          jsonHasDefault = true;
        }
      } else {
        _advance();
      }
    }
    if (upper == 'JSON_VALUE' && (jsonRetType != null || jsonHasDefault)) {
      args.add(LiteralExpr('\u0001JV:${jsonEncode({
            'ret': jsonRetType,
            if (jsonHasDefault) 'def': jsonDefault,
          })}'));
    } else if (upper == 'JSON_QUERY' && jsonWrapper) {
      args.add(LiteralExpr('\u0001JQW'));
    }
    // Oracle `IGNORE NULLS` / `RESPECT NULLS` modifier (FIRST_VALUE,
    // LAST_VALUE, LAG, LEAD, NTH_VALUE).
    bool ignoreNulls = false;
    if (_matchWord('IGNORE')) {
      _expectWord('NULLS');
      ignoreNulls = true;
    } else if (_matchWord('RESPECT')) {
      _expectWord('NULLS');
    }
    List<WindowOrderItem>? aggOrderBy;
    if (_matchKw('ORDER')) {
      _expectKw('BY');
      aggOrderBy = <WindowOrderItem>[_parseWindowOrderItem()];
      while (_match(TokType.punct, ',')) {
        aggOrderBy.add(_parseWindowOrderItem());
      }
    }
    _expect(TokType.punct, ')');
    // Oracle ordered-set aggregate: `agg(args) WITHIN GROUP (ORDER BY …)`.
    if (_matchWord('WITHIN')) {
      _expectWord('GROUP');
      _expect(TokType.punct, '(');
      _expectKw('ORDER');
      _expectKw('BY');
      aggOrderBy = <WindowOrderItem>[_parseWindowOrderItem()];
      while (_match(TokType.punct, ',')) {
        aggOrderBy.add(_parseWindowOrderItem());
      }
      _expect(TokType.punct, ')');
    }
    // IIF(cond, a, b) desugars to CASE WHEN cond THEN a ELSE b END so
    // that branches short-circuit, matching SQLite semantics.
    if (upper == 'IIF' && args.length == 3) {
      return CaseExpr([args[0]], [args[1]], args[2]);
    }
    Expr? filterExpr;
    if (_matchKw('FILTER')) {
      _expect(TokType.punct, '(');
      _expectKw('WHERE');
      filterExpr = _parseExpr();
      _expect(TokType.punct, ')');
    }
    // Oracle `KEEP (DENSE_RANK FIRST|LAST ORDER BY …)` ordered-set modifier.
    bool? keepFirst;
    List<WindowOrderItem>? keepOrderBy;
    if (_matchWord('KEEP')) {
      _expect(TokType.punct, '(');
      _matchWord('DENSE_RANK');
      final sawFirst = _matchWord('FIRST') || _matchKw('FIRST');
      final sawLast = !sawFirst && (_matchWord('LAST') || _matchKw('LAST'));
      keepFirst = !sawLast;
      _expectKw('ORDER');
      _expectKw('BY');
      keepOrderBy = <WindowOrderItem>[_parseWindowOrderItem()];
      while (_match(TokType.punct, ',')) {
        keepOrderBy.add(_parseWindowOrderItem());
      }
      _expect(TokType.punct, ')');
    }
    // Oracle `IGNORE NULLS` / `RESPECT NULLS` may also follow the closing paren
    // (LEAD/LAG: `LEAD(v) IGNORE NULLS OVER (...)`).
    if (!ignoreNulls) {
      if (_matchWord('IGNORE')) {
        _expectWord('NULLS');
        ignoreNulls = true;
      } else if (_matchWord('RESPECT')) {
        _expectWord('NULLS');
      }
    }
    // Oracle `NTH_VALUE(expr, n) FROM FIRST|LAST`. Only consume FROM when it
    // introduces this modifier (FIRST/LAST next), never the query's FROM clause.
    bool fromLast = false;
    if (_checkKw('FROM') &&
        (_peek(1).upper == 'FIRST' || _peek(1).upper == 'LAST')) {
      _advance(); // FROM
      fromLast = _advance().upper == 'LAST';
    }
    // IGNORE/RESPECT NULLS can also trail the FROM FIRST|LAST clause.
    if (!ignoreNulls) {
      if (_matchWord('IGNORE')) {
        _expectWord('NULLS');
        ignoreNulls = true;
      } else if (_matchWord('RESPECT')) {
        _expectWord('NULLS');
      }
    }
    WindowSpec? window;
    if (_matchKw('OVER')) {
      // OVER w   |   OVER (...)
      if (_check(TokType.punct, '(')) {
        window = _parseWindowSpec();
      } else {
        final n = _advance();
        window = WindowSpec(baseName: n.text);
      }
    }
    return FunctionCallExpr(
      upper,
      args,
      isStarArg: isStar,
      distinct: distinct,
      window: window,
      filterExpr: filterExpr,
      aggOrderBy: aggOrderBy,
      keepFirst: keepFirst,
      keepOrderBy: keepOrderBy,
      ignoreNulls: ignoreNulls,
      fromLast: fromLast,
    );
  }

  WindowSpec _parseWindowSpec() {
    _expect(TokType.punct, '(');
    String? baseName;
    // Optional leading window name to extend.
    if (_peek().type == TokType.ident &&
        !_checkKw('PARTITION') &&
        !_checkKw('ORDER') &&
        !_checkKw('ROWS') &&
        !_checkKw('RANGE') &&
        !_checkKw('GROUPS')) {
      baseName = _advance().text;
    }
    final partition = <Expr>[];
    final order = <WindowOrderItem>[];
    if (_matchKw('PARTITION')) {
      _expectKw('BY');
      partition.add(_parseExpr());
      while (_match(TokType.punct, ',')) {
        partition.add(_parseExpr());
      }
    }
    if (_matchKw('ORDER')) {
      _expectKw('BY');
      order.add(_parseWindowOrderItem());
      while (_match(TokType.punct, ',')) {
        order.add(_parseWindowOrderItem());
      }
    }
    WindowFrame? frame;
    if (_checkKw('ROWS') || _checkKw('RANGE') || _checkKw('GROUPS')) {
      frame = _parseWindowFrame();
    }
    _expect(TokType.punct, ')');
    return WindowSpec(
      partitionBy: partition,
      orderBy: order,
      frame: frame,
      baseName: baseName,
    );
  }

  WindowFrame _parseWindowFrame() {
    FrameMode mode;
    if (_matchKw('ROWS')) {
      mode = FrameMode.rows;
    } else if (_matchKw('RANGE')) {
      mode = FrameMode.range;
    } else {
      _expectKw('GROUPS');
      mode = FrameMode.groups;
    }
    FrameBound start;
    FrameBound end = const FrameBound(FrameBoundKind.currentRow);
    if (_matchKw('BETWEEN')) {
      start = _parseFrameBound(isStart: true);
      _expectKw('AND');
      end = _parseFrameBound(isStart: false);
    } else {
      start = _parseFrameBound(isStart: true);
    }
    var exclude = FrameExclude.noOthers;
    if (_matchKw('EXCLUDE')) {
      if (_matchKw('NO')) {
        _expectKw('OTHERS');
        exclude = FrameExclude.noOthers;
      } else if (_matchKw('CURRENT')) {
        _expectKw('ROW');
        exclude = FrameExclude.currentRow;
      } else if (_matchKw('GROUP')) {
        exclude = FrameExclude.group;
      } else if (_matchKw('TIES')) {
        exclude = FrameExclude.ties;
      } else {
        throw FormatException('Expected NO OTHERS|CURRENT ROW|GROUP|TIES');
      }
    }
    return WindowFrame(mode: mode, start: start, end: end, exclude: exclude);
  }

  FrameBound _parseFrameBound({required bool isStart}) {
    if (_matchKw('UNBOUNDED')) {
      if (_matchKw('PRECEDING')) {
        return const FrameBound(FrameBoundKind.unboundedPreceding);
      }
      _expectKw('FOLLOWING');
      return const FrameBound(FrameBoundKind.unboundedFollowing);
    }
    if (_matchKw('CURRENT')) {
      _expectKw('ROW');
      return const FrameBound(FrameBoundKind.currentRow);
    }
    final off = _parseExpr();
    if (_matchKw('PRECEDING')) {
      return FrameBound(FrameBoundKind.preceding, offset: off);
    }
    _expectKw('FOLLOWING');
    return FrameBound(FrameBoundKind.following, offset: off);
  }

  WindowOrderItem _parseWindowOrderItem() {
    final e = _parseExpr();
    bool desc = false;
    if (_matchKw('ASC')) {
      desc = false;
    } else if (_matchKw('DESC')) {
      desc = true;
    }
    bool? nullsFirst;
    if (_matchKw('NULLS')) {
      if (_matchKw('FIRST')) {
        nullsFirst = true;
      } else if (_matchKw('LAST')) {
        nullsFirst = false;
      } else {
        throw FormatException('Expected FIRST or LAST after NULLS');
      }
    }
    return WindowOrderItem(e, descending: desc, nullsFirst: nullsFirst);
  }

  Expr _parseCaseExpr() {
    _expectKw('CASE');
    Expr? subject;
    if (!_checkKw('WHEN')) {
      subject = _parseExpr();
    }
    final whens = <Expr>[];
    final thens = <Expr>[];
    while (_matchKw('WHEN')) {
      final cond = _parseExpr();
      _expectKw('THEN');
      final result = _parseExpr();
      if (subject != null) {
        whens.add(BinaryExpr('=', subject, cond));
      } else {
        whens.add(cond);
      }
      thens.add(result);
    }
    Expr? elseExpr;
    if (_matchKw('ELSE')) elseExpr = _parseExpr();
    _expectKw('END');
    return CaseExpr(whens, thens, elseExpr);
  }

  Expr _parseCastExpr() {
    _expectKw('CAST');
    _expect(TokType.punct, '(');
    final e = _parseExpr();
    _expectKw('AS');
    final typeTok = _advance();
    final type = parseDataType(typeTok.text);
    // Oracle CAST enforces the declared size: NUMBER(p,s) rounds to the scale,
    // VARCHAR2/CHAR(n) truncates to the length.
    int? numericScale;
    int? charLength;
    if (_check(TokType.punct, '(')) {
      final rawType = typeTok.text.toUpperCase();
      const charTypes = {
        'VARCHAR', 'VARCHAR2', 'CHAR', 'NCHAR', 'NVARCHAR', 'NVARCHAR2',
        'CHARACTER',
      };
      _advance(); // (
      final first = _advance();
      final firstN = int.tryParse(first.text);
      if (_matchWord('CHAR') || _matchWord('BYTE')) {}
      if (_match(TokType.punct, ',')) {
        var neg = false;
        if (_check(TokType.op, '-')) {
          neg = true;
          _advance();
        }
        final sc = int.tryParse(_advance().text);
        numericScale = sc == null ? null : (neg ? -sc : sc);
      } else if (charTypes.contains(rawType)) {
        charLength = firstN;
      }
      while (!_check(TokType.punct, ')') && !_check(TokType.eof)) {
        _advance();
      }
      _expect(TokType.punct, ')');
    }
    _expect(TokType.punct, ')');
    return CastExpr(e, type,
        numericScale: numericScale, charLength: charLength);
  }

  Expr _parseExistsExpr() {
    _expectKw('EXISTS');
    _expect(TokType.punct, '(');
    final sel = _parseSelect();
    _expect(TokType.punct, ')');
    return SubqueryExistsExpr(sel);
  }

  // ---------------------------------------------------------------------------
  // Slice helpers (for stored CHECK constraint source)
  // ---------------------------------------------------------------------------
  String _sliceSource(int startOffset, int endOffset) {
    final buf = StringBuffer();
    var first = true;
    for (final tok in _tokens) {
      if (tok.offset < startOffset) continue;
      if (tok.offset >= endOffset) break;
      if (!first) buf.write(' ');
      first = false;
      if (tok.type == TokType.string) {
        buf.write("'${tok.text.replaceAll("'", "''")}'");
      } else {
        buf.write(tok.text);
      }
    }
    return buf.toString();
  }
}
