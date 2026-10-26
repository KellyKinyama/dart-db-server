// Drives the dart_db_server Oracle wire front-end with the real `oracledb`
// client to find any real-world protocol mismatch. Run: dart run bin/validate.dart
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:oracledb/oracledb.dart';

Future<void> main() async {
  final db = await Database.open(null);
  final server = OracleServer(db, port: 0, users: {'testuser': 'testpassword'});
  server.onLog = (m) => stderr.writeln(m);
  await server.start();
  final port = server.boundPort;
  stdout.writeln('>> server listening on 127.0.0.1:$port');

  OracleConnection? conn;
  try {
    stdout.writeln('>> connecting with the real oracledb client...');
    conn = await OracleConnection.connect(
      '127.0.0.1:$port/DARTDB',
      user: 'testuser',
      password: 'testpassword',
    );
    stdout.writeln('>> CONNECTED + authenticated');

    await conn.execute(
        'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)');
    stdout.writeln('>> CREATE TABLE ok');

    final ins = await conn.execute("INSERT INTO people VALUES (1, 'alice')");
    stdout.writeln('>> INSERT ok (rowsAffected=${ins.rowsAffected})');

    await conn.execute("INSERT INTO people VALUES (2, 'bob')");

    final sel = await conn.execute('SELECT id, name FROM people ORDER BY id');
    final cols = sel.columns.map((c) => c.name).toList();
    stdout.writeln('>> SELECT columns: $cols');
    for (final row in sel.rows) {
      final id = row[0];
      final name = row[1];
      stdout.writeln('>>   row: id=$id (${id.runtimeType}), name=$name');
    }

    final ok = sel.rows.length == 2 &&
        sel.rows[0][0] == 1 &&
        sel.rows[0][1] == 'alice' &&
        sel.rows[1][0] == 2 &&
        sel.rows[1][1] == 'bob';
    if (!ok) throw StateError('row values did not round-trip: ${sel.rows}');

    stdout.writeln('\n*** VALIDATION PASSED ***');
  } catch (e, st) {
    stdout.writeln('\n!!! VALIDATION FAILED: $e');
    stderr.writeln(st);
    exitCode = 1;
  } finally {
    try {
      await conn?.close();
    } catch (_) {}
    await server.stop();
  }
}
