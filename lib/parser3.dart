import 'dart:io';

// =============================================================================
// AST (Abstract Syntax Tree) Nodes
// These classes represent the structured output of the parser.
// =============================================================================

/// Base class for all SQL statements.
abstract class SqlStatement {}

/// The root node of a parsed SELECT statement.
class SelectStatement implements SqlStatement {
  final List<dynamic> columns;
  final TableExpression fromClause;
  final WhereClause? whereClause;
  final GroupByClause? groupByClause;
  final OrderByClause? orderByClause;
  final LimitClause? limitClause;

  SelectStatement({
    required this.columns,
    required this.fromClause,
    this.whereClause,
    this.groupByClause,
    this.orderByClause,
    this.limitClause,
  });

  @override
  String toString() {
    final cols = columns.map((c) => c.toString()).join(', ');
    final from = 'FROM ${fromClause.toString()}';
    final where = whereClause != null ? ' WHERE ${whereClause.toString()}' : '';
    final groupBy = groupByClause != null ? ' ${groupByClause.toString()}' : '';
    final orderBy = orderByClause != null ? ' ${orderByClause.toString()}' : '';
    final limit = limitClause != null ? ' ${limitClause.toString()}' : '';
    return 'SELECT $cols $from$where$groupBy$orderBy$limit';
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

/// Represents a function call (e.g., `COUNT(*)`).
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
  KEYWORD_ORDER,
  KEYWORD_ASC,
  KEYWORD_DESC,
  KEYWORD_LIMIT,

  // Literals
  IDENTIFIER,
  STRING,
  NUMBER,
  ASTERISK,

  // Symbols
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

/// Converts a string to its corresponding keyword token type.
TokenType _getTokenType(String value) {
  switch (value.toUpperCase()) {
    case 'SELECT':
      return TokenType.KEYWORD_SELECT;
    case 'FROM':
      return TokenType.KEYWORD_FROM;
    case 'WHERE':
      return TokenType.KEYWORD_WHERE;
    case 'AND':
      return TokenType.KEYWORD_AND;
    case 'OR':
      return TokenType.KEYWORD_OR;
    case 'INSERT':
      return TokenType.KEYWORD_INSERT;
    case 'INTO':
      return TokenType.KEYWORD_INTO;
    case 'VALUES':
      return TokenType.KEYWORD_VALUES;
    case 'UPDATE':
      return TokenType.KEYWORD_UPDATE;
    case 'SET':
      return TokenType.KEYWORD_SET;
    case 'DELETE':
      return TokenType.KEYWORD_DELETE;
    case 'JOIN':
      return TokenType.KEYWORD_JOIN;
    case 'ON':
      return TokenType.KEYWORD_ON;
    case 'GROUP':
      return TokenType.KEYWORD_GROUP;
    case 'BY':
      return TokenType.KEYWORD_BY;
    case 'ORDER':
      return TokenType.KEYWORD_ORDER;
    case 'ASC':
      return TokenType.KEYWORD_ASC;
    case 'DESC':
      return TokenType.KEYWORD_DESC;
    case 'LIMIT':
      return TokenType.KEYWORD_LIMIT;
    default:
      return TokenType.IDENTIFIER;
  }
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

      if (char == '*') {
        tokens.add(Token(TokenType.ASTERISK, char));
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
        tokens.add(Token(TokenType.LESS_THAN, char));
        _position++;
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

      if (RegExp(r'[0-9]').hasMatch(char)) {
        tokens.add(_readNumber());
        continue;
      }

      if (RegExp(r'[a-zA-Z_]').hasMatch(char)) {
        tokens.add(_readIdentifier());
        continue;
      }

      throw ParserException('Unexpected character: $char');
    }
    tokens.add(Token(TokenType.EOF, ''));
    return tokens;
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

  /// Helper to read a numeric literal.
  Token _readNumber() {
    final start = _position;
    while (_position < _input.length &&
        RegExp(r'[0-9]').hasMatch(_input[_position])) {
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
    final columns = _parseSelectClause();
    final fromClause = _parseFromClause();
    final whereClause =
        _peek().type == TokenType.KEYWORD_WHERE ? _parseWhereClause() : null;
    final groupByClause =
        _peek().type == TokenType.KEYWORD_GROUP ? _parseGroupByClause() : null;
    final orderByClause =
        _peek().type == TokenType.KEYWORD_ORDER ? _parseOrderByClause() : null;
    final limitClause =
        _peek().type == TokenType.KEYWORD_LIMIT ? _parseLimitClause() : null;

    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }

    // The correct check is to make sure nothing is left after the semicolon, except the EOF token.
    if (_peek().type != TokenType.EOF) {
      throw ParserException('Expected end of statement.');
    }

    return SelectStatement(
      columns: columns,
      fromClause: fromClause,
      whereClause: whereClause,
      groupByClause: groupByClause,
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

    // The correct check is to make sure nothing is left after the semicolon, except the EOF token.
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
    final value = _parsePrimaryExpression();
    return Assignment(column: column, value: value);
  }

  /// Parses the SELECT clause and column list.
  List<dynamic> _parseSelectClause() {
    _expect(TokenType.KEYWORD_SELECT, 'Expected SELECT keyword');
    final columns = <dynamic>[];
    if (_peek().type == TokenType.ASTERISK) {
      columns.add('*');
      _consume();
    } else {
      columns.add(_parsePrimaryExpression());
      while (_peek().type == TokenType.COMMA) {
        _consume();
        columns.add(_parsePrimaryExpression());
      }
    }
    return columns;
  }

  /// Parses the FROM clause, including optional JOINs.
  TableExpression _parseFromClause() {
    _expect(TokenType.KEYWORD_FROM, 'Expected FROM keyword');
    final tableName = _parseIdentifier().name;
    JoinClause? joinClause;
    if (_peek().type == TokenType.KEYWORD_JOIN) {
      joinClause = _parseJoinClause();
    }
    return TableExpression(tableName: tableName, joinClause: joinClause);
  }

  /// Parses a JOIN clause.
  JoinClause _parseJoinClause() {
    _expect(TokenType.KEYWORD_JOIN, 'Expected JOIN keyword');
    final joinTable = _parseIdentifier().name;
    _expect(TokenType.KEYWORD_ON, 'Expected ON keyword');
    final onExpression = _parseExpression();
    return JoinClause(
        joinType: 'INNER', joinTable: joinTable, onExpression: onExpression);
  }

  /// Parses the WHERE clause.
  WhereClause _parseWhereClause() {
    _expect(TokenType.KEYWORD_WHERE, 'Expected WHERE keyword');
    return WhereClause(expression: _parseExpression());
  }

  /// Parses the GROUP BY clause.
  GroupByClause _parseGroupByClause() {
    _expect(TokenType.KEYWORD_GROUP, 'Expected GROUP keyword');
    _expect(TokenType.KEYWORD_BY, 'Expected BY keyword');
    final columns = <Expression>[];
    columns.add(_parsePrimaryExpression());
    while (_peek().type == TokenType.COMMA) {
      _consume();
      columns.add(_parsePrimaryExpression());
    }
    return GroupByClause(columns: columns);
  }

  /// Parses the ORDER BY clause.
  OrderByClause _parseOrderByClause() {
    _expect(TokenType.KEYWORD_ORDER, 'Expected ORDER keyword');
    _expect(TokenType.KEYWORD_BY, 'Expected BY keyword');
    final column = _parsePrimaryExpression();
    String direction = 'ASC';
    if (_peek().type == TokenType.KEYWORD_ASC) {
      _consume();
    } else if (_peek().type == TokenType.KEYWORD_DESC) {
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

  /// Parses a boolean expression (e.g., `a > 10 AND b = 'test'`).
  Expression _parseExpression() {
    var left = _parseComparison();
    while (_peek().type == TokenType.KEYWORD_AND ||
        _peek().type == TokenType.KEYWORD_OR) {
      final op = _consume().value;
      final right = _parseComparison();
      left = BinaryExpression(left: left, right: right, op: op);
    }
    return left;
  }

  /// Parses a comparison expression (e.g., `column = value`).
  Expression _parseComparison() {
    final left = _parsePrimaryExpression();
    final opToken = _peek();

    // Check for a comparison operator
    if ([TokenType.EQUALS, TokenType.GREATER_THAN, TokenType.LESS_THAN]
        .contains(opToken.type)) {
      final op = _consume().value;
      final right = _parsePrimaryExpression();
      return BinaryExpression(left: left, right: right, op: op);
    }

    return left; // No comparison, just an identifier.
  }

  /// Parses a primary expression, which can be an identifier, literal, or function call.
  Expression _parsePrimaryExpression() {
    final token = _peek();
    if (token.type == TokenType.IDENTIFIER) {
      _consume();
      // Check for a function call like `COUNT(*)` or qualified identifier `table.column`
      if (_peek().type == TokenType.LEFT_PAREN) {
        return _parseFunctionCall(token.value);
      } else if (_peek().type == TokenType.DOT) {
        _consume(); // Consumes the dot
        final columnToken = _peek();
        _expect(TokenType.IDENTIFIER, 'Expected column name after `.`');
        return QualifiedIdentifierExpression(
            table: token.value, column: columnToken.value);
      }
      return IdentifierExpression(name: token.value);
    } else if (token.type == TokenType.STRING ||
        token.type == TokenType.NUMBER) {
      return _parseLiteral();
    } else if (token.type == TokenType.ASTERISK) {
      _consume();
      return IdentifierExpression(name: '*');
    }
    throw ParserException(
        'Expected identifier, literal, or function call but found: ${token.value}');
  }

  /// Parses a function call expression (e.g., `COUNT(*)`).
  FunctionCallExpression _parseFunctionCall(String name) {
    _expect(TokenType.LEFT_PAREN, 'Expected `(` for function call arguments');
    final arguments = <Expression>[];
    if (_peek().type != TokenType.RIGHT_PAREN) {
      if (_peek().type == TokenType.ASTERISK) {
        arguments.add(IdentifierExpression(name: '*'));
        _consume();
      } else {
        arguments.add(_parseExpression());
        while (_peek().type == TokenType.COMMA) {
          _consume();
          arguments.add(_parseExpression());
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
      return LiteralExpression(
          value: int.tryParse(token.value) ?? double.parse(token.value));
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
    "SELECT id, name FROM users WHERE id > 10 AND status = 'active';",
    "SELECT * FROM orders JOIN products ON orders.product_id = products.id;",
    "SELECT category, COUNT(*) FROM products GROUP BY category ORDER BY COUNT(*) DESC LIMIT 5;",
    "INSERT INTO users (id, name, email) VALUES (1, 'Alice', 'alice@example.com');",
    "UPDATE users SET status = 'inactive', last_login = NOW() WHERE id = 100;",
    "DELETE FROM users WHERE status = 'inactive' AND id < 50;"
  ];

  for (final query in sqlQueries) {
    try {
      print('Parsing SQL: $query');
      final lexer = Lexer(query);
      final tokens = lexer.tokenize();
      print('Tokens:');
      tokens.forEach(print);
      print('---');

      final parser = Parser(tokens);
      final ast = parser.parse();

      print('Parsed Abstract Syntax Tree:');
      print(ast);
      print('====================================\n');
    } catch (e, stacktrace) {
      print('Error parsing SQL: $e');
      print('Stack Trace: $stacktrace');
      print('====================================\n');
    }
  }
}
