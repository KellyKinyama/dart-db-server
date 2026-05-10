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

  /// Consume an optional `INDEXED BY name` or `NOT INDEXED` hint. The
  /// hint is parsed for compatibility with SQLite syntax and otherwise
  /// ignored — this engine has no query planner that reads it.
  void _consumeIndexedHint() {
    if (_matchKw('INDEXED')) {
      _expectKw('BY');
      _expectIdent();
    } else if (_matchKw('NOT')) {
      _expectKw('INDEXED');
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
    // any order, optionally separated by commas.
    bool strict = false;
    while (true) {
      if (_matchKw('WITHOUT')) {
        _expectKw('ROWID');
      } else if (_matchKw('STRICT')) {
        strict = true;
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
        constraints: constraints, ifNotExists: ifNotExists, strict: strict);
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
        if (_matchKw('AUTOINCREMENT') || _matchKw('AUTO_INCREMENT'))
          autoInc = true;
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
        // Allow signed numeric default.
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
    final saved = _pos;
    if (_check(TokType.ident) &&
        (_peek(1).type == TokType.punct &&
            (_peek(1).text == ')' || _peek(1).text == ','))) {
      col = _expectIdent().text;
      // Tolerate `CREATE INDEX i ON t(c1, c2)` by ignoring extras
      // (multi-column indexes not supported — use the first column).
      while (_match(TokType.punct, ',')) {
        _expectIdent();
      }
    } else {
      // Expression index.
      _pos = saved;
      final start = _peek().offset;
      _parseExpr();
      final end = _peek().offset;
      exprSql = _sliceSource(start, end);
      col = exprSql;
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
        unique: unique, whereSql: whereSql, exprSql: exprSql);
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
    final sel = _parseSelect();
    return CreateViewStmt(name, sel, ifNotExists: ifNotExists);
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
      return DropIndexStmt(_expectIdent().text);
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
      } else {
        throw FormatException('Expected REPLACE or IGNORE after INSERT OR');
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
    if (_matchKw('VALUES')) {
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
    _consumeIndexedHint();
    _expectKw('SET');
    final assignments = <String, Expr>{};
    do {
      final col = _expectIdent().text;
      _expect(TokType.op, '=');
      assignments[col] = _parseExpr();
    } while (_match(TokType.punct, ','));
    Expr? where;
    if (_matchKw('WHERE')) where = _parseExpr();
    final ret = _parseReturning();
    return UpdateStmt(table, assignments, where, returning: ret);
  }

  // ---- DELETE -------------------------------------------------------------
  DeleteStmt _parseDelete() {
    _expectKw('DELETE');
    _expectKw('FROM');
    final table = _expectIdent().text;
    _consumeIndexedHint();
    Expr? where;
    if (_matchKw('WHERE')) where = _parseExpr();
    final ret = _parseReturning();
    return DeleteStmt(table, where, returning: ret);
  }

  // ---- WITH (CTEs) --------------------------------------------------------
  Statement _parseWith() {
    _expectKw('WITH');
    final recursive = _matchKw('RECURSIVE');
    final ctes = <String, SelectStmt>{};
    final cteColumns = <String, List<String>>{};
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
      // Optional MATERIALIZED / NOT MATERIALIZED hint — accept and ignore.
      if (_matchKw('NOT')) {
        _expectKw('MATERIALIZED');
      } else {
        _matchKw('MATERIALIZED');
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
            ctesRecursive: recursive);
      case 'DELETE':
        final s = _parseDelete();
        return DeleteStmt(s.table, s.where,
            returning: s.returning,
            ctes: ctes,
            cteColumns: cteColumns,
            ctesRecursive: recursive);
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
      _consumeIndexedHint();
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
        _consumeIndexedHint();
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
            subquery: sub, using: usingCols, natural: natural));
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
      _expectKw('NULL');
      return UnaryExpr(negated ? 'IS NOT NULL' : 'IS NULL', left);
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
      Expr like = BinaryExpr('LIKE', left, _parseConcat());
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
    var left = _parseAddSub();
    while (_check(TokType.op, '->') || _check(TokType.op, '->>')) {
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
    while (_check(TokType.op) && (_peek().text == '*' || _peek().text == '/')) {
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
    return _parsePrimary();
  }

  Expr _parsePrimary() {
    final t = _peek();
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
