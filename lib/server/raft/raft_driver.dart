library;

import 'dart:async';
import 'dart:math';

import 'raft_node.dart';

/// Drives a [RaftNode] with real timers: a periodic leader heartbeat and a
/// randomized election timeout that fires only when the node hasn't heard from
/// a leader (or granted a vote) during the interval. Turns the explicit-tick
/// test API ([RaftNode.onElectionTimeout] / [RaftNode.sendHeartbeats]) into an
/// autonomous, self-electing node.
class RaftDriver {
  final RaftNode node;
  final Duration heartbeatInterval;
  final Duration minElectionTimeout;
  final Duration maxElectionTimeout;
  final Random _rng;

  Timer? _electionTimer;
  Timer? _heartbeatTimer;
  bool _running = false;

  RaftDriver(
    this.node, {
    this.heartbeatInterval = const Duration(milliseconds: 50),
    this.minElectionTimeout = const Duration(milliseconds: 150),
    this.maxElectionTimeout = const Duration(milliseconds: 300),
    Random? rng,
  }) : _rng = rng ?? Random();

  void start() {
    if (_running) return;
    _running = true;
    _resetElectionTimer();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (node.isLeader) unawaited(node.sendHeartbeats());
    });
  }

  void _resetElectionTimer() {
    _electionTimer?.cancel();
    final span =
        maxElectionTimeout.inMilliseconds - minElectionTimeout.inMilliseconds;
    final ms = minElectionTimeout.inMilliseconds +
        (span > 0 ? _rng.nextInt(span) : 0);
    _electionTimer = Timer(Duration(milliseconds: ms), _onElectionTimeout);
  }

  Future<void> _onElectionTimeout() async {
    if (!_running) return;
    // Only campaign if we're not the leader and heard from no leader this cycle.
    if (!node.isLeader && !node.heardFromLeader) {
      await node.onElectionTimeout();
    }
    node.heardFromLeader = false;
    if (_running) _resetElectionTimer();
  }

  void stop() {
    _running = false;
    _electionTimer?.cancel();
    _heartbeatTimer?.cancel();
    _electionTimer = null;
    _heartbeatTimer = null;
  }
}
