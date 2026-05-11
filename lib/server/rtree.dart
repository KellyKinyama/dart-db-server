/// In-memory R-tree spatial index over axis-aligned bounding boxes in
/// arbitrary dimension. Supports bulk-load, point insertion, deletion by
/// rowid, and range (bounding-box intersection) queries.
///
/// Node splits use Guttman's linear split heuristic. Bulk loads use the
/// straightforward "sort-tile recursive" (STR) algorithm, which produces
/// a well-balanced tree without needing repeated splits.
library;

import 'dart:math' as math;

/// A closed axis-aligned bounding box in `dims` dimensions. The first
/// `dims` entries of [bounds] are the per-axis minima and the next
/// `dims` are the maxima.
class BBox {
  /// Number of dimensions.
  final int dims;

  /// `[min0..min{d-1}, max0..max{d-1}]`, length `2*dims`.
  final List<double> bounds;

  BBox(this.dims, this.bounds)
      : assert(bounds.length == 2 * dims, 'bounds must be 2*dims long'),
        assert(_validMinMax(dims, bounds), 'min must be <= max on every axis');

  factory BBox.point(List<double> coords) {
    final d = coords.length;
    return BBox(d, [...coords, ...coords]);
  }

  factory BBox.fromMinMax(List<double> mins, List<double> maxs) {
    assert(mins.length == maxs.length);
    return BBox(mins.length, [...mins, ...maxs]);
  }

  static bool _validMinMax(int dims, List<double> b) {
    for (var i = 0; i < dims; i++) {
      if (b[i] > b[i + dims]) return false;
    }
    return true;
  }

  double minOf(int axis) => bounds[axis];
  double maxOf(int axis) => bounds[axis + dims];

  /// Axis-wise area (product of side lengths). For dims=1 this is the
  /// 1-d extent.
  double area() {
    var a = 1.0;
    for (var i = 0; i < dims; i++) {
      a *= bounds[i + dims] - bounds[i];
    }
    return a;
  }

  /// Returns true when [this] and [other] share at least one point
  /// (closed-interval intersection).
  bool intersects(BBox other) {
    assert(other.dims == dims);
    for (var i = 0; i < dims; i++) {
      if (bounds[i + dims] < other.bounds[i]) return false;
      if (other.bounds[i + dims] < bounds[i]) return false;
    }
    return true;
  }

  /// Returns the smallest box enclosing both `this` and [other].
  BBox enlarge(BBox other) {
    assert(other.dims == dims);
    final out = List<double>.filled(2 * dims, 0);
    for (var i = 0; i < dims; i++) {
      out[i] = math.min(bounds[i], other.bounds[i]);
      out[i + dims] = math.max(bounds[i + dims], other.bounds[i + dims]);
    }
    return BBox(dims, out);
  }

  /// Returns the smallest box enclosing a non-empty iterable.
  static BBox enclose(Iterable<BBox> boxes) {
    final it = boxes.iterator;
    if (!it.moveNext()) {
      throw ArgumentError('enclose requires at least one box');
    }
    var cur = it.current;
    while (it.moveNext()) {
      cur = cur.enlarge(it.current);
    }
    return cur;
  }

  @override
  String toString() => 'BBox($bounds)';
}

class _Entry {
  /// For leaves: the rowid. For inner nodes: unused (always -1).
  final int rowid;
  final BBox bbox;

  /// For leaves: null. For inner nodes: the referenced child node.
  final _Node? child;
  _Entry.leaf(this.rowid, this.bbox) : child = null;
  _Entry.inner(this.bbox, _Node this.child) : rowid = -1;
}

class _Node {
  bool isLeaf;
  final List<_Entry> entries;
  _Node(this.isLeaf, this.entries);
}

/// An in-memory R-tree spatial index. Each indexed item has an `int`
/// rowid and a [BBox] of fixed dimensionality.
class RTreeIndex {
  /// Number of dimensions of every indexed box.
  final int dims;

  /// Maximum number of entries per node before a split is forced.
  final int maxEntries;

  /// Minimum number of entries per node after a split.
  final int minEntries;
  _Node _root;

  RTreeIndex(this.dims, {this.maxEntries = 16})
      : assert(maxEntries >= 4, 'maxEntries must be >= 4'),
        minEntries = maxEntries ~/ 2,
        _root = _Node(true, <_Entry>[]);

  /// Bulk-load an index from `(rowid, bbox)` pairs using sort-tile-recursive
  /// packing. Produces a balanced tree without per-row splits and is the
  /// preferred constructor for large static sets.
  factory RTreeIndex.bulkLoad(
    int dims,
    List<MapEntry<int, BBox>> items, {
    int maxEntries = 16,
  }) {
    final idx = RTreeIndex(dims, maxEntries: maxEntries);
    if (items.isEmpty) return idx;
    final leaves =
        items.map((e) => _Entry.leaf(e.key, e.value)).toList(growable: false);
    idx._root = idx._packLevel(leaves, isLeaf: true);
    return idx;
  }

  /// Number of indexed items (recursive count of leaf entries).
  int get length => _countLeaves(_root);

  static int _countLeaves(_Node n) {
    if (n.isLeaf) return n.entries.length;
    var c = 0;
    for (final e in n.entries) {
      c += _countLeaves(e.child!);
    }
    return c;
  }

  /// Insert a single `(rowid, bbox)` pair. Splits propagate up if needed.
  void insert(int rowid, BBox bbox) {
    assert(bbox.dims == dims);
    final sibling = _insert(_root, _Entry.leaf(rowid, bbox));
    if (sibling != null) {
      _root = _Node(false, [
        _Entry.inner(_encloseNode(_root), _root),
        _Entry.inner(_encloseNode(sibling), sibling),
      ]);
    }
  }

  /// Remove all entries whose rowid equals [rowid]. Returns the number of
  /// entries removed. After a deletion the tree may be slightly suboptimal
  /// but remains correct.
  int remove(int rowid) {
    final removed = _remove(_root, rowid);
    // If the root has a single child after a deletion, collapse it.
    while (!_root.isLeaf && _root.entries.length == 1) {
      _root = _root.entries.first.child!;
    }
    return removed;
  }

  /// All rowids whose bbox intersects [query]. Ordering is unspecified.
  Iterable<int> search(BBox query) sync* {
    assert(query.dims == dims);
    final stack = <_Node>[_root];
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      for (final e in n.entries) {
        if (!e.bbox.intersects(query)) continue;
        if (n.isLeaf) {
          yield e.rowid;
        } else {
          stack.add(e.child!);
        }
      }
    }
  }

  /// Convenience point query: returns rowids whose bbox contains [point].
  Iterable<int> searchPoint(List<double> point) => search(BBox.point(point));

  // --- internal: insertion ----------------------------------------------

  /// Inserts [entry] into the subtree rooted at [node]. Returns a new
  /// sibling node (peer of [node]) if [node] overflowed and was split,
  /// otherwise null.
  _Node? _insert(_Node node, _Entry entry) {
    if (node.isLeaf) {
      node.entries.add(entry);
      if (node.entries.length <= maxEntries) return null;
      return _splitNode(node);
    }
    // Choose subtree: the child whose bbox needs least enlargement.
    var best = 0;
    var bestEnlarge = double.infinity;
    var bestArea = double.infinity;
    for (var i = 0; i < node.entries.length; i++) {
      final child = node.entries[i];
      final enlarged = child.bbox.enlarge(entry.bbox);
      final delta = enlarged.area() - child.bbox.area();
      if (delta < bestEnlarge ||
          (delta == bestEnlarge && child.bbox.area() < bestArea)) {
        best = i;
        bestEnlarge = delta;
        bestArea = child.bbox.area();
      }
    }
    final chosenChild = node.entries[best].child!;
    final newSibling = _insert(chosenChild, entry);
    // Refresh the chosen child's covering bbox.
    node.entries[best] = _Entry.inner(_encloseNode(chosenChild), chosenChild);
    if (newSibling == null) return null;
    // The child split: attach the new sibling at this level.
    node.entries.add(_Entry.inner(_encloseNode(newSibling), newSibling));
    if (node.entries.length <= maxEntries) return null;
    return _splitNode(node);
  }

  /// Linear split (Guttman 1984). Picks the two most extreme entries on
  /// some axis as seeds, then distributes the remainder while keeping
  /// each group at least `minEntries`.
  _Node _splitNode(_Node node) {
    final entries = node.entries;
    // Pick seeds: the pair of entries whose axis-wise gap is largest
    // relative to that axis's total extent.
    var seedA = 0;
    var seedB = 1;
    var bestNorm = -1.0;
    for (var axis = 0; axis < dims; axis++) {
      var lowestHigh = double.infinity;
      var lowestHighIdx = 0;
      var highestLow = double.negativeInfinity;
      var highestLowIdx = 0;
      var minLow = double.infinity;
      var maxHigh = double.negativeInfinity;
      for (var i = 0; i < entries.length; i++) {
        final b = entries[i].bbox;
        if (b.maxOf(axis) < lowestHigh) {
          lowestHigh = b.maxOf(axis);
          lowestHighIdx = i;
        }
        if (b.minOf(axis) > highestLow) {
          highestLow = b.minOf(axis);
          highestLowIdx = i;
        }
        if (b.minOf(axis) < minLow) minLow = b.minOf(axis);
        if (b.maxOf(axis) > maxHigh) maxHigh = b.maxOf(axis);
      }
      final width = maxHigh - minLow;
      if (width <= 0) continue;
      final norm = (highestLow - lowestHigh).abs() / width;
      if (norm > bestNorm && lowestHighIdx != highestLowIdx) {
        bestNorm = norm;
        seedA = lowestHighIdx;
        seedB = highestLowIdx;
      }
    }
    final a = entries[seedA];
    final b = entries[seedB];
    final groupA = <_Entry>[a];
    final groupB = <_Entry>[b];
    var boxA = a.bbox;
    var boxB = b.bbox;
    final remaining = <_Entry>[
      for (var i = 0; i < entries.length; i++)
        if (i != seedA && i != seedB) entries[i],
    ];
    while (remaining.isNotEmpty) {
      // Force-fill if one group would otherwise drop below minEntries.
      final remaining_ = remaining.length;
      if (groupA.length + remaining_ == minEntries) {
        groupA.addAll(remaining);
        for (final e in remaining) {
          boxA = boxA.enlarge(e.bbox);
        }
        remaining.clear();
        break;
      }
      if (groupB.length + remaining_ == minEntries) {
        groupB.addAll(remaining);
        for (final e in remaining) {
          boxB = boxB.enlarge(e.bbox);
        }
        remaining.clear();
        break;
      }
      // Otherwise pick the entry with the strongest preference for one
      // side (the side whose area grows least).
      var bestIdx = 0;
      var bestDiff = double.negativeInfinity;
      var bestSide = 0; // 0=A, 1=B
      for (var i = 0; i < remaining.length; i++) {
        final e = remaining[i];
        final deltaA = boxA.enlarge(e.bbox).area() - boxA.area();
        final deltaB = boxB.enlarge(e.bbox).area() - boxB.area();
        final diff = (deltaA - deltaB).abs();
        if (diff > bestDiff) {
          bestDiff = diff;
          bestIdx = i;
          bestSide = deltaA < deltaB ? 0 : 1;
        }
      }
      final e = remaining.removeAt(bestIdx);
      if (bestSide == 0) {
        groupA.add(e);
        boxA = boxA.enlarge(e.bbox);
      } else {
        groupB.add(e);
        boxB = boxB.enlarge(e.bbox);
      }
    }
    // Rewrite `node` to hold group A and return a fresh sibling for group B.
    node.entries
      ..clear()
      ..addAll(groupA);
    return _Node(node.isLeaf, groupB);
  }

  // --- internal: removal ------------------------------------------------

  int _remove(_Node node, int rowid) {
    if (node.isLeaf) {
      final before = node.entries.length;
      node.entries.removeWhere((e) => e.rowid == rowid);
      return before - node.entries.length;
    }
    var removed = 0;
    for (var i = 0; i < node.entries.length; i++) {
      final child = node.entries[i].child!;
      // Recurse only if this child *might* contain the rowid; without an
      // index from rowid to leaf we just recurse everywhere. (Correct,
      // and bounded since trees stay shallow.)
      removed += _remove(child, rowid);
      if (child.entries.isNotEmpty) {
        node.entries[i] = _Entry.inner(_encloseNode(child), child);
      }
    }
    // Drop any now-empty children.
    node.entries.removeWhere((e) => e.child!.entries.isEmpty);
    return removed;
  }

  // --- internal: bulk load (STR-style) ---------------------------------

  _Node _packLevel(List<_Entry> entries, {required bool isLeaf}) {
    if (entries.length <= maxEntries) {
      return _Node(isLeaf, List<_Entry>.from(entries));
    }
    // Number of slices per axis. For uniform packing we use
    // ceil(N / maxEntries)^(1/dims) slices per axis, then sort along
    // each axis in turn.
    final groups = (entries.length / maxEntries).ceil();
    final slicesPerAxis = math.max(1, math.pow(groups, 1 / dims).ceil());
    var cur = entries;
    for (var axis = 0; axis < dims; axis++) {
      cur.sort((a, b) => a.bbox.minOf(axis).compareTo(b.bbox.minOf(axis)));
      // Group into slices on this axis.
      final sliceSize = (cur.length / slicesPerAxis).ceil();
      final sliced = <_Entry>[];
      for (var i = 0; i < cur.length; i += sliceSize) {
        final end = math.min(i + sliceSize, cur.length);
        // Within each slice, the next axis sort will further partition.
        sliced.addAll(cur.sublist(i, end));
      }
      cur = sliced;
    }
    // Now bucketize into runs of `maxEntries` and pack each as a child node.
    final children = <_Entry>[];
    for (var i = 0; i < cur.length; i += maxEntries) {
      final end = math.min(i + maxEntries, cur.length);
      final bucket = cur.sublist(i, end);
      final node = _Node(isLeaf, bucket);
      children.add(_Entry.inner(_encloseNode(node), node));
    }
    return _packLevel(children, isLeaf: false);
  }
}

BBox _encloseNode(_Node n) => BBox.enclose(n.entries.map((e) => e.bbox));
