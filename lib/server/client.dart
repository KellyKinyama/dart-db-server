/// A simple TCP client for [DbServer]. Useful for tests and the bin/repl.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'schema.dart' show jsonValueToStorage;

class DbClient {
  final Socket _socket;
  final StreamIterator<String> _lines;
  int _nextId = 1;

  DbClient._(this._socket, this._lines);

  static Future<DbClient> connect({
    String host = '127.0.0.1',
    int port = 4555,
  }) async {
    final socket = await Socket.connect(host, port);
    final lines = StreamIterator(
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    return DbClient._(socket, lines);
  }

  Future<Map<String, Object?>> exec(String sql) async {
    final id = _nextId++;
    _socket.write('${jsonEncode({'id': id, 'sql': sql})}\n');
    if (!await _lines.moveNext()) {
      throw StateError('connection closed');
    }
    final reply = jsonDecode(_lines.current) as Map<String, Object?>;
    if (reply['ok'] != true) {
      throw StateError(reply['error']?.toString() ?? 'unknown error');
    }
    // Reverse the BLOB sentinel encoding applied by QueryResult.toJson so
    // callers see real Uint8List values for BLOB columns.
    final rows = reply['rows'];
    if (rows is List) {
      reply['rows'] = rows
          .map((r) => (r as List).map((v) => jsonValueToStorage(v)).toList())
          .toList();
    }
    return reply;
  }

  Future<void> close() async {
    await _socket.close();
  }
}
