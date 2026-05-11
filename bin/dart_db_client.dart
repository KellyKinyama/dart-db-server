/// dart-db-client: simple line-oriented REPL that connects to a running
/// dart-db-server over TCP.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';

Future<void> main(List<String> args) async {
  String host = '127.0.0.1';
  int port = 4555;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    String? next() => i + 1 < args.length ? args[++i] : null;
    switch (a) {
      case '--host':
        host = next() ?? host;
        break;
      case '--port':
        port = int.parse(next() ?? '$port');
        break;
      case '-h':
      case '--help':
        stdout.writeln('Usage: dart_db_client [--host H] [--port N]');
        return;
    }
  }

  final client = await DbClient.connect(host: host, port: port);
  stdout.writeln('connected to $host:$port');
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
      final reply = await client.exec(sql);
      final cols = (reply['columns'] as List?)?.cast<String>() ?? const [];
      final rows = (reply['rows'] as List?) ?? const [];
      if (cols.isEmpty) {
        stdout.writeln(reply['message'] ?? '(ok)');
      } else {
        stdout.writeln(cols.join(' | '));
        stdout.writeln(cols.map((c) => '-' * c.length).join('-+-'));
        for (final row in rows) {
          stdout.writeln((row as List).map((v) => v ?? 'NULL').join(' | '));
        }
        stdout.writeln('(${rows.length} row${rows.length == 1 ? '' : 's'})');
      }
    } catch (e) {
      stdout.writeln('ERROR: $e');
    }
  }
  await client.close();
}
