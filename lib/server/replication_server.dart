library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'database.dart';
import 'oplog.dart';

/// Serves a primary's [OpLog] over TCP so replicas on other hosts can follow
/// live. A replica connects and sends one JSON line `{"from_lsn": N}`; the
/// server streams every record with `lsn > N` — first the on-disk backlog, then
/// the live tail — each as one JSON line (`OpLogRecord.toJson`).
///
/// One record = one line keeps framing trivial and lets a replica resume from
/// its last applied LSN after a disconnect (HA Phase 2 streaming transport).
class ReplicationServer {
  final OpLog log;
  ServerSocket? _socket;
  final _clients = <Socket>{};

  ReplicationServer(this.log);

  /// The bound port (0 before [start]).
  int get port => _socket?.port ?? 0;

  /// Bind and begin accepting replica connections. Pass `port: 0` for an
  /// ephemeral port (returned here and via [port]).
  Future<int> start({String host = '127.0.0.1', int port = 0}) async {
    final s = await ServerSocket.bind(host, port);
    _socket = s;
    s.listen(_handleClient, onError: (_) {});
    return s.port;
  }

  Future<void> _handleClient(Socket client) async {
    _clients.add(client);
    StreamSubscription<OpLogRecord>? tail;
    try {
      final firstLine = await client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final req = (jsonDecode(firstLine) as Map).cast<String, Object?>();
      final fromLsn = (req['from_lsn'] as num?)?.toInt() ?? 0;

      var lastSent = fromLsn;
      void send(OpLogRecord rec) {
        client.writeln(jsonEncode(rec.toJson()));
        lastSent = rec.lsn;
      }

      // Subscribe to the live tail BEFORE draining the backlog so a record
      // appended mid-drain is buffered, not lost; the lsn guard de-dupes.
      final pending = <OpLogRecord>[];
      var draining = true;
      tail = log.onAppend.listen((rec) {
        if (draining) {
          pending.add(rec);
        } else if (rec.lsn > lastSent) {
          send(rec);
        }
      });

      await for (final rec in log.readFrom(fromLsn)) {
        send(rec);
      }
      for (final rec in pending) {
        if (rec.lsn > lastSent) send(rec);
      }
      draining = false;

      await client.done;
    } catch (_) {
      /* client gone / malformed handshake */
    } finally {
      await tail?.cancel();
      _clients.remove(client);
      try {
        await client.close();
      } catch (_) {/* best-effort */}
    }
  }

  /// Stop accepting connections and drop existing replica sockets.
  Future<void> stop() async {
    await _socket?.close();
    _socket = null;
    for (final c in _clients.toList()) {
      try {
        await c.close();
      } catch (_) {/* best-effort */}
    }
    _clients.clear();
  }
}

/// Connects a replica [Database] to a [ReplicationServer], streaming op-log
/// records from the replica's current `appliedLsn` and applying each in order.
class ReplicationClient {
  final Database target;
  Socket? _socket;
  StreamSubscription<String>? _sub;
  final _done = Completer<void>();

  ReplicationClient(this.target) {
    target.markReplica();
  }

  /// Connect to [host]:[port] and begin applying streamed records. Returns once
  /// connected; records continue applying in the background until [close].
  Future<void> connect(String host, int port) async {
    final sock = await Socket.connect(host, port);
    _socket = sock;
    sock.writeln(jsonEncode({'from_lsn': target.appliedLsn}));
    _sub = sock
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        // Backpressure: pause until this record is applied so records apply
        // strictly in LSN order (never concurrently).
        _sub!.pause(_applyLine(line));
      },
      onError: (_) {},
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  Future<void> _applyLine(String line) async {
    if (line.trim().isEmpty) return;
    final m = (jsonDecode(line) as Map).cast<String, Object?>();
    await target.applyReplicated(OpLogRecord.fromJson(m));
  }

  /// Completes when the stream ends (server closed / disconnected).
  Future<void> get done => _done.future;

  Future<void> close() async {
    await _sub?.cancel();
    await _socket?.close();
    if (!_done.isCompleted) _done.complete();
  }
}
