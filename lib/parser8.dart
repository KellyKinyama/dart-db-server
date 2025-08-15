import 'dart:io';

// =============================================================================
// AST (Abstract Syntax Tree) Nodes
// These classes represent the structured output of the parser.
// =============================================================================

/// Base class for all SQL statements.
abstract class SqlStatement {}

/// The root node of a parsed SELECT statement.
class SelectStatement implements SqlStatement {
  final bool isDistinct;
  final List<dynamic> columns;
  final TableExpression fromClause;
  final WhereClause? whereClause;
  final GroupByClause? groupByClause;
  final HavingClause? havingClause;
  final OrderByClause? orderByClause;
  final LimitClause? limitClause;

  SelectStatement({
    this.isDistinct = false,
    required this.columns,
    required this.fromClause,
    this.whereClause,
    this.groupByClause,
    this.havingClause,
    this.orderByClause,
    this.limitClause,
  });

  @override
  String toString() {
    final distinct = isDistinct ? 'DISTINCT ' : '';
    final cols = columns.map((c) => c.toString()).join(', ');
    final from = 'FROM ${fromClause.toString()}';
    final where = whereClause != null ? ' WHERE ${whereClause.toString()}' : '';
    final groupBy = groupByClause != null ? ' ${groupByClause.toString()}' : '';
    final having = havingClause != null ? ' ${havingClause.toString()}' : '';
    final orderBy = orderByClause != null ? ' ${orderByClause.toString()}' : '';
    final limit = limitClause != null ? ' ${limitClause.toString()}' : '';
    return 'SELECT $distinct$cols $from$where$groupBy$having$orderBy$limit';
  }
}

/// The root node of a parsed INSERT statement.
class InsertStatement implements SqlStatement {
  final String tableName;
  final List<String> columns;
  final List<dynamic> values;

  InsertStatement(
      {required this.tableName, required this.columns, required this.values});

  @override
  String toString() {
    final cols = columns.join(', ');
    final vals =
        values.map((v) => v is String ? "'$v'" : v.toString()).join(', ');
    return 'INSERT INTO $tableName ($cols) VALUES ($vals)';
  }
}

/// The root node of a parsed UPDATE statement.
class UpdateStatement implements SqlStatement {
  final String tableName;
  final List<Assignment> assignments;
  final WhereClause? whereClause;

  UpdateStatement({
    required this.tableName,
    required this.assignments,
    this.whereClause,
  });

  @override
  String toString() {
    final sets = assignments.map((a) => a.toString()).join(', ');
    final where = whereClause != null ? ' WHERE ${whereClause.toString()}' : '';
    return 'UPDATE $tableName SET $sets$where';
  }
}

/// Represents a single assignment in an UPDATE statement (e.g., `column = value`).
class Assignment {
  final String column;
  final Expression value;

  Assignment({required this.column, required this.value});

  @override
  String toString() => '$column = $value';
}

/// The root node of a parsed DELETE statement.
class DeleteStatement implements SqlStatement {
  final String tableName;
  final WhereClause? whereClause;

  DeleteStatement({required this.tableName, this.whereClause});

  @override
  String toString() {
    final where = whereClause != null ? ' WHERE ${whereClause.toString()}' : '';
    return 'DELETE FROM $tableName$where';
  }
}

/// Represents the FROM clause, which can include joins.
class TableExpression {
  final String tableName;
  final JoinClause? joinClause;

  TableExpression({required this.tableName, this.joinClause});

  @override
  String toString() {
    final join = joinClause != null ? ' ${joinClause.toString()}' : '';
    return '$tableName$join';
  }
}

/// Represents a JOIN clause.
class JoinClause {
  final String joinType;
  final String joinTable;
  final Expression onExpression;

  JoinClause(
      {required this.joinType,
      required this.joinTable,
      required this.onExpression});

  @override
  String toString() => '$joinType JOIN $joinTable ON $onExpression';
}

/// Represents the WHERE clause of a statement.
class WhereClause {
  final Expression expression;

  WhereClause({required this.expression});

  @override
  String toString() => expression.toString();
}

/// Represents the GROUP BY clause.
class GroupByClause {
  final List<Expression> columns;

  GroupByClause({required this.columns});

  @override
  String toString() =>
      'GROUP BY ${columns.map((e) => e.toString()).join(', ')}';
}

/// Represents the HAVING clause.
class HavingClause {
  final Expression expression;

  HavingClause({required this.expression});

  @override
  String toString() => 'HAVING ${expression.toString()}';
}

/// Represents the ORDER BY clause.
class OrderByClause {
  final Expression column;
  final String direction;

  OrderByClause({required this.column, required this.direction});

  @override
  String toString() => 'ORDER BY $column $direction';
}

/// Represents the LIMIT clause.
class LimitClause {
  final int count;

  LimitClause({required this.count});

  @override
  String toString() => 'LIMIT $count';
}

/// Base class for all expressions.
abstract class Expression {}

/// Represents a binary expression (e.g., `A = B`, `C > 10`, `X AND Y`).
class BinaryExpression implements Expression {
  final Expression left;
  final Expression right;
  final String op;

  BinaryExpression({required this.left, required this.right, required this.op});

  @override
  String toString() => '($left $op $right)';
}

/// Represents a unary expression (e.g., `IS NULL`).
class UnaryExpression implements Expression {
  final Expression operand;
  final String op;

  UnaryExpression({required this.operand, required this.op});

  @override
  String toString() => '($operand $op)';
}

/// Represents a BETWEEN expression (e.g., `column BETWEEN a AND b`).
class BetweenExpression implements Expression {
  final Expression value;
  final Expression lowerBound;
  final Expression upperBound;

  BetweenExpression(
      {required this.value,
      required this.lowerBound,
      required this.upperBound});

  @override
  String toString() => '($value BETWEEN $lowerBound AND $upperBound)';
}

/// Represents an IN expression (e.g., `column IN (1, 2, 3)`).
class InExpression implements Expression {
  final Expression value;
  final List<Expression> list;

  InExpression({required this.value, required this.list});

  @override
  String toString() =>
      '$value IN (${list.map((e) => e.toString()).join(', ')})';
}

/// Represents a qualified identifier (e.g., `table.column`).
class QualifiedIdentifierExpression implements Expression {
  final String table;
  final String column;

  QualifiedIdentifierExpression({required this.table, required this.column});

  @override
  String toString() => '$table.$column';
}

/// Represents a column or table identifier.
class IdentifierExpression implements Expression {
  final String name;

  IdentifierExpression({required this.name});

  @override
  String toString() => name;
}

/// Represents a literal value (e.g., number, string).
class LiteralExpression implements Expression {
  final dynamic value;

  LiteralExpression({required this.value});

  @override
  String toString() => value is String ? "'$value'" : value.toString();
}

/// Represents a function call (e.g., `COUNT(*)` or `MAX(price)`).
class FunctionCallExpression implements Expression {
  final String name;
  final List<Expression> arguments;

  FunctionCallExpression({required this.name, required this.arguments});

  @override
  String toString() {
    final args = arguments.map((a) => a.toString()).join(', ');
    return '$name($args)';
  }
}

// =============================================================================
// Lexer (Tokenizer)
// Breaks the input string into a stream of tokens.
// =============================================================================

/// The types of tokens the lexer can recognize.
enum TokenType {
  // Keywords
  KEYWORD_SELECT,
  KEYWORD_DISTINCT,
  KEYWORD_FROM,
  KEYWORD_WHERE,
  KEYWORD_AND,
  KEYWORD_OR,
  KEYWORD_INSERT,
  KEYWORD_INTO,
  KEYWORD_VALUES,
  KEYWORD_UPDATE,
  KEYWORD_SET,
  KEYWORD_DELETE,
  KEYWORD_JOIN,
  KEYWORD_ON,
  KEYWORD_GROUP,
  KEYWORD_BY,
  KEYWORD_HAVING,
  KEYWORD_ORDER,
  KEYWORD_ASC,
  KEYWORD_DESC,
  KEYWORD_LIMIT,
  KEYWORD_LEFT,
  KEYWORD_RIGHT,
  KEYWORD_OUTER,
  KEYWORD_INNER,
  KEYWORD_MAX,
  KEYWORD_MIN,
  KEYWORD_AVG,
  KEYWORD_SUM,
  KEYWORD_COUNT,
  KEYWORD_BETWEEN,
  KEYWORD_IN,
  KEYWORD_LIKE,
  KEYWORD_IS,
  KEYWORD_NULL,
  KEYWORD_ASCENDING,
  KEYWORD_DESCENDING,
  KEYWORD_NOT,

  // Literals
  IDENTIFIER,
  STRING,
  NUMBER,
  
  // Symbols
  ASTERISK, // Updated to be a general symbol
  PLUS, // New token for addition
  MINUS, // New token for subtraction
  SLASH, // New token for division
  LEFT_PAREN,
  RIGHT_PAREN,
  COMMA,
  DOT,
  EQUALS,
  GREATER_THAN,
  LESS_THAN,
  NOT_EQUALS,
  SEMICOLON,

  // End of file
  EOF,
}

/// Represents a single token with its type and value.
class Token {
  final TokenType type;
  final String value;

  Token(this.type, this.value);

  @override
  String toString() => 'Token(type: $type, value: "$value")';
}

/// A custom exception for lexer and parser errors.
class ParserException implements Exception {
  final String message;
  ParserException(this.message);

  @override
  String toString() => 'ParserException: $message';
}

/// A map to convert a string to its corresponding keyword token type. This is more scalable
/// than a switch statement.
final Map<String, TokenType> _keywordMap = {
  'SELECT': TokenType.KEYWORD_SELECT,
  'DISTINCT': TokenType.KEYWORD_DISTINCT,
  'FROM': TokenType.KEYWORD_FROM,
  'WHERE': TokenType.KEYWORD_WHERE,
  'AND': TokenType.KEYWORD_AND,
  'OR': TokenType.KEYWORD_OR,
  'INSERT': TokenType.KEYWORD_INSERT,
  'INTO': TokenType.KEYWORD_INTO,
  'VALUES': TokenType.KEYWORD_VALUES,
  'UPDATE': TokenType.KEYWORD_UPDATE,
  'SET': TokenType.KEYWORD_SET,
  'DELETE': TokenType.KEYWORD_DELETE,
  'JOIN': TokenType.KEYWORD_JOIN,
  'ON': TokenType.KEYWORD_ON,
  'GROUP': TokenType.KEYWORD_GROUP,
  'BY': TokenType.KEYWORD_BY,
  'HAVING': TokenType.KEYWORD_HAVING,
  'ORDER': TokenType.KEYWORD_ORDER,
  'ASC': TokenType.KEYWORD_ASC,
  'DESC': TokenType.KEYWORD_DESC,
  'LIMIT': TokenType.KEYWORD_LIMIT,
  'LEFT': TokenType.KEYWORD_LEFT,
  'RIGHT': TokenType.KEYWORD_RIGHT,
  'OUTER': TokenType.KEYWORD_OUTER,
  'INNER': TokenType.KEYWORD_INNER,
  'MAX': TokenType.KEYWORD_MAX,
  'MIN': TokenType.KEYWORD_MIN,
  'AVG': TokenType.KEYWORD_AVG,
  'SUM': TokenType.KEYWORD_SUM,
  'COUNT': TokenType.KEYWORD_COUNT,
  'BETWEEN': TokenType.KEYWORD_BETWEEN,
  'IN': TokenType.KEYWORD_IN,
  'LIKE': TokenType.KEYWORD_LIKE,
  'IS': TokenType.KEYWORD_IS,
  'NULL': TokenType.KEYWORD_NULL,
  'ASCENDING': TokenType.KEYWORD_ASCENDING,
  'DESCENDING': TokenType.KEYWORD_DESCENDING,
  'NOT': TokenType.KEYWORD_NOT,
};

TokenType _getTokenType(String value) {
  return _keywordMap[value.toUpperCase()] ?? TokenType.IDENTIFIER;
}

/// The main lexer class.
class Lexer {
  final String _input;
  int _position = 0;

  Lexer(this._input);

  /// Get all tokens from the input string.
  List<Token> tokenize() {
    final tokens = <Token>[];
    while (_position < _input.length) {
      final char = _input[_position];

      if (RegExp(r'\s').hasMatch(char)) {
        _position++;
        continue;
      }

      // Handle comments -- and /* */
      if (char == '-' && _peekChar() == '-') {
        _skipLineComment();
        continue;
      }
      if (char == '/' && _peekChar() == '*') {
        _skipBlockComment();
        continue;
      }

      // Handle single-character symbols
      if (char == '*') {
        tokens.add(Token(TokenType.ASTERISK, char));
        _position++;
        continue;
      }
      if (char == '+') {
        tokens.add(Token(TokenType.PLUS, char));
        _position++;
        continue;
      }
      if (char == '-') {
        tokens.add(Token(TokenType.MINUS, char));
        _position++;
        continue;
      }
      if (char == '/') {
        // Special case for block comments handled above
        tokens.add(Token(TokenType.SLASH, char));
        _position++;
        continue;
      }

      if (char == '(') {
        tokens.add(Token(TokenType.LEFT_PAREN, char));
        _position++;
        continue;
      }

      if (char == ')') {
        tokens.add(Token(TokenType.RIGHT_PAREN, char));
        _position++;
        continue;
      }

      if (char == ',') {
        tokens.add(Token(TokenType.COMMA, char));
        _position++;
        continue;
      }

      if (char == '.') {
        tokens.add(Token(TokenType.DOT, char));
        _position++;
        continue;
      }

      if (char == '=') {
        tokens.add(Token(TokenType.EQUALS, char));
        _position++;
        continue;
      }

      if (char == '>') {
        tokens.add(Token(TokenType.GREATER_THAN, char));
        _position++;
        continue;
      }

      if (char == '<') {
        if (_peekChar() == '>') {
          tokens.add(Token(TokenType.NOT_EQUALS, '<>'));
          _position += 2;
        } else {
          tokens.add(Token(TokenType.LESS_THAN, char));
          _position++;
        }
        continue;
      }

      if (char == ';') {
        tokens.add(Token(TokenType.SEMICOLON, char));
        _position++;
        continue;
      }

      if (char == '\'') {
        tokens.add(_readString());
        continue;
      }

      // Check for a number, including a potential decimal point.
      if (RegExp(r'[0-9]').hasMatch(char)) {
        tokens.add(_readNumber());
        continue;
      }

      if (RegExp(r'[a-zA-Z_]').hasMatch(char)) {
        tokens.add(_readIdentifier());
        continue;
      }

      throw ParserException(
          'Unexpected character at position $_position: $char');
    }
    tokens.add(Token(TokenType.EOF, ''));
    return tokens;
  }

  String _peekChar() {
    if (_position + 1 < _input.length) {
      return _input[_position + 1];
    }
    return '';
  }

  void _skipLineComment() {
    _position += 2; // Skip '--'
    while (_position < _input.length && _input[_position] != '\n') {
      _position++;
    }
    _position++; // Skip the newline
  }

  void _skipBlockComment() {
    _position += 2; // Skip '/*'
    while (_position < _input.length) {
      if (_input[_position] == '*' && _peekChar() == '/') {
        _position += 2;
        return;
      }
      _position++;
    }
    throw ParserException('Unterminated block comment');
  }

  /// Helper to read a string literal.
  Token _readString() {
    final start = _position + 1;
    _position++;
    while (_position < _input.length && _input[_position] != '\'') {
      _position++;
    }
    if (_position >= _input.length) {
      throw ParserException('Unterminated string literal');
    }
    final value = _input.substring(start, _position);
    _position++;
    return Token(TokenType.STRING, value);
  }

  /// Helper to read a numeric literal, including floats.
  Token _readNumber() {
    final start = _position;
    bool hasDecimal = false;
    while (_position < _input.length &&
        RegExp(r'[0-9\.]').hasMatch(_input[_position])) {
      if (_input[_position] == '.') {
        if (hasDecimal) {
          throw ParserException(
              'Invalid number format: multiple decimal points');
        }
        hasDecimal = true;
      }
      _position++;
    }
    return Token(TokenType.NUMBER, _input.substring(start, _position));
  }

  /// Helper to read an identifier or keyword.
  Token _readIdentifier() {
    final start = _position;
    while (_position < _input.length &&
        RegExp(r'[a-zA-Z0-9_]').hasMatch(_input[_position])) {
      _position++;
    }
    final value = _input.substring(start, _position);
    final type = _getTokenType(value);
    return Token(type, value);
  }
}

// =============================================================================
// Parser
// Creates the AST from the token stream using recursive descent.
// =============================================================================

/// The main parser class.
class Parser {
  final List<Token> _tokens;
  int _position = 0;

  Parser(this._tokens);

  /// The main entry point to start parsing.
  SqlStatement parse() {
    final tokenType = _peek().type;
    switch (tokenType) {
      case TokenType.KEYWORD_SELECT:
        return _parseSelectStatement();
      case TokenType.KEYWORD_INSERT:
        return _parseInsertStatement();
      case TokenType.KEYWORD_UPDATE:
        return _parseUpdateStatement();
      case TokenType.KEYWORD_DELETE:
        return _parseDeleteStatement();
      default:
        throw ParserException(
            'Expected SELECT, INSERT, UPDATE, or DELETE statement, but found: $tokenType');
    }
  }

  /// Consumes the current token and moves to the next one.
  Token _consume() {
    if (_position >= _tokens.length) {
      return Token(TokenType.EOF, '');
    }
    return _tokens[_position++];
  }

  /// Gets the current token without consuming it.
  Token _peek() {
    if (_position >= _tokens.length) {
      return Token(TokenType.EOF, '');
    }
    return _tokens[_position];
  }

  /// Throws an error if the current token's type doesn't match the expected type.
  void _expect(TokenType type, String message) {
    if (_peek().type != type) {
      throw ParserException(message);
    }
    _consume();
  }

  /// Parses a full SELECT statement.
  SelectStatement _parseSelectStatement() {
    _expect(TokenType.KEYWORD_SELECT, 'Expected SELECT keyword');
    final isDistinct = _peek().type == TokenType.KEYWORD_DISTINCT;
    if (isDistinct) {
      _consume();
    }

    final columns = _parseSelectClause();
    final fromClause = _parseFromClause();
    final whereClause =
        _peek().type == TokenType.KEYWORD_WHERE ? _parseWhereClause() : null;
    final groupByClause =
        _peek().type == TokenType.KEYWORD_GROUP ? _parseGroupByClause() : null;
    final havingClause =
        _peek().type == TokenType.KEYWORD_HAVING ? _parseHavingClause() : null;
    final orderByClause =
        _peek().type == TokenType.KEYWORD_ORDER ? _parseOrderByClause() : null;
    final limitClause =
        _peek().type == TokenType.KEYWORD_LIMIT ? _parseLimitClause() : null;

    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }

    if (_peek().type != TokenType.EOF) {
      throw ParserException('Expected end of statement.');
    }

    return SelectStatement(
      isDistinct: isDistinct,
      columns: columns,
      fromClause: fromClause,
      whereClause: whereClause,
      groupByClause: groupByClause,
      havingClause: havingClause,
      orderByClause: orderByClause,
      limitClause: limitClause,
    );
  }

  /// Parses a full INSERT statement.
  InsertStatement _parseInsertStatement() {
    _expect(TokenType.KEYWORD_INSERT, 'Expected INSERT keyword');
    _expect(TokenType.KEYWORD_INTO, 'Expected INTO keyword');
    final tableName = _parseIdentifier().name;

    _expect(TokenType.LEFT_PAREN, 'Expected `(` for column list');
    final columns = <String>[];
    columns.add(_parseIdentifier().name);
    while (_peek().type == TokenType.COMMA) {
      _consume();
      columns.add(_parseIdentifier().name);
    }
    _expect(TokenType.RIGHT_PAREN, 'Expected `)` after column list');

    _expect(TokenType.KEYWORD_VALUES, 'Expected VALUES keyword');
    _expect(TokenType.LEFT_PAREN, 'Expected `(` for value list');
    final values = <dynamic>[];
    values.add(_parseLiteral().value);
    while (_peek().type == TokenType.COMMA) {
      _consume();
      values.add(_parseLiteral().value);
    }
    _expect(TokenType.RIGHT_PAREN, 'Expected `)` after value list');

    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }

    if (_peek().type != TokenType.EOF) {
      throw ParserException('Expected end of statement.');
    }

    return InsertStatement(
      tableName: tableName,
      columns: columns,
      values: values,
    );
  }

  /// Parses a full UPDATE statement.
  UpdateStatement _parseUpdateStatement() {
    _expect(TokenType.KEYWORD_UPDATE, 'Expected UPDATE keyword');
    final tableName = _parseIdentifier().name;

    _expect(TokenType.KEYWORD_SET, 'Expected SET keyword');
    final assignments = <Assignment>[];
    assignments.add(_parseAssignment());
    while (_peek().type == TokenType.COMMA) {
      _consume();
      assignments.add(_parseAssignment());
    }

    final whereClause =
        _peek().type == TokenType.KEYWORD_WHERE ? _parseWhereClause() : null;

    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }

    if (_peek().type != TokenType.EOF) {
      throw ParserException('Expected end of statement.');
    }

    return UpdateStatement(
      tableName: tableName,
      assignments: assignments,
      whereClause: whereClause,
    );
  }

  /// Parses a full DELETE statement.
  DeleteStatement _parseDeleteStatement() {
    _expect(TokenType.KEYWORD_DELETE, 'Expected DELETE keyword');
    _expect(TokenType.KEYWORD_FROM, 'Expected FROM keyword');
    final tableName = _parseIdentifier().name;
    final whereClause =
        _peek().type == TokenType.KEYWORD_WHERE ? _parseWhereClause() : null;

    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }

    if (_peek().type != TokenType.EOF) {
      throw ParserException('Expected end of statement.');
    }

    return DeleteStatement(
      tableName: tableName,
      whereClause: whereClause,
    );
  }

  /// Parses a single assignment for an UPDATE statement (e.g., `column = value`).
  Assignment _parseAssignment() {
    final column = _parseIdentifier().name;
    _expect(TokenType.EQUALS, 'Expected `=` for assignment');
    // We now parse a full arithmetic expression for the value
    final value = _parseArithmeticExpression();
    return Assignment(column: column, value: value);
  }

  /// Parses the SELECT clause and column list.
  List<dynamic> _parseSelectClause() {
    final columns = <dynamic>[];
    if (_peek().type == TokenType.ASTERISK) {
      columns.add('*');
      _consume();
    } else {
      // The select clause can contain full arithmetic expressions, not just primary ones.
      columns.add(_parseArithmeticExpression());
      while (_peek().type == TokenType.COMMA) {
        _consume();
        columns.add(_parseArithmeticExpression());
      }
    }
    return columns;
  }

  /// Parses the FROM clause, including optional JOINs.
  TableExpression _parseFromClause() {
    _expect(TokenType.KEYWORD_FROM, 'Expected FROM keyword');
    final tableName = _parseIdentifier().name;
    JoinClause? joinClause;
    final joinTypeToken = _peek();
    String? joinType;
    if (joinTypeToken.type == TokenType.KEYWORD_LEFT ||
        joinTypeToken.type == TokenType.KEYWORD_RIGHT ||
        joinTypeToken.type == TokenType.KEYWORD_OUTER ||
        joinTypeToken.type == TokenType.KEYWORD_INNER) {
      joinType = joinTypeToken.value.toUpperCase();
      _consume();
    }

    if (_peek().type == TokenType.KEYWORD_JOIN) {
      joinClause = _parseJoinClause(joinType);
    }

    return TableExpression(tableName: tableName, joinClause: joinClause);
  }

  /// Parses a JOIN clause.
  JoinClause _parseJoinClause(String? joinType) {
    _expect(TokenType.KEYWORD_JOIN, 'Expected JOIN keyword');
    final joinTable = _parseIdentifier().name;
    _expect(TokenType.KEYWORD_ON, 'Expected ON keyword');
    final onExpression = _parseLogicalExpression();
    return JoinClause(
        joinType: joinType ?? 'INNER',
        joinTable: joinTable,
        onExpression: onExpression);
  }

  /// Parses the WHERE clause.
  WhereClause _parseWhereClause() {
    _expect(TokenType.KEYWORD_WHERE, 'Expected WHERE keyword');
    return WhereClause(expression: _parseLogicalExpression());
  }

  /// Parses the GROUP BY clause.
  GroupByClause _parseGroupByClause() {
    _expect(TokenType.KEYWORD_GROUP, 'Expected GROUP keyword');
    _expect(TokenType.KEYWORD_BY, 'Expected BY keyword');
    final columns = <Expression>[];
    columns.add(_parseArithmeticExpression());
    while (_peek().type == TokenType.COMMA) {
      _consume();
      columns.add(_parseArithmeticExpression());
    }
    return GroupByClause(columns: columns);
  }

  /// Parses the HAVING clause.
  HavingClause _parseHavingClause() {
    _expect(TokenType.KEYWORD_HAVING, 'Expected HAVING keyword');
    return HavingClause(expression: _parseLogicalExpression());
  }

  /// Parses the ORDER BY clause.
  OrderByClause _parseOrderByClause() {
    _expect(TokenType.KEYWORD_ORDER, 'Expected ORDER keyword');
    _expect(TokenType.KEYWORD_BY, 'Expected BY keyword');
    final column = _parseArithmeticExpression();
    String direction = 'ASC';
    if (_peek().type == TokenType.KEYWORD_ASC ||
        _peek().type == TokenType.KEYWORD_ASCENDING) {
      _consume();
      direction = 'ASC';
    } else if (_peek().type == TokenType.KEYWORD_DESC ||
        _peek().type == TokenType.KEYWORD_DESCENDING) {
      _consume();
      direction = 'DESC';
    }
    return OrderByClause(column: column, direction: direction);
  }

  /// Parses the LIMIT clause.
  LimitClause _parseLimitClause() {
    _expect(TokenType.KEYWORD_LIMIT, 'Expected LIMIT keyword');
    final token = _peek();
    if (token.type == TokenType.NUMBER) {
      _consume();
      return LimitClause(count: int.parse(token.value));
    }
    throw ParserException('Expected number for LIMIT clause');
  }

  // --- New expression parsing methods for operator precedence ---

  /// Parses a logical expression (highest level, handles AND/OR).
  Expression _parseLogicalExpression() {
    var left = _parseComparison();
    while (_peek().type == TokenType.KEYWORD_AND ||
        _peek().type == TokenType.KEYWORD_OR) {
      final op = _consume().value;
      final right = _parseComparison();
      left = BinaryExpression(left: left, right: right, op: op);
    }
    return left;
  }

  /// Parses a comparison expression (handles =, >, <, LIKE, etc.).
  Expression _parseComparison() {
    // Starts by parsing an arithmetic expression
    final left = _parseArithmeticExpression();
    final opToken = _peek();

    if (opToken.type == TokenType.KEYWORD_BETWEEN) {
      _consume();
      final lowerBound = _parseArithmeticExpression();
      _expect(TokenType.KEYWORD_AND,
          'Expected AND after lower bound in BETWEEN clause');
      final upperBound = _parseArithmeticExpression();
      return BetweenExpression(
          value: left, lowerBound: lowerBound, upperBound: upperBound);
    }

    if (opToken.type == TokenType.KEYWORD_IN) {
      _consume();
      _expect(TokenType.LEFT_PAREN, 'Expected `(` after IN keyword');
      final list = <Expression>[];
      if (_peek().type != TokenType.RIGHT_PAREN) {
        list.add(_parseArithmeticExpression());
        while (_peek().type == TokenType.COMMA) {
          _consume();
          list.add(_parseArithmeticExpression());
        }
      }
      _expect(TokenType.RIGHT_PAREN, 'Expected `)` after IN list');
      return InExpression(value: left, list: list);
    }

    if (opToken.type == TokenType.KEYWORD_LIKE) {
      final op = _consume().value;
      final right = _parseArithmeticExpression();
      return BinaryExpression(left: left, right: right, op: op);
    }

    // Handle IS NULL and IS NOT NULL
    if (opToken.type == TokenType.KEYWORD_IS) {
      _consume();
      final isToken = _peek();
      if (isToken.type == TokenType.KEYWORD_NOT) {
        _consume();
        _expect(TokenType.KEYWORD_NULL,
            'Expected NULL after NOT in IS NOT NULL clause');
        return UnaryExpression(operand: left, op: 'IS NOT NULL');
      }
      if (isToken.type == TokenType.KEYWORD_NULL) {
        _consume();
        return UnaryExpression(operand: left, op: 'IS NULL');
      }
      throw ParserException('Expected NULL or NOT NULL after IS');
    }

    if ([
      TokenType.EQUALS,
      TokenType.GREATER_THAN,
      TokenType.LESS_THAN,
      TokenType.NOT_EQUALS
    ].contains(opToken.type)) {
      final op = _consume().value;
      final right = _parseArithmeticExpression();
      return BinaryExpression(left: left, right: right, op: op);
    }

    return left;
  }

  // New method to handle all arithmetic expressions with precedence.
  Expression _parseArithmeticExpression() {
    return _parseAdditiveExpression();
  }

  // New method to handle addition and subtraction (lower precedence).
  Expression _parseAdditiveExpression() {
    var left = _parseMultiplicativeExpression();
    while (_peek().type == TokenType.PLUS || _peek().type == TokenType.MINUS) {
      final op = _consume().value;
      final right = _parseMultiplicativeExpression();
      left = BinaryExpression(left: left, right: right, op: op);
    }
    return left;
  }

  // New method to handle multiplication and division (higher precedence).
  Expression _parseMultiplicativeExpression() {
    var left = _parsePrimaryExpression();
    while (_peek().type == TokenType.ASTERISK || _peek().type == TokenType.SLASH) {
      final op = _consume().value;
      final right = _parsePrimaryExpression();
      left = BinaryExpression(left: left, right: right, op: op);
    }
    return left;
  }

  /// Parses a primary expression, which can be an identifier, literal, or function call.
  Expression _parsePrimaryExpression() {
    final token = _peek();
    if ([
      TokenType.IDENTIFIER,
      TokenType.KEYWORD_MAX,
      TokenType.KEYWORD_MIN,
      TokenType.KEYWORD_AVG,
      TokenType.KEYWORD_SUM,
      TokenType.KEYWORD_COUNT
    ].contains(token.type)) {
      final idName = token.value;
      _consume();
      if (_peek().type == TokenType.LEFT_PAREN) {
        return _parseFunctionCall(idName);
      } else if (_peek().type == TokenType.DOT) {
        _consume();
        final columnToken = _peek();
        _expect(TokenType.IDENTIFIER, 'Expected column name after `.`');
        return QualifiedIdentifierExpression(
            table: idName, column: columnToken.value);
      }
      return IdentifierExpression(name: idName);
    } else if (token.type == TokenType.STRING ||
        token.type == TokenType.NUMBER) {
      return _parseLiteral();
    } else if (token.type == TokenType.LEFT_PAREN) {
        _consume();
        final expression = _parseLogicalExpression();
        _expect(TokenType.RIGHT_PAREN, 'Expected `)` after expression');
        return expression;
    }
    throw ParserException(
        'Expected identifier, literal, or function call but found: ${token.value}');
  }

  /// Parses a function call expression (e.g., `COUNT(*)` or `MAX(price)`).
  FunctionCallExpression _parseFunctionCall(String name) {
    _expect(TokenType.LEFT_PAREN, 'Expected `(` for function call arguments');
    final arguments = <Expression>[];
    if (_peek().type != TokenType.RIGHT_PAREN) {
      if (_peek().type == TokenType.ASTERISK) {
        arguments.add(IdentifierExpression(name: '*'));
        _consume();
      } else {
        // Function arguments can be full expressions
        arguments.add(_parseArithmeticExpression());
        while (_peek().type == TokenType.COMMA) {
          _consume();
          arguments.add(_parseArithmeticExpression());
        }
      }
    }
    _expect(
        TokenType.RIGHT_PAREN, 'Expected `)` after function call arguments');
    return FunctionCallExpression(name: name, arguments: arguments);
  }

  /// Parses an identifier (column or table name).
  IdentifierExpression _parseIdentifier() {
    final token = _peek();
    if (token.type == TokenType.IDENTIFIER) {
      _consume();
      return IdentifierExpression(name: token.value);
    }
    throw ParserException('Expected identifier but found: ${token.value}');
  }

  /// Parses a literal value (string or number).
  LiteralExpression _parseLiteral() {
    final token = _peek();
    if (token.type == TokenType.STRING) {
      _consume();
      return LiteralExpression(value: token.value);
    }
    if (token.type == TokenType.NUMBER) {
      _consume();
      if (token.value.contains('.')) {
        return LiteralExpression(value: double.parse(token.value));
      }
      return LiteralExpression(value: int.parse(token.value));
    }
    throw ParserException(
        'Expected string or number literal but found: ${token.value}');
  }
}

// =============================================================================
// Main function for demonstration
// =============================================================================
void main() {
  final sqlQueries = [
    // SELECT statements with arithmetic expressions
    "SELECT DISTINCT name, salary * 1.1 AS new_salary, 'hello' FROM users WHERE (age > 25 AND salary > 50000) OR salary * 1.2 > 60000;",
    "SELECT (price * 1.1) + tax FROM products;",
    "SELECT category, COUNT(*) FROM products GROUP BY category HAVING AVG(price) > 100;",
    "SELECT MIN(price), MAX(price), AVG(price) FROM products WHERE category = 'electronics' AND price > 100 / 2;",
    "SELECT id, name FROM users WHERE id IN (1, 2, 5, 8) AND name <> 'John';",
    "SELECT * FROM orders INNER JOIN customers ON orders.customer_id = customers.id;",
    "SELECT name FROM products WHERE price BETWEEN 10.5 * 10 AND 99.99;",
    "SELECT name FROM products WHERE price IS NOT NULL ORDER BY price DESC;",
    "SELECT id, name FROM users LEFT JOIN orders ON users.id = orders.user_id;",
    "SELECT COUNT(*) FROM users; -- This is a comment",
    "SELECT /* count all users */ COUNT(*) FROM users;",

    // UPDATE, INSERT, DELETE statements
    "INSERT INTO users (name, email) VALUES ('Jane Doe', 'jane@example.com');",
    "UPDATE products SET price = price * 1.1, name = 'New Name' WHERE id = 1;",
    "DELETE FROM users WHERE last_login < '2023-01-01';",
  ];

  for (final query in sqlQueries) {
    try {
      final lexer = Lexer(query);
      final tokens = lexer.tokenize();
      final parser = Parser(tokens);
      final statement = parser.parse();
      print('--- Query: $query');
      print('--- Parsed AST: ${statement.toString()}');
    } on ParserException catch (e) {
      print('--- Query: $query');
      print('--- ERROR: ${e.message}');
    }
    print('');
  }
}