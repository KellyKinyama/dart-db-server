/// Tiny micro-benchmark harness. Not part of the test suite — run with:
///
///     dart run bench/bench.dart
///
/// Prints rows/sec for a handful of representative workloads. Numbers
/// are wall-clock on whatever machine you run it on; use them to spot
/// regressions, not to claim absolute performance.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';

const int _scaleSmall = 1000;
const int _scaleMid = 10000;

Future<void> _bench(String name, Future<void> Function() body) async {
  // Warm-up.
  await body();
  // Take the best of N runs to drop GC / scheduler jitter; using min
  // (rather than mean) keeps the number reproducible across runs.
  const reps = 5;
  var bestUs = 1 << 62;
  for (var i = 0; i < reps; i++) {
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    if (sw.elapsedMicroseconds < bestUs) bestUs = sw.elapsedMicroseconds;
  }
  stdout.writeln('  ${name.padRight(48)} $bestUs us  (best of $reps)');
}

Future<void> main() async {
  stdout.writeln('dart-db-server micro-benchmarks');
  stdout.writeln('  scale.small=$_scaleSmall  scale.mid=$_scaleMid');

  // ---- INSERT ----
  await _bench('INSERT $_scaleSmall rows (single-stmt loop)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
      for (var i = 0; i < _scaleSmall; i++) {
        await db.execute('INSERT INTO t VALUES ($i, ${i * 2})');
      }
    } finally {
      await db.close();
    }
  });

  await _bench('INSERT $_scaleSmall rows (prepared)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
      final stmt = db.prepare('INSERT INTO t VALUES (?, ?)');
      for (var i = 0; i < _scaleSmall; i++) {
        await stmt.execute(positional: [i, i * 2]);
      }
    } finally {
      await db.close();
    }
  });

  // ---- SELECT (full scan) ----
  await _bench('SELECT * full scan over $_scaleMid rows', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
      final stmt = db.prepare('INSERT INTO t VALUES (?, ?)');
      for (var i = 0; i < _scaleMid; i++) {
        await stmt.execute(positional: [i, i]);
      }
      final r = await db.execute('SELECT * FROM t');
      if (r.rows.length != _scaleMid) {
        throw StateError('row count mismatch: ${r.rows.length}');
      }
    } finally {
      await db.close();
    }
  });

  // ---- WHERE filter (no index) ----
  await _bench('SELECT WHERE on $_scaleMid rows (no index)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
      final stmt = db.prepare('INSERT INTO t VALUES (?, ?)');
      for (var i = 0; i < _scaleMid; i++) {
        await stmt.execute(positional: [i, i % 100]);
      }
      await db.execute('SELECT id, v FROM t WHERE v = 42');
    } finally {
      await db.close();
    }
  });

  // ---- WHERE filter (indexed) ----
  await _bench('SELECT WHERE on $_scaleMid rows (indexed)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute('CREATE INDEX t_v ON t(v)');
      final stmt = db.prepare('INSERT INTO t VALUES (?, ?)');
      for (var i = 0; i < _scaleMid; i++) {
        await stmt.execute(positional: [i, i % 100]);
      }
      await db.execute('SELECT id, v FROM t WHERE v = 42');
    } finally {
      await db.close();
    }
  });

  // ---- GROUP BY ----
  await _bench('GROUP BY over $_scaleMid rows', () async {
    final db = await Database.open();
    try {
      await db
          .execute('CREATE TABLE t(id INTEGER PRIMARY KEY, k TEXT, n INTEGER)');
      final stmt = db.prepare('INSERT INTO t VALUES (?, ?, ?)');
      for (var i = 0; i < _scaleMid; i++) {
        await stmt.execute(positional: [i, 'k${i % 16}', i]);
      }
      await db.execute('SELECT k, COUNT(*), SUM(n) FROM t GROUP BY k');
    } finally {
      await db.close();
    }
  });

  // ---- 2-table JOIN ----
  await _bench('JOIN 2 tables ($_scaleSmall x $_scaleSmall via PK)', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY, v INTEGER)');
      await db.execute(
          'CREATE TABLE b(id INTEGER PRIMARY KEY, a_id INTEGER, w INTEGER)');
      await db.execute('CREATE INDEX b_a_id ON b(a_id)');
      final ai = db.prepare('INSERT INTO a VALUES (?, ?)');
      final bi = db.prepare('INSERT INTO b VALUES (?, ?, ?)');
      for (var i = 0; i < _scaleSmall; i++) {
        await ai.execute(positional: [i, i]);
        await bi.execute(positional: [i, i, i * 3]);
      }
      await db
          .execute('SELECT a.id, b.w FROM a JOIN b ON b.a_id = a.id LIMIT 100');
    } finally {
      await db.close();
    }
  });
}
