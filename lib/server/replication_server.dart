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

  /// Highest LSN each connected replica has acknowledged applying.
  final Map<Socket, int> _acked = {};

  /// Pending semi-sync waiters: each wants [count] replicas acked up to [lsn].
  final List<_AckWaiter> _ackWaiters = [];

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

  /// Number of replicas that have acknowledged applying up to at least [lsn].
  int ackedReplicas(int lsn) =>
      _acked.values.where((a) => a >= lsn).length;

  /// Semi-sync barrier: completes once [count] replicas have acked [lsn], or
  /// after [timeout] (degrading to asynchronous — the commit still stands, it
  /// just wasn't confirmed by enough replicas in time). A [count] of 0 returns
  /// immediately (pure async replication).
  Future<void> awaitAcks(int lsn, int count, Duration timeout) {
    if (count <= 0 || ackedReplicas(lsn) >= count) return Future.value();
    final completer = Completer<void>();
    final waiter = _AckWaiter(lsn, count, completer);
    _ackWaiters.add(waiter);
    Timer(timeout, () {
      if (!completer.isCompleted) {
        _ackWaiters.remove(waiter);
        completer.complete();
      }
    });
    return completer.future;
  }

  void _onAck(Socket client, int lsn) {
    final prev = _acked[client] ?? 0;
    if (lsn > prev) _acked[client] = lsn;
    _ackWaiters.removeWhere((w) {
      if (ackedReplicas(w.lsn) >= w.count) {
        if (!w.completer.isCompleted) w.completer.complete();
        return true;
      }
      return false;
    });
  }

  void _handleClient(Socket client) {
    _clients.add(client);
    StreamSubscription<OpLogRecord>? tail;
    var lastSent = 0;
    var handshaken = false;

    void send(OpLogRecord rec) {
      client.writeln(jsonEncode(rec.toJson()));
      lastSent = rec.lsn;
    }

    final lines = client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    lines.listen(
      (line) async {
        if (line.trim().isEmpty) return;
        try {
          final m = (jsonDecode(line) as Map).cast<String, Object?>();
          // Replica → primary acks (semi-sync feedback).
          if (m.containsKey('ack')) {
            _onAck(client, (m['ack'] as num).toInt());
            return;
          }
          // Handshake: begin streaming backlog + live tail.
          if (!handshaken && m.containsKey('from_lsn')) {
            handshaken = true;
            final fromLsn = (m['from_lsn'] as num?)?.toInt() ?? 0;
            lastSent = fromLsn;
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
          }
        } catch (_) {/* malformed line */}
      },
      onError: (_) {},
      onDone: () async {
        await tail?.cancel();
        _acked.remove(client);
        _clients.remove(client);
        try {
          await client.close();
        } catch (_) {/* best-effort */}
      },
    );
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
    _acked.clear();
    for (final w in _ackWaiters) {
      if (!w.completer.isCompleted) w.completer.complete();
    }
    _ackWaiters.clear();
  }
}

/// A TCP liveness probe for a primary's replication endpoint. [alive] attempts
/// a connection within [timeout]; success means the primary is reachable. Wire
/// it into `FailoverController.isPrimaryAlive` for real heartbeat-based failover.
class PrimaryProbe {
  final String host;
  final int port;
  final Duration timeout;

  PrimaryProbe(this.host, this.port,
      {this.timeout = const Duration(seconds: 1)});

  /// True when a TCP connection to the primary succeeds within [timeout].
  Future<bool> alive() async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Serves `GET /health` (JSON of [Database.haStatus]) over HTTP so a load
/// balancer, orchestrator, or operator can poll a node's role, epoch, and
/// replication position. Any other path returns 404.
class HealthServer {
  final Database node;
  HttpServer? _server;

  HealthServer(this.node);

  /// The bound port (0 before [start]).
  int get port => _server?.port ?? 0;

  Future<int> start({String host = '127.0.0.1', int port = 0}) async {
    final s = await HttpServer.bind(host, port);
    _server = s;
    s.listen((req) {
      if (req.uri.path == '/health') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(node.haStatus().toJson()));
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      req.response.close();
    }, onError: (_) {});
    return s.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
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
    final rec = OpLogRecord.fromJson(m);
    await target.applyReplicated(rec);
    // Ack back to the primary so semi-sync commits can be confirmed.
    try {
      _socket?.writeln(jsonEncode({'ack': rec.lsn}));
    } catch (_) {/* socket closing — ack is best-effort */}
  }

  /// Completes when the stream ends (server closed / disconnected).
  Future<void> get done => _done.future;

  Future<void> close() async {
    await _sub?.cancel();
    await _socket?.close();
    if (!_done.isCompleted) _done.complete();
  }
}

/// One pending semi-sync barrier: completes when [count] replicas have
/// acknowledged applying up to [lsn].
class _AckWaiter {
  final int lsn;
  final int count;
  final Completer<void> completer;
  _AckWaiter(this.lsn, this.count, this.completer);
}
