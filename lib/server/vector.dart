/// Dense-vector primitives and a FAISS-style brute-force k-NN index.
///
/// This module is pure Dart — no dependency on the SQL layer — so it can
/// be exercised in isolation. It exposes:
///
///   * [Vector]              — a fixed-dimension `Float32List` wrapper.
///   * [VectorMetric]        — L2 / L2² / inner-product / cosine.
///   * [encodeVectorBlob] / [decodeVectorBlob] — canonical BLOB layout:
///     little-endian `uint32 dim` followed by `dim × float32` values.
///   * [parseVectorText]     — accepts `[1, 2, 3.5]` JSON-array-of-numbers.
///   * Distance helpers used by the SQL scalar functions
///     (`vecL2Sq`, `vecL2`, `vecInnerProduct`, `vecCosineDistance`,
///     `vecCosineSimilarity`, `vecNormalize`).
///   * [FlatIndex] — an `IndexFlatL2` / `IndexFlatIP` equivalent that
///     stores every vector verbatim and answers `search(q, k)` by an
///     O(N·d) scan with an incremental top-k heap.
///
/// Higher-level structures (HNSW, IVF, PQ) can be layered on top in a
/// later phase; the SQL front-end only needs the scalar functions and a
/// blob column type today.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Which FAISS-style index implementation should back a
/// [VectorIndexSpec]. See the corresponding index class for parameter
/// semantics.
enum VectorIndexKind {
  /// Brute-force exhaustive scan ([FlatIndex]). Exact but O(N·d) per
  /// query — useful as ground truth and for small tables.
  flat,

  /// Hierarchical Navigable Small World graph ([HnswIndex]).
  hnsw,

  /// Inverted-file cell-probe index ([IvfFlatIndex]).
  ivf,

  /// Sign-projection Locality-Sensitive Hashing ([LshIndex]). Ranks
  /// by Hamming distance between projected bit codes; extremely cheap
  /// memory-wise (nbits/8 bytes per vector) at the cost of recall.
  lsh,

  /// Product-Quantization index ([PqIndex]). Each vector is compressed
  /// to `m` bytes via subspace k-means codebooks; search uses
  /// asymmetric distance computation (ADC). 4×–32× smaller than Flat.
  pq,

  /// IVF + PQ composite ([IvfPqIndex]). Coarse k-means quantizer
  /// partitions space into `nlist` cells; PQ codebooks compress the
  /// residual `x - centroid_c` in each cell to `m` bytes. FAISS's
  /// billion-scale workhorse: `nprobe` cells scanned × ADC lookup
  /// per code = sub-linear search in a tiny memory footprint.
  ivfPq,
}

/// Declarative description of a vector index attached to a
/// `(table, column)` pair. Passed to `Database.createVectorIndex` and
/// returned by `Database.vectorIndexes`.
///
/// All algorithm parameters carry FAISS-conventional names and default
/// to values matching the underlying index class:
///   * HNSW: [m] = 16, [efConstruction] = 40, [efSearch] = 16
///   * IVF : [nlist] required, [nprobe] = 1
///   * LSH : [nbits] = 64 (packs into an 8-byte code)
///
/// [rescoreFactor] controls two-stage retrieval. When > 1, the planner
/// fetches `k * rescoreFactor` candidates from the index, then rescores
/// them with the exact metric against the original (uncompressed) row
/// blobs before returning the true top-k. Essential for approximate
/// indexes (LSH, PQ, IvfPq) where the index metric is lossy.
class VectorIndexSpec {
  final String table;
  final String column;
  final VectorIndexKind kind;
  final int dim;
  final VectorMetric metric;
  final int m;
  final int efConstruction;
  final int efSearch;
  final int nlist;
  final int nprobe;
  final int nbits;
  final int rescoreFactor;
  final int seed;

  /// V36: columns on the same row eligible for payload-index-driven
  /// filter pruning at KNN time. Equality-only WHERE clauses on these
  /// columns produce a pre-computed row-set that the KNN candidate
  /// list is intersected against — turning the O(N) filter attrition
  /// of V11 over-fetch into O(1) set lookup + O(k) intersection.
  final List<String> filterColumns;

  const VectorIndexSpec({
    required this.table,
    required this.column,
    required this.dim,
    this.kind = VectorIndexKind.flat,
    this.metric = VectorMetric.l2sq,
    this.m = 16,
    this.efConstruction = 40,
    this.efSearch = 16,
    this.nlist = 0,
    this.nprobe = 1,
    this.nbits = 64,
    this.rescoreFactor = 1,
    this.seed = 1234,
    this.filterColumns = const [],
  });

  @override
  String toString() =>
      'VectorIndexSpec($table.$column, dim=$dim, kind=${kind.name}, '
      'metric=${metric.name})';
}

/// Similarity / distance metric identifiers. Mirrors FAISS's
/// `METRIC_L2` / `METRIC_INNER_PRODUCT`; cosine is inner-product on
/// pre-normalized vectors and is exposed as a distance (1 - similarity).
enum VectorMetric {
  /// Squared Euclidean distance. Cheapest to compute and monotone in
  /// L2, so it is what the flat index ranks on internally.
  l2sq,

  /// Euclidean distance (√l2sq).
  l2,

  /// Inner (dot) product. Larger = more similar; the k-NN search
  /// therefore keeps the k LARGEST scores here.
  innerProduct,

  /// Cosine distance = 1 − (a·b)/(‖a‖·‖b‖). Range [0, 2].
  cosine,
}

/// A dense `dim`-dimensional real vector held as `Float32List`. The
/// underlying representation matches FAISS on-disk / on-wire so BLOB
/// I/O is a straight memcpy.
class Vector {
  /// Backing storage. Length == [dim]. Callers should treat this as
  /// immutable; use [Vector.copy] before mutating.
  final Float32List values;

  Vector(this.values);

  /// Construct from an iterable of numbers, coercing each to `double`.
  factory Vector.fromList(List<num> src) {
    final buf = Float32List(src.length);
    for (var i = 0; i < src.length; i++) {
      buf[i] = src[i].toDouble();
    }
    return Vector(buf);
  }

  /// Zero-filled vector of length [d].
  factory Vector.zero(int d) => Vector(Float32List(d));

  /// Deep copy.
  Vector copy() => Vector(Float32List.fromList(values));

  int get dim => values.length;

  @override
  String toString() {
    // Compact JSON-ish form — safe for logging and matches the text
    // syntax accepted by [parseVectorText].
    final sb = StringBuffer('[');
    for (var i = 0; i < values.length; i++) {
      if (i != 0) sb.write(',');
      final v = values[i];
      // Prefer int-form for integral f32 values to keep output tidy.
      if (v.isFinite && v == v.truncateToDouble()) {
        sb.write(v.toInt().toString());
      } else {
        sb.write(v.toString());
      }
    }
    sb.write(']');
    return sb.toString();
  }
}

/// Encode [v] as the canonical BLOB layout:
/// `LE uint32 dim`, then `dim × LE float32` values.
Uint8List encodeVectorBlob(Vector v) {
  final out = Uint8List(4 + 4 * v.dim);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, v.dim, Endian.little);
  for (var i = 0; i < v.dim; i++) {
    bd.setFloat32(4 + 4 * i, v.values[i], Endian.little);
  }
  return out;
}

/// Decode a vector BLOB previously produced by [encodeVectorBlob].
/// Throws [FormatException] if [bytes] does not have the expected size
/// or dim header.
Vector decodeVectorBlob(List<int> bytes) {
  if (bytes.length < 4) {
    throw const FormatException('vector blob too short (need 4-byte header)');
  }
  final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final bd = ByteData.sublistView(u8);
  final dim = bd.getUint32(0, Endian.little);
  final expected = 4 + 4 * dim;
  if (u8.length != expected) {
    throw FormatException(
      'vector blob length ${u8.length} does not match dim=$dim '
      '(expected $expected bytes)',
    );
  }
  final out = Float32List(dim);
  for (var i = 0; i < dim; i++) {
    out[i] = bd.getFloat32(4 + 4 * i, Endian.little);
  }
  return Vector(out);
}

/// Parse a vector from text of the form `[1, 2, 3.5]`. Accepts any
/// JSON array of numbers.
Vector parseVectorText(String s) {
  final trimmed = s.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('empty vector literal');
  }
  final decoded = jsonDecode(trimmed);
  if (decoded is! List) {
    throw FormatException('vector literal must be a JSON array, got $decoded');
  }
  final buf = Float32List(decoded.length);
  for (var i = 0; i < decoded.length; i++) {
    final e = decoded[i];
    if (e is num) {
      buf[i] = e.toDouble();
    } else {
      throw FormatException('vector element $i is not a number: $e');
    }
  }
  return Vector(buf);
}

/// Parse a batch of vectors from `'[[1,2,3], [4,5,6]]'` — a JSON array
/// of arrays-of-numbers. A single-vector literal `'[1,2,3]'` is
/// accepted and wrapped in a singleton list. All inner vectors must
/// share the same dimension.
List<Vector> parseVectorBatchText(String s) {
  final trimmed = s.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('empty vector batch literal');
  }
  final decoded = jsonDecode(trimmed);
  if (decoded is! List) {
    throw FormatException(
      'vector batch literal must be a JSON array, got $decoded',
    );
  }
  if (decoded.isEmpty) return const [];
  // Detect single-vector shorthand: `[1, 2, 3]` -> wrap.
  if (decoded.first is num) {
    return [parseVectorText(trimmed)];
  }
  final out = <Vector>[];
  int? dim;
  for (var i = 0; i < decoded.length; i++) {
    final row = decoded[i];
    if (row is! List) {
      throw FormatException(
        'vector batch entry $i must be a JSON array, got $row',
      );
    }
    final buf = Float32List(row.length);
    for (var j = 0; j < row.length; j++) {
      final e = row[j];
      if (e is num) {
        buf[j] = e.toDouble();
      } else {
        throw FormatException(
          'vector batch [$i][$j] is not a number: $e',
        );
      }
    }
    dim ??= buf.length;
    if (buf.length != dim) {
      throw FormatException(
        'vector batch entry $i has dim ${buf.length}, expected $dim',
      );
    }
    out.add(Vector(buf));
  }
  return out;
}

/// Coerce a SQL value to a [Vector]. Accepts:
///   * a BLOB (`List<int>`) in [encodeVectorBlob] layout,
///   * a TEXT JSON-array literal, or
///   * an already-decoded [Vector].
///
/// Returns null when [v] is null; throws [FormatException] on unusable
/// input so scalar functions surface the error to the caller.
Vector? coerceVector(Object? v) {
  if (v == null) return null;
  if (v is Vector) return v;
  if (v is List<int>) return decodeVectorBlob(v);
  if (v is String) return parseVectorText(v);
  if (v is List) {
    // Generic Dart list (e.g. from JSON persistence round-trip).
    final nums = <num>[];
    for (final e in v) {
      if (e is num) {
        nums.add(e);
      } else {
        throw FormatException('vector element not numeric: $e');
      }
    }
    return Vector.fromList(nums);
  }
  throw FormatException(
    'cannot coerce ${v.runtimeType} to vector; expected BLOB, TEXT, or List',
  );
}

void _checkSameDim(Vector a, Vector b) {
  if (a.dim != b.dim) {
    throw StateError(
      'vector dimension mismatch: ${a.dim} vs ${b.dim}',
    );
  }
}

/// Squared L2 distance ‖a - b‖².
double vecL2Sq(Vector a, Vector b) {
  _checkSameDim(a, b);
  var acc = 0.0;
  final av = a.values;
  final bv = b.values;
  for (var i = 0; i < av.length; i++) {
    final d = av[i] - bv[i];
    acc += d * d;
  }
  return acc;
}

/// Euclidean distance ‖a - b‖.
double vecL2(Vector a, Vector b) => math.sqrt(vecL2Sq(a, b));

/// Inner (dot) product a·b.
double vecInnerProduct(Vector a, Vector b) {
  _checkSameDim(a, b);
  var acc = 0.0;
  final av = a.values;
  final bv = b.values;
  for (var i = 0; i < av.length; i++) {
    acc += av[i] * bv[i];
  }
  return acc;
}

/// L2 norm ‖v‖.
double vecNorm(Vector v) {
  var acc = 0.0;
  for (final x in v.values) {
    acc += x * x;
  }
  return math.sqrt(acc);
}

/// Cosine similarity in [-1, 1]. Returns 0 when either vector is the
/// zero vector (mirroring FAISS's behavior of treating undefined
/// directions as maximally dissimilar-ish).
double vecCosineSimilarity(Vector a, Vector b) {
  _checkSameDim(a, b);
  final na = vecNorm(a);
  final nb = vecNorm(b);
  if (na == 0.0 || nb == 0.0) return 0.0;
  return vecInnerProduct(a, b) / (na * nb);
}

/// Cosine distance = 1 − cosine similarity, in [0, 2].
double vecCosineDistance(Vector a, Vector b) => 1.0 - vecCosineSimilarity(a, b);

/// Return a new L2-normalized copy of [v]. A zero vector is returned
/// unchanged.
Vector vecNormalize(Vector v) {
  final n = vecNorm(v);
  if (n == 0.0) return v.copy();
  final out = Float32List(v.dim);
  for (var i = 0; i < v.dim; i++) {
    out[i] = v.values[i] / n;
  }
  return Vector(out);
}

/// Element-wise sum, returning a new vector.
Vector vecAdd(Vector a, Vector b) {
  _checkSameDim(a, b);
  final out = Float32List(a.dim);
  for (var i = 0; i < a.dim; i++) {
    out[i] = a.values[i] + b.values[i];
  }
  return Vector(out);
}

/// Element-wise difference a - b, returning a new vector.
Vector vecSub(Vector a, Vector b) {
  _checkSameDim(a, b);
  final out = Float32List(a.dim);
  for (var i = 0; i < a.dim; i++) {
    out[i] = a.values[i] - b.values[i];
  }
  return Vector(out);
}

/// One `(id, distance)` search result. `id` is whatever caller-supplied
/// key was passed to [FlatIndex.add]; `distance` is in the metric that
/// was requested at `search` time (smaller = better for L2/cosine,
/// larger = better for inner-product; the returned list is always
/// sorted best-first).
class VectorSearchHit {
  final Object? id;
  final double distance;
  const VectorSearchHit(this.id, this.distance);

  @override
  String toString() => 'VectorSearchHit($id, $distance)';
}

/// Brute-force nearest-neighbor index (FAISS `IndexFlatL2` /
/// `IndexFlatIP` equivalent). Stores every added vector verbatim in a
/// contiguous `Float32List` and scans them on each query.
///
/// This is deliberately the simplest possible index: no clustering, no
/// approximation, no build step. It is the reference implementation the
/// planner falls back to when no ANN index is present, and it also
/// serves as ground truth for any future HNSW/IVF layer.
class FlatIndex {
  /// Vector dimension. Every vector added must have this dim.
  final int dim;

  /// Default metric used when `search` is called without one.
  final VectorMetric defaultMetric;

  /// Backing storage: flat `Float32List` of length `count * dim`.
  Float32List _data;

  /// Ids, one per row. Parallel to `_data` rows.
  final List<Object?> _ids = <Object?>[];

  /// Number of vectors currently stored.
  int get length => _ids.length;

  /// V50: snapshot of live ids in insertion order.
  Iterable<Object?> get liveIds => List<Object?>.unmodifiable(_ids);

  FlatIndex(this.dim, {this.defaultMetric = VectorMetric.l2sq})
      : _data = Float32List(0);

  /// Add [v] under key [id]. Dim must match [dim].
  void add(Object? id, Vector v) {
    if (v.dim != dim) {
      throw StateError(
        'FlatIndex.add: vector dim ${v.dim} != index dim $dim',
      );
    }
    final n = _ids.length;
    final needed = (n + 1) * dim;
    if (_data.length < needed) {
      // Grow geometrically, minimum 16 rows.
      final newRows = math.max(n * 2, 16);
      final grown = Float32List(newRows * dim);
      grown.setRange(0, n * dim, _data);
      _data = grown;
    }
    _data.setRange(n * dim, (n + 1) * dim, v.values);
    _ids.add(id);
  }

  /// Remove the first entry whose id equals [id]. Returns true if
  /// something was removed. O(N) — this class is meant for small-to-
  /// medium in-memory indices; a paged variant is a follow-up.
  bool removeId(Object? id) {
    for (var i = 0; i < _ids.length; i++) {
      if (_ids[i] == id) {
        _removeAt(i);
        return true;
      }
    }
    return false;
  }

  void _removeAt(int i) {
    final n = _ids.length;
    if (i != n - 1) {
      _data.setRange(i * dim, (i + 1) * dim, _data, (n - 1) * dim);
      _ids[i] = _ids[n - 1];
    }
    _ids.removeLast();
  }

  /// Read row [i] as a fresh [Vector] (copy). Mainly for tests.
  Vector getVector(int i) {
    if (i < 0 || i >= _ids.length) {
      throw RangeError.index(i, _ids, 'i', null, _ids.length);
    }
    final out = Float32List(dim);
    out.setRange(0, dim, _data, i * dim);
    return Vector(out);
  }

  /// Return the top-[k] nearest neighbors of [query] under [metric]
  /// (defaults to [defaultMetric]). Result is sorted best-first —
  /// smallest first for L2/cosine, largest first for inner-product.
  ///
  /// Ties break by insertion order (stable).
  List<VectorSearchHit> search(
    Vector query,
    int k, {
    VectorMetric? metric,
  }) {
    if (query.dim != dim) {
      throw StateError(
        'FlatIndex.search: query dim ${query.dim} != index dim $dim',
      );
    }
    if (k <= 0 || _ids.isEmpty) return const [];
    final m = metric ?? defaultMetric;
    final larger = m == VectorMetric.innerProduct;
    final n = _ids.length;
    final effK = math.min(k, n);

    // Precompute query-side scalars once.
    double qNorm = 0.0;
    if (m == VectorMetric.cosine) {
      for (final x in query.values) {
        qNorm += x * x;
      }
      qNorm = math.sqrt(qNorm);
      if (qNorm == 0.0) qNorm = 1.0; // avoid div-by-zero
    }

    // Simple partial selection: keep the running "worst kept" score in
    // `_scores`/`_hitIds`. For small k this is fine; for very large k
    // a proper heap would help. We size for effK.
    final scores = List<double>.filled(effK, 0.0);
    final ids = List<Object?>.filled(effK, null);
    var filled = 0;

    for (var row = 0; row < n; row++) {
      final base = row * dim;
      double score;
      switch (m) {
        case VectorMetric.l2sq:
        case VectorMetric.l2:
          var acc = 0.0;
          for (var i = 0; i < dim; i++) {
            final d = _data[base + i] - query.values[i];
            acc += d * d;
          }
          score = acc;
          break;
        case VectorMetric.innerProduct:
          var acc = 0.0;
          for (var i = 0; i < dim; i++) {
            acc += _data[base + i] * query.values[i];
          }
          score = acc;
          break;
        case VectorMetric.cosine:
          var dot = 0.0;
          var norm = 0.0;
          for (var i = 0; i < dim; i++) {
            final a = _data[base + i];
            final b = query.values[i];
            dot += a * b;
            norm += a * a;
          }
          norm = math.sqrt(norm);
          score = norm == 0.0 ? 1.0 : 1.0 - dot / (norm * qNorm);
          break;
      }

      // Insert into the top-k list. `larger` flips the comparison.
      if (filled < effK) {
        // Insert in sorted position.
        var j = filled;
        while (j > 0 && _better(score, scores[j - 1], larger)) {
          scores[j] = scores[j - 1];
          ids[j] = ids[j - 1];
          j--;
        }
        scores[j] = score;
        ids[j] = _ids[row];
        filled++;
      } else if (_better(score, scores[effK - 1], larger)) {
        // Displace the current worst-kept.
        var j = effK - 1;
        while (j > 0 && _better(score, scores[j - 1], larger)) {
          scores[j] = scores[j - 1];
          ids[j] = ids[j - 1];
          j--;
        }
        scores[j] = score;
        ids[j] = _ids[row];
      }
    }

    // Convert stored score to the caller-visible distance:
    //   - l2sq: pass through
    //   - l2  : sqrt at the end
    //   - ip  : pass through (larger = better)
    //   - cos : pass through
    final out = <VectorSearchHit>[];
    for (var i = 0; i < filled; i++) {
      final s = m == VectorMetric.l2 ? math.sqrt(scores[i]) : scores[i];
      out.add(VectorSearchHit(ids[i], s));
    }
    return out;
  }

  static bool _better(double a, double b, bool larger) =>
      larger ? a > b : a < b;

  /// Serialize the entire built state to a JSON-encodable map. Used
  /// by the SQL layer to persist warmed indexes across `close()` /
  /// reopen.
  Map<String, Object?> toJson() {
    final n = _ids.length;
    return {
      'dim': dim,
      'metric': defaultMetric.name,
      'ids': [for (final id in _ids) id],
      'data': _encodeF32Slice(_data, 0, n * dim),
    };
  }

  /// Reconstruct a [FlatIndex] from [toJson] output. Throws on any
  /// structural mismatch so callers can fall back to a fresh build.
  static FlatIndex fromJson(Map<String, Object?> j) {
    final dim = (j['dim'] as num).toInt();
    final metric = VectorMetric.values.firstWhere(
      (m) => m.name == j['metric'],
      orElse: () => VectorMetric.l2sq,
    );
    final idx = FlatIndex(dim, defaultMetric: metric);
    final ids = (j['ids'] as List).cast<Object?>();
    final data = _decodeF32Slice(j['data'] as String);
    if (data.length != ids.length * dim) {
      throw FormatException(
        'FlatIndex.fromJson: data length ${data.length} '
        '!= ids ${ids.length} * dim $dim',
      );
    }
    idx._data = data;
    idx._ids.addAll(ids);
    return idx;
  }
}

// ---------------------------------------------------------------------------
// HnswIndex — approximate k-NN over a Hierarchical Navigable Small World
// graph (Malkov & Yashunin, 2018), equivalent to FAISS `IndexHNSWFlat`.
//
// Port adapted from the sibling `dart-vector-store` package
// (lib/src/hnsw.dart). Simplified to the (id, Vector) one-at-a-time API
// used by the rest of dart-db-server; internal graph algorithms are
// unchanged.
// ---------------------------------------------------------------------------

/// Approximate nearest-neighbor index using an HNSW graph. Same public
/// shape as [FlatIndex] — you can swap it in wherever brute-force gets
/// too slow. Search cost is O(log N · efSearch · d) instead of O(N · d),
/// at the price of small recall loss controlled by [efSearch].
///
/// Parameters mirror FAISS `IndexHNSWFlat`:
///   * [M] — max neighbors per node above layer 0 (layer 0 gets `2*M`).
///     Larger = better recall / more memory. Typical: 8–48.
///   * [efConstruction] — build-time beam width. Larger = better graph,
///     slower add. Typical: 40–200.
///   * [efSearch] — query-time beam width. Larger = better recall,
///     slower search. Tunable per-search via [search]'s `ef` argument.
///
/// Metric semantics: [VectorMetric.l2] and [VectorMetric.l2sq] both use
/// squared L2 internally for ranking; the visible distance is sqrt'd
/// for `l2` at the end. [VectorMetric.innerProduct] flips comparisons
/// (larger = closer); [VectorMetric.cosine] is normalized-ip distance.
class HnswIndex {
  final int dim;
  final VectorMetric defaultMetric;
  final int m;
  final int mMax0;
  int efConstruction;
  int efSearch;

  final double _mL;
  final math.Random _rng;

  // Row-major float32 storage: `_data[nodeId*dim .. (nodeId+1)*dim]`.
  Float32List _data;
  final List<Object?> _ids = <Object?>[];
  final List<int> _nodeLevel = <int>[];
  final List<List<List<int>>> _links = <List<List<int>>>[];

  int _entry = -1;
  int _topLayer = -1;
  int _tombstoneCount = 0;

  HnswIndex(
    this.dim, {
    this.m = 16,
    this.efConstruction = 40,
    this.efSearch = 16,
    this.defaultMetric = VectorMetric.l2sq,
    int seed = 1234,
  })  : mMax0 = m * 2,
        _mL = 1.0 / math.log(m.toDouble()),
        _rng = math.Random(seed),
        _data = Float32List(0);

  int get length => _ids.length;

  int get tombstoneCount => _tombstoneCount;
  int get liveCount => _ids.length - _tombstoneCount;
  double get tombstoneRatio =>
      _ids.isEmpty ? 0.0 : _tombstoneCount / _ids.length;

  /// V50: snapshot of live (non-tombstoned) ids, insertion order.
  Iterable<Object?> get liveIds => [
        for (final id in _ids)
          if (id != _tombstone) id,
      ];

  /// Add [v] under key [id]. Runs one graph-insertion step; not thread
  /// safe. Ids need not be unique, but [removeId] removes only the
  /// first match.
  void add(Object? id, Vector v) {
    if (v.dim != dim) {
      throw StateError(
        'HnswIndex.add: vector dim ${v.dim} != index dim $dim',
      );
    }
    final nodeId = _ids.length;
    _ensureCapacity(nodeId + 1);
    _data.setRange(nodeId * dim, (nodeId + 1) * dim, v.values);
    _ids.add(id);

    final level = _randomLevel();
    _nodeLevel.add(level);
    _links.add(List<List<int>>.generate(level + 1, (_) => <int>[]));

    if (_entry < 0) {
      _entry = nodeId;
      _topLayer = level;
      return;
    }

    var cur = _entry;
    for (var lc = _topLayer; lc > level; lc--) {
      cur = _greedyDescendNode(nodeId, cur, lc);
    }
    for (var lc = math.min(level, _topLayer); lc >= 0; lc--) {
      final candidates = _searchLayerNode(nodeId, cur, efConstruction, lc);
      final selected = _selectHeuristic(candidates, _maxLinksAt(lc)).toList();
      _links[nodeId][lc] = selected;
      for (final nb in selected) {
        final nbLinks = _links[nb][lc];
        nbLinks.add(nodeId);
        final maxL = _maxLinksAt(lc);
        if (nbLinks.length > maxL) {
          final cand = <(double, int)>[
            for (final v in nbLinks) (_distNodeNode(nb, v), v),
          ];
          final trimmed = _selectHeuristic(cand, maxL).toList();
          _links[nb][lc]
            ..clear()
            ..addAll(trimmed);
        }
      }
      cur = _closestOf(candidates);
    }
    if (level > _topLayer) {
      _topLayer = level;
      _entry = nodeId;
    }
  }

  /// Search for [k] nearest neighbors of [query] under [metric] (or
  /// [defaultMetric]). Optional per-call [ef] overrides [efSearch].
  /// Result is sorted best-first.
  List<VectorSearchHit> search(
    Vector query,
    int k, {
    VectorMetric? metric,
    int? ef,
  }) {
    if (query.dim != dim) {
      throw StateError(
        'HnswIndex.search: query dim ${query.dim} != index dim $dim',
      );
    }
    if (k <= 0 || _ids.isEmpty) return const [];
    final m = metric ?? defaultMetric;
    final larger = m == VectorMetric.innerProduct;
    final effEf = math.max(k, ef ?? efSearch);

    // Precompute query-side scalar for cosine.
    double qNorm = 0.0;
    if (m == VectorMetric.cosine) {
      for (final x in query.values) {
        qNorm += x * x;
      }
      qNorm = math.sqrt(qNorm);
      if (qNorm == 0.0) qNorm = 1.0;
    }

    double distQ(int nodeId) => _distQuery(query, nodeId, m, qNorm);

    // Greedy descent from top layer with ef=1.
    var cur = _entry;
    for (var lc = _topLayer; lc > 0; lc--) {
      var curD = distQ(cur);
      var improved = true;
      while (improved) {
        improved = false;
        if (lc >= _links[cur].length) break;
        for (final nb in _links[cur][lc]) {
          final di = distQ(nb);
          if (_isBetter(di, curD, larger)) {
            curD = di;
            cur = nb;
            improved = true;
          }
        }
      }
    }

    // Beam search at layer 0.
    final w = _searchLayerQuery(distQ, cur, effEf, 0, larger);
    w.sort((a, b) => larger ? b.$1.compareTo(a.$1) : a.$1.compareTo(b.$1));
    final effK = math.min(k, w.length);
    final out = <VectorSearchHit>[];
    for (var i = 0; i < effK; i++) {
      final s = m == VectorMetric.l2 ? math.sqrt(w[i].$1) : w[i].$1;
      out.add(VectorSearchHit(_ids[w[i].$2], s));
    }
    return out;
  }

  /// Remove the first entry whose id equals [id]. Returns true if
  /// removed. This is a soft-delete (the node stays in the graph as a
  /// tombstone) — the vector is zeroed and the id set to a sentinel so
  /// search skips it. HNSW does not support cheap true deletion.
  bool removeId(Object? id) {
    for (var i = 0; i < _ids.length; i++) {
      if (_ids[i] == id) {
        _ids[i] = _tombstone;
        _tombstoneCount++;
        // Zero its vector so any future distance is (typically) large.
        for (var j = 0; j < dim; j++) {
          _data[i * dim + j] = 0.0;
        }
        return true;
      }
    }
    return false;
  }

  static const Object _tombstone = Object();

  void _ensureCapacity(int rows) {
    final need = rows * dim;
    if (_data.length >= need) return;
    var cap = _data.isEmpty ? 16 * dim : _data.length;
    while (cap < need) {
      cap *= 2;
    }
    final grown = Float32List(cap);
    grown.setRange(0, _ids.length * dim, _data);
    _data = grown;
  }

  int _randomLevel() {
    var u = _rng.nextDouble();
    if (u < 1e-12) u = 1e-12;
    return (-math.log(u) * _mL).floor();
  }

  int _maxLinksAt(int level) => level == 0 ? mMax0 : m;

  // --- Distances -----------------------------------------------------------
  //
  // Internal ranking is always in the "raw" metric space:
  //   L2 / L2SQ       → squared L2   (smaller = closer)
  //   INNER_PRODUCT   → dot product  (larger  = closer)
  //   COSINE          → 1 - cos_sim  (smaller = closer)
  //
  // For construction, both endpoints are DB nodes and always use L2² —
  // this is what FAISS does too: graph topology only needs a consistent
  // ordering, and L2 gives a well-behaved "small world" regardless of
  // the search metric. Query-time distances use the requested metric.

  double _distNodeNode(int a, int b) {
    var s = 0.0;
    final ao = a * dim, bo = b * dim;
    for (var i = 0; i < dim; i++) {
      final d = _data[ao + i] - _data[bo + i];
      s += d * d;
    }
    return s;
  }

  double _distQuery(Vector q, int nodeId, VectorMetric m, double qNorm) {
    final base = nodeId * dim;
    switch (m) {
      case VectorMetric.l2:
      case VectorMetric.l2sq:
        var s = 0.0;
        for (var i = 0; i < dim; i++) {
          final d = _data[base + i] - q.values[i];
          s += d * d;
        }
        return s;
      case VectorMetric.innerProduct:
        var s = 0.0;
        for (var i = 0; i < dim; i++) {
          s += _data[base + i] * q.values[i];
        }
        return s;
      case VectorMetric.cosine:
        var dot = 0.0, norm = 0.0;
        for (var i = 0; i < dim; i++) {
          final a = _data[base + i];
          dot += a * q.values[i];
          norm += a * a;
        }
        norm = math.sqrt(norm);
        return norm == 0.0 ? 1.0 : 1.0 - dot / (norm * qNorm);
    }
  }

  static bool _isBetter(double a, double b, bool larger) =>
      larger ? a > b : a < b;

  // --- Graph traversal -----------------------------------------------------

  int _greedyDescendNode(int target, int entry, int layer) {
    var cur = entry;
    var curD = _distNodeNode(target, cur);
    var improved = true;
    while (improved) {
      improved = false;
      if (layer >= _links[cur].length) break;
      for (final nb in _links[cur][layer]) {
        final di = _distNodeNode(target, nb);
        if (di < curD) {
          curD = di;
          cur = nb;
          improved = true;
        }
      }
    }
    return cur;
  }

  /// Malkov & Yashunin Algorithm 2, node-vs-node variant used during
  /// insertion. Returns up to [ef] `(distance, nodeId)` pairs.
  List<(double, int)> _searchLayerNode(
    int target,
    int entry,
    int ef,
    int layer,
  ) {
    final visited = HashSet<int>()..add(entry);
    final startD = _distNodeNode(target, entry);
    final candidates = <(double, int)>[(startD, entry)];
    final w = <(double, int)>[(startD, entry)];

    while (candidates.isNotEmpty) {
      var bestIdx = 0;
      for (var i = 1; i < candidates.length; i++) {
        if (candidates[i].$1 < candidates[bestIdx].$1) bestIdx = i;
      }
      final cur = candidates.removeAt(bestIdx);
      var worst = w.first;
      for (final e in w) {
        if (e.$1 > worst.$1) worst = e;
      }
      if (cur.$1 > worst.$1 && w.length >= ef) break;
      if (layer >= _links[cur.$2].length) continue;
      for (final nb in _links[cur.$2][layer]) {
        if (!visited.add(nb)) continue;
        final di = _distNodeNode(target, nb);
        var wWorst = w.first;
        for (final e in w) {
          if (e.$1 > wWorst.$1) wWorst = e;
        }
        if (di < wWorst.$1 || w.length < ef) {
          candidates.add((di, nb));
          w.add((di, nb));
          if (w.length > ef) {
            var worstIdx = 0;
            for (var i = 1; i < w.length; i++) {
              if (w[i].$1 > w[worstIdx].$1) worstIdx = i;
            }
            w.removeAt(worstIdx);
          }
        }
      }
    }
    return w;
  }

  /// Layer-0 beam search from a query vector. [larger] flips the sort
  /// for inner-product ranking.
  List<(double, int)> _searchLayerQuery(
    double Function(int) distQ,
    int entry,
    int ef,
    int layer,
    bool larger,
  ) {
    final visited = HashSet<int>()..add(entry);
    final startD = distQ(entry);
    final candidates = <(double, int)>[(startD, entry)];
    final w = <(double, int)>[(startD, entry)];

    bool worseThanWorst(double d, double worst) =>
        larger ? d < worst : d > worst;
    bool betterThanWorst(double d, double worst) =>
        larger ? d > worst : d < worst;

    while (candidates.isNotEmpty) {
      // Pop best candidate.
      var bestIdx = 0;
      for (var i = 1; i < candidates.length; i++) {
        if (_isBetter(candidates[i].$1, candidates[bestIdx].$1, larger)) {
          bestIdx = i;
        }
      }
      final cur = candidates.removeAt(bestIdx);
      // Current worst of w.
      var worst = w.first;
      for (final e in w) {
        if (larger ? e.$1 < worst.$1 : e.$1 > worst.$1) worst = e;
      }
      if (worseThanWorst(cur.$1, worst.$1) && w.length >= ef) break;
      if (layer >= _links[cur.$2].length) continue;
      for (final nb in _links[cur.$2][layer]) {
        if (!visited.add(nb)) continue;
        if (_ids[nb] == _tombstone) continue;
        final di = distQ(nb);
        var wWorst = w.first;
        for (final e in w) {
          if (larger ? e.$1 < wWorst.$1 : e.$1 > wWorst.$1) wWorst = e;
        }
        if (betterThanWorst(di, wWorst.$1) || w.length < ef) {
          candidates.add((di, nb));
          w.add((di, nb));
          if (w.length > ef) {
            var worstIdx = 0;
            for (var i = 1; i < w.length; i++) {
              if (larger
                  ? w[i].$1 < w[worstIdx].$1
                  : w[i].$1 > w[worstIdx].$1) {
                worstIdx = i;
              }
            }
            w.removeAt(worstIdx);
          }
        }
      }
    }
    return w;
  }

  /// Malkov & Yashunin Algorithm 4 (with keepPrunedConnections=true) —
  /// FAISS's diversifying neighbor-selection heuristic. `candidates`
  /// are (dist-to-target, nodeId) pairs; we keep up to [maxN] that are
  /// closer to the target than to any already-selected node.
  Iterable<int> _selectHeuristic(List<(double, int)> candidates, int maxN) {
    if (candidates.length <= maxN) {
      final sorted = List<(double, int)>.from(candidates)
        ..sort((a, b) => a.$1.compareTo(b.$1));
      return sorted.map((e) => e.$2);
    }
    final working = List<(double, int)>.from(candidates)
      ..sort((a, b) => a.$1.compareTo(b.$1));
    final result = <(double, int)>[];
    final discarded = <(double, int)>[];
    for (final e in working) {
      if (result.length >= maxN) break;
      var good = true;
      for (final r in result) {
        final der = _distNodeNode(e.$2, r.$2);
        if (der < e.$1) {
          good = false;
          break;
        }
      }
      if (good) {
        result.add(e);
      } else {
        discarded.add(e);
      }
    }
    var i = 0;
    while (result.length < maxN && i < discarded.length) {
      result.add(discarded[i++]);
    }
    return result.map((e) => e.$2);
  }

  int _closestOf(List<(double, int)> cs) {
    var best = cs.first;
    for (final c in cs) {
      if (c.$1 < best.$1) best = c;
    }
    return best.$2;
  }

  /// Serialize the built graph. Excludes the RNG state — subsequent
  /// `add()` calls on a reloaded index will follow a fresh sequence,
  /// which is harmless because level assignments are heuristic.
  Map<String, Object?> toJson() {
    final n = _ids.length;
    return {
      'dim': dim,
      'metric': defaultMetric.name,
      'm': m,
      'efConstruction': efConstruction,
      'efSearch': efSearch,
      'entry': _entry,
      'topLayer': _topLayer,
      'ids': [
        for (final id in _ids) id == _tombstone ? {'__tomb__': true} : id
      ],
      'nodeLevel': _nodeLevel,
      'links': _links,
      'data': _encodeF32Slice(_data, 0, n * dim),
    };
  }

  /// Reconstruct an [HnswIndex] from [toJson] output.
  static HnswIndex fromJson(Map<String, Object?> j) {
    final dim = (j['dim'] as num).toInt();
    final metric = VectorMetric.values.firstWhere(
      (m) => m.name == j['metric'],
      orElse: () => VectorMetric.l2sq,
    );
    final idx = HnswIndex(
      dim,
      m: (j['m'] as num?)?.toInt() ?? 16,
      efConstruction: (j['efConstruction'] as num?)?.toInt() ?? 40,
      efSearch: (j['efSearch'] as num?)?.toInt() ?? 16,
      defaultMetric: metric,
    );
    final rawIds = (j['ids'] as List).cast<Object?>();
    idx._ids.addAll([
      for (final e in rawIds)
        if (e is Map && e['__tomb__'] == true) HnswIndex._tombstone else e
    ]);
    idx._tombstoneCount = idx._ids.where((e) => e == _tombstone).length;
    idx._nodeLevel
        .addAll((j['nodeLevel'] as List).cast<num>().map((n) => n.toInt()));
    idx._links.addAll([
      for (final perNode in (j['links'] as List).cast<List>())
        [
          for (final perLayer in perNode.cast<List>())
            [for (final v in perLayer.cast<num>()) v.toInt()],
        ],
    ]);
    idx._entry = (j['entry'] as num).toInt();
    idx._topLayer = (j['topLayer'] as num).toInt();
    idx._data = _decodeF32Slice(j['data'] as String);
    final n = idx._ids.length;
    if (idx._data.length != n * dim) {
      throw FormatException(
        'HnswIndex.fromJson: data length ${idx._data.length} '
        '!= ids $n * dim $dim',
      );
    }
    return idx;
  }
}

// ---------------------------------------------------------------------------
// IvfFlatIndex — cell-probe partitioning (FAISS `IndexIVFFlat`).
//
// Space is split into `nlist` Voronoi cells by k-means. On `add`, each
// vector goes to its nearest centroid's inverted list. On `search`, the
// `nprobe` nearest centroids are picked and only those inverted lists
// are scanned — trading a bit of recall for a large speedup at scale.
//
// Rule of thumb (FAISS wiki): `nlist ≈ 10·sqrt(N)`, `nprobe` between
// 1 and nlist. `nprobe = nlist` degenerates to a Flat scan.
//
// Coarse quantization is always squared-L2 (matches FAISS regardless of
// search metric) so cell topology is well-behaved. Only the final
// scoring uses the caller's [VectorMetric].
//
// Port adapted from `dart-vector-store/lib/src/ivf.dart` +
// `kmeans.dart`. Simplified to the (id, Vector) one-at-a-time API.
// ---------------------------------------------------------------------------

/// Lloyd-algorithm k-means with k-means++ initialization. Used
/// internally by [IvfFlatIndex] as the coarse quantizer. Kept private
/// because callers rarely need centroids directly.
class _KMeans {
  final int dim;
  final int k;
  final int niter;
  final math.Random _rng;

  /// Row-major `k * dim` centroids after [train].
  late Float32List centroids;

  _KMeans({
    required this.dim,
    required this.k,
    this.niter = 25,
    int seed = 1234,
  }) : _rng = math.Random(seed);

  /// Fit centroids on a flat row-major `n * dim` training buffer.
  /// Returns the mean squared distance to the assigned centroid on the
  /// last iteration (FAISS `Clustering::obj`).
  double train(Float32List xs) {
    if (xs.length % dim != 0) {
      throw ArgumentError('xs length ${xs.length} not multiple of dim=$dim');
    }
    final n = xs.length ~/ dim;
    if (n < k) {
      throw ArgumentError('need at least k=$k training points, got $n');
    }
    centroids = _kmeansPlusPlusInit(xs, n);
    final counts = Int32List(k);
    final nextCentroids = Float32List(k * dim);
    var lastObj = 0.0;

    for (var it = 0; it < niter; it++) {
      for (var i = 0; i < k; i++) {
        counts[i] = 0;
      }
      for (var i = 0; i < nextCentroids.length; i++) {
        nextCentroids[i] = 0.0;
      }
      var obj = 0.0;

      for (var i = 0; i < n; i++) {
        final off = i * dim;
        var best = 0;
        var bestD = double.infinity;
        for (var c = 0; c < k; c++) {
          final di = _sqL2Flat(xs, centroids, dim, off, c * dim);
          if (di < bestD) {
            bestD = di;
            best = c;
          }
        }
        obj += bestD;
        counts[best]++;
        final tgt = best * dim;
        for (var j = 0; j < dim; j++) {
          nextCentroids[tgt + j] += xs[off + j];
        }
      }

      for (var c = 0; c < k; c++) {
        if (counts[c] > 0) {
          final inv = 1.0 / counts[c];
          final tgt = c * dim;
          for (var j = 0; j < dim; j++) {
            centroids[tgt + j] = nextCentroids[tgt + j] * inv;
          }
        } else {
          // Steal from largest cluster with a tiny perturbation.
          var big = 0;
          for (var cc = 1; cc < k; cc++) {
            if (counts[cc] > counts[big]) big = cc;
          }
          final srcBase = big * dim;
          final dstBase = c * dim;
          for (var j = 0; j < dim; j++) {
            final jitter = (_rng.nextDouble() - 0.5) * 1e-6;
            centroids[dstBase + j] = centroids[srcBase + j] + jitter;
          }
          counts[c] = counts[big] ~/ 2;
          counts[big] -= counts[c];
        }
      }
      lastObj = obj / n;
    }
    return lastObj;
  }

  Float32List _kmeansPlusPlusInit(Float32List xs, int n) {
    final out = Float32List(k * dim);
    final first = _rng.nextInt(n);
    out.setRange(0, dim, xs, first * dim);
    final closest = Float32List(n);
    for (var i = 0; i < n; i++) {
      closest[i] = _sqL2Flat(xs, out, dim, i * dim, 0);
    }
    for (var c = 1; c < k; c++) {
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += closest[i];
      }
      int pick;
      if (sum <= 0) {
        pick = _rng.nextInt(n);
      } else {
        var target = _rng.nextDouble() * sum;
        pick = n - 1;
        for (var i = 0; i < n; i++) {
          target -= closest[i];
          if (target <= 0) {
            pick = i;
            break;
          }
        }
      }
      out.setRange(c * dim, (c + 1) * dim, xs, pick * dim);
      for (var i = 0; i < n; i++) {
        final di = _sqL2Flat(xs, out, dim, i * dim, c * dim);
        if (di < closest[i]) closest[i] = di;
      }
    }
    return out;
  }

  /// Return the index of the centroid closest (squared-L2) to the
  /// vector at `xs[offset..offset+dim]`.
  int assign(Float32List xs, int offset) {
    var best = 0;
    var bestD = double.infinity;
    for (var c = 0; c < k; c++) {
      final di = _sqL2Flat(xs, centroids, dim, offset, c * dim);
      if (di < bestD) {
        bestD = di;
        best = c;
      }
    }
    return best;
  }
}

double _sqL2Flat(Float32List a, Float32List b, int dim, int ao, int bo) {
  var s = 0.0;
  for (var i = 0; i < dim; i++) {
    final d = a[ao + i] - b[bo + i];
    s += d * d;
  }
  return s;
}

/// Cell-probe inverted-file index over dense vectors. FAISS
/// `IndexIVFFlat` port.
///
/// Lifecycle: `train(samples)` → `add(id, v)…` → `search(q, k)`.
///
/// Parameters:
///   * [nlist]  — number of Voronoi cells (k-means centroids). Larger
///     = smaller lists (faster search) but need more training data.
///   * [nprobe] — how many nearest cells to scan at query time. 1
///     lower-bound (fastest, lowest recall); [nlist] upper-bound
///     (equivalent to a Flat scan).
///   * [defaultMetric] — scoring metric at search time. The coarse
///     quantizer is always L2 (matches FAISS).
class IvfFlatIndex {
  final int dim;
  final int nlist;
  int nprobe;
  final VectorMetric defaultMetric;

  final _KMeans _quantizer;
  bool _trained = false;
  int _n = 0;

  // Per-cell packed storage. Grown geometrically.
  final List<Float32List> _cellVecs;
  final List<List<Object?>> _cellIds;
  final List<int> _cellCounts;

  IvfFlatIndex(
    this.dim, {
    required this.nlist,
    this.nprobe = 1,
    this.defaultMetric = VectorMetric.l2sq,
    int seed = 1234,
    int niter = 25,
  })  : _quantizer = _KMeans(dim: dim, k: nlist, niter: niter, seed: seed),
        _cellVecs = List<Float32List>.generate(nlist, (_) => Float32List(0)),
        _cellIds = List<List<Object?>>.generate(nlist, (_) => <Object?>[]),
        _cellCounts = List<int>.filled(nlist, 0);

  int get length => _n;
  bool get isTrained => _trained;

  /// V50: snapshot of all ids across every cell.
  Iterable<Object?> get liveIds => [
        for (var c = 0; c < nlist; c++)
          for (var i = 0; i < _cellCounts[c]; i++) _cellIds[c][i],
      ];

  /// Train the coarse quantizer on [samples]. Must be called once
  /// before [add]. [samples] should be representative of the data
  /// distribution and contain at least [nlist] vectors.
  void train(List<Vector> samples) {
    if (samples.length < nlist) {
      throw StateError(
        'IvfFlatIndex.train: need at least nlist=$nlist samples, got '
        '${samples.length}',
      );
    }
    final buf = Float32List(samples.length * dim);
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].dim != dim) {
        throw StateError(
          'IvfFlatIndex.train: sample $i dim ${samples[i].dim} != $dim',
        );
      }
      buf.setRange(i * dim, (i + 1) * dim, samples[i].values);
    }
    _quantizer.train(buf);
    _trained = true;
  }

  /// Add [v] under key [id]. Requires [train] to have been called.
  void add(Object? id, Vector v) {
    if (!_trained) {
      throw StateError('IvfFlatIndex.add: call train() first');
    }
    if (v.dim != dim) {
      throw StateError(
        'IvfFlatIndex.add: vector dim ${v.dim} != index dim $dim',
      );
    }
    // Assign — need a Float32List for centroid math; wrap v.values.
    final cell = _quantizer.assign(v.values, 0);
    _pushToCell(cell, v, id);
    _n++;
  }

  void _pushToCell(int cell, Vector v, Object? id) {
    final count = _cellCounts[cell];
    final needFloats = (count + 1) * dim;
    if (_cellVecs[cell].length < needFloats) {
      var cap = _cellVecs[cell].isEmpty ? 4 * dim : _cellVecs[cell].length;
      while (cap < needFloats) {
        cap *= 2;
      }
      final grown = Float32List(cap);
      grown.setRange(0, count * dim, _cellVecs[cell]);
      _cellVecs[cell] = grown;
    }
    _cellVecs[cell].setRange(count * dim, (count + 1) * dim, v.values);
    _cellIds[cell].add(id);
    _cellCounts[cell] = count + 1;
  }

  /// Remove the first entry whose id equals [id]. O(nlist + cellSize).
  bool removeId(Object? id) {
    for (var c = 0; c < nlist; c++) {
      final ids = _cellIds[c];
      for (var i = 0; i < ids.length; i++) {
        if (ids[i] == id) {
          _removeAt(c, i);
          return true;
        }
      }
    }
    return false;
  }

  void _removeAt(int cell, int i) {
    final count = _cellCounts[cell];
    if (i != count - 1) {
      // Move last row into slot i.
      _cellVecs[cell]
          .setRange(i * dim, (i + 1) * dim, _cellVecs[cell], (count - 1) * dim);
      _cellIds[cell][i] = _cellIds[cell][count - 1];
    }
    _cellIds[cell].removeLast();
    _cellCounts[cell] = count - 1;
    _n--;
  }

  /// Pick the [nprobe] nearest cell centroids (squared-L2) to [query].
  List<int> _probeCells(Vector query, int nProbe) {
    final probes = nProbe.clamp(1, nlist);
    // Simple partial selection since nlist is typically small.
    final scored = List<(double, int)>.generate(nlist, (c) {
      var s = 0.0;
      final base = c * dim;
      for (var i = 0; i < dim; i++) {
        final d = _quantizer.centroids[base + i] - query.values[i];
        s += d * d;
      }
      return (s, c);
    })
      ..sort((a, b) => a.$1.compareTo(b.$1));
    return [for (var i = 0; i < probes; i++) scored[i].$2];
  }

  /// Top-[k] nearest neighbors of [query] under [metric] (or
  /// [defaultMetric]). Optional per-call [nprobe] overrides the field.
  List<VectorSearchHit> search(
    Vector query,
    int k, {
    VectorMetric? metric,
    int? nprobe,
  }) {
    if (!_trained) {
      throw StateError('IvfFlatIndex.search: call train() first');
    }
    if (query.dim != dim) {
      throw StateError(
        'IvfFlatIndex.search: query dim ${query.dim} != index dim $dim',
      );
    }
    if (k <= 0 || _n == 0) return const [];
    final m = metric ?? defaultMetric;
    final larger = m == VectorMetric.innerProduct;
    final cells = _probeCells(query, nprobe ?? this.nprobe);

    // Precompute cosine query-norm.
    double qNorm = 0.0;
    if (m == VectorMetric.cosine) {
      for (final x in query.values) {
        qNorm += x * x;
      }
      qNorm = math.sqrt(qNorm);
      if (qNorm == 0.0) qNorm = 1.0;
    }

    final effK = math.min(k, _n);
    final scores = List<double>.filled(effK, 0.0);
    final ids = List<Object?>.filled(effK, null);
    var filled = 0;

    for (final cell in cells) {
      final vecs = _cellVecs[cell];
      final cellIds = _cellIds[cell];
      final count = _cellCounts[cell];
      for (var r = 0; r < count; r++) {
        final base = r * dim;
        double score;
        switch (m) {
          case VectorMetric.l2sq:
          case VectorMetric.l2:
            var s = 0.0;
            for (var i = 0; i < dim; i++) {
              final d = vecs[base + i] - query.values[i];
              s += d * d;
            }
            score = s;
            break;
          case VectorMetric.innerProduct:
            var s = 0.0;
            for (var i = 0; i < dim; i++) {
              s += vecs[base + i] * query.values[i];
            }
            score = s;
            break;
          case VectorMetric.cosine:
            var dot = 0.0, norm = 0.0;
            for (var i = 0; i < dim; i++) {
              final a = vecs[base + i];
              dot += a * query.values[i];
              norm += a * a;
            }
            norm = math.sqrt(norm);
            score = norm == 0.0 ? 1.0 : 1.0 - dot / (norm * qNorm);
            break;
        }
        _insertTopK(scores, ids, filled, score, cellIds[r], larger, effK);
        if (filled < effK) filled++;
      }
    }

    final out = <VectorSearchHit>[];
    for (var i = 0; i < filled; i++) {
      final s = m == VectorMetric.l2 ? math.sqrt(scores[i]) : scores[i];
      out.add(VectorSearchHit(ids[i], s));
    }
    return out;
  }

  /// Insertion-sort into the fixed-size (scores, ids) top-k arrays.
  /// [filled] is the current fill; grows up to [cap]. Elements are
  /// kept best-first (smallest when !larger, largest when larger).
  static void _insertTopK(
    List<double> scores,
    List<Object?> ids,
    int filled,
    double score,
    Object? id,
    bool larger,
    int cap,
  ) {
    bool better(double a, double b) => larger ? a > b : a < b;
    if (filled < cap) {
      var j = filled;
      while (j > 0 && better(score, scores[j - 1])) {
        scores[j] = scores[j - 1];
        ids[j] = ids[j - 1];
        j--;
      }
      scores[j] = score;
      ids[j] = id;
      return;
    }
    if (!better(score, scores[cap - 1])) return;
    var j = cap - 1;
    while (j > 0 && better(score, scores[j - 1])) {
      scores[j] = scores[j - 1];
      ids[j] = ids[j - 1];
      j--;
    }
    scores[j] = score;
    ids[j] = id;
  }

  /// Serialize the trained coarse quantizer + every populated cell.
  Map<String, Object?> toJson() {
    return {
      'dim': dim,
      'metric': defaultMetric.name,
      'nlist': nlist,
      'nprobe': nprobe,
      'trained': _trained,
      'n': _n,
      'centroids': _encodeF32Slice(
        _quantizer.centroids,
        0,
        _quantizer.centroids.length,
      ),
      'cells': [
        for (var c = 0; c < nlist; c++)
          {
            'count': _cellCounts[c],
            'ids': [for (final id in _cellIds[c]) id],
            'vecs': _encodeF32Slice(_cellVecs[c], 0, _cellCounts[c] * dim),
          },
      ],
    };
  }

  /// Reconstruct an [IvfFlatIndex] from [toJson] output.
  static IvfFlatIndex fromJson(Map<String, Object?> j) {
    final dim = (j['dim'] as num).toInt();
    final metric = VectorMetric.values.firstWhere(
      (m) => m.name == j['metric'],
      orElse: () => VectorMetric.l2sq,
    );
    final nlist = (j['nlist'] as num).toInt();
    final idx = IvfFlatIndex(
      dim,
      nlist: nlist,
      nprobe: (j['nprobe'] as num?)?.toInt() ?? 1,
      defaultMetric: metric,
    );
    final centroids = _decodeF32Slice(j['centroids'] as String);
    if (centroids.length != nlist * dim) {
      throw FormatException(
        'IvfFlatIndex.fromJson: centroids length ${centroids.length} '
        '!= nlist $nlist * dim $dim',
      );
    }
    idx._quantizer.centroids = centroids;
    idx._trained = (j['trained'] as bool?) ?? true;
    idx._n = (j['n'] as num).toInt();
    final cells = (j['cells'] as List).cast<Map>();
    if (cells.length != nlist) {
      throw FormatException(
        'IvfFlatIndex.fromJson: cells length ${cells.length} != nlist $nlist',
      );
    }
    for (var c = 0; c < nlist; c++) {
      final cell = cells[c].cast<String, Object?>();
      final count = (cell['count'] as num).toInt();
      idx._cellCounts[c] = count;
      idx._cellIds[c] = (cell['ids'] as List).cast<Object?>().toList();
      idx._cellVecs[c] = _decodeF32Slice(cell['vecs'] as String);
    }
    return idx;
  }
}

// ---------------------------------------------------------------------------
// LshIndex — sign-projection Locality-Sensitive Hashing (FAISS `IndexLSH`).
//
// Each vector is projected onto `nbits` Gaussian hyperplanes; the sign
// of every projection becomes one bit. Search ranks the whole database
// by Hamming distance between packed codes — dramatically cheaper
// per-comparison than L2 in float space (an 8-byte popcount vs
// dim * (sub + mul + add)) though still a full linear scan of codes.
//
// LSH is approximate. Recall depends on `nbits` (more bits = better
// separation; typical 32..1024). Below ~64 bits recall on non-toy data
// drops steeply.
//
// Ranks are always in Hamming space regardless of the caller's
// requested metric. The planner treats it as an L2-proxy and rescoring
// on the surviving top-k with the true metric is a common pattern.
//
// Port adapted from `dart-vector-store/lib/src/lsh.dart`.
// ---------------------------------------------------------------------------

/// Sign-projection LSH over dense vectors. See file header for
/// semantics. Codes are packed into `(nbits + 7) ~/ 8` bytes each.
class LshIndex {
  final int dim;
  final int nbits;
  final int codeSize;
  final Float32List _projectors;
  final List<Object?> _ids = <Object?>[];
  Uint8List _codes = Uint8List(0);

  LshIndex(
    this.dim, {
    this.nbits = 64,
    int seed = 1234,
  })  : codeSize = (nbits + 7) ~/ 8,
        _projectors = _randomGaussianMatrix(nbits, dim, seed);

  int get length => _ids.length;

  /// V50: snapshot of ids in insertion order.
  Iterable<Object?> get liveIds => List<Object?>.unmodifiable(_ids);

  /// Add [v] under key [id]. Encodes on-the-fly; codes are stored
  /// contiguously in [_codes].
  void add(Object? id, Vector v) {
    if (v.dim != dim) {
      throw StateError(
        'LshIndex.add: vector dim ${v.dim} != index dim $dim',
      );
    }
    final n = _ids.length;
    final need = (n + 1) * codeSize;
    if (_codes.length < need) {
      var cap = _codes.isEmpty ? 16 * codeSize : _codes.length;
      while (cap < need) {
        cap *= 2;
      }
      final grown = Uint8List(cap);
      grown.setRange(0, n * codeSize, _codes);
      _codes = grown;
    }
    _encodeOne(v.values, _codes, n * codeSize);
    _ids.add(id);
  }

  /// Remove the first entry whose id equals [id]. Swap-last, O(N) in
  /// the id lookup.
  bool removeId(Object? id) {
    for (var i = 0; i < _ids.length; i++) {
      if (_ids[i] == id) {
        final n = _ids.length;
        if (i != n - 1) {
          _codes.setRange(
              i * codeSize, (i + 1) * codeSize, _codes, (n - 1) * codeSize);
          _ids[i] = _ids[n - 1];
        }
        _ids.removeLast();
        return true;
      }
    }
    return false;
  }

  /// Encode `v[0..dim]` into `dst[dstOff..dstOff+codeSize]`.
  void _encodeOne(Float32List v, Uint8List dst, int dstOff) {
    for (var b = 0; b < codeSize; b++) {
      dst[dstOff + b] = 0;
    }
    for (var i = 0; i < nbits; i++) {
      var s = 0.0;
      final row = i * dim;
      for (var j = 0; j < dim; j++) {
        s += _projectors[row + j] * v[j];
      }
      if (s > 0) {
        dst[dstOff + (i >> 3)] |= (1 << (i & 7));
      }
    }
  }

  static int _popcount(int x) {
    var v = x;
    var c = 0;
    while (v != 0) {
      v &= v - 1;
      c++;
    }
    return c;
  }

  int _hamming(Uint8List a, int aOff, Uint8List b, int bOff) {
    var s = 0;
    for (var i = 0; i < codeSize; i++) {
      s += _popcount(a[aOff + i] ^ b[bOff + i]);
    }
    return s;
  }

  /// Top-[k] nearest neighbors of [query] under Hamming distance. The
  /// [metric] argument is accepted for API symmetry with the other
  /// index kinds but ignored — LSH always ranks in Hamming space.
  List<VectorSearchHit> search(
    Vector query,
    int k, {
    VectorMetric? metric,
  }) {
    if (query.dim != dim) {
      throw StateError(
        'LshIndex.search: query dim ${query.dim} != index dim $dim',
      );
    }
    if (k <= 0 || _ids.isEmpty) return const [];
    final n = _ids.length;
    final effK = math.min(k, n);
    final qcode = Uint8List(codeSize);
    _encodeOne(query.values, qcode, 0);

    final scores = List<double>.filled(effK, 0.0);
    final ids = List<Object?>.filled(effK, null);
    var filled = 0;
    for (var r = 0; r < n; r++) {
      final di = _hamming(qcode, 0, _codes, r * codeSize).toDouble();
      if (filled < effK) {
        var j = filled;
        while (j > 0 && di < scores[j - 1]) {
          scores[j] = scores[j - 1];
          ids[j] = ids[j - 1];
          j--;
        }
        scores[j] = di;
        ids[j] = _ids[r];
        filled++;
      } else if (di < scores[effK - 1]) {
        var j = effK - 1;
        while (j > 0 && di < scores[j - 1]) {
          scores[j] = scores[j - 1];
          ids[j] = ids[j - 1];
          j--;
        }
        scores[j] = di;
        ids[j] = _ids[r];
      }
    }
    return [
      for (var i = 0; i < filled; i++) VectorSearchHit(ids[i], scores[i])
    ];
  }

  /// Box-Muller Gaussian projector matrix; `rows * cols` values, row-major.
  static Float32List _randomGaussianMatrix(int rows, int cols, int seed) {
    final rng = math.Random(seed);
    final out = Float32List(rows * cols);
    for (var i = 0; i < rows * cols; i += 2) {
      final u1 = rng.nextDouble().clamp(1e-12, 1.0);
      final u2 = rng.nextDouble();
      final r = math.sqrt(-2.0 * math.log(u1));
      final theta = 2.0 * math.pi * u2;
      out[i] = r * math.cos(theta);
      if (i + 1 < out.length) out[i + 1] = r * math.sin(theta);
    }
    return out;
  }

  /// Serialize the built code table. Projectors are regenerated from
  /// `(seed, nbits, dim)` on load — no need to persist them.
  Map<String, Object?> toJson(int seed) {
    return {
      'dim': dim,
      'nbits': nbits,
      'seed': seed,
      'ids': [for (final id in _ids) id],
      'codes': base64.encode(_codes.sublist(0, _ids.length * codeSize)),
    };
  }

  /// Reconstruct an [LshIndex] from [toJson] output.
  static LshIndex fromJson(Map<String, Object?> j) {
    final dim = (j['dim'] as num).toInt();
    final nbits = (j['nbits'] as num?)?.toInt() ?? 64;
    final seed = (j['seed'] as num?)?.toInt() ?? 1234;
    final idx = LshIndex(dim, nbits: nbits, seed: seed);
    final ids = (j['ids'] as List).cast<Object?>();
    final codes = base64.decode(j['codes'] as String);
    if (codes.length != ids.length * idx.codeSize) {
      throw FormatException(
        'LshIndex.fromJson: codes length ${codes.length} '
        '!= ids ${ids.length} * codeSize ${idx.codeSize}',
      );
    }
    idx._codes = Uint8List.fromList(codes);
    idx._ids.addAll(ids);
    return idx;
  }
}

/// Encode a slice of a [Float32List] to base64 (LE byte order).
String _encodeF32Slice(Float32List src, int start, int lengthInFloats) {
  final bytes = Uint8List(lengthInFloats * 4);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < lengthInFloats; i++) {
    bd.setFloat32(i * 4, src[start + i], Endian.little);
  }
  return base64.encode(bytes);
}

/// Decode a base64 payload from [_encodeF32Slice] into a fresh
/// [Float32List]. Length is inferred from the payload size.
Float32List _decodeF32Slice(String b64) {
  final bytes = base64.decode(b64);
  if (bytes.length % 4 != 0) {
    throw FormatException(
      'float32 payload length ${bytes.length} not a multiple of 4',
    );
  }
  final out = Float32List(bytes.length ~/ 4);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < out.length; i++) {
    out[i] = bd.getFloat32(i * 4, Endian.little);
  }
  return out;
}

// ---------------------------------------------------------------------------
// PqIndex — Product Quantization (FAISS `IndexPQ`).
//
// Compresses each d-dim vector to `m` bytes by splitting it into `m`
// contiguous sub-vectors of size `dsub = d / m` and encoding each
// sub-vector as its nearest codebook centroid (256 per subspace, since
// nbits is fixed at 8). Search precomputes an m×256 ADC lookup table
// per query, then sums m table lookups per DB vector — one order of
// magnitude cheaper than an f32 L2 scan while ranking approximately
// the same rows.
//
// Ports `dart-vector-store/lib/src/pq.dart`, adapted to the one-at-a-
// time `(id, Vector)` API and reusing the private `_KMeans` helper.
// ---------------------------------------------------------------------------

/// PQ codec: splits d-dim vectors into `m` sub-vectors and encodes each
/// as an 8-bit code via subspace k-means. Not a search index by itself
/// — [PqIndex] wraps it.
class _ProductQuantizer {
  final int dim;
  final int m;
  final int dsub;
  static const int ksub = 256; // nbits = 8

  /// Row-major `m * ksub * dsub` centroid table.
  late Float32List centroids;
  bool trained = false;

  final int _seed;
  final int _niter;

  _ProductQuantizer({
    required this.dim,
    required this.m,
    int seed = 1234,
    int niter = 25,
  })  : dsub = dim ~/ m,
        _seed = seed,
        _niter = niter {
    if (dim % m != 0) {
      throw ArgumentError('PQ dim=$dim must be a multiple of m=$m');
    }
  }

  int _subOffset(int sub) => sub * ksub * dsub;

  /// Fit `m` codebooks — one k-means per subspace. FAISS recommends
  /// at least `40 * ksub` training points for stable codebooks.
  void train(Float32List xs) {
    if (xs.length % dim != 0) {
      throw ArgumentError('PQ train xs length not multiple of dim');
    }
    final n = xs.length ~/ dim;
    centroids = Float32List(m * ksub * dsub);
    final subBuf = Float32List(n * dsub);
    for (var sub = 0; sub < m; sub++) {
      for (var i = 0; i < n; i++) {
        subBuf.setRange(i * dsub, (i + 1) * dsub, xs, i * dim + sub * dsub);
      }
      final km = _KMeans(dim: dsub, k: ksub, niter: _niter, seed: _seed + sub);
      km.train(subBuf);
      centroids.setRange(
        _subOffset(sub),
        _subOffset(sub) + ksub * dsub,
        km.centroids,
      );
    }
    trained = true;
  }

  /// Encode a single d-dim vector into `m` byte codes.
  void encodeOne(Float32List v, Uint8List dst, int dstOff) {
    for (var sub = 0; sub < m; sub++) {
      final subOff = _subOffset(sub);
      final vOff = sub * dsub;
      var best = 0;
      var bestD = double.infinity;
      for (var c = 0; c < ksub; c++) {
        var s = 0.0;
        final cOff = subOff + c * dsub;
        for (var j = 0; j < dsub; j++) {
          final diff = v[vOff + j] - centroids[cOff + j];
          s += diff * diff;
        }
        if (s < bestD) {
          bestD = s;
          best = c;
        }
      }
      dst[dstOff + sub] = best;
    }
  }

  /// Build the `m * ksub` asymmetric-distance lookup table for the
  /// query [q]. Entry `[sub * ksub + c]` = squared L2 between the
  /// query's sub-vector and centroid `c` of subspace `sub`.
  Float32List buildDistanceTable(Float32List q) {
    final lut = Float32List(m * ksub);
    for (var sub = 0; sub < m; sub++) {
      final subOff = _subOffset(sub);
      final qsubOff = sub * dsub;
      for (var c = 0; c < ksub; c++) {
        var s = 0.0;
        final cOff = subOff + c * dsub;
        for (var j = 0; j < dsub; j++) {
          final diff = q[qsubOff + j] - centroids[cOff + j];
          s += diff * diff;
        }
        lut[sub * ksub + c] = s;
      }
    }
    return lut;
  }

  double lookupDistance(Float32List lut, Uint8List codes, int codeOff) {
    var s = 0.0;
    for (var sub = 0; sub < m; sub++) {
      s += lut[sub * ksub + codes[codeOff + sub]];
    }
    return s;
  }
}

/// Product-quantization search index. Requires `train(...)` before
/// `add(...)`. Stores each vector as [m] bytes; search uses ADC and
/// ranks in approximate squared-L2 space.
class PqIndex {
  final int dim;
  final int m;
  final _ProductQuantizer _pq;
  Uint8List _codes = Uint8List(0);
  final List<Object?> _ids = <Object?>[];

  PqIndex(
    this.dim, {
    required this.m,
    int seed = 1234,
    int niter = 25,
  }) : _pq = _ProductQuantizer(dim: dim, m: m, seed: seed, niter: niter);

  int get length => _ids.length;
  bool get isTrained => _pq.trained;

  /// V50: snapshot of ids in insertion order.
  Iterable<Object?> get liveIds => List<Object?>.unmodifiable(_ids);

  /// Fit codebooks on training vectors.
  void train(List<Vector> samples) {
    if (samples.isEmpty) {
      throw StateError('PqIndex.train: need at least 1 sample');
    }
    final buf = Float32List(samples.length * dim);
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].dim != dim) {
        throw StateError(
          'PqIndex.train: sample $i dim ${samples[i].dim} != $dim',
        );
      }
      buf.setRange(i * dim, (i + 1) * dim, samples[i].values);
    }
    _pq.train(buf);
  }

  /// Add [v] under key [id]. Encodes on-the-fly into the running code
  /// buffer.
  void add(Object? id, Vector v) {
    if (!_pq.trained) {
      throw StateError('PqIndex.add: call train() first');
    }
    if (v.dim != dim) {
      throw StateError('PqIndex.add: vector dim ${v.dim} != index dim $dim');
    }
    final n = _ids.length;
    final need = (n + 1) * m;
    if (_codes.length < need) {
      var cap = _codes.isEmpty ? 16 * m : _codes.length;
      while (cap < need) {
        cap *= 2;
      }
      final grown = Uint8List(cap);
      grown.setRange(0, n * m, _codes);
      _codes = grown;
    }
    _pq.encodeOne(v.values, _codes, n * m);
    _ids.add(id);
  }

  /// Remove the first entry whose id equals [id] via swap-last. O(N).
  bool removeId(Object? id) {
    for (var i = 0; i < _ids.length; i++) {
      if (_ids[i] == id) {
        final n = _ids.length;
        if (i != n - 1) {
          _codes.setRange(i * m, (i + 1) * m, _codes, (n - 1) * m);
          _ids[i] = _ids[n - 1];
        }
        _ids.removeLast();
        return true;
      }
    }
    return false;
  }

  /// Top-[k] nearest neighbors of [query] under ADC. The [metric] arg
  /// is accepted for API symmetry but ignored — PQ ranks in
  /// approximate squared-L2 always.
  List<VectorSearchHit> search(
    Vector query,
    int k, {
    VectorMetric? metric,
  }) {
    if (!_pq.trained) {
      throw StateError('PqIndex.search: call train() first');
    }
    if (query.dim != dim) {
      throw StateError(
        'PqIndex.search: query dim ${query.dim} != index dim $dim',
      );
    }
    if (k <= 0 || _ids.isEmpty) return const [];
    final n = _ids.length;
    final effK = math.min(k, n);
    final lut = _pq.buildDistanceTable(query.values);
    final scores = List<double>.filled(effK, 0.0);
    final ids = List<Object?>.filled(effK, null);
    var filled = 0;
    for (var r = 0; r < n; r++) {
      final di = _pq.lookupDistance(lut, _codes, r * m);
      if (filled < effK) {
        var j = filled;
        while (j > 0 && di < scores[j - 1]) {
          scores[j] = scores[j - 1];
          ids[j] = ids[j - 1];
          j--;
        }
        scores[j] = di;
        ids[j] = _ids[r];
        filled++;
      } else if (di < scores[effK - 1]) {
        var j = effK - 1;
        while (j > 0 && di < scores[j - 1]) {
          scores[j] = scores[j - 1];
          ids[j] = ids[j - 1];
          j--;
        }
        scores[j] = di;
        ids[j] = _ids[r];
      }
    }
    return [
      for (var i = 0; i < filled; i++) VectorSearchHit(ids[i], scores[i]),
    ];
  }

  /// Serialize the trained codebooks + code table.
  Map<String, Object?> toJson() {
    return {
      'dim': dim,
      'm': m,
      'trained': _pq.trained,
      'centroids': _encodeF32Slice(
        _pq.centroids,
        0,
        _pq.centroids.length,
      ),
      'ids': [for (final id in _ids) id],
      'codes': base64.encode(_codes.sublist(0, _ids.length * m)),
    };
  }

  /// Reconstruct a [PqIndex] from [toJson] output.
  static PqIndex fromJson(Map<String, Object?> j) {
    final dim = (j['dim'] as num).toInt();
    final m = (j['m'] as num).toInt();
    final idx = PqIndex(dim, m: m);
    final centroids = _decodeF32Slice(j['centroids'] as String);
    final expected = idx._pq.m * _ProductQuantizer.ksub * idx._pq.dsub;
    if (centroids.length != expected) {
      throw FormatException(
        'PqIndex.fromJson: centroids length ${centroids.length} != $expected',
      );
    }
    idx._pq.centroids = centroids;
    idx._pq.trained = (j['trained'] as bool?) ?? true;
    final ids = (j['ids'] as List).cast<Object?>();
    final codes = base64.decode(j['codes'] as String);
    if (codes.length != ids.length * m) {
      throw FormatException(
        'PqIndex.fromJson: codes length ${codes.length} '
        '!= ids ${ids.length} * m $m',
      );
    }
    idx._codes = Uint8List.fromList(codes);
    idx._ids.addAll(ids);
    return idx;
  }
}

// ---------------------------------------------------------------------------
// IvfPqIndex — IVF + PQ composite (FAISS `IndexIVFPQ`).
//
// The FAISS workhorse for billion-scale ANN. Space is partitioned into
// `nlist` Voronoi cells by k-means (the "coarse quantizer"); within
// each cell, vectors are stored as PQ codes of their **residuals**
// (`x - centroid_c`). At query time only the `nprobe` nearest cells
// are scanned, and inside each cell distances are computed via ADC on
// the residual codes — sub-linear search over a compressed store.
//
// Distance semantics: for a probed cell with centroid c,
//   ||q - x||² = ||(q - c) - (x - c)||² ≈ ADC(q - c, PQcode(x - c))
// so the ADC LUT is rebuilt per cell using the residual query. The
// codebooks themselves are shared across cells.
//
// Ports composition ideas from `dart-vector-store/lib/src/ivfpq.dart`.
// ---------------------------------------------------------------------------

/// IVF cell-probe + PQ residual compression. Requires `train(...)`
/// before `add(...)` (trains coarse quantizer and PQ codebooks in
/// sequence). Ranks in approximate squared L2 always — the `metric`
/// argument to `search` is accepted for API symmetry but ignored.
class IvfPqIndex {
  final int dim;
  final int nlist;
  int nprobe;
  final int m;

  final _KMeans _coarseQuantizer;
  final _ProductQuantizer _pq;
  bool _trained = false;
  int _n = 0;

  // Per-cell packed storage.
  final List<Uint8List> _cellCodes;
  final List<List<Object?>> _cellIds;
  final List<int> _cellCounts;

  IvfPqIndex(
    this.dim, {
    required this.nlist,
    required this.m,
    this.nprobe = 1,
    int seed = 1234,
    int niter = 25,
  })  : _coarseQuantizer =
            _KMeans(dim: dim, k: nlist, niter: niter, seed: seed),
        _pq = _ProductQuantizer(
          dim: dim,
          m: m,
          seed: seed + 100,
          niter: niter,
        ),
        _cellCodes = List<Uint8List>.generate(nlist, (_) => Uint8List(0)),
        _cellIds = List<List<Object?>>.generate(nlist, (_) => <Object?>[]),
        _cellCounts = List<int>.filled(nlist, 0);

  int get length => _n;
  bool get isTrained => _trained;

  /// V50: snapshot of all ids across every cell.
  Iterable<Object?> get liveIds => [
        for (var c = 0; c < nlist; c++)
          for (var i = 0; i < _cellCounts[c]; i++) _cellIds[c][i],
      ];

  /// Train coarse quantizer + PQ codebooks on residuals.
  void train(List<Vector> samples) {
    if (samples.length < nlist) {
      throw StateError(
        'IvfPqIndex.train: need at least nlist=$nlist samples, got '
        '${samples.length}',
      );
    }
    final buf = Float32List(samples.length * dim);
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].dim != dim) {
        throw StateError(
          'IvfPqIndex.train: sample $i dim ${samples[i].dim} != $dim',
        );
      }
      buf.setRange(i * dim, (i + 1) * dim, samples[i].values);
    }
    _coarseQuantizer.train(buf);

    // Compute residuals against each sample's nearest centroid.
    final residuals = Float32List(samples.length * dim);
    for (var i = 0; i < samples.length; i++) {
      final cell = _coarseQuantizer.assign(buf, i * dim);
      final cOff = cell * dim;
      final rOff = i * dim;
      for (var j = 0; j < dim; j++) {
        residuals[rOff + j] =
            buf[i * dim + j] - _coarseQuantizer.centroids[cOff + j];
      }
    }
    _pq.train(residuals);
    _trained = true;
  }

  /// Add [v] under key [id]. Assigns to nearest cell, encodes its
  /// residual, appends the PQ code.
  void add(Object? id, Vector v) {
    if (!_trained) {
      throw StateError('IvfPqIndex.add: call train() first');
    }
    if (v.dim != dim) {
      throw StateError(
        'IvfPqIndex.add: vector dim ${v.dim} != index dim $dim',
      );
    }
    final cell = _coarseQuantizer.assign(v.values, 0);
    final cOff = cell * dim;
    final residual = Float32List(dim);
    for (var j = 0; j < dim; j++) {
      residual[j] = v.values[j] - _coarseQuantizer.centroids[cOff + j];
    }
    final code = Uint8List(m);
    _pq.encodeOne(residual, code, 0);
    _pushToCell(cell, code, id);
    _n++;
  }

  void _pushToCell(int cell, Uint8List code, Object? id) {
    final count = _cellCounts[cell];
    final need = (count + 1) * m;
    if (_cellCodes[cell].length < need) {
      var cap = _cellCodes[cell].isEmpty ? 4 * m : _cellCodes[cell].length;
      while (cap < need) {
        cap *= 2;
      }
      final grown = Uint8List(cap);
      grown.setRange(0, count * m, _cellCodes[cell]);
      _cellCodes[cell] = grown;
    }
    _cellCodes[cell].setRange(count * m, need, code);
    _cellIds[cell].add(id);
    _cellCounts[cell] = count + 1;
  }

  /// Remove the first entry whose id equals [id]. Walks all cells.
  bool removeId(Object? id) {
    for (var c = 0; c < nlist; c++) {
      final ids = _cellIds[c];
      for (var i = 0; i < ids.length; i++) {
        if (ids[i] == id) {
          _removeAt(c, i);
          return true;
        }
      }
    }
    return false;
  }

  void _removeAt(int cell, int i) {
    final count = _cellCounts[cell];
    if (i != count - 1) {
      _cellCodes[cell]
          .setRange(i * m, (i + 1) * m, _cellCodes[cell], (count - 1) * m);
      _cellIds[cell][i] = _cellIds[cell][count - 1];
    }
    _cellIds[cell].removeLast();
    _cellCounts[cell] = count - 1;
    _n--;
  }

  /// Return the [nProbe] nearest cell centroids to [query].
  List<int> _probeCells(Vector query, int nProbe) {
    final probes = nProbe.clamp(1, nlist);
    final scored = List<(double, int)>.generate(nlist, (c) {
      var s = 0.0;
      final base = c * dim;
      for (var i = 0; i < dim; i++) {
        final d = _coarseQuantizer.centroids[base + i] - query.values[i];
        s += d * d;
      }
      return (s, c);
    })
      ..sort((a, b) => a.$1.compareTo(b.$1));
    return [for (var i = 0; i < probes; i++) scored[i].$2];
  }

  /// Top-[k] nearest neighbors of [query]. Per-call [nprobe] overrides
  /// the field.
  List<VectorSearchHit> search(
    Vector query,
    int k, {
    VectorMetric? metric,
    int? nprobe,
  }) {
    if (!_trained) {
      throw StateError('IvfPqIndex.search: call train() first');
    }
    if (query.dim != dim) {
      throw StateError(
        'IvfPqIndex.search: query dim ${query.dim} != index dim $dim',
      );
    }
    if (k <= 0 || _n == 0) return const [];
    final cells = _probeCells(query, nprobe ?? this.nprobe);
    final effK = math.min(k, _n);
    final scores = List<double>.filled(effK, 0.0);
    final ids = List<Object?>.filled(effK, null);
    var filled = 0;
    final residual = Float32List(dim);

    for (final cell in cells) {
      final cOff = cell * dim;
      for (var j = 0; j < dim; j++) {
        residual[j] = query.values[j] - _coarseQuantizer.centroids[cOff + j];
      }
      final lut = _pq.buildDistanceTable(residual);
      final codes = _cellCodes[cell];
      final cellIds = _cellIds[cell];
      final count = _cellCounts[cell];
      for (var r = 0; r < count; r++) {
        final di = _pq.lookupDistance(lut, codes, r * m);
        if (filled < effK) {
          var j = filled;
          while (j > 0 && di < scores[j - 1]) {
            scores[j] = scores[j - 1];
            ids[j] = ids[j - 1];
            j--;
          }
          scores[j] = di;
          ids[j] = cellIds[r];
          filled++;
        } else if (di < scores[effK - 1]) {
          var j = effK - 1;
          while (j > 0 && di < scores[j - 1]) {
            scores[j] = scores[j - 1];
            ids[j] = ids[j - 1];
            j--;
          }
          scores[j] = di;
          ids[j] = cellIds[r];
        }
      }
    }
    return [
      for (var i = 0; i < filled; i++) VectorSearchHit(ids[i], scores[i]),
    ];
  }

  /// Serialize coarse centroids + PQ codebooks + every populated cell.
  Map<String, Object?> toJson() {
    return {
      'dim': dim,
      'nlist': nlist,
      'nprobe': nprobe,
      'm': m,
      'trained': _trained,
      'n': _n,
      'coarseCentroids': _encodeF32Slice(
        _coarseQuantizer.centroids,
        0,
        _coarseQuantizer.centroids.length,
      ),
      'pqCentroids': _encodeF32Slice(
        _pq.centroids,
        0,
        _pq.centroids.length,
      ),
      'pqTrained': _pq.trained,
      'cells': [
        for (var c = 0; c < nlist; c++)
          {
            'count': _cellCounts[c],
            'ids': [for (final id in _cellIds[c]) id],
            'codes': base64.encode(
              _cellCodes[c].sublist(0, _cellCounts[c] * m),
            ),
          },
      ],
    };
  }

  /// Reconstruct an [IvfPqIndex] from [toJson] output.
  static IvfPqIndex fromJson(Map<String, Object?> j) {
    final dim = (j['dim'] as num).toInt();
    final nlist = (j['nlist'] as num).toInt();
    final m = (j['m'] as num).toInt();
    final idx = IvfPqIndex(
      dim,
      nlist: nlist,
      m: m,
      nprobe: (j['nprobe'] as num?)?.toInt() ?? 1,
    );
    final coarse = _decodeF32Slice(j['coarseCentroids'] as String);
    if (coarse.length != nlist * dim) {
      throw FormatException(
        'IvfPqIndex.fromJson: coarse centroids length ${coarse.length} '
        '!= nlist $nlist * dim $dim',
      );
    }
    idx._coarseQuantizer.centroids = coarse;
    final pqCentroids = _decodeF32Slice(j['pqCentroids'] as String);
    final pqExpected = m * _ProductQuantizer.ksub * (dim ~/ m);
    if (pqCentroids.length != pqExpected) {
      throw FormatException(
        'IvfPqIndex.fromJson: pq centroids length ${pqCentroids.length} '
        '!= $pqExpected',
      );
    }
    idx._pq.centroids = pqCentroids;
    idx._pq.trained = (j['pqTrained'] as bool?) ?? true;
    idx._trained = (j['trained'] as bool?) ?? true;
    idx._n = (j['n'] as num).toInt();
    final cells = (j['cells'] as List).cast<Map>();
    if (cells.length != nlist) {
      throw FormatException(
        'IvfPqIndex.fromJson: cells length ${cells.length} != nlist $nlist',
      );
    }
    for (var c = 0; c < nlist; c++) {
      final cell = cells[c].cast<String, Object?>();
      final count = (cell['count'] as num).toInt();
      idx._cellCounts[c] = count;
      idx._cellIds[c] = (cell['ids'] as List).cast<Object?>().toList();
      idx._cellCodes[c] =
          Uint8List.fromList(base64.decode(cell['codes'] as String));
    }
    return idx;
  }
}

/// Dispatch on the runtime type of a built index and return its
/// serialized state, or null when the type isn't recognised.
Map<String, Object?>? vectorIndexBuiltStateToJson(
  Object idx, {
  int seed = 1234,
}) {
  if (idx is FlatIndex) return idx.toJson();
  if (idx is HnswIndex) return idx.toJson();
  if (idx is IvfFlatIndex) return idx.toJson();
  if (idx is LshIndex) return idx.toJson(seed);
  if (idx is PqIndex) return idx.toJson();
  if (idx is IvfPqIndex) return idx.toJson();
  return null;
}

/// Reconstruct a built index from a JSON payload previously produced by
/// [vectorIndexBuiltStateToJson]. Dispatches on `spec.kind`.
Object vectorIndexBuiltStateFromJson(
  VectorIndexSpec spec,
  Map<String, Object?> j,
) {
  switch (spec.kind) {
    case VectorIndexKind.flat:
      return FlatIndex.fromJson(j);
    case VectorIndexKind.hnsw:
      return HnswIndex.fromJson(j);
    case VectorIndexKind.ivf:
      return IvfFlatIndex.fromJson(j);
    case VectorIndexKind.lsh:
      return LshIndex.fromJson(j);
    case VectorIndexKind.pq:
      return PqIndex.fromJson(j);
    case VectorIndexKind.ivfPq:
      return IvfPqIndex.fromJson(j);
  }
}
