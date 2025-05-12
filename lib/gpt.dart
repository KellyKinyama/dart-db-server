import 'database_engine/executor.dart';
import 'database_engine/parser.dart';

void main() {
  final parser = Parser();
  final db = Database();

  final commands = [
    // CREATE TABLE
    "CREATE TABLE users (id INT, name TEXT, age INT);",

    // INSERT rows
    "INSERT INTO users (id, name, age) VALUES (1, 'Alice', 30);",
    "INSERT INTO users (id, name, age) VALUES (2, 'Bob', 25);",
    "INSERT INTO users (id, name, age) VALUES (3, 'Charlie', 35);",
    "INSERT INTO users (id, name, age) VALUES (4, 'Dana', 40);",

    // SELECT all
    "SELECT * FROM users;",

    // UPDATE specific row
    "UPDATE users SET age = 31 WHERE name = 'Alice';",

    // SELECT updated row
    "SELECT * FROM users WHERE name = 'Alice';",

    // DELETE a row
    "DELETE FROM users WHERE id = 2;",

    // SELECT all after delete
    "SELECT * FROM users;",

    // UPDATE multiple rows
    "UPDATE users SET age = age + 1 WHERE age >= 35;",

    // SELECT rows with age > 30
    "SELECT * FROM users WHERE age > 30;",

    // SELECT only names
    "SELECT name FROM users WHERE age >= 31;",

    // Try deleting non-existent row
    "DELETE FROM users WHERE id = 999;",

    // Final state
    "SELECT * FROM users;",

    // Invalid SQL test
    //"UPDTE users SET age = 99 WHERE name = 'Bob';", // Typo intentional
    //"ALTER TABLE users ADD age int DEFAULT 30;",
    //"ALTER TABLE users ADD active bool DEFAULT true;"
  ];

  for (final commandText in commands) {
    print("\nCommand: $commandText");
    try {
      final command = parser.parse(commandText);
      final result = db.execute(command);
      // if (result != null) {
      //   for (final row in result) {
      //     print(row);
      //   }
      // }
    } catch (e) {
      print("Error: $e");
    }
  }
}
