/// MySQL classic-protocol front-end for dart-db-server.
///
/// Usage:
///   dart run bin/dart_mysql_server.dart [--port 3306] [--host 127.0.0.1]
///                                       [--file data.json] [--memory]
///                                       [--password secret]
///
/// Connect with any MySQL client, e.g.:
///   mysql -h 127.0.0.1 -P 3306 -u root [-psecret]
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';

Future<void> main(List<String> args) async {
  String filePath = 'mydatabase.json';
  int port = 3306;
  String host = '127.0.0.1';
  String? password;
  bool memory = false;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? next() => i + 1 < args.length ? args[++i] : null;
    switch (a) {
      case '--file':
        filePath = next() ?? filePath;
        break;
      case '--port':
        port = int.parse(next() ?? '$port');
        break;
      case '--host':
        host = next() ?? host;
        break;
      case '--password':
        password = next();
        break;
      case '--memory':
        memory = true;
        break;
      case '-h':
      case '--help':
        _help();
        return;
      default:
        stderr.writeln('Unknown option: $a');
        _help();
        exit(64);
    }
  }

  final db = await Database.open(memory ? null : filePath);
  final server = MySqlServer(
    db,
    address: InternetAddress(host),
    port: port,
    password: password,
  );
  await server.start();

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nshutting down...');
    await server.stop();
    await db.flush();
    exit(0);
  });

  final c = Completer<void>();
  await c.future;
}

void _help() {
  stdout.writeln('''
dart_mysql_server - MySQL wire protocol front-end for dart-db-server

Options:
  --file <path>       JSON file used for persistence (default: mydatabase.json)
  --port <n>          TCP port to listen on (default: 3306)
  --host <addr>       Bind address (default: 127.0.0.1)
  --password <pw>     Require mysql_native_password auth with this password
  --memory            Run in-memory only (no persistence)
  -h, --help          Show this help
''');
}
