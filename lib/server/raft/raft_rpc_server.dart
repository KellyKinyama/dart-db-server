library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'rpc.dart';
import 'transport.dart';

/// Serves a node's inbound Raft RPCs over TCP. Each connection carries one
/// request JSON line (`{"rpc": ...}`) and receives one response JSON line, then
/// closes — simple request/response framing adequate for the low RPC rate of a
/// small cluster.
class RaftRpcServer {
  final RaftHandlers handlers;
  ServerSocket? _socket;

  RaftRpcServer(this.handlers);

  int get port => _socket?.port ?? 0;

  Future<int> start({String host = '127.0.0.1', int port = 0}) async {
    final s = await ServerSocket.bind(host, port);
    _socket = s;
    s.listen(_handle, onError: (_) {});
    return s.port;
  }

  Future<void> _handle(Socket client) async {
    try {
      final line = await client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final m = (jsonDecode(line) as Map).cast<String, Object?>();
      Object? reply;
      switch (m['rpc']) {
        case 'request_vote':
          reply = (await handlers.handleRequestVote(RequestVoteArgs.fromJson(m)))
              .toJson();
          break;
        case 'append_entries':
          reply =
              (await handlers.handleAppendEntries(AppendEntriesArgs.fromJson(m)))
                  .toJson();
          break;
      }
      if (reply != null) client.writeln(jsonEncode(reply));
    } catch (_) {
      /* malformed / dropped */
    } finally {
      try {
        await client.close();
      } catch (_) {/* best-effort */}
    }
  }

  Future<void> stop() async {
    await _socket?.close();
    _socket = null;
  }
}

/// Sends Raft RPCs to peers over TCP. One short-lived connection per call keeps
/// the client stateless and resilient to peer restarts; a null return (connect
/// failure / timeout / malformed reply) is treated by Raft as a lost RPC.
class TcpRaftTransport implements RaftTransport {
  /// Peer id → `host:port`.
  final Map<String, String> peers;
  final Duration timeout;

  TcpRaftTransport(this.peers,
      {this.timeout = const Duration(milliseconds: 500)});

  @override
  Future<RequestVoteReply?> sendRequestVote(
      String peerId, RequestVoteArgs args) async {
    final m = await _rpc(peerId, args.toJson());
    return m == null ? null : RequestVoteReply.fromJson(m);
  }

  @override
  Future<AppendEntriesReply?> sendAppendEntries(
      String peerId, AppendEntriesArgs args) async {
    final m = await _rpc(peerId, args.toJson());
    return m == null ? null : AppendEntriesReply.fromJson(m);
  }

  Future<Map<String, Object?>?> _rpc(
      String peerId, Map<String, Object?> request) async {
    final addr = peers[peerId];
    if (addr == null) return null;
    final i = addr.lastIndexOf(':');
    if (i < 0) return null;
    final host = addr.substring(0, i);
    final port = int.tryParse(addr.substring(i + 1));
    if (port == null) return null;
    Socket? sock;
    try {
      sock = await Socket.connect(host, port, timeout: timeout);
      sock.writeln(jsonEncode(request));
      final line = await sock
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(timeout);
      return (jsonDecode(line) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    } finally {
      try {
        await sock?.close();
      } catch (_) {/* best-effort */}
    }
  }
}
