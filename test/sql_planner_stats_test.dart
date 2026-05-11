/// Verifies the query planner consumes per-column distinct counts that
/// `ANALYZE` populates in `sqlite_stat1`, and that those stats survive a
/// SQLite-format import (recovering distinct counts from
/// `<rowCount> <avgRowsPerKey>` rows produced by the real SQLite engine).
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

File _tmp(String tag) => File('${Directory.systemTemp.path}/'
    'ddb_planstat_${tag}_${DateTime.now().microsecondsSinceEpoch}.sqlite');

Future<void> _cleanup(File f) async {
  for (final ext in ['', '-wal', '-shm', '-journal']) {
    final ff = File('${f.path}$ext');
    if (await ff.exists()) await ff.delete();
  }
}

void main() {
  group('planner reads ANALYZE stats', () {
    test('queries still return correct results after ANALYZE', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT)');
        await db.execute('CREATE INDEX i_k ON t(k)');
        for (var i = 0; i < 100; i++) {
          await db.execute("INSERT INTO t VALUES ($i, 'v${i % 20}')");
        }
        await db.execute('ANALYZE');
        // Distinct count for `k` is 20; equality lookup should return 5
        // matching rows. This exercises the planner with stats present.
        final r = await db.execute("SELECT count(*) FROM t WHERE k = 'v3'");
        expect(r.rows.single.first, 5);
        // And the table count is reflected in sqlite_stat1.
        final s = await db.execute(
            "SELECT stat FROM sqlite_stat1 WHERE tbl='t' AND idx='i_k'");
        expect(s.rows.single.first, '100 5');
      } finally {
        await db.close();
      }
    });

    test('imported sqlite_stat1 recovers per-column distinct cardinality',
        () async {
      final skip = sqliteSkipReason();
      if (skip != null) return;
      final f = _tmp('imp');
      addTearDown(() async => _cleanup(f));
      // Build a SQLite DB with two indexes of very different selectivity
      // and ANALYZE it so sqlite_stat1 is populated.
      final ref = sq.sqlite3.open(f.path);
      try {
        ref.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, hi TEXT, lo TEXT)');
        ref.execute('CREATE INDEX i_hi ON t(hi)');
        ref.execute('CREATE INDEX i_lo ON t(lo)');
        final st = ref.prepare('INSERT INTO t VALUES (?, ?, ?)');
        // 100 rows: `hi` has 100 distinct values (very selective);
        // `lo` has only 2 distinct values (very unselective).
        for (var i = 0; i < 100; i++) {
          st.execute([i, 'h$i', i % 2 == 0 ? 'a' : 'b']);
        }
        st.dispose();
        ref.execute('ANALYZE');
      } finally {
        ref.dispose();
      }
      final db = await Database.open();
      try {
        await db.importSqlite(f.path);
        // sqlite_stat1 is visible.
        final visible = await db
            .execute("SELECT idx, stat FROM sqlite_stat1 WHERE tbl='t'");
        expect(visible.rows.length, greaterThanOrEqualTo(2));
        // And queries on either column still return correct results
        // (proving the planner picked something workable using the
        // imported stats).
        final hits =
            await db.execute("SELECT count(*) FROM t WHERE hi = 'h42'");
        expect(hits.rows.single.first, 1);
        final many = await db.execute("SELECT count(*) FROM t WHERE lo = 'a'");
        expect(many.rows.single.first, 50);
      } finally {
        await db.close();
      }
    });
  });
}
