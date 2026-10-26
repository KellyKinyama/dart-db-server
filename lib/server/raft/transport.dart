library;

import 'dart:async';

import 'rpc.dart';

/// Outbound RPC channel from one node to its peers. A null return means the
/// peer was unreachable (dropped / partitioned / timed out) — Raft treats that
/// as a failed RPC and retries.
abstract class RaftTransport {
  Future<RequestVoteReply?> sendRequestVote(
      String peerId, RequestVoteArgs args);
  Future<AppendEntriesReply?> sendAppendEntries(
      String peerId, AppendEntriesArgs args);
}

/// Inbound RPC handlers a node exposes (implemented by the Raft node).
abstract class RaftHandlers {
  Future<RequestVoteReply> handleRequestVote(RequestVoteArgs args);
  Future<AppendEntriesReply> handleAppendEntries(AppendEntriesArgs args);
}

/// An in-memory network connecting several nodes in one isolate, with
/// injectable partitions and latency — the deterministic substrate the Raft
/// module is developed and invariant-tested against before real sockets.
class SimulatedNetwork {
  final Map<String, RaftHandlers> _nodes = {};

  /// Directed drops: `(from, to)` present ⇒ messages from `from` to `to` are
  /// lost (a partition installs both directions).
  final Set<String> _blocked = {};

  /// Delay applied to every delivered message (0 = immediate microtask hop).
  Duration latency = Duration.zero;

  void register(String id, RaftHandlers handlers) => _nodes[id] = handlers;

  static String _edge(String from, String to) => '$from->$to';

  /// Sever the link between [a] and [b] in both directions.
  void partition(String a, String b) {
    _blocked
      ..add(_edge(a, b))
      ..add(_edge(b, a));
  }

  /// Fully isolate [id] from every other node.
  void isolate(String id) {
    for (final other in _nodes.keys) {
      if (other != id) partition(id, other);
    }
  }

  /// Restore the link between [a] and [b].
  void heal(String a, String b) {
    _blocked
      ..remove(_edge(a, b))
      ..remove(_edge(b, a));
  }

  /// Restore every link.
  void healAll() => _blocked.clear();

  bool _blockedEdge(String from, String to) =>
      _blocked.contains(_edge(from, to));

  bool _deliverable(String from, String to) =>
      _nodes.containsKey(to) && !_blockedEdge(from, to);

  /// A transport bound to the node [from].
  RaftTransport transportFor(String from) => _SimTransport(this, from);
}

class _SimTransport implements RaftTransport {
  final SimulatedNetwork net;
  final String from;

  _SimTransport(this.net, this.from);

  Future<T?> _deliver<T>(
      String to, Future<T> Function(RaftHandlers h) call) async {
    if (!net._deliverable(from, to)) return null; // request lost
    if (net.latency > Duration.zero) await Future<void>.delayed(net.latency);
    final handler = net._nodes[to];
    if (handler == null) return null;
    final reply = await call(handler);
    // The reply travels back over the same link; a reverse partition drops it.
    if (net._blockedEdge(to, from)) return null;
    if (net.latency > Duration.zero) await Future<void>.delayed(net.latency);
    return reply;
  }

  @override
  Future<RequestVoteReply?> sendRequestVote(
          String peerId, RequestVoteArgs args) =>
      _deliver(peerId, (h) => h.handleRequestVote(args));

  @override
  Future<AppendEntriesReply?> sendAppendEntries(
          String peerId, AppendEntriesArgs args) =>
      _deliver(peerId, (h) => h.handleAppendEntries(args));
}
