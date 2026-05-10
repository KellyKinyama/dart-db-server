/// WAL writer round-trip: a freshly-built WAL parses back into the
/// same page overrides.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

import 'regression/sqlite_oracle.dart';

Uint8List _makePage(int pageSize, int fillByte) {
  final p = Uint8List(pageSize);
  for (var i = 0; i < pageSize; i++) {
    p[i] = fillByte;
  }
  return p;
}

void main() {
  group('WAL writer', () {
    test('built WAL parses back via SqliteFile.fromBytesWithWal', () async {
      // Build a minimal valid SQLite file via the oracle so we have
      // something whose page-size matches our WAL.
      final reason = sqliteSkipReason();
      if (reason != null) {
        markTestSkipped(reason);
        return;
      }
      final tmp = File('${Directory.systemTemp.path}/'
          'ddb_walwriter_${DateTime.now().microsecondsSinceEpoch}.sqlite');
      addTearDown(() async {
        for (final ext in ['', '-wal', '-shm', '-journal']) {
          final ff = File('${tmp.path}$ext');
          if (await ff.exists()) await ff.delete();
        }
      });
      final ora = sq.sqlite3.open(tmp.path);
      ora.execute('CREATE TABLE t(x INTEGER);');
      ora.execute('INSERT INTO t VALUES (1),(2),(3);');
      ora.dispose();
      final dbBytes = tmp.readAsBytesSync();
      final base = SqliteFile.fromBytes(dbBytes);
      final pageSize = base.header.pageSize;
      final basePages = base.header.dbSizeInPages;

      // Build a WAL that "overrides" page 2 (a content page, not the
      // schema root) with a deterministic filler. The WAL is a single
      // commit with no DB extension.
      final overridePage = _makePage(pageSize, 0xAB);
      final wal = buildWal(
        pageSize: pageSize,
        pageOverrides: {2: overridePage},
        dbSizeAfterCommit: basePages,
      );
      // Magic check: little-endian variant.
      expect(ByteData.sublistView(wal).getUint32(0), 0x377f0682);

      // Parse it back.
      final f = SqliteFile.fromBytesWithWal(dbBytes, wal);
      final p2 = f.page(2);
      expect(p2.length, pageSize);
      expect(p2.every((b) => b == 0xAB), isTrue,
          reason: 'page 2 should be the WAL override, not the original');
    });

    test('multi-frame WAL replays in order, last frame is the commit',
        () async {
      const pageSize = 4096;
      final overrides = {
        2: _makePage(pageSize, 0x11),
        5: _makePage(pageSize, 0x22),
        9: _makePage(pageSize, 0x33),
      };
      final wal = buildWal(
        pageSize: pageSize,
        pageOverrides: overrides,
        dbSizeAfterCommit: 9,
      );
      // Header is 32 bytes, then 3 frames of (24 + 4096) each.
      expect(wal.length, 32 + 3 * (24 + pageSize));
      // Last frame's commit field (offset 4 of its header) must be 9.
      final lastFrameStart = 32 + 2 * (24 + pageSize);
      final commitField =
          ByteData.sublistView(wal).getUint32(lastFrameStart + 4);
      expect(commitField, 9);
      // Earlier frames must have commit==0.
      for (var i = 0; i < 2; i++) {
        final off = 32 + i * (24 + pageSize);
        expect(ByteData.sublistView(wal).getUint32(off + 4), 0);
      }
    });
  });
}
