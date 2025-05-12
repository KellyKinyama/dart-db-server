import 'package:dart_db_server/database_engine/parser.dart';

import 'database_engine/executor.dart';

void main() {
  final parser = Parser();
  final db = Database();

  final commands = [
    // CREATE TABLE
    "CREATE TABLE users (id INT, name TEXT, age INT);",

    // INSERT
    "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30);",
    "INSERT INTO users (id, name, age) VALUES (2, 'Bob', 25);",
    "INSERT INTO users (id, name, age) VALUES (3, 'Charlie', 35);",

    // SELECT
    "SELECT * FROM users;",

    // UPDATE
    "UPDATE users SET age = 31 WHERE name = 'Alice';",

    // SELECT after update
    "SELECT * FROM users WHERE name = 'Alice';",

    // DELETE
    "DELETE FROM users WHERE id = 2;",

    // SELECT after delete
    "SELECT * FROM users;"
  ];

  for (final commandText in commands) {
    print("\nCommand: $commandText");
    // try {
    final command = parser.parse(commandText);
    final result = db.execute(command);
    // if (result != null) {
    //   print("Result: $result");
    // }
    // } catch (e) {
    //   print("Error: $e");
    //  }
  }
}
