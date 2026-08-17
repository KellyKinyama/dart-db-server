/// V37 persist-chain: overlapping `_persist()` calls (unawaited from
/// TVFs vs awaited from public API) must serialise instead of racing
/// on the `.tmp` file. Previously flaked under CI concurrency with
/// `PathAccessException: The process cannot access the file`.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_vec37_');
  return '${dir.path}${Platform.pathSeparator}$tag.json';
}

void main() {
  group('V37 persist serialisation', () {
    test('vec_batch_insert + warmVectorIndexes tight loop does not race',
        () async {
      // Repeat enough iterations to shake out any residual race.
      for (var iter = 0; iter < 5; iter++) {
        final db = await Database.open(_tmp('race_$iter'));
        try {
          await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
              'embedding BLOB VECTOR(dim=2))');

          // Fire a bunch of batch inserts (each schedules an unawaited
          // _persist) then immediately warm (awaited _persist).
          for (var b = 0; b < 4; b++) {
            final base = b * 10 + 1;
            await db.execute(
              "SELECT inserted FROM vec_batch_insert("
              "'docs', 'id', 'embedding', "
              "'[{\"id\":${base},\"vec\":[1,0]},"
              " {\"id\":${base + 1},\"vec\":[2,0]}]')",
            );
          }
          await db.warmVectorIndexes();

          final r = await db.execute('SELECT COUNT(*) FROM docs');
          expect(r.rows.single[0], 8);
        } finally {
          await db.close();
        }
      }
    });

    test('close mid-persist waits for chain to drain', () async {
      final path = _tmp('close_drain');
      final db = await Database.open(path);
      try {
        await db.execute('CREATE TABLE docs (id INTEGER PRIMARY KEY, '
            'embedding BLOB VECTOR(dim=2))');
        await db.execute(
          "SELECT inserted FROM vec_batch_insert("
          "'docs', 'id', 'embedding', "
          "'[{\"id\":1,\"vec\":[1,0]}]')",
        );
        // `close()` calls flush()->_persist which awaits the chain.
      } finally {
        await db.close();
      }
      // Reopen; the batch-inserted row should have been persisted.
      final db2 = await Database.open(path);
      try {
        final r = await db2.execute('SELECT COUNT(*) FROM docs');
        expect(r.rows.single[0], 1);
      } finally {
        await db2.close();
      }
    });
  });
}
