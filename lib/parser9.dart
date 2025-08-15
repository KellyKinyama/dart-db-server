// The main function where the parser is tested with various queries.
import 'dart:io';

// --- Tokenization ---

// Represents the types of tokens in the SQL language.
enum TokenType {
  // Keywords
  KEYWORD_SELECT,
  KEYWORD_FROM,
  KEYWORD_WHERE,
  KEYWORD_AND,
  KEYWORD_OR,
  KEYWORD_GROUP,
  KEYWORD_BY,
  KEYWORD_HAVING,
  KEYWORD_DISTINCT,
  KEYWORD_AS,
  KEYWORD_ORDER,
  KEYWORD_DESC,
  KEYWORD_ASC,
  KEYWORD_NULL,
  KEYWORD_IS,
  KEYWORD_NOT,
  KEYWORD_IN,
  KEYWORD_BETWEEN,
  KEYWORD_INSERT,
  KEYWORD_INTO,
  KEYWORD_VALUES,
  KEYWORD_UPDATE,
  KEYWORD_SET,
  KEYWORD_DELETE,
  KEYWORD_JOIN,
  KEYWORD_ON,
  KEYWORD_INNER,
  KEYWORD_LEFT,
  KEYWORD_RIGHT,
  KEYWORD_OUTER,
  KEYWORD_CREATE,
  KEYWORD_TABLE,
  KEYWORD_PRIMARY,
  KEYWORD_KEY,
  KEYWORD_FOREIGN,
  KEYWORD_REFERENCES,
  KEYWORD_UNIQUE,
  KEYWORD_CHECK,
  KEYWORD_DEFAULT,
  KEYWORD_TEXT,
  KEYWORD_INTEGER,
  KEYWORD_REAL,
  KEYWORD_VARCHAR,
  KEYWORD_CASCADE,
  KEYWORD_RESTRICT,
  KEYWORD_NULL_KEYWORD,

  // Literals and identifiers
  IDENTIFIER,
  NUMBER,
  STRING,

  // Operators and punctuation
  OPERATOR_PLUS,
  OPERATOR_MINUS,
  OPERATOR_MULTIPLY,
  OPERATOR_DIVIDE,
  OPERATOR_EQUAL,
  OPERATOR_NOT_EQUAL,
  OPERATOR_LESS_THAN,
  OPERATOR_GREATER_THAN,
  OPERATOR_LESS_THAN_OR_EQUAL,
  OPERATOR_GREATER_THAN_OR_EQUAL,
  OPERATOR_LIKE,
  OPERATOR_GLOB,

  LPAREN,
  RPAREN,
  COMMA,
  SEMICOLON,
  DOT,

  // Special
  EOF,
}

// Maps lowercase keyword strings to their TokenType.
const Map<String, TokenType> _keywordMap = {
  'select': TokenType.KEYWORD_SELECT,
  'from': TokenType.KEYWORD_FROM,
  'where': TokenType.KEYWORD_WHERE,
  'and': TokenType.KEYWORD_AND,
  'or': TokenType.KEYWORD_OR,
  'group': TokenType.KEYWORD_GROUP,
  'by': TokenType.KEYWORD_BY,
  'having': TokenType.KEYWORD_HAVING,
  'distinct': TokenType.KEYWORD_DISTINCT,
  'as': TokenType.KEYWORD_AS,
  'order': TokenType.KEYWORD_ORDER,
  'desc': TokenType.KEYWORD_DESC,
  'asc': TokenType.KEYWORD_ASC,
  'null': TokenType.KEYWORD_NULL_KEYWORD,
  'is': TokenType.KEYWORD_IS,
  'not': TokenType.KEYWORD_NOT,
  'in': TokenType.KEYWORD_IN,
  'between': TokenType.KEYWORD_BETWEEN,
  'insert': TokenType.KEYWORD_INSERT,
  'into': TokenType.KEYWORD_INTO,
  'values': TokenType.KEYWORD_VALUES,
  'update': TokenType.KEYWORD_UPDATE,
  'set': TokenType.KEYWORD_SET,
  'delete': TokenType.KEYWORD_DELETE,
  'join': TokenType.KEYWORD_JOIN,
  'on': TokenType.KEYWORD_ON,
  'inner': TokenType.KEYWORD_INNER,
  'left': TokenType.KEYWORD_LEFT,
  'right': TokenType.KEYWORD_RIGHT,
  'outer': TokenType.KEYWORD_OUTER,
  'create': TokenType.KEYWORD_CREATE,
  'table': TokenType.KEYWORD_TABLE,
  'primary': TokenType.KEYWORD_PRIMARY,
  'key': TokenType.KEYWORD_KEY,
  'foreign': TokenType.KEYWORD_FOREIGN,
  'references': TokenType.KEYWORD_REFERENCES,
  'unique': TokenType.KEYWORD_UNIQUE,
  'check': TokenType.KEYWORD_CHECK,
  'default': TokenType.KEYWORD_DEFAULT,
  'text': TokenType.KEYWORD_TEXT,
  'integer': TokenType.KEYWORD_INTEGER,
  'real': TokenType.KEYWORD_REAL,
  'varchar': TokenType.KEYWORD_VARCHAR,
  'cascade': TokenType.KEYWORD_CASCADE,
  'restrict': TokenType.KEYWORD_RESTRICT,
};

// Represents a single token with its type and value.
class Token {
  final TokenType type;
  final String value;
  final int offset;

  Token(this.type, this.value, this.offset);

  @override
  String toString() {
    return 'Token(${type.toString().split('.').last}, "$value", offset: $offset)';
  }
}

// The Lexer (or Tokenizer) class converts a SQL query string into a sequence of tokens.
class Lexer {
  final String _input;
  int _position = 0;
  List<Token> _tokens = [];

  Lexer(this._input) {
    _tokenize();
  }

  List<Token> get tokens => _tokens;

  // Tokenizes the entire input string.
  void _tokenize() {
    while (_position < _input.length) {
      final char = _input[_position];

      if (char.trim().isEmpty) {
        _position++;
        continue;
      }

      if (char == '/' &&
          _position + 1 < _input.length &&
          _input[_position + 1] == '*') {
        _skipMultiLineComment();
        continue;
      }
      if (char == '-' &&
          _position + 1 < _input.length &&
          _input[_position + 1] == '-') {
        _skipSingleLineComment();
        continue;
      }

      if (_isPunctuation(char)) {
        _addPunctuationToken(char);
      } else if (_isDigit(char) ||
          (char == '-' &&
              _position + 1 < _input.length &&
              _isDigit(_input[_position + 1]))) {
        _addNumberToken();
      } else if (char == "'" || char == '"') {
        _addStringToken(char);
      } else {
        _addIdentifierOrKeywordToken();
      }
    }
    _tokens.add(Token(TokenType.EOF, '', _input.length));
  }

  // Skips a multi-line comment.
  void _skipMultiLineComment() {
    final start = _position;
    _position += 2; // Skip '/*'
    while (_position + 1 < _input.length &&
        (_input[_position] != '*' || _input[_position + 1] != '/')) {
      _position++;
    }
    if (_position + 1 < _input.length) {
      _position += 2; // Skip '*/'
    } else {
      // Handle unterminated comment
      _position = _input.length;
    }
  }

  // Skips a single-line comment.
  void _skipSingleLineComment() {
    while (_position < _input.length && _input[_position] != '\n') {
      _position++;
    }
  }

  // Checks if a character is a digit.
  bool _isDigit(String char) {
    return char.compareTo('0') >= 0 && char.compareTo('9') <= 0;
  }

  // Checks if a character is a letter or underscore.
  bool _isAlpha(String char) {
    return (char.toLowerCase().compareTo('a') >= 0 &&
            char.toLowerCase().compareTo('z') <= 0) ||
        char == '_';
  }

  // Checks if a character is a punctuation symbol.
  bool _isPunctuation(String char) {
    return ['(', ')', ',', ';', '*', '/', '+', '-', '=', '<', '>', '.', '!']
        .contains(char);
  }

  // Adds a punctuation token.
  void _addPunctuationToken(String char) {
    final start = _position;
    String value = char;
    TokenType type;

    // Handle two-character operators like '<=' or '>='
    if ((char == '<' || char == '>') &&
        _position + 1 < _input.length &&
        _input[_position + 1] == '=') {
      value += '=';
      _position++;
    } else if (char == '!' &&
        _position + 1 < _input.length &&
        _input[_position + 1] == '=') {
      value += '=';
      _position++;
    }

    switch (value) {
      case '+':
        type = TokenType.OPERATOR_PLUS;
        break;
      case '-':
        type = TokenType.OPERATOR_MINUS;
        break;
      case '*':
        type = TokenType.OPERATOR_MULTIPLY;
        break;
      case '/':
        type = TokenType.OPERATOR_DIVIDE;
        break;
      case '=':
        type = TokenType.OPERATOR_EQUAL;
        break;
      case '<':
        type = TokenType.OPERATOR_LESS_THAN;
        break;
      case '>':
        type = TokenType.OPERATOR_GREATER_THAN;
        break;
      case '<=':
        type = TokenType.OPERATOR_LESS_THAN_OR_EQUAL;
        break;
      case '>=':
        type = TokenType.OPERATOR_GREATER_THAN_OR_EQUAL;
        break;
      case '!=':
        type = TokenType.OPERATOR_NOT_EQUAL;
        break;
      case '(':
        type = TokenType.LPAREN;
        break;
      case ')':
        type = TokenType.RPAREN;
        break;
      case ',':
        type = TokenType.COMMA;
        break;
      case ';':
        type = TokenType.SEMICOLON;
        break;
      case '.':
        type = TokenType.DOT;
        break;
      default:
        throw Exception('Unknown operator: $value');
    }
    _tokens.add(Token(type, value, start));
    _position++;
  }

  // Adds a number token.
  void _addNumberToken() {
    final start = _position;
    // Handle optional negative sign
    if (_input[start] == '-') {
      _position++;
    }

    while (_position < _input.length && _isDigit(_input[_position])) {
      _position++;
    }
    if (_position < _input.length && _input[_position] == '.') {
      _position++;
      while (_position < _input.length && _isDigit(_input[_position])) {
        _position++;
      }
    }
    final value = _input.substring(start, _position);
    _tokens.add(Token(TokenType.NUMBER, value, start));
  }

  // Adds a string token.
  void _addStringToken(String quoteChar) {
    final start = _position;
    _position++;
    while (_position < _input.length && _input[_position] != quoteChar) {
      _position++;
    }
    if (_position < _input.length) {
      _position++; // Skip the closing quote
    }
    final value = _input.substring(start + 1, _position - 1);
    _tokens.add(Token(TokenType.STRING, value, start));
  }

  // Adds an identifier or keyword token.
  void _addIdentifierOrKeywordToken() {
    final start = _position;
    while (_position < _input.length &&
        (_isAlpha(_input[_position]) || _isDigit(_input[_position]))) {
      _position++;
    }
    final value = _input.substring(start, _position);
    final type = _keywordMap[value.toLowerCase()] ?? TokenType.IDENTIFIER;
    _tokens.add(Token(type, value, start));
  }
}

// --- AST (Abstract Syntax Tree) Nodes ---

// Represents an expression in the SQL query.
abstract class Expression {
  String toAstString();
}

// Represents a binary operation like `a + b` or `a > b`.
class BinaryExpression implements Expression {
  final Expression left;
  final String operator;
  final Expression right;

  BinaryExpression(this.left, this.operator, this.right);

  @override
  String toAstString() {
    return '(${left.toAstString()} $operator ${right.toAstString()})';
  }
}

// Represents a literal value like a string or number.
class LiteralExpression implements Expression {
  final String value;
  final String type; // 'number' or 'string'

  LiteralExpression(this.value, this.type);

  @override
  String toAstString() {
    if (type == 'string') {
      return "'$value'";
    }
    return value;
  }
}

// Represents an identifier, typically a column or table name.
class IdentifierExpression implements Expression {
  final String name;

  IdentifierExpression(this.name);

  @override
  String toAstString() {
    return name;
  }
}

// Represents a function call like `COUNT(*)` or `AVG(price)`.
class FunctionExpression implements Expression {
  final String name;
  final Expression argument;

  FunctionExpression(this.name, this.argument);

  @override
  String toAstString() {
    return '$name(${argument.toAstString()})';
  }
}

// Represents an `IN` clause.
class InExpression implements Expression {
  final Expression left;
  final bool not;
  final List<Expression> values;

  InExpression(this.left, this.not, this.values);

  @override
  String toAstString() {
    final notString = not ? ' NOT' : '';
    return '${left.toAstString()} IN$notString (${values.map((v) => v.toAstString()).join(', ')})';
  }
}

// Represents a `BETWEEN` clause.
class BetweenExpression implements Expression {
  final Expression left;
  final Expression start;
  final Expression end;

  BetweenExpression(this.left, this.start, this.end);

  @override
  String toAstString() {
    return '(${left.toAstString()} BETWEEN ${start.toAstString()} AND ${end.toAstString()})';
  }
}

// Represents an `IS NULL` or `IS NOT NULL` clause.
class IsNullExpression implements Expression {
  final Expression left;
  final bool not;

  IsNullExpression(this.left, this.not);

  @override
  String toAstString() {
    final notString = not ? ' NOT' : '';
    return '(${left.toAstString()} IS$notString NULL)';
  }
}

// Represents a `SELECT` statement.
class SelectStatement {
  final bool isDistinct;
  final List<Expression> columns;
  final String? fromTable;
  final List<JoinClause> joins;
  final Expression? whereClause;
  final Expression? groupByClause;
  final Expression? havingClause;
  final Expression? orderByClause;

  SelectStatement({
    this.isDistinct = false,
    required this.columns,
    this.fromTable,
    this.joins = const [],
    this.whereClause,
    this.groupByClause,
    this.havingClause,
    this.orderByClause,
  });

  String toAstString() {
    final distinct = isDistinct ? 'DISTINCT ' : '';
    final columnsStr = columns.map((e) => e.toAstString()).join(', ');
    final fromStr = fromTable != null ? ' FROM $fromTable' : '';
    final joinsStr = joins.map((j) => j.toAstString()).join(' ');
    final whereStr =
        whereClause != null ? ' WHERE ${whereClause!.toAstString()}' : '';
    final groupByStr = groupByClause != null
        ? ' GROUP BY ${groupByClause!.toAstString()}'
        : '';
    final havingStr =
        havingClause != null ? ' HAVING ${havingClause!.toAstString()}' : '';
    final orderByStr = orderByClause != null
        ? ' ORDER BY ${orderByClause!.toAstString()}'
        : '';

    return 'SELECT $distinct$columnsStr$fromStr$joinsStr$whereStr$groupByStr$havingStr$orderByStr';
  }
}

// Represents a join clause.
class JoinClause {
  final String joinType;
  final String table;
  final Expression onClause;

  JoinClause(this.joinType, this.table, this.onClause);

  String toAstString() {
    return '$joinType JOIN $table ON ${onClause.toAstString()}';
  }
}

// Represents an `AS` alias.
class AliasExpression implements Expression {
  final Expression expression;
  final String alias;

  AliasExpression(this.expression, this.alias);

  @override
  String toAstString() {
    return '${expression.toAstString()} AS $alias';
  }
}

// Represents an `INSERT` statement.
class InsertStatement {
  final String table;
  final List<String> columns;
  final List<List<Expression>> values;

  InsertStatement({
    required this.table,
    required this.columns,
    required this.values,
  });

  String toAstString() {
    final colsStr = columns.join(', ');
    final valuesStr = values
        .map((row) => '(${row.map((e) => e.toAstString()).join(', ')})')
        .join(', ');
    return 'INSERT INTO $table ($colsStr) VALUES $valuesStr';
  }
}

// Represents an `UPDATE` statement.
class UpdateStatement {
  final String table;
  final List<Expression> setClauses;
  final Expression? whereClause;

  UpdateStatement({
    required this.table,
    required this.setClauses,
    this.whereClause,
  });

  String toAstString() {
    final setStr = setClauses.map((e) => e.toAstString()).join(', ');
    final whereStr =
        whereClause != null ? ' WHERE ${whereClause!.toAstString()}' : '';
    return 'UPDATE $table SET $setStr$whereStr';
  }
}

// Represents a `DELETE` statement.
class DeleteStatement {
  final String table;
  final Expression? whereClause;

  DeleteStatement({
    required this.table,
    this.whereClause,
  });

  String toAstString() {
    final whereStr =
        whereClause != null ? ' WHERE ${whereClause!.toAstString()}' : '';
    return 'DELETE FROM $table$whereStr';
  }
}

// Represents a `CREATE TABLE` statement.
class CreateTableStatement {
  final String table;
  final List<ColumnDefinition> columns;
  final List<TableConstraint> constraints;

  CreateTableStatement({
    required this.table,
    required this.columns,
    required this.constraints,
  });

  String toAstString() {
    final columnsStr = columns.map((c) => c.toAstString()).join(', ');
    final constraintsStr = constraints.map((c) => c.toAstString()).join(', ');
    final body =
        [columnsStr, constraintsStr].where((s) => s.isNotEmpty).join(', ');
    return 'CREATE TABLE $table ($body)';
  }
}

// Represents a column definition in a `CREATE TABLE` statement.
class ColumnDefinition {
  final String name;
  final String dataType;
  final List<String> constraints;
  final Expression? defaultValue;

  ColumnDefinition(
    this.name,
    this.dataType, {
    this.constraints = const [],
    this.defaultValue,
  });

  String toAstString() {
    String constraintStr = constraints.join(' ');
    String defaultStr =
        defaultValue != null ? " DEFAULT ${defaultValue!.toAstString()}" : "";
    return '$name $dataType $constraintStr$defaultStr'.trim();
  }
}

// Represents a table constraint.
class TableConstraint {
  final String type;
  final List<String> columns;
  final String? referencedTable;
  final List<String>? referencedColumns;
  final String? onDelete;
  final String? onUpdate;

  TableConstraint({
    required this.type,
    required this.columns,
    this.referencedTable,
    this.referencedColumns,
    this.onDelete,
    this.onUpdate,
  });

  String toAstString() {
    final cols = columns.join(', ');
    switch (type) {
      case 'PRIMARY KEY':
        return 'PRIMARY KEY ($cols)';
      case 'FOREIGN KEY':
        final onDel = onDelete != null ? ' ON DELETE $onDelete' : '';
        final onUpd = onUpdate != null ? ' ON UPDATE $onUpdate' : '';
        return 'FOREIGN KEY ($cols) REFERENCES $referencedTable (${referencedColumns!.join(', ')})'
            '$onDel$onUpd';
      case 'UNIQUE':
        return 'UNIQUE ($cols)';
      default:
        return '';
    }
  }
}

// --- Parser ---

// The Parser class builds an AST from a sequence of tokens.
class Parser {
  final List<Token> _tokens;
  int _position = 0;

  Parser(this._tokens);

  Token _peek([int offset = 0]) {
    final newPosition = _position + offset;
    if (newPosition < _tokens.length) {
      return _tokens[newPosition];
    }
    return _tokens.last;
  }

  Token _consume() {
    if (_position < _tokens.length) {
      return _tokens[_position++];
    }
    return _tokens.last;
  }

  Token _expect(TokenType type) {
    if (_peek().type != type) {
      throw Exception(
          'Expected ${type.toString().split('.').last} keyword, but got ${_peek().type.toString().split('.').last} at offset ${_peek().offset}');
    }
    return _consume();
  }

  dynamic parse() {
    final token = _peek();
    switch (token.type) {
      case TokenType.KEYWORD_SELECT:
        return _parseSelectStatement();
      case TokenType.KEYWORD_INSERT:
        return _parseInsertStatement();
      case TokenType.KEYWORD_UPDATE:
        return _parseUpdateStatement();
      case TokenType.KEYWORD_DELETE:
        return _parseDeleteStatement();
      case TokenType.KEYWORD_CREATE:
        return _parseCreateStatement();
      default:
        throw Exception('Unexpected token: ${token.value}');
    }
  }

  // Parses a `CREATE` statement.
  dynamic _parseCreateStatement() {
    _expect(TokenType.KEYWORD_CREATE);
    _expect(TokenType.KEYWORD_TABLE);
    final tableName = _expect(TokenType.IDENTIFIER).value;
    _expect(TokenType.LPAREN);

    final columnDefinitions = <ColumnDefinition>[];
    final tableConstraints = <TableConstraint>[];

    if (_peek().type != TokenType.RPAREN) {
      while (true) {
        final token = _peek();
        if (token.type == TokenType.KEYWORD_PRIMARY ||
            token.type == TokenType.KEYWORD_FOREIGN ||
            token.type == TokenType.KEYWORD_UNIQUE) {
          tableConstraints.add(_parseTableConstraint());
        } else {
          columnDefinitions.add(_parseColumnDefinition());
        }

        if (_peek().type == TokenType.COMMA) {
          _consume();
          if (_peek().type == TokenType.RPAREN) {
            throw Exception('Trailing comma in CREATE TABLE statement');
          }
        } else {
          break;
        }
      }
    }

    _expect(TokenType.RPAREN);
    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }
    _expect(TokenType.EOF);

    return CreateTableStatement(
      table: tableName,
      columns: columnDefinitions,
      constraints: tableConstraints,
    );
  }

  // Parses a column definition.
  ColumnDefinition _parseColumnDefinition() {
    final columnName = _expect(TokenType.IDENTIFIER).value;
    final dataType = _parseDataType();
    final constraints = <String>[];
    Expression? defaultValue;

    while (_peek().type != TokenType.COMMA &&
        _peek().type != TokenType.RPAREN &&
        _peek().type != TokenType.EOF) {
      final token = _peek();
      switch (token.type) {
        case TokenType.KEYWORD_PRIMARY:
          _consume(); // PRIMARY
          _expect(TokenType.KEYWORD_KEY);
          constraints.add('PRIMARY KEY');
          break;
        case TokenType.KEYWORD_NOT:
          _consume(); // NOT
          _expect(TokenType.KEYWORD_NULL_KEYWORD);
          constraints.add('NOT NULL');
          break;
        case TokenType.KEYWORD_UNIQUE:
          _consume();
          constraints.add('UNIQUE');
          break;
        case TokenType.KEYWORD_DEFAULT:
          _consume();
          defaultValue = _parseExpression();
          break;
        default:
          // If it's not a constraint, we assume we're done with this column def.
          return ColumnDefinition(
            columnName,
            dataType,
            constraints: constraints,
            defaultValue: defaultValue,
          );
      }
    }

    return ColumnDefinition(
      columnName,
      dataType,
      constraints: constraints,
      defaultValue: defaultValue,
    );
  }

  // Parses a data type.
  String _parseDataType() {
    final typeToken = _consume();
    String result = typeToken.value.toUpperCase();

    final validDataTypes = [
      TokenType.KEYWORD_INTEGER,
      TokenType.KEYWORD_TEXT,
      TokenType.KEYWORD_REAL,
      TokenType.KEYWORD_VARCHAR
    ];

    if (!validDataTypes.contains(typeToken.type)) {
      throw Exception('Expected a data type, but got ${typeToken.type}');
    }

    if (typeToken.type == TokenType.KEYWORD_VARCHAR) {
      _expect(TokenType.LPAREN);
      result += '(${_expect(TokenType.NUMBER).value})';
      _expect(TokenType.RPAREN);
    }
    return result;
  }

  // Parses a table constraint.
  TableConstraint _parseTableConstraint() {
    final token = _peek();
    if (token.type == TokenType.KEYWORD_PRIMARY) {
      _consume();
      _expect(TokenType.KEYWORD_KEY);
      _expect(TokenType.LPAREN);
      final columns = [_expect(TokenType.IDENTIFIER).value];
      while (_peek().type == TokenType.COMMA) {
        _consume();
        columns.add(_expect(TokenType.IDENTIFIER).value);
      }
      _expect(TokenType.RPAREN);
      return TableConstraint(type: 'PRIMARY KEY', columns: columns);
    } else if (token.type == TokenType.KEYWORD_FOREIGN) {
      _consume();
      _expect(TokenType.KEYWORD_KEY);
      _expect(TokenType.LPAREN);
      final columns = [_expect(TokenType.IDENTIFIER).value];
      while (_peek().type == TokenType.COMMA) {
        _consume();
        columns.add(_expect(TokenType.IDENTIFIER).value);
      }
      _expect(TokenType.RPAREN);
      _expect(TokenType.KEYWORD_REFERENCES);
      final refTable = _expect(TokenType.IDENTIFIER).value;
      _expect(TokenType.LPAREN);
      final refCols = [_expect(TokenType.IDENTIFIER).value];
      while (_peek().type == TokenType.COMMA) {
        _consume();
        refCols.add(_expect(TokenType.IDENTIFIER).value);
      }
      _expect(TokenType.RPAREN);
      String? onDelete;
      String? onUpdate;
      while (_peek().type == TokenType.KEYWORD_ON) {
        _consume(); // consume ON
        if (_peek().type == TokenType.KEYWORD_DELETE) {
          _consume(); // consume DELETE
          onDelete = _peek().value.toUpperCase();
          _consume();
        } else if (_peek().type == TokenType.KEYWORD_UPDATE) {
          _consume(); // consume UPDATE
          onUpdate = _peek().value.toUpperCase();
          _consume();
        }
      }
      return TableConstraint(
        type: 'FOREIGN KEY',
        columns: columns,
        referencedTable: refTable,
        referencedColumns: refCols,
        onDelete: onDelete,
        onUpdate: onUpdate,
      );
    } else if (token.type == TokenType.KEYWORD_UNIQUE) {
      _consume();
      _expect(TokenType.LPAREN);
      final columns = [_expect(TokenType.IDENTIFIER).value];
      while (_peek().type == TokenType.COMMA) {
        _consume();
        columns.add(_expect(TokenType.IDENTIFIER).value);
      }
      _expect(TokenType.RPAREN);
      return TableConstraint(type: 'UNIQUE', columns: columns);
    }
    throw Exception('Unexpected token in table constraint: ${token.value}');
  }

  // Parses a `SELECT` statement.
  SelectStatement _parseSelectStatement() {
    _expect(TokenType.KEYWORD_SELECT);
    final isDistinct = _peek().type == TokenType.KEYWORD_DISTINCT;
    if (isDistinct) {
      _consume();
    }

    final columns = _parseSelectColumns();

    String? fromTable;
    if (_peek().type == TokenType.KEYWORD_FROM) {
      _consume();
      fromTable = _expect(TokenType.IDENTIFIER).value;
    }

    final joins = <JoinClause>[];
    while (_isJoinKeyword(_peek())) {
      joins.add(_parseJoinClause());
    }

    Expression? whereClause;
    if (_peek().type == TokenType.KEYWORD_WHERE) {
      _consume();
      whereClause = _parseExpression();
    }

    Expression? groupByClause;
    if (_peek().type == TokenType.KEYWORD_GROUP) {
      _consume();
      _expect(TokenType.KEYWORD_BY);
      groupByClause = _parseExpression();
    }

    Expression? havingClause;
    if (_peek().type == TokenType.KEYWORD_HAVING) {
      _consume();
      havingClause = _parseExpression();
    }

    Expression? orderByClause;
    if (_peek().type == TokenType.KEYWORD_ORDER) {
      _consume();
      _expect(TokenType.KEYWORD_BY);
      orderByClause = _parseOrderByClause();
    }

    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }
    _expect(TokenType.EOF);

    return SelectStatement(
      isDistinct: isDistinct,
      columns: columns,
      fromTable: fromTable,
      joins: joins,
      whereClause: whereClause,
      groupByClause: groupByClause,
      havingClause: havingClause,
      orderByClause: orderByClause,
    );
  }

  // Checks if the token is a join keyword.
  bool _isJoinKeyword(Token token) {
    return token.type == TokenType.KEYWORD_JOIN ||
        token.type == TokenType.KEYWORD_INNER ||
        token.type == TokenType.KEYWORD_LEFT ||
        token.type == TokenType.KEYWORD_RIGHT ||
        token.type == TokenType.KEYWORD_OUTER;
  }

  // Parses a join clause.
  JoinClause _parseJoinClause() {
    String joinType = '';
    final token = _peek();
    if (token.type == TokenType.KEYWORD_INNER ||
        token.type == TokenType.KEYWORD_LEFT ||
        token.type == TokenType.KEYWORD_RIGHT ||
        token.type == TokenType.KEYWORD_OUTER) {
      joinType = _consume().value.toUpperCase() + ' ';
    }
    _expect(TokenType.KEYWORD_JOIN);
    joinType += 'JOIN';
    final table = _expect(TokenType.IDENTIFIER).value;
    _expect(TokenType.KEYWORD_ON);
    final onClause = _parseExpression();
    return JoinClause(joinType, table, onClause);
  }

  // CORRECTED: Parses the columns in the `SELECT` clause.
  List<Expression> _parseSelectColumns() {
    final columns = <Expression>[];
    // Handle SELECT *
    if (_peek().type == TokenType.OPERATOR_MULTIPLY) {
      columns.add(IdentifierExpression(_consume().value));
      return columns;
    }

    while (_peek().type != TokenType.KEYWORD_FROM &&
        _peek().type != TokenType.EOF &&
        _peek().type != TokenType.SEMICOLON) {
      Expression expr = _parseExpression();
      if (_peek().type == TokenType.KEYWORD_AS) {
        _consume();
        final alias = _expect(TokenType.IDENTIFIER).value;
        expr = AliasExpression(expr, alias);
      }
      columns.add(expr);
      if (_peek().type == TokenType.COMMA) {
        _consume();
      } else {
        break;
      }
    }
    return columns;
  }

  // Parses the `ORDER BY` clause.
  Expression _parseOrderByClause() {
    final column = _parseExpression();
    if (_peek().type == TokenType.KEYWORD_DESC ||
        _peek().type == TokenType.KEYWORD_ASC) {
      final order = _consume().value.toUpperCase();
      return IdentifierExpression('${column.toAstString()} $order');
    }
    return column;
  }

  // Parses an `INSERT` statement.
  InsertStatement _parseInsertStatement() {
    _expect(TokenType.KEYWORD_INSERT);
    _expect(TokenType.KEYWORD_INTO);
    final table = _expect(TokenType.IDENTIFIER).value;
    _expect(TokenType.LPAREN);
    final columns = <String>[];
    while (_peek().type != TokenType.RPAREN) {
      columns.add(_expect(TokenType.IDENTIFIER).value);
      if (_peek().type == TokenType.COMMA) {
        _consume();
      }
    }
    _expect(TokenType.RPAREN);

    _expect(TokenType.KEYWORD_VALUES);
    final values = <List<Expression>>[];
    while (_peek().type == TokenType.LPAREN) {
      _consume();
      final row = <Expression>[];
      while (_peek().type != TokenType.RPAREN) {
        row.add(_parseExpression());
        if (_peek().type == TokenType.COMMA) {
          _consume();
        }
      }
      _expect(TokenType.RPAREN);
      values.add(row);
      if (_peek().type == TokenType.COMMA) {
        _consume();
      } else {
        break;
      }
    }
    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }
    _expect(TokenType.EOF);

    return InsertStatement(
      table: table,
      columns: columns,
      values: values,
    );
  }

  // Parses an `UPDATE` statement.
  UpdateStatement _parseUpdateStatement() {
    _expect(TokenType.KEYWORD_UPDATE);
    final table = _expect(TokenType.IDENTIFIER).value;
    _expect(TokenType.KEYWORD_SET);
    final setClauses = <Expression>[];
    while (_peek().type != TokenType.KEYWORD_WHERE &&
        _peek().type != TokenType.EOF &&
        _peek().type != TokenType.SEMICOLON) {
      final identifier = _expect(TokenType.IDENTIFIER).value;
      _expect(TokenType.OPERATOR_EQUAL);
      final value = _parseExpression();
      setClauses
          .add(BinaryExpression(IdentifierExpression(identifier), '=', value));
      if (_peek().type == TokenType.COMMA) {
        _consume();
      } else {
        break;
      }
    }
    Expression? whereClause;
    if (_peek().type == TokenType.KEYWORD_WHERE) {
      _consume();
      whereClause = _parseExpression();
    }
    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }
    _expect(TokenType.EOF);

    return UpdateStatement(
      table: table,
      setClauses: setClauses,
      whereClause: whereClause,
    );
  }

  // Parses a `DELETE` statement.
  DeleteStatement _parseDeleteStatement() {
    _expect(TokenType.KEYWORD_DELETE);
    _expect(TokenType.KEYWORD_FROM);
    final table = _expect(TokenType.IDENTIFIER).value;

    Expression? whereClause;
    if (_peek().type == TokenType.KEYWORD_WHERE) {
      _consume();
      whereClause = _parseExpression();
    }
    if (_peek().type == TokenType.SEMICOLON) {
      _consume();
    }
    _expect(TokenType.EOF);

    return DeleteStatement(
      table: table,
      whereClause: whereClause,
    );
  }

  // CORRECTED: Parses a generic expression using operator precedence (Pratt Parser).
  Expression _parseExpression({int precedence = 0}) {
    Expression left = _parsePrimary();

    while (precedence < _getOperatorPrecedence(_peek())) {
      final token = _consume();
      final operator = token.value;

      if (token.type == TokenType.KEYWORD_IN ||
          (token.type == TokenType.KEYWORD_NOT &&
              _peek().type == TokenType.KEYWORD_IN)) {
        bool isNot = token.type == TokenType.KEYWORD_NOT;
        if (isNot) _consume(); // consume IN

        _expect(TokenType.LPAREN);
        final values = <Expression>[];
        while (_peek().type != TokenType.RPAREN) {
          values.add(_parseExpression());
          if (_peek().type == TokenType.COMMA) {
            _consume();
          } else {
            break;
          }
        }
        _expect(TokenType.RPAREN);
        left = InExpression(left, isNot, values);
        continue;
      } else if (token.type == TokenType.KEYWORD_BETWEEN) {
        final start = _parseExpression();
        _expect(TokenType.KEYWORD_AND);
        final end = _parseExpression();
        left = BetweenExpression(left, start, end);
        continue;
      } else if (token.type == TokenType.KEYWORD_IS) {
        bool not = false;
        if (_peek().type == TokenType.KEYWORD_NOT) {
          _consume();
          not = true;
        }
        _expect(TokenType.KEYWORD_NULL_KEYWORD);
        left = IsNullExpression(left, not);
        continue;
      }

      final right = _parseExpression(precedence: _getOperatorPrecedence(token));
      left = BinaryExpression(left, operator, right);
    }
    return left;
  }

  // Parses a primary expression (single value, identifier, or parenthesized expression).
  Expression _parsePrimary() {
    final token = _peek();
    if (token.type == TokenType.LPAREN) {
      _consume();
      final expr = _parseExpression();
      _expect(TokenType.RPAREN);
      return expr;
    } else if (token.type == TokenType.IDENTIFIER &&
        _peek(1).type == TokenType.LPAREN) {
      return _parseFunctionCall();
    } else if (token.type == TokenType.IDENTIFIER) {
      return IdentifierExpression(_consume().value);
    } else if (token.type == TokenType.NUMBER) {
      return LiteralExpression(_consume().value, 'number');
    } else if (token.type == TokenType.STRING) {
      return LiteralExpression(_consume().value, 'string');
    }
    throw Exception('Unexpected token in primary expression: ${token.value}');
  }

  // CORRECTED: Parses a function call, handling COUNT(*).
  Expression _parseFunctionCall() {
    final functionName = _consume().value.toUpperCase();
    _expect(TokenType.LPAREN);

    // Handle COUNT(*)
    if (_peek().type == TokenType.OPERATOR_MULTIPLY) {
      _consume(); // consume '*'
      _expect(TokenType.RPAREN);
      return FunctionExpression(functionName, IdentifierExpression('*'));
    }

    final argument = _parseExpression();
    _expect(TokenType.RPAREN);
    return FunctionExpression(functionName, argument);
  }

  // Gets the precedence level for a given operator token.
  int _getOperatorPrecedence(Token token) {
    switch (token.type) {
      case TokenType.KEYWORD_OR:
        return 1;
      case TokenType.KEYWORD_AND:
        return 2;
      case TokenType.KEYWORD_NOT:
        return 3;
      case TokenType.OPERATOR_EQUAL:
      case TokenType.OPERATOR_NOT_EQUAL:
      case TokenType.OPERATOR_LESS_THAN:
      case TokenType.OPERATOR_GREATER_THAN:
      case TokenType.OPERATOR_LESS_THAN_OR_EQUAL:
      case TokenType.OPERATOR_GREATER_THAN_OR_EQUAL:
      case TokenType.KEYWORD_IN:
      case TokenType.KEYWORD_BETWEEN:
      case TokenType.KEYWORD_IS:
        return 4;
      case TokenType.OPERATOR_PLUS:
      case TokenType.OPERATOR_MINUS:
        return 5;
      case TokenType.OPERATOR_MULTIPLY:
      case TokenType.OPERATOR_DIVIDE:
        return 6;
      default:
        return 0; // Not an operator
    }
  }
}

// --- Main execution ---
void main() {
  final queries = [
    // Corrected CREATE TABLE statements
    "CREATE TABLE users ( id INTEGER PRIMARY KEY, name VARCHAR(255) NOT NULL, email TEXT NOT NULL, created_at TEXT DEFAULT '2023-01-01');",
    "CREATE TABLE orders ( id INTEGER, user_id INTEGER, FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE ON UPDATE RESTRICT);",
    "CREATE TABLE products ( id INTEGER, category_id INTEGER, name VARCHAR(255), price REAL, FOREIGN KEY (category_id) REFERENCES categories (id));",
    "CREATE TABLE categories ( id INTEGER, name VARCHAR(255), UNIQUE (name, id));",
    "CREATE TABLE employees ( emp_id INTEGER, emp_name VARCHAR(100), PRIMARY KEY (emp_id));",

    // Corrected SELECT statements
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
    "INSERT INTO users (name, email) VALUES ('Jane Doe', 'jane@example.com');",
    "UPDATE products SET price = price * 1.1, name = 'New Name' WHERE id = 1;",
    "DELETE FROM users WHERE last_login < '2023-01-01';",
  ];

  for (final query in queries) {
    print('--- Query: $query');
    try {
      final lexer = Lexer(query);
      final tokens = lexer.tokens;
      // print(tokens); // Uncomment for debugging
      final parser = Parser(tokens);
      final ast = parser.parse();
      print('--- Parsed AST: ${ast.toAstString()}');
    } catch (e) {
      print('--- ERROR: $e');
    }
    print(''); // Add a blank line for readability
  }
}
