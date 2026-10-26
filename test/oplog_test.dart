library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/server/oplog.dart';
import 'package:test/test.dart';

String _tmpDir(String tag) =>
    Directory.systemTemp.createTempSync('ddbs_oplog_${tag}_').path;

void main() {
  group('OpLog', () {
    test('append assigns monotonic LSNs and replays in order', () async {
      final dir = _tmpDir('basic');
      final log = OpLog(dir);
      await log.open();
      final l1 = await log.append(['CREATE TABLE t(id INT)']);
      final l2 = await log.append(["INSERT INTO t VALUES (1)"]);
      final l3 = await log.append(["INSERT INTO t VALUES (2)"]);
      expect([l1, l2, l3], [1, 2, 3]);
      expect(log.lastLsn, 3);

      final recs = await log.readFrom(0).toList();
      expect(recs.map((r) => r.lsn), [1, 2, 3]);
      expect(recs.first.ops, ['CREATE TABLE t(id INT)']);
      await log.close();
    });

    test('readFrom(afterLsn) returns only later records', () async {
      final dir = _tmpDir('after');
      final log = OpLog(dir);
      await log.open();
      for (var i = 0; i < 5; i++) {
        await log.append(['op$i']);
      }
      final recs = await log.readFrom(3).toList();
      expect(recs.map((r) => r.lsn), [4, 5]);
      await log.close();
    });

    test('reopen recovers lastLsn and all records from disk', () async {
      final dir = _tmpDir('reopen');
      var log = OpLog(dir);
      await log.open();
      await log.append(['a']);
      await log.append(['b']);
      await log.close();

      log = OpLog(dir);
      await log.open();
      expect(log.lastLsn, 2);
      await log.append(['c']);
      expect(log.lastLsn, 3);
      final recs = await log.readFrom(0).toList();
      expect(recs.map((r) => r.ops.single), ['a', 'b', 'c']);
      await log.close();
    });

    test('segment rotation splits records across files', () async {
      final dir = _tmpDir('rotate');
      final log = OpLog(dir, segmentBytes: 64); // tiny -> frequent rotation
      await log.open();
      for (var i = 0; i < 10; i++) {
        await log.append(['payload-$i']);
      }
      final segFiles = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .length;
      expect(segFiles, greaterThan(1));
      final recs = await log.readFrom(0).toList();
      expect(recs.map((r) => r.lsn), List<int>.generate(10, (i) => i + 1));
      await log.close();
    });

    test('torn tail frame from a crash mid-append is discarded on reopen',
        () async {
      final dir = _tmpDir('torn');
      var log = OpLog(dir);
      await log.open();
      await log.append(['good1']);
      await log.append(['good2']);
      await log.close();

      // Simulate a crash: append a partial/garbage frame to the live segment.
      final segPath = Directory(dir)
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.log'))
          .path;
      final raf = await File(segPath).open(mode: FileMode.append);
      // A header claiming 100 payload bytes, but only a few written.
      final header = ByteData(8)
        ..setUint32(0, 100, Endian.little)
        ..setUint32(4, 0xDEADBEEF, Endian.little);
      await raf.writeFrom(header.buffer.asUint8List());
      await raf.writeFrom([1, 2, 3]);
      await raf.close();

      log = OpLog(dir);
      await log.open();
      expect(log.lastLsn, 2, reason: 'torn frame must not advance the LSN');
      final recs = await log.readFrom(0).toList();
      expect(recs.map((r) => r.ops.single), ['good1', 'good2']);
      // A subsequent append continues cleanly past the truncated tail.
      final l3 = await log.append(['good3']);
      expect(l3, 3);
      await log.close();
    });

    test('truncateBelow drops fully-consumed segments but keeps active',
        () async {
      final dir = _tmpDir('gc');
      final log = OpLog(dir, segmentBytes: 48);
      await log.open();
      for (var i = 0; i < 8; i++) {
        await log.append(['x$i']);
      }
      final before = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .length;
      await log.truncateBelow(log.lastLsn); // keep only the tail
      final after = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.log'))
          .length;
      expect(after, lessThan(before));
      // Records at/above the active segment's range survive.
      final recs = await log.readFrom(0).toList();
      expect(recs, isNotEmpty);
      await log.close();
    });

    test('CRC32 matches a known vector', () {
      // CRC32("123456789") == 0xCBF43926.
      expect(opLogCrc32('123456789'.codeUnits), 0xCBF43926);
    });
  });
}
