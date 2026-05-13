/// Recursive-descent SQL parser. Consumes tokens from [Lexer] and produces
/// [Statement] AST nodes. Supports the SQL subset documented in README.
library;

import 'expression.dart';
import 'lexer.dart';
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
          'Unexpected token after statement: ${_peek().text}');
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
        'Expected identifier but got "${t.text}" at offset ${t.offset}');
  }

  /// Accept an identifier OR a keyword (used where keywords like `name`
  /// or `text` may legitimately appear as a column / alias name).
  String _expectName() {
    final t = _peek();
    if (t.type == TokType.ident) return _advance().text;
    if (t.type == TokType.keyword) return _advance().text;
    throw FormatException(
        'Expected name but got "${t.text}" at offset ${t.offset}');
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
          _advance();
          _matchKw('TRANSACTION');
          return BeginStmt();
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
          _advance();
          _expectKw('TABLES');
          return ShowTablesStmt();
        case 'DESCRIBE':
          _advance();
          return DescribeStmt(_expectIdent().text);
        case 'EXPLAIN':
          _advance();
          // SQLite syntax: `EXPLAIN [QUERY PLAN] <stmt>`. We don't yet
          // distinguish bytecode-EXPLAIN from EXPLAIN QUERY PLAN; both
          // route through the same plan-tree formatter.
          {
            final p0 = _peek();
            final p1 = _peek(1);
            if (p0.type == TokType.ident &&
                p0.upper == 'QUERY' &&
                p1.type == TokType.ident &&
                p1.upper == 'PLAN') {
              _advance();
              _advance();
            }
          }
          return ExplainStmt(_parseStatement());
        case 'PRAGMA':
          return _parsePragma();
        case 'VACUUM':
          _advance();
          String? schema;
          if (_check(TokType.ident)) schema = _advance().text;
          _matchKw('INTO'); // accept and ignore: "VACUUM INTO 'file'"
          if (_peek().type == TokType.string) _advance();
          return VacuumStmt(schema: schema);
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
                'ATTACH DATABASE expects a string path at ${pathTok.offset}');
          }
          _expectKw('AS');
          return AttachDatabaseStmt(pathTok.text, _expectName());
        case 'DETACH':
          _advance();
          _matchKw('DATABASE');
          return DetachDatabaseStmt(_expectName());
      }
    }
    throw FormatException('Unsupported statement starting with "${t.text}"');
  }

  // ---- CREATE -------------------------------------------------------------
  Statement _parseCreate() {
    _expectKw('CREATE');
    // Accept TEMP / TEMPORARY before TABLE/VIEW/TRIGGER/INDEX. We don't
    // model temp scope; the modifier is parsed and ignored so that the
    // CREATE statement is recognised.
    {
      final p = _peek();
      if (p.type == TokType.ident &&
          (p.upper == 'TEMP' || p.upper == 'TEMPORARY')) {
        _advance();
      }
    }
    if (_matchKw('TABLE')) return _parseCreateTableTail();
    if (_matchKw('VIRTUAL')) {
      _expectKw('TABLE');
      return _parseCreateVirtualTableTail();
    }
    final isUnique = _matchKw('UNIQUE');
    if (_matchKw('INDEX')) return _parseCreateIndexTail(unique: isUnique);
    if (_matchKw('VIEW')) return _parseCreateViewTail();
    if (_matchKw('TRIGGER')) return _parseCreateTriggerTail();
    throw FormatException(
        'Expected TABLE, INDEX, VIEW or TRIGGER after CREATE');
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

  CreateTableStmt _parseCreateTableTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _expectIdent().text;
    _expect(TokType.punct, '(');
    final cols = <ColumnDef>[];
    final rawTypes = <String>[]; // parallel to cols; for STRICT validation
    final constraints = <TableConstraint>[];
    do {
      if (_isTableLevelConstraintStart()) {
        constraints.add(_parseTableConstraint());
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
              'CREATE TABLE $name USING $mod: only "paged" is supported');
        }
        usingPaged = true;
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
              'INT, INTEGER, REAL, TEXT, BLOB, ANY.');
        }
      }
    }
    return CreateTableStmt(name, cols,
        constraints: constraints,
        ifNotExists: ifNotExists,
        strict: strict,
        withoutRowid: withoutRowid,
        usingPaged: usingPaged);
  }

  bool _isTableLevelConstraintStart() {
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
    final tbl = _expectIdent().text;
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
    return ForeignKeyRef(tbl,
        column: col, onDelete: onDelete, onUpdate: onUpdate);
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
    // Optional size/precision qualifier: VARCHAR(10), DECIMAL(10,2), etc.
    // Consumed and ignored — it does not affect affinity.
    if (_match(TokType.punct, '(')) {
      _advance(); // first number
      if (_match(TokType.punct, ',')) {
        _advance(); // second number
      }
      _expect(TokType.punct, ')');
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
    while (true) {
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
        // 3) Bare literal (possibly signed numeric).
        Expr lit;
        if (_check(TokType.op, '-') || _check(TokType.op, '+')) {
          final sign = _advance().text;
          final next = _parsePrimary();
          if (next is! LiteralExpr || next.value is! num) {
            throw FormatException('DEFAULT must be a literal');
          }
          lit = LiteralExpr(sign == '-' ? -(next.value as num) : next.value);
        } else {
          lit = _parsePrimary();
        }
        if (lit is! LiteralExpr) {
          throw FormatException('DEFAULT must be a literal');
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
        continue;
      }
      if (_checkKw('REFERENCES')) {
        references = _parseReferencesClause();
        continue;
      }
      if (_matchKw('GENERATED')) {
        _expectKw('ALWAYS');
        _expectKw('AS');
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
      break;
    }
    return ColumnDef(name, type,
        primaryKey: primaryKey,
        notNull: notNull,
        unique: unique,
        autoIncrement: autoInc,
        defaultValue: defaultValue,
        defaultExprSql: defaultExprSql,
        checkExprSql: checkSql,
        references: references,
        generatedExprSql: generatedSql,
        generatedStored: generatedStored);
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
    return CreateIndexStmt(indexName, table, col,
        unique: unique,
        whereSql: whereSql,
        exprSql: exprSql,
        columns: extraCols == null ? null : [col, ...extraCols],
        collations: collations);
  }

  CreateViewStmt _parseCreateViewTail() {
    bool ifNotExists = false;
    if (_matchKw('IF')) {
      _expectKw('NOT');
      _expectKw('EXISTS');
      ifNotExists = true;
    }
    final name = _expectIdent().text;
    _expectKw('AS');
    final selStart = _peek().offset;
    final sel = _parseSelect();
    final selEnd = _peek().offset;
    final selSql = _sliceSource(selStart, selEnd).trim();
    return CreateViewStmt(name, sel,
        ifNotExists: ifNotExists, selectSql: selSql);
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
    _expectKw('BEGIN');
    final body = <Statement>[];
    while (!_checkKw('END')) {
      body.add(_parseStatement());
      _match(TokType.punct, ';');
    }
    _expectKw('END');
    return CreateTriggerStmt(name, timing, event, table, when, body,
        ifNotExists: ifNotExists);
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
      return DropTableStmt(_expectIdent().text, ifExists: ifExists);
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
    throw FormatException('Expected TABLE, INDEX, VIEW or TRIGGER after DROP');
  }

  // ---- ALTER --------------------------------------------------------------
  Statement _parseAlter() {
    _expectKw('ALTER');
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
    if (_matchKw('DROP')) {
      _matchKw('COLUMN');
      return AlterTableDropColumnStmt(table, _expectIdent().text);
    }
    _expectKw('ADD');
    _matchKw('COLUMN');
    final col = _parseColumnDef();
    return AlterTableAddColumnStmt(table, col);
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
              'Expected REPLACE/IGNORE/ABORT/FAIL/ROLLBACK after INSERT OR');
        }
      }
    }
    return _parseInsertTail(mode);
  }

  InsertStmt _parseReplace() {
    _expectKw('REPLACE');
    return _parseInsertTail(InsertMode.orReplace);
  }

  InsertStmt _parseInsertTail(InsertMode mode) {
    _expectKw('INTO');
    final table = _expectIdent().text;
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
    return InsertStmt(table, cols, rows,
        mode: mode, select: srcSelect, returning: ret, onConflict: onConflict);
  }

  /// Parse an optional `ON CONFLICT [(col, ...)] DO {NOTHING|UPDATE SET ...}`
  /// clause. Returns null if `ON CONFLICT` is not present.
  OnConflictClause? _parseOnConflictClause() {
    if (!_matchKw('ON')) return null;
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
        targetColumns: cols, assignments: assigns, where: where);
  }

  // ---- UPDATE -------------------------------------------------------------
  UpdateStmt _parseUpdate() {
    _expectKw('UPDATE');
    final table = _expectIdent().text;
    final hint = _consumeIndexedHint();
    _expectKw('SET');
    final assignments = <String, Expr>{};
    do {
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
    return UpdateStmt(table, assignments, where,
        returning: ret,
        indexedBy: hint,
        fromTable: fromTable,
        fromAlias: fromAlias,
        limit: limit,
        offset: offset);
  }

  // ---- DELETE -------------------------------------------------------------
  DeleteStmt _parseDelete() {
    _expectKw('DELETE');
    _expectKw('FROM');
    final table = _expectIdent().text;
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
    return DeleteStmt(table, where,
        returning: ret, indexedBy: hint, limit: limit, offset: offset);
  }

  // ---- WITH (CTEs) --------------------------------------------------------
  Statement _parseWith() {
    _expectKw('WITH');
    final recursive = _matchKw('RECURSIVE');
    final ctes = <String, SelectStmt>{};
    final cteColumns = <String, List<String>>{};
    final cteMaterialized = <String, bool>{};
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
    } while (_match(TokType.punct, ','));

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
        );
      case 'INSERT':
        final s = _parseInsert();
        return InsertStmt(s.table, s.columns, s.rows,
            mode: s.mode,
            select: s.select,
            returning: s.returning,
            ctes: ctes,
            cteColumns: cteColumns,
            ctesRecursive: recursive);
      case 'UPDATE':
        final s = _parseUpdate();
        return UpdateStmt(s.table, s.assignments, s.where,
            returning: s.returning,
            ctes: ctes,
            cteColumns: cteColumns,
            ctesRecursive: recursive,
            indexedBy: s.indexedBy,
            fromTable: s.fromTable,
            fromAlias: s.fromAlias,
            limit: s.limit,
            offset: s.offset);
      case 'DELETE':
        final s = _parseDelete();
        return DeleteStmt(s.table, s.where,
            returning: s.returning,
            ctes: ctes,
            cteColumns: cteColumns,
            ctesRecursive: recursive,
            indexedBy: s.indexedBy,
            limit: s.limit,
            offset: s.offset);
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
    return items;
  }

  // ---- SELECT -------------------------------------------------------------
  SelectStmt _parseSelect() {
    if (_checkKw('VALUES')) {
      return _parseValuesAsSelect();
    }
    final base = _parseSimpleSelect();
    String? setOp;
    SelectStmt? right;
    if (_matchKw('UNION')) {
      setOp = _matchKw('ALL') ? 'UNION ALL' : 'UNION';
      right = _parseSelect();
    } else if (_matchKw('INTERSECT')) {
      setOp = 'INTERSECT';
      right = _parseSelect();
    } else if (_matchKw('EXCEPT')) {
      setOp = 'EXCEPT';
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
            'VALUES rows must all have the same number of columns');
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
      limit = int.parse(_expect(TokType.number).text);
    }
    if (_matchKw('OFFSET')) {
      offset = int.parse(_expect(TokType.number).text);
    }
    SelectStmt makeArm(List<Expr> vals, {bool nameCols = false}) {
      final proj = <SelectItem>[];
      for (var i = 0; i < vals.length; i++) {
        proj.add(SelectItem.expr(vals[i],
            alias: nameCols ? 'column${i + 1}' : null));
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
    final joins = <JoinClause>[];
    if (_matchKw('FROM')) {
      if (_match(TokType.punct, '(')) {
        fromSub = _parseSelect();
        _expect(TokType.punct, ')');
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
      if (_check(TokType.ident)) {
        fromAlias = _advance().text;
      } else if (_matchKw('AS')) {
        fromAlias = _expectName();
      }
      fromIndexHint = _consumeIndexedHint();
      while (true) {
        String? joinType;
        bool natural = false;
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
          _expectKw('JOIN');
          joinType = 'CROSS';
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
        if (!natural && joinType != 'CROSS') {
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
        joins.add(JoinClause(joinType, tbl, alias, on,
            subquery: sub,
            using: usingCols,
            natural: natural,
            indexedBy: joinHint));
      }
    }
    Expr? where;
    if (_matchKw('WHERE')) where = _parseExpr();
    final groupBy = <Expr>[];
    Expr? having;
    if (_matchKw('GROUP')) {
      _expectKw('BY');
      groupBy.add(_parseExpr());
      while (_match(TokType.punct, ',')) {
        groupBy.add(_parseExpr());
      }
      if (_matchKw('HAVING')) having = _parseExpr();
    }
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
    if (_matchKw('LIMIT')) {
      limit = int.parse(_expect(TokType.number).text);
    }
    if (_matchKw('OFFSET')) {
      offset = int.parse(_expect(TokType.number).text);
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
      fromFunction: fromFunc,
      namedWindows: namedWindows,
      indexedBy: fromIndexHint,
    );
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
            negated ? 'IS NOT DISTINCT FROM' : 'IS DISTINCT FROM', left, right);
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
    if (negated) {
      throw FormatException('Unexpected NOT before "${_peek().text}"');
    }
    while (_check(TokType.op) &&
        const {'=', '!=', '<>', '<', '<=', '>', '>='}.contains(_peek().text)) {
      final op = _advance().text;
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
    return _parsePrimary();
  }

  Expr _parsePrimary() {
    final t = _peek();
    if (t.type == TokType.param) {
      _advance();
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
      if (t.text.contains('.')) return LiteralExpr(double.parse(t.text));
      return LiteralExpr(int.parse(t.text));
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
      _expect(TokType.punct, ')');
      return e;
    }
    if (t.type == TokType.ident) {
      _advance();
      if (_check(TokType.punct, '(')) {
        return _parseFunctionCall(t.text);
      }
      if (_check(TokType.punct, '.')) {
        _advance();
        final col = _expectName();
        return ColumnExpr(col, table: t.text);
      }
      // Special bare-word datetime literals (no parentheses).
      const bareFns = {'CURRENT_TIMESTAMP', 'CURRENT_DATE', 'CURRENT_TIME'};
      if (bareFns.contains(t.upper)) {
        return FunctionCallExpr(t.upper, const []);
      }
      return ColumnExpr(t.text);
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
      return ColumnExpr(t.text);
    }
    throw FormatException('Unexpected token "${t.text}" at offset ${t.offset}');
  }

  Expr _parseFunctionCall(String name) {
    final upper = name.toUpperCase();
    _expect(TokType.punct, '(');
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
      } else {
        if (_matchKw('DISTINCT')) distinct = true;
        args.add(_parseExpr());
        while (_match(TokType.punct, ',')) {
          args.add(_parseExpr());
        }
      }
    }
    _expect(TokType.punct, ')');
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
    return FunctionCallExpr(upper, args,
        isStarArg: isStar,
        distinct: distinct,
        window: window,
        filterExpr: filterExpr);
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
    _expect(TokType.punct, ')');
    return CastExpr(e, type);
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
