/// SQL lexer (tokenizer). Case-insensitive keyword matching, supports
/// `--` and `/* */` comments, single/double-quoted strings, integers,
/// reals, identifiers, multi-char operators (<=, >=, !=, <>).
library;

enum TokType {
  ident,
  number,
  string,
  blob, // X'...' hex literal — text holds the hex digits (no X'')
  keyword,
  op,
  punct, // ( ) , ; .
  // Bind-parameter placeholder. text is the literal source spelling:
  //   '?'        -> anonymous positional (auto-numbered 1.. left-to-right)
  //   '?<digits>'-> explicit positional, e.g. '?3'
  //   ':name', '@name', '$name' -> named
  param,
  eof,
}

class Token {
  final TokType type;
  final String text;
  final String upper; // text uppercased (only meaningful for keywords/idents)
  final int offset;
  Token(this.type, this.text, this.offset) : upper = text.toUpperCase();
  @override
  String toString() => '$type($text)';
}

const Set<String> _keywords = {
  'SELECT',
  'FROM',
  'WHERE',
  'AND',
  'OR',
  'NOT',
  'NULL',
  'IS',
  'IN',
  'BETWEEN',
  'LIKE',
  'ESCAPE',
  'AS',
  'ORDER',
  'BY',
  'ASC',
  'DESC',
  'LIMIT',
  'OFFSET',
  'DISTINCT',
  'INSERT',
  'INTO',
  'VALUES',
  'UPDATE',
  'SET',
  'DELETE',
  'CREATE',
  'DROP',
  'ALTER',
  'TABLE',
  'INDEX',
  'ON',
  'IF',
  'EXISTS',
  'ADD',
  'COLUMN',
  'PRIMARY',
  'KEY',
  'UNIQUE',
  'DEFAULT',
  'JOIN',
  'INNER',
  'LEFT',
  'OUTER',
  'BEGIN',
  'COMMIT',
  'ROLLBACK',
  'TRANSACTION',
  'TRUE',
  'FALSE',
  'INT',
  'INTEGER',
  'BIGINT',
  'REAL',
  'DOUBLE',
  'FLOAT',
  'NUMERIC',
  'TEXT',
  'STRING',
  'VARCHAR',
  'CHAR',
  'BOOL',
  'BOOLEAN',
  'SHOW',
  'TABLES',
  'DESCRIBE',
  // --- aggregates / GROUP BY ---
  'GROUP',
  'HAVING',
  'ROLLUP',
  'CUBE',
  'GROUPING',
  'SETS',
  'COUNT',
  'SUM',
  'AVG',
  'MIN',
  'MAX',
  // --- CASE ---
  'CASE',
  'WHEN',
  'THEN',
  'ELSE',
  'END',
  // --- joins ---
  'CROSS',
  'RIGHT',
  'FULL',
  'USING',
  'NATURAL',
  // --- set ops ---
  'UNION',
  'ALL',
  'INTERSECT',
  'EXCEPT',
  // --- DDL extras ---
  'AUTOINCREMENT',
  'AUTO_INCREMENT',
  'CHECK',
  'FOREIGN',
  'REFERENCES',
  'CASCADE',
  'RESTRICT',
  'ACTION',
  'NO',
  'VIEW',
  // --- DML extras ---
  'REPLACE',
  'TRUNCATE',
  'IGNORE',
  'WITH',
  'RECURSIVE',
  'RETURNING',
  'GLOB',
  'REGEXP',
  // --- misc ---
  'NULLS',
  'FIRST',
  'LAST',
  'CAST',
  'EXPLAIN',
  'PRAGMA',
  // --- ALTER / generated columns ---
  'RENAME',
  'TO',
  'GENERATED',
  'ALWAYS',
  'STORED',
  'VIRTUAL',
  // --- triggers / savepoints ---
  'TRIGGER',
  'BEFORE',
  'AFTER',
  'INSTEAD',
  'OF',
  'EACH',
  'ROW',
  'FOR',
  'NEW',
  'OLD',
  'SAVEPOINT',
  'RELEASE',
  // --- attach / windows ---
  'ATTACH',
  'DETACH',
  'DATABASE',
  'OVER',
  'PARTITION',
  'WINDOW',
  // --- upsert ---
  'CONFLICT',
  'DO',
  'NOTHING',
  'EXCLUDED',
  // --- window frames ---
  'ROWS',
  'RANGE',
  'GROUPS',
  'FILTER',
  'FOLLOWING',
  'PRECEDING',
  'UNBOUNDED',
  'EXCLUDE',
  'OTHERS',
  'TIES',
  'CURRENT',
  // --- A5 ---
  'INDEXED',
  'MATERIALIZED',
  'ROWID',
  'VACUUM',
  'ANALYZE',
  'REINDEX',
  'WITHOUT',
  'STRICT',
  'MATCH',
  'COLLATE',
  'USE',
  'DATABASES',
  'SCHEMAS',
  'COLUMNS',
  'VARIABLES',
  'STATUS',
  'NAMES',
  'DUPLICATE',
};

class Lexer {
  final String src;
  int _pos = 0;
  Lexer(this.src);

  List<Token> tokenize() {
    final out = <Token>[];
    while (_pos < src.length) {
      final c = src[_pos];
      if (_isWhitespace(c)) {
        _pos++;
        continue;
      }
      if (c == '-' && _peek(1) == '-') {
        _skipLineComment();
        continue;
      }
      if (c == '/' && _peek(1) == '*') {
        _skipBlockComment();
        continue;
      }
      if (c == "'" || c == '"') {
        out.add(_readString(c));
        continue;
      }
      // MySQL-style backtick-quoted identifier.
      if (c == '`') {
        out.add(_readBacktickIdent());
        continue;
      }
      // X'...' BLOB literal (hex). Must be a standalone X immediately
      // followed by a single-quoted run of hex digits.
      if ((c == 'X' || c == 'x') && _peek(1) == "'") {
        out.add(_readBlobLiteral());
        continue;
      }
      if (_isDigit(c) || (c == '.' && _isDigit(_peek(1) ?? ''))) {
        out.add(_readNumber());
        continue;
      }
      if (_isIdentStart(c)) {
        out.add(_readIdentOrKeyword());
        continue;
      }
      out.add(_readOperatorOrPunct());
    }
    out.add(Token(TokType.eof, '', _pos));
    return out;
  }

  String? _peek(int n) => _pos + n < src.length ? src[_pos + n] : null;

  bool _isWhitespace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';
  bool _isDigit(String c) =>
      c.isNotEmpty && c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  bool _isAlpha(String c) {
    if (c.isEmpty) return false;
    final cu = c.codeUnitAt(0);
    return (cu >= 65 && cu <= 90) || (cu >= 97 && cu <= 122) || c == '_';
  }

  bool _isIdentStart(String c) => _isAlpha(c);
  bool _isIdentCont(String c) => _isAlpha(c) || _isDigit(c);

  void _skipLineComment() {
    while (_pos < src.length && src[_pos] != '\n') {
      _pos++;
    }
  }

  void _skipBlockComment() {
    _pos += 2;
    while (_pos + 1 < src.length &&
        !(src[_pos] == '*' && src[_pos + 1] == '/')) {
      _pos++;
    }
    if (_pos + 1 < src.length) _pos += 2;
  }

  Token _readString(String quote) {
    final start = _pos;
    _pos++; // opening quote
    final buf = StringBuffer();
    while (_pos < src.length) {
      final c = src[_pos];
      if (c == quote) {
        // SQL doubled-quote escape
        if (_peek(1) == quote) {
          buf.write(quote);
          _pos += 2;
          continue;
        }
        _pos++;
        return Token(TokType.string, buf.toString(), start);
      }
      if (c == '\\' && _pos + 1 < src.length) {
        final n = src[_pos + 1];
        if (n == 'n') {
          buf.write('\n');
          _pos += 2;
          continue;
        }
        if (n == 't') {
          buf.write('\t');
          _pos += 2;
          continue;
        }
        if (n == '\\') {
          buf.write('\\');
          _pos += 2;
          continue;
        }
        if (n == quote) {
          buf.write(quote);
          _pos += 2;
          continue;
        }
      }
      buf.write(c);
      _pos++;
    }
    throw FormatException('Unterminated string at $start');
  }

  Token _readBacktickIdent() {
    final start = _pos;
    _pos++; // opening backtick
    final buf = StringBuffer();
    while (_pos < src.length) {
      final c = src[_pos];
      if (c == '`') {
        // Doubled backtick is an escape for a literal backtick.
        if (_peek(1) == '`') {
          buf.write('`');
          _pos += 2;
          continue;
        }
        _pos++;
        return Token(TokType.ident, buf.toString(), start);
      }
      buf.write(c);
      _pos++;
    }
    throw FormatException('Unterminated backtick identifier at $start');
  }

  Token _readBlobLiteral() {
    final start = _pos;
    _pos += 2; // skip X'
    final buf = StringBuffer();
    while (_pos < src.length && src[_pos] != "'") {
      final c = src[_pos];
      final ok =
          (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) ||
          (c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 70) ||
          (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 102);
      if (!ok) {
        throw FormatException('Invalid hex digit in BLOB literal at $_pos');
      }
      buf.write(c);
      _pos++;
    }
    if (_pos >= src.length) {
      throw FormatException('Unterminated BLOB literal at $start');
    }
    _pos++; // closing '
    if (buf.length.isOdd) {
      throw FormatException('BLOB literal must have even hex length');
    }
    return Token(TokType.blob, buf.toString(), start);
  }

  Token _readNumber() {
    final start = _pos;
    bool dotSeen = false;
    while (_pos < src.length) {
      final c = src[_pos];
      if (_isDigit(c)) {
        _pos++;
        continue;
      }
      if (c == '.' && !dotSeen) {
        dotSeen = true;
        _pos++;
        continue;
      }
      break;
    }
    return Token(TokType.number, src.substring(start, _pos), start);
  }

  Token _readIdentOrKeyword() {
    final start = _pos;
    while (_pos < src.length && _isIdentCont(src[_pos])) {
      _pos++;
    }
    final text = src.substring(start, _pos);
    final upper = text.toUpperCase();
    if (_keywords.contains(upper)) {
      return Token(TokType.keyword, text, start);
    }
    return Token(TokType.ident, text, start);
  }

  Token _readOperatorOrPunct() {
    final start = _pos;
    final c = src[_pos];
    // multi-char operators
    if (c == '<' && _peek(1) == '=') {
      _pos += 2;
      return Token(TokType.op, '<=', start);
    }
    if (c == '>' && _peek(1) == '=') {
      _pos += 2;
      return Token(TokType.op, '>=', start);
    }
    if (c == '!' && _peek(1) == '=') {
      _pos += 2;
      return Token(TokType.op, '!=', start);
    }
    if (c == '<' && _peek(1) == '>') {
      _pos += 2;
      return Token(TokType.op, '<>', start);
    }
    if (c == '|' && _peek(1) == '|') {
      _pos += 2;
      return Token(TokType.op, '||', start);
    }
    if (c == '<' && _peek(1) == '<') {
      _pos += 2;
      return Token(TokType.op, '<<', start);
    }
    if (c == '>' && _peek(1) == '>') {
      _pos += 2;
      return Token(TokType.op, '>>', start);
    }
    if (c == '-' && _peek(1) == '>' && _peek(2) == '>') {
      _pos += 3;
      return Token(TokType.op, '->>', start);
    }
    if (c == '-' && _peek(1) == '>') {
      _pos += 2;
      return Token(TokType.op, '->', start);
    }
    if ('=<>+-*/%&|~'.contains(c)) {
      _pos++;
      return Token(TokType.op, c, start);
    }
    if ('(),;.'.contains(c)) {
      _pos++;
      return Token(TokType.punct, c, start);
    }
    if (c == '?') {
      _pos++;
      // Optional digits for explicit numbering: ?12
      final ds = _pos;
      while (_pos < src.length && _isDigit(src[_pos])) {
        _pos++;
      }
      return Token(TokType.param, '?${src.substring(ds, _pos)}', start);
    }
    if (c == ':' || c == '@' || c == '\$') {
      // MySQL system variable: @@name or @@global.name / @@session.name.
      if (c == '@' && _peek(1) == '@') {
        final s = _pos;
        _pos += 2;
        while (_pos < src.length &&
            (_isIdentCont(src[_pos]) || src[_pos] == '.')) {
          _pos++;
        }
        if (_pos == s + 2) {
          throw FormatException('Empty system-variable name at $s');
        }
        return Token(TokType.ident, src.substring(s, _pos), s);
      }
      // Named parameter: leading sigil + identifier characters.
      _pos++;
      final ns = _pos;
      while (_pos < src.length && _isIdentCont(src[_pos])) {
        _pos++;
      }
      if (ns == _pos) {
        throw FormatException(
          'Empty named-parameter at $start (expected $c<name>)',
        );
      }
      return Token(TokType.param, '$c${src.substring(ns, _pos)}', start);
    }
    throw FormatException('Unexpected character "$c" at $start');
  }
}
