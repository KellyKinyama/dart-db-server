/// V32 sqlite-vec compat aliases — vec_length, vec_type, vec_slice
/// plus the already-existing vec_distance_L2/cosine/f32/normalize.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('V32 sqlite-vec compat aliases', () {
    late Database db;

    setUp(() async {
      db = await Database.open();
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, e BLOB)');
      await db.execute("INSERT INTO t VALUES (1, VEC('[1, 2, 3, 4]'))");
    });

    tearDown(() async {
      await db.close();
    });

    test('vec_length returns byte count (dim * 4)', () async {
      final r = await db.execute('SELECT vec_length(e) FROM t');
      expect(r.rows.single[0], 16); // 4 dims × 4 bytes
    });

    test('vec_type returns "float32"', () async {
      final r = await db.execute('SELECT vec_type(e) FROM t');
      expect(r.rows.single[0], 'float32');
    });

    test('vec_slice extracts a sub-vector', () async {
      final r = await db.execute(
        'SELECT vec_to_json(vec_slice(e, 1, 3)) FROM t',
      );
      expect(r.rows.single[0], '[2,3]');
    });

    test('vec_distance_L2 (sqlite-vec) aliases VEC_L2', () async {
      final r = await db.execute(
        "SELECT vec_distance_L2(e, VEC('[1, 2, 3, 4]')) FROM t",
      );
      expect(r.rows.single[0], 0.0);
    });

    test('vec_distance_cosine (sqlite-vec) aliases VEC_COSINE', () async {
      final r = await db.execute(
        "SELECT vec_distance_cosine(e, VEC('[1, 2, 3, 4]')) FROM t",
      );
      expect((r.rows.single[0] as num).toDouble(), closeTo(0.0, 1e-6));
    });
  });
}
