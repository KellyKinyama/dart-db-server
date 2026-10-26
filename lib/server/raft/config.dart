library;

/// Static cluster configuration for one Raft group: this node's [nodeId] and
/// the address of every peer (including self is optional — peers excludes self
/// by convention). Identical on every node.
class RaftConfig {
  final String nodeId;

  /// Peer id → `host:port`, excluding this node.
  final Map<String, String> peers;

  RaftConfig(this.nodeId, this.peers);

  /// All node ids in the cluster (peers + self).
  Set<String> get members => {nodeId, ...peers.keys};

  /// Total cluster size (peers + self).
  int get clusterSize => peers.length + 1;

  /// Votes needed to win an election / commit an entry: a strict majority.
  int get majority => (clusterSize ~/ 2) + 1;

  /// True when [votes] (including this node's self-vote) is a majority.
  bool hasMajority(int votes) => votes >= majority;
}
