abstract class PlanNode {}

class ScanNode extends PlanNode {
  final String table;
  ScanNode(this.table);
}

class FilterNode extends PlanNode {
  final PlanNode source;
  final String column;
  final String operator;
  final String value;
  FilterNode(this.source, this.column, this.operator, this.value);
}

class JoinNode extends PlanNode {
  final PlanNode left;
  final PlanNode right;
  final String leftCol;
  final String rightCol;
  JoinNode(this.left, this.right, this.leftCol, this.rightCol);
}

// Edit
PlanNode optimize(PlanNode node) {
  if (node is FilterNode && node.source is JoinNode) {
    final join = node.source as JoinNode;

    // Push filter below join if it applies to left
    if ((join.left as ScanNode).table == node.column.split('.')[0]) {
      return JoinNode(
        FilterNode(join.left, node.column, node.operator, node.value),
        join.right,
        join.leftCol,
        join.rightCol,
      );
    }
  }
  return node;
}

class ColumnDefinition {
  final String name;
  final String type;

  ColumnDefinition(this.name, this.type);
}
