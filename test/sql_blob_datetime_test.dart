/// Per-feature unit tests for BLOB and DATE/TIME support.
///
/// These exercise our engine in isolation; cross-engine parity with
/// SQLite for the same surface is in test/regression/.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('BLOB', () {
    late Database db;
    setUp(() async {
      db = await Database.open();
    });

    test('X\'..\' literal round-trips through INSERT / SELECT', () async {
      await db.execute('CREATE TABLE b (id INTEGER, data BLOB)');
      await db.execute("INSERT INTO b VALUES (1, X'cafebabe')");
      final r = await db.execute('SELECT data FROM b WHERE id = 1');
      final v = r.rows.single.single;
      expect(v, isA<List<int>>());
      expect((v as List<int>).toList(), [0xca, 0xfe, 0xba, 0xbe]);
    });

    test('TYPEOF(blob) reports "blob"', () async {
      final r = await db.execute("SELECT TYPEOF(X'00ff') AS t");
      expect(r.rows.single.single, 'blob');
    });

    test('LENGTH on a BLOB returns the byte count', () async {
      final r = await db.execute("SELECT LENGTH(X'cafebabe') AS n");
      expect(r.rows.single.single, 4);
    });

    test('JSON file persistence: BLOB survives a save/reload cycle', () async {
      final tmp = File('${Directory.systemTemp.path}/'
          'ddb_blob_${DateTime.now().microsecondsSinceEpoch}.json');
      try {
        final db1 = await Database.open(tmp.path);
        await db1.execute('CREATE TABLE b (id INTEGER, data BLOB)');
        await db1.execute("INSERT INTO b VALUES (1, X'cafe')");
        await db1.execute("INSERT INTO b VALUES (2, X'00ff7f80')");
        await db1.flush();
        await db1.close();

        final db2 = await Database.open(tmp.path);
        final r = await db2.execute('SELECT id, data FROM b ORDER BY id');
        expect(r.rows.length, 2);
        expect(r.rows[0][0], 1);
        expect((r.rows[0][1] as List<int>).toList(), [0xca, 0xfe]);
        expect(r.rows[1][0], 2);
        expect((r.rows[1][1] as List<int>).toList(), [0x00, 0xff, 0x7f, 0x80]);
        await db2.close();
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });

    test('BLOB column does not get confused with an integer array', () async {
      final tmp = File('${Directory.systemTemp.path}/'
          'ddb_blob2_${DateTime.now().microsecondsSinceEpoch}.json');
      try {
        // Pre-populate the file with a row whose BLOB column happens to
        // contain the bytes [1,2,3]. After reload, the value must still
        // be a List<int> that LENGTH() reports as 3 bytes (not as the
        // length of an array of integers).
        final db1 = await Database.open(tmp.path);
        await db1.execute('CREATE TABLE b (data BLOB)');
        await db1.execute("INSERT INTO b VALUES (X'010203')");
        await db1.flush();
        await db1.close();

        final db2 = await Database.open(tmp.path);
        final r = await db2.execute('SELECT LENGTH(data) FROM b');
        expect(r.rows.single.single, 3);
        await db2.close();
      } finally {
        if (tmp.existsSync()) tmp.deleteSync();
      }
    });

    test('coerce(STRING -> BLOB) uses UTF-8, not codeUnits', () async {
      // Sanity check on the public coerce() helper. The character
      // 'é' is two bytes in UTF-8 (0xc3 0xa9) but a single codeUnit.
      final v = coerce('é', DataType.blob);
      expect(v, isA<Uint8List>());
      expect((v as Uint8List).toList(), [0xc3, 0xa9]);
    });
  });

  group('DATE / TIME', () {
    late Database db;
    setUp(() async {
      db = await Database.open();
    });

    test('DATE / TIME / DATETIME on an ISO timestamp', () async {
      final r = await db.execute("SELECT DATE('2024-03-15T10:20:30Z'), "
          "TIME('2024-03-15T10:20:30Z'), "
          "DATETIME('2024-03-15T10:20:30Z')");
      expect(r.rows.single, ['2024-03-15', '10:20:30', '2024-03-15 10:20:30']);
    });

    test('STRFTIME formats individual components', () async {
      final r = await db.execute(
          "SELECT STRFTIME('%Y/%m/%d %H:%M:%S', '2024-03-15T10:20:30Z')");
      expect(r.rows.single.single, '2024/03/15 10:20:30');
    });

    test('JULIANDAY returns the Julian day of the Unix epoch as 2440587.5',
        () async {
      final r = await db.execute("SELECT JULIANDAY('1970-01-01T00:00:00Z')");
      expect(r.rows.single.single, closeTo(2440587.5, 1e-9));
    });

    test('UNIXEPOCH on the Unix epoch returns 0', () async {
      final r = await db.execute("SELECT UNIXEPOCH('1970-01-01T00:00:00Z')");
      expect(r.rows.single.single, 0);
    });

    test('Modifier: +N day / -N day', () async {
      final r = await db.execute("SELECT DATE('2024-03-15', '+10 days'), "
          "DATE('2024-03-15', '-15 days')");
      expect(r.rows.single, ['2024-03-25', '2024-02-29']); // 2024 leap
    });

    test('Modifier: start of month / start of year', () async {
      final r = await db.execute("SELECT DATE('2024-03-15', 'start of month'), "
          "DATE('2024-03-15', 'start of year')");
      expect(r.rows.single, ['2024-03-01', '2024-01-01']);
    });

    test('Modifier: +N months wraps year correctly', () async {
      final r = await db.execute("SELECT DATE('2024-11-15', '+3 months')");
      expect(r.rows.single.single, '2025-02-15');
    });

    test('unixepoch modifier: numeric arg is treated as epoch seconds',
        () async {
      final r = await db.execute("SELECT DATETIME(0, 'unixepoch')");
      expect(r.rows.single.single, '1970-01-01 00:00:00');
    });
  });
}
