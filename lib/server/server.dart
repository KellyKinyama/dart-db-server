/// Line-oriented JSON protocol server: each client connection accepts a
/// stream of JSON requests, one per line, and replies with one JSON object
/// per request.
///
/// Request:  {"id": <any>, "sql": "SELECT ..."}
///           or {"id": <any>, "ping": true}
/// Response: {"id": <same>, "ok": true,  "columns": [...], "rows": [...], "affected": N, "message": "..."}
///           {"id": <same>, "ok": false, "error": "..."}
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'database.dart';
import 'result.dart';

class DbServer {
  final Database db;
  final InternetAddress address;
  final int port;
  ServerSocket? _socket;
  final Set<Socket> _clients = <Socket>{};
  void Function(String msg)? onLog;

  DbServer(this.db, {InternetAddress? address, this.port = 4555})
      : address = address ?? InternetAddress.loopbackIPv4;

  Future<void> start() async {
    _socket = await ServerSocket.bind(address, port);
    _log('listening on ${address.address}:$port');
    _socket!.listen(_handleClient);
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      await c.close();
    }
    await _socket?.close();
    await db.flush();
  }

  void _handleClient(Socket socket) {
    _clients.add(socket);
    final remote = '${socket.remoteAddress.address}:${socket.remotePort}';
    _log('client connected: $remote');

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) async {
        if (line.trim().isEmpty) return;
        await _handleLine(socket, line);
      },
      onError: (Object e, StackTrace st) {
        _log('client error $remote: $e');
      },
      onDone: () {
        _clients.remove(socket);
        _log('client disconnected: $remote');
      },
      cancelOnError: false,
    );
  }

  Future<void> _handleLine(Socket socket, String line) async {
    Object? id;
    try {
      final req = jsonDecode(line);
      if (req is! Map)
        throw const FormatException('request must be JSON object');
      id = req['id'];
      if (req['ping'] == true) {
        _send(socket, {'id': id, 'ok': true, 'message': 'pong'});
        return;
      }
      final sql = req['sql'];
      if (sql is! String) throw const FormatException('missing "sql" string');
      final results = await db.executeScript(sql);
      final last = results.isEmpty ? QueryResult.empty : results.last;
      _send(socket, {'id': id, 'ok': true, ...last.toJson()});
    } catch (e) {
      _send(socket, {'id': id, 'ok': false, 'error': e.toString()});
    }
  }

  void _send(Socket socket, Map<String, Object?> obj) {
    socket.write('${jsonEncode(obj)}\n');
  }

  void _log(String msg) => (onLog ?? print).call('[db] $msg');
}
