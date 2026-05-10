/// dart-db-server entry point.
///
/// Usage:
///   dart run bin/dart_db_server.dart [options]
///
/// Options:
///   --file <path>    JSON file used for persistence (default: mydatabase.json)
///   --port <n>       TCP port to listen on (default: 4555, 0 disables)
///   --host <addr>    Bind address (default: 127.0.0.1)
///   --repl           Also start an interactive REPL on stdin
///   --memory         Run in-memory only (no persistence)
///   -h, --help       Show this help
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';

Future<void> main(List<String> args) async {
  String filePath = 'mydatabase.json';
  int port = 4555;
  String host = '127.0.0.1';
  bool repl = false;
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
      case '--repl':
        repl = true;
        break;
      case '--memory':
        memory = true;
        break;
      case '-h':
      case '--help':
        _printHelp();
        return;
      default:
        stderr.writeln('Unknown option: $a');
        _printHelp();
        exit(64);
    }
  }

  final db = await Database.open(memory ? null : filePath);

  DbServer? server;
  if (port > 0) {
    server = DbServer(db, address: InternetAddress(host), port: port);
    await server.start();
  }

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nshutting down...');
    await server?.stop();
    await db.flush();
    exit(0);
  });

  if (repl || port == 0) {
    await _runRepl(db);
    await server?.stop();
    await db.flush();
  } else {
    // Block forever (server is running in the background).
    final completer = Completer<void>();
    await completer.future;
  }
}

void _printHelp() {
  stdout.writeln('''
dart-db-server - SQL database server

Usage: dart run bin/dart_db_server.dart [options]

Options:
  --file <path>    JSON file used for persistence (default: mydatabase.json)
  --port <n>       TCP port to listen on (default: 4555, 0 disables)
  --host <addr>    Bind address (default: 127.0.0.1)
  --repl           Also start an interactive REPL on stdin
  --memory         Run in-memory only (no persistence)
  -h, --help       Show this help
''');
}

Future<void> _runRepl(Database db) async {
  stdout.writeln("dart-db-server REPL. Type SQL terminated by ';' or 'exit'.");
  final buffer = StringBuffer();
  while (true) {
    stdout.write(buffer.isEmpty ? 'dartdb> ' : '   ...> ');
    final line = stdin.readLineSync();
    if (line == null) break;
    final trimmed = line.trim();
    if (buffer.isEmpty &&
        (trimmed == 'exit' || trimmed == 'quit' || trimmed == '\\q')) {
      break;
    }
    buffer.writeln(line);
    if (!trimmed.endsWith(';')) continue;
    final sql = buffer.toString();
    buffer.clear();
    try {
      final results = await db.executeScript(sql);
      for (final r in results) {
        _printResult(r);
      }
    } catch (e) {
      stdout.writeln('ERROR: $e');
    }
  }
}

void _printResult(QueryResult r) {
  if (r.columns.isEmpty) {
    stdout.writeln(r.message ?? '(no output)');
    return;
  }
  // Compute column widths.
  final widths =
      List<int>.generate(r.columns.length, (i) => r.columns[i].length);
  for (final row in r.rows) {
    for (var i = 0; i < row.length; i++) {
      final s = row[i] == null ? 'NULL' : row[i].toString();
      if (s.length > widths[i]) widths[i] = s.length;
    }
  }
  String fmt(List<Object?> cells) => cells
      .asMap()
      .entries
      .map((e) => (e.value == null ? 'NULL' : e.value.toString())
          .padRight(widths[e.key]))
      .join(' | ');
  stdout.writeln(fmt(r.columns.cast<Object?>()));
  stdout.writeln(widths.map((w) => '-' * w).join('-+-'));
  for (final row in r.rows) {
    stdout.writeln(fmt(row));
  }
  stdout.writeln('(${r.rows.length} row${r.rows.length == 1 ? '' : 's'})');
}
