import 'dart:io';

// =============================================================================
// AST (Abstract Syntax Tree) Nodes
// These classes represent the structured output of the parser.
// =============================================================================

/// The root node of a parsed SELECT statement.
class SelectStatement {
  final List<dynamic> columns;
  final String tableName;
  final WhereClause? whereClause;

  SelectStatement(
      {required this.columns, required this.tableName, this.whereClause});

  @override
  String toString() {
    final cols = columns.map((c) => c is String ? c : c.toString()).join(', ');
    final where = whereClause != null ? ' WHERE ${whereClause.toString()}' : '';
    return 'SELECT $cols FROM $tableName$where';
  }
}

/// Represents the WHERE clause of a statement.
class WhereClause {
  final Expression expression;

  WhereClause({required this.expression});

  @override
  String toString() => expression.toString();
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

  // Literals
  IDENTIFIER,
  STRING,
  NUMBER,
  ASTERISK,

  // Symbols
  LEFT_PAREN,
  RIGHT_PAREN,
  COMMA,
  EQUALS,
  GREATER_THAN,
  LESS_THAN,
  NOT_EQUALS,
  SEMICOLON, // Added new token type for semicolon

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
        // Added rule to handle semicolon
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
  SelectStatement parse() {
    return _parseSelectStatement();
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
    final tableName = _parseFromClause();
    final whereClause =
        _peek().type == TokenType.KEYWORD_WHERE ? _parseWhereClause() : null;
    if (_peek().type == TokenType.SEMICOLON) {
      // Consume the semicolon if it exists
      _consume();
    }
    _expect(TokenType.EOF, 'Expected end of statement.');
    return SelectStatement(
        columns: columns, tableName: tableName, whereClause: whereClause);
  }

  /// Parses the SELECT clause and column list.
  List<dynamic> _parseSelectClause() {
    _expect(TokenType.KEYWORD_SELECT, 'Expected SELECT keyword');
    final columns = <dynamic>[];
    if (_peek().type == TokenType.ASTERISK) {
      columns.add('*');
      _consume();
    } else {
      columns.add(_parseIdentifier().name);
      while (_peek().type == TokenType.COMMA) {
        _consume();
        columns.add(_parseIdentifier().name);
      }
    }
    return columns;
  }

  /// Parses the FROM clause.
  String _parseFromClause() {
    _expect(TokenType.KEYWORD_FROM, 'Expected FROM keyword');
    return _parseIdentifier().name;
  }

  /// Parses the WHERE clause.
  WhereClause _parseWhereClause() {
    _expect(TokenType.KEYWORD_WHERE, 'Expected WHERE keyword');
    return WhereClause(expression: _parseExpression());
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
    final left = _parseIdentifier();
    final opToken = _peek();

    // Check for a comparison operator
    if ([TokenType.EQUALS, TokenType.GREATER_THAN, TokenType.LESS_THAN]
        .contains(opToken.type)) {
      final op = _consume().value;
      final right = _parseLiteral();
      return BinaryExpression(left: left, right: right, op: op);
    }

    return left; // No comparison, just an identifier.
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
  final sqlQuery =
      "SELECT id, name FROM users WHERE id > 10 AND status = 'active';";

  try {
    final lexer = Lexer(sqlQuery);
    final tokens = lexer.tokenize();
    print('Tokens:');
    tokens.forEach(print);
    print('---');

    final parser = Parser(tokens);
    final ast = parser.parse();

    print('Parsed Abstract Syntax Tree:');
    print(ast); // Prints the structured representation
    print('Columns: ${ast.columns.join(', ')}');
    print('Table: ${ast.tableName}');
    print('WHERE clause: ${ast.whereClause}');
  } catch (e) {
    print('Error parsing SQL: $e');
  }
}
