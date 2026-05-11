/// Unit tests for the in-memory R-tree spatial index.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('BBox', () {
    test('point bbox has zero area and intersects itself', () {
      final p = BBox.point([1.0, 2.0]);
      expect(p.dims, 2);
      expect(p.area(), 0.0);
      expect(p.intersects(p), isTrue);
    });

    test('intersection is closed (touching boxes intersect)', () {
      final a = BBox.fromMinMax([0, 0], [1, 1]);
      final b = BBox.fromMinMax([1, 1], [2, 2]);
      expect(a.intersects(b), isTrue);
    });

    test('disjoint boxes do not intersect', () {
      final a = BBox.fromMinMax([0, 0], [1, 1]);
      final b = BBox.fromMinMax([2, 2], [3, 3]);
      expect(a.intersects(b), isFalse);
    });

    test('enlarge produces a superset', () {
      final a = BBox.fromMinMax([0, 0], [1, 1]);
      final b = BBox.fromMinMax([3, 3], [4, 4]);
      final e = a.enlarge(b);
      expect(e.minOf(0), 0);
      expect(e.maxOf(0), 4);
      expect(e.area(), 16.0);
    });
  });

  group('RTreeIndex (incremental insert)', () {
    test('empty index reports length 0 and yields nothing', () {
      final idx = RTreeIndex(2);
      expect(idx.length, 0);
      expect(idx.search(BBox.fromMinMax([-1e9, -1e9], [1e9, 1e9])),
          isEmpty);
    });

    test('point lookup returns only the matching rowid', () {
      final idx = RTreeIndex(2);
      idx.insert(1, BBox.fromMinMax([0, 0], [10, 10]));
      idx.insert(2, BBox.fromMinMax([20, 20], [30, 30]));
      idx.insert(3, BBox.fromMinMax([4, 4], [6, 6]));
      final hits = idx.searchPoint([5, 5]).toList()..sort();
      expect(hits, [1, 3]);
    });

    test('window query returns all intersecting rowids', () {
      final idx = RTreeIndex(2);
      idx.insert(1, BBox.fromMinMax([0, 0], [10, 10]));
      idx.insert(2, BBox.fromMinMax([5, 5], [15, 15]));
      idx.insert(3, BBox.fromMinMax([20, 20], [25, 25]));
      final hits =
          idx.search(BBox.fromMinMax([8, 8], [12, 12])).toList()..sort();
      expect(hits, [1, 2]);
    });

    test('many inserts force splits and remain correct', () {
      // Use a small node fanout to ensure several splits happen.
      final idx = RTreeIndex(2, maxEntries: 4);
      final rnd = math.Random(0xBADF00D);
      final inserted = <int, BBox>{};
      for (var i = 0; i < 200; i++) {
        final x = rnd.nextDouble() * 100;
        final y = rnd.nextDouble() * 100;
        final box = BBox.fromMinMax([x, y], [x + 1, y + 1]);
        idx.insert(i, box);
        inserted[i] = box;
      }
      expect(idx.length, 200);
      // Brute-force a query and compare.
      final query = BBox.fromMinMax([10, 10], [40, 40]);
      final expected = <int>[
        for (final e in inserted.entries)
          if (e.value.intersects(query)) e.key,
      ]..sort();
      final actual = idx.search(query).toList()..sort();
      expect(actual, expected);
    });
  });

  group('RTreeIndex.bulkLoad', () {
    test('bulk load is a valid index over its items', () {
      final rnd = math.Random(42);
      final items = <MapEntry<int, BBox>>[];
      final by = <int, BBox>{};
      for (var i = 0; i < 500; i++) {
        final x = rnd.nextDouble() * 1000;
        final y = rnd.nextDouble() * 1000;
        final w = rnd.nextDouble() * 5;
        final h = rnd.nextDouble() * 5;
        final box = BBox.fromMinMax([x, y], [x + w, y + h]);
        items.add(MapEntry(i, box));
        by[i] = box;
      }
      final idx = RTreeIndex.bulkLoad(2, items);
      expect(idx.length, 500);
      // Sample a few windows and confirm exact match against brute force.
      for (var t = 0; t < 5; t++) {
        final cx = rnd.nextDouble() * 1000;
        final cy = rnd.nextDouble() * 1000;
        final q = BBox.fromMinMax([cx - 50, cy - 50], [cx + 50, cy + 50]);
        final expected = <int>[
          for (final e in by.entries)
            if (e.value.intersects(q)) e.key,
        ]..sort();
        final actual = idx.search(q).toList()..sort();
        expect(actual, expected,
            reason: 'mismatch at center=($cx,$cy)');
      }
    });

    test('bulk load works in 3 dimensions', () {
      final items = <MapEntry<int, BBox>>[
        MapEntry(1, BBox.point([0, 0, 0])),
        MapEntry(2, BBox.point([1, 1, 1])),
        MapEntry(3, BBox.point([5, 5, 5])),
      ];
      final idx = RTreeIndex.bulkLoad(3, items);
      final hits =
          idx.search(BBox.fromMinMax([-0.5, -0.5, -0.5], [1.5, 1.5, 1.5]))
              .toList()
            ..sort();
      expect(hits, [1, 2]);
    });
  });

  group('RTreeIndex.remove', () {
    test('removed entries no longer appear in search results', () {
      final idx = RTreeIndex(2);
      for (var i = 0; i < 50; i++) {
        idx.insert(i, BBox.point([i.toDouble(), 0]));
      }
      expect(idx.length, 50);
      final removed = idx.remove(10);
      expect(removed, 1);
      expect(idx.length, 49);
      final hits = idx.searchPoint([10, 0]);
      expect(hits, isEmpty);
      // Other points still findable.
      expect(idx.searchPoint([11, 0]), [11]);
    });

    test('removing a non-existent rowid is a no-op', () {
      final idx = RTreeIndex(2);
      idx.insert(1, BBox.point([0, 0]));
      expect(idx.remove(999), 0);
      expect(idx.length, 1);
    });
  });
}
