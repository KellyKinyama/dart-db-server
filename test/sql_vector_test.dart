/// Vector-database primitives + `VEC_*` SQL scalar functions and the
/// brute-force `FlatIndex` (FAISS `IndexFlatL2` / `IndexFlatIP` port).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Vector encode/decode', () {
    test('round-trip preserves values (bit-exact for f32-representable)', () {
      final v = Vector.fromList([1.0, -2.5, 0.0, 3.75]);
      final blob = encodeVectorBlob(v);
      expect(blob.length, 4 + 4 * 4);
      final back = decodeVectorBlob(blob);
      expect(back.dim, 4);
      expect(back.values, [1.0, -2.5, 0.0, 3.75]);
    });

    test('dim is written as LE uint32 header', () {
      final v = Vector.fromList([0, 0, 0]);
      final blob = encodeVectorBlob(v);
      final bd = ByteData.sublistView(blob);
      expect(bd.getUint32(0, Endian.little), 3);
    });

    test('decodeVectorBlob rejects short input', () {
      expect(() => decodeVectorBlob([1, 2, 3]), throwsFormatException);
    });

    test('decodeVectorBlob rejects size mismatch', () {
      // dim=2 header says 8 payload bytes; give only 4.
      final bad = Uint8List(4 + 4);
      ByteData.sublistView(bad).setUint32(0, 2, Endian.little);
      expect(() => decodeVectorBlob(bad), throwsFormatException);
    });

    test('parseVectorText accepts JSON array of numbers', () {
      final v = parseVectorText('[1, 2, 3.5, -4]');
      expect(v.dim, 4);
      expect(v.values, [1.0, 2.0, 3.5, -4.0]);
    });

    test('parseVectorText rejects non-array / non-numeric', () {
      expect(() => parseVectorText(''), throwsFormatException);
      expect(() => parseVectorText('"hi"'), throwsFormatException);
      expect(() => parseVectorText('[1, "x"]'), throwsFormatException);
    });
  });

  group('Distance functions', () {
    test('L2sq / L2 basic identities', () {
      final a = Vector.fromList([0, 0, 0]);
      final b = Vector.fromList([3, 4, 0]);
      expect(vecL2Sq(a, b), 25.0);
      expect(vecL2(a, b), 5.0);
      expect(vecL2Sq(a, a), 0.0);
    });

    test('inner product', () {
      final a = Vector.fromList([1, 2, 3]);
      final b = Vector.fromList([4, -5, 6]);
      // 1*4 + 2*-5 + 3*6 = 4 - 10 + 18 = 12
      expect(vecInnerProduct(a, b), 12.0);
    });

    test('cosine similarity / distance', () {
      final a = Vector.fromList([1, 0]);
      final b = Vector.fromList([1, 0]);
      final c = Vector.fromList([0, 1]);
      final d = Vector.fromList([-1, 0]);
      expect(vecCosineSimilarity(a, b), closeTo(1.0, 1e-6));
      expect(vecCosineDistance(a, b), closeTo(0.0, 1e-6));
      expect(vecCosineSimilarity(a, c), closeTo(0.0, 1e-6));
      expect(vecCosineSimilarity(a, d), closeTo(-1.0, 1e-6));
      expect(vecCosineDistance(a, d), closeTo(2.0, 1e-6));
    });

    test('dimension mismatch throws StateError', () {
      final a = Vector.fromList([1, 2, 3]);
      final b = Vector.fromList([1, 2]);
      expect(() => vecL2Sq(a, b), throwsStateError);
      expect(() => vecInnerProduct(a, b), throwsStateError);
    });

    test('vecNormalize yields unit norm', () {
      final v = Vector.fromList([3, 4]);
      final n = vecNormalize(v);
      expect(vecNorm(n), closeTo(1.0, 1e-6));
    });

    test('vecNormalize preserves zero vector', () {
      final z = Vector.fromList([0, 0, 0]);
      final n = vecNormalize(z);
      expect(n.values, [0, 0, 0]);
    });
  });

  group('FlatIndex brute-force k-NN (FAISS IndexFlatL2)', () {
    test('empty index returns empty search', () {
      final idx = FlatIndex(3);
      final r = idx.search(Vector.fromList([1, 2, 3]), 5);
      expect(r, isEmpty);
    });

    test('L2 nearest neighbor ordering', () {
      final idx = FlatIndex(2);
      idx.add('a', Vector.fromList([0, 0]));
      idx.add('b', Vector.fromList([10, 10]));
      idx.add('c', Vector.fromList([1, 1]));
      idx.add('d', Vector.fromList([5, 5]));
      final hits = idx.search(Vector.fromList([0, 0]), 3);
      expect(hits.map((h) => h.id).toList(), ['a', 'c', 'd']);
      // Best-first, non-decreasing distance.
      expect(hits[0].distance, lessThanOrEqualTo(hits[1].distance));
      expect(hits[1].distance, lessThanOrEqualTo(hits[2].distance));
    });

    test('L2 metric returns euclidean (not squared) distance', () {
      final idx = FlatIndex(2, defaultMetric: VectorMetric.l2);
      idx.add('p', Vector.fromList([3, 4]));
      final r = idx.search(Vector.fromList([0, 0]), 1);
      expect(r.single.distance, closeTo(5.0, 1e-6));
    });

    test('inner-product ranking picks largest', () {
      final idx = FlatIndex(2, defaultMetric: VectorMetric.innerProduct);
      idx.add('a', Vector.fromList([1, 0])); // ip with [1,1] = 1
      idx.add('b', Vector.fromList([2, 3])); // ip with [1,1] = 5
      idx.add('c', Vector.fromList([-1, -1])); // ip = -2
      final hits = idx.search(Vector.fromList([1, 1]), 3);
      expect(hits.map((h) => h.id).toList(), ['b', 'a', 'c']);
      expect(hits[0].distance, 5.0);
    });

    test('cosine ranking is scale-invariant', () {
      final idx = FlatIndex(2, defaultMetric: VectorMetric.cosine);
      idx.add('parallel', Vector.fromList([2, 0])); // same direction
      idx.add('orthogonal', Vector.fromList([0, 5]));
      idx.add('opposite', Vector.fromList([-3, 0]));
      final hits = idx.search(Vector.fromList([1, 0]), 3);
      expect(hits[0].id, 'parallel');
      expect(hits[0].distance, closeTo(0.0, 1e-6));
      expect(hits.last.id, 'opposite');
      expect(hits.last.distance, closeTo(2.0, 1e-6));
    });

    test('k larger than N returns all rows', () {
      final idx = FlatIndex(1);
      idx.add(1, Vector.fromList([1]));
      idx.add(2, Vector.fromList([2]));
      final r = idx.search(Vector.fromList([0]), 100);
      expect(r.length, 2);
    });

    test('removeId compacts storage and search still correct', () {
      final idx = FlatIndex(1);
      idx.add(1, Vector.fromList([1]));
      idx.add(2, Vector.fromList([2]));
      idx.add(3, Vector.fromList([3]));
      expect(idx.removeId(2), isTrue);
      expect(idx.length, 2);
      expect(idx.removeId(999), isFalse);
      final hits = idx.search(Vector.fromList([2.1]), 2);
      // Remaining ids are 1 and 3; nearer to 2.1 is 3.
      expect(hits.map((h) => h.id).toList(), [3, 1]);
    });

    test('dim mismatch on add/search throws', () {
      final idx = FlatIndex(3);
      expect(() => idx.add('x', Vector.fromList([1, 2])), throwsStateError);
      idx.add('y', Vector.fromList([1, 2, 3]));
      expect(
        () => idx.search(Vector.fromList([1, 2]), 1),
        throwsStateError,
      );
    });

    test('agrees with brute-force reference on random data', () {
      // Sanity: for small random N, FlatIndex order must match a naive
      // sort of all (id, distance) pairs.
      const dim = 8;
      const n = 40;
      final idx = FlatIndex(dim);
      final vecs = <int, Vector>{};
      // Deterministic pseudo-random.
      var seed = 1;
      double rnd() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return (seed % 10000) / 10000.0 - 0.5;
      }

      for (var i = 0; i < n; i++) {
        final v = Vector.fromList(List.generate(dim, (_) => rnd()));
        idx.add(i, v);
        vecs[i] = v;
      }
      final q = Vector.fromList(List.generate(dim, (_) => rnd()));
      final hits = idx.search(q, 5);

      final naive = vecs.entries
          .map((e) => MapEntry(e.key, vecL2Sq(e.value, q)))
          .toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      expect(hits.map((h) => h.id).toList(), naive.take(5).map((e) => e.key));
    });
  });

  group('SQL VEC_* scalar functions', () {
    test('VEC(text) round-trips through VEC_TO_JSON and VEC_DIM', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          "SELECT VEC_DIM(VEC('[1, 2, 3, 4]')) AS d, "
          "VEC_TO_JSON(VEC('[1, 2, 3, 4]')) AS s",
        );
        expect(r.rows.single[0], 4);
        // Text form is compact JSON.
        expect(jsonDecode(r.rows.single[1] as String), [1, 2, 3, 4]);
      } finally {
        await db.close();
      }
    });

    test('VEC returns a BLOB with LE dim header', () async {
      final db = await Database.open();
      try {
        final r = await db.execute("SELECT VEC('[7, 8]') AS b");
        final blob = r.rows.single[0];
        expect(blob, isA<List<int>>());
        final bytes = blob as List<int>;
        // 4-byte header + 2 * 4-byte floats.
        expect(bytes.length, 12);
        final bd = ByteData.sublistView(Uint8List.fromList(bytes));
        expect(bd.getUint32(0, Endian.little), 2);
      } finally {
        await db.close();
      }
    });

    test('VEC_L2 / VEC_L2SQ / VEC_IP / VEC_COSINE compute correctly', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          "SELECT "
          "VEC_L2SQ(VEC('[0,0]'),   VEC('[3,4]'))   AS l2sq, "
          "VEC_L2  (VEC('[0,0]'),   VEC('[3,4]'))   AS l2, "
          "VEC_IP  (VEC('[1,2,3]'), VEC('[4,-5,6]')) AS ip, "
          "VEC_COSINE(VEC('[1,0]'), VEC('[1,0]'))    AS cos_same, "
          "VEC_COSINE(VEC('[1,0]'), VEC('[-1,0]'))   AS cos_opp",
        );
        final row = r.rows.single;
        expect(row[0], 25.0);
        expect(row[1], closeTo(5.0, 1e-6));
        expect(row[2], 12.0);
        expect(row[3] as double, closeTo(0.0, 1e-6));
        expect(row[4] as double, closeTo(2.0, 1e-6));
      } finally {
        await db.close();
      }
    });

    test('NULL propagation', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          "SELECT VEC_L2(NULL, VEC('[1,2]')) AS a, "
          "VEC_DIM(NULL) AS b, VEC_TO_JSON(NULL) AS c",
        );
        expect(r.rows.single, [null, null, null]);
      } finally {
        await db.close();
      }
    });

    test('dim mismatch surfaces as an error', () async {
      final db = await Database.open();
      try {
        expect(
          () => db.execute("SELECT VEC_L2(VEC('[1,2]'), VEC('[1,2,3]'))"),
          throwsA(isA<StateError>()),
        );
      } finally {
        await db.close();
      }
    });

    test('VEC_NORMALIZE produces a unit vector', () async {
      final db = await Database.open();
      try {
        final r = await db.execute(
          "SELECT VEC_NORM(VEC_NORMALIZE(VEC('[3,4]'))) AS n",
        );
        expect(r.rows.single[0] as double, closeTo(1.0, 1e-6));
      } finally {
        await db.close();
      }
    });

    test('end-to-end: store vectors in a table and rank by VEC_L2', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'title TEXT, embedding BLOB)');
        await db.execute(
          "INSERT INTO docs VALUES (1, 'apple',  VEC('[1, 0, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (2, 'banana', VEC('[0, 1, 0]'))",
        );
        await db.execute(
          "INSERT INTO docs VALUES (3, 'cherry', VEC('[0.9, 0.1, 0]'))",
        );

        // Brute-force k-NN via ORDER BY + LIMIT (no index yet).
        final r = await db.execute(
          "SELECT id, title FROM docs "
          "ORDER BY VEC_L2(embedding, VEC('[1, 0, 0]')) ASC "
          "LIMIT 2",
        );
        expect(r.rows.map((r) => r[0]).toList(), [1, 3]);

        // Inner-product ranking (larger = more similar) picks apple then
        // cherry too, since their IP with [1,0,0] is 1.0 and 0.9.
        final ip = await db.execute(
          "SELECT id FROM docs "
          "ORDER BY VEC_IP(embedding, VEC('[1, 0, 0]')) DESC "
          "LIMIT 2",
        );
        expect(ip.rows.map((r) => r[0]).toList(), [1, 3]);

        // VEC_DIM of the persisted BLOB.
        final dims =
            await db.execute('SELECT VEC_DIM(embedding) FROM docs LIMIT 1');
        expect(dims.rows.single[0], 3);
      } finally {
        await db.close();
      }
    });
  });
}

