import 'dart:io';

import 'database_engine/executor.dart';
import 'database_engine/parser.dart';

void main() async {
  final parser = Parser();
  final db = Database();

  print("Simple DartDB. Type SQL commands or 'exit'.");

  while (true) {
    stdout.write('dartdb> ');
    final line = stdin.readLineSync();
    if (line == null || line.trim().toLowerCase() == 'exit') break;

    try {
      final command = parser.parse(line);
      db.execute(command);
    } catch (e) {
      print('Error: $e');
    }
  }
}
// CREATE TABLE users (id int, name string, isAdmin bool);
// INSERT INTO users VALUES (1, Alice, true);
// INSERT INTO users VALUES (2, Bob, false);
// SELECT * FROM users WHERE isAdmin = true;
