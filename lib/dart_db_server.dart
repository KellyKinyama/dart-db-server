import 'dart:io';

import 'database_engine/executor.dart';
import 'database_engine/parser.dart';

class DatabaseServer {
  DatabaseServer();
  void init() async {
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

  static Future<DatabaseServer> initialize() async {
    final db = DatabaseServer();
    db.init();
    return db;
  }
}
