// Unit tests for the native (thick OCI/OCCI) query-response encoder.
//
// These lock in the reverse-engineered describe/row/status byte layout that
// real Instant Client builds (oci8 / OCCI 23.9) accept, so future refactors
// cannot silently regress native query execution.
library;

import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_native_execute.dart';
import 'package:dart_db_server/server/result.dart';
import 'package:test/test.dart';

void main() {
  group('native query response encoder', () {
    test('single NUMBER column, single row', () {
      final r = buildNativeQueryResponse(
          const QueryResult(columns: ['N'], rows: [
        [7]
      ]));
      expect(r[0], 0x10); // describe-info message type
      expect(r[32], 1); // column count
      expect(r[36], 0x82); // shared describe prefix
      // NUMBER column record: 02 00 00 <flag=0x81> <size> ...
      expect(r.sublist(37, 41), [0x02, 0x00, 0x00, 0x81]);
    });

    test('single NUMBER column, multiple rows carries row count + markers', () {
      final r = buildNativeQueryResponse(
          const QueryResult(columns: ['N'], rows: [
        [1],
        [2],
        [3]
      ]));
      // Row count appears in the trailing status block (3 rows).
      final status = r.sublist(r.length - 142);
      expect(status[42], 3);
      expect(status[106], 3);
      expect(status[80], 3 + 4); // status[80] = rowCount + 4
      // The third row (index >= 2) is prefixed with the inter-row marker
      // 15 <ncols> 00 <2*ncols-1>; for one column that is 15 01 00 01.
      expect(_contains(r, [0x15, 0x01, 0x00, 0x01]), isTrue);
    });

    test('multi-column multi-row uses an ncols-scaled inter-row marker', () {
      final r = buildNativeQueryResponse(
          const QueryResult(columns: ['N', 'M'], rows: [
        [1, 'a'],
        [2, 'bb'],
        [3, 'ccc']
      ]));
      expect(r[32], 2); // two columns
      // Two-column marker is 15 02 00 03.
      expect(_contains(r, [0x15, 0x02, 0x00, 0x03]), isTrue);
      final status = r.sublist(r.length - 142);
      expect(status[42], 3);
    });

    test('empty result set has no row data and a distinct status block', () {
      final r = buildNativeQueryResponse(
          const QueryResult(columns: ['N'], rows: []));
      expect(r[0], 0x10);
      // Ends with the ORA-01403 no-data terminal.
      expect(_contains(r, 'ORA-01403'.codeUnits), isTrue);
    });

    test('canEncodeNativeQuery accepts any non-empty column set', () {
      expect(
          canEncodeNativeQuery(
              const QueryResult(columns: ['A', 'B'], rows: [])),
          isTrue);
      expect(canEncodeNativeQuery(const QueryResult(columns: [], rows: [])),
          isFalse);
    });
  });

  group('native DML response encoder', () {
    test('carries the affected-row count at offsets 42 and 120', () {
      final r = buildNativeDmlResponse(3);
      expect(r[0], 0x08); // status message type
      expect(r[42], 3); // row count (low byte of LE32)
      expect(r[120], 3); // echoed count
    });

    test('large counts are written as a little-endian 32-bit value', () {
      final r = buildNativeDmlResponse(300);
      expect(r[42], 300 & 0xFF);
      expect(r[43], (300 >> 8) & 0xFF);
    });

    test('zero-row / DDL uses the shorter template', () {
      final r = buildNativeDmlResponse(0);
      expect(r[0], 0x08);
      expect(r.length, lessThan(buildNativeDmlResponse(1).length));
    });

    test('native status terminal is the 8-byte end-of-call OK', () {
      expect(buildNativeStatusOk(),
          [0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1d]);
    });

    test('native error carries the ORA code and message', () {
      final r = buildNativeExecuteError(942, 'table or view does not exist');
      expect(r[0], 0x04); // error message type
      // ORA code as a little-endian 32-bit value at byte 11 and echoed at 66.
      expect(r[11] | (r[12] << 8), 942);
      expect(r[66] | (r[67] << 8), 942);
      expect(r.last, 0x1d); // terminator
      final text = String.fromCharCodes(r.where((b) => b >= 0x20 && b < 0x7f));
      expect(text, contains('ORA-00942:'));
      expect(text, contains('table or view does not exist'));
    });

    test('native error does not double-prefix an ORA- message', () {
      final r = buildNativeExecuteError(1, 'ORA-00001: unique constraint');
      final text = String.fromCharCodes(r.where((b) => b >= 0x20 && b < 0x7f));
      expect(text, contains('ORA-00001: unique constraint'));
      expect('ORA-'.allMatches(text).length, 1);
    });
  });

  group('native paginated fetch', () {
    test('describe + fetch paginate a large result, done terminal last', () {
      final rows = [
        for (var i = 1; i <= 250; i++) [i]
      ];
      final cursor =
          NativeResultCursor(QueryResult(columns: const ['N'], rows: rows));
      final describe = cursor.describe(nativeBatchSize);
      expect(describe[0], 0x10); // describe-info
      expect(cursor.hasMore, isTrue);

      final f1 = cursor.fetch(nativeBatchSize);
      expect(f1[0], 0x06); // row-data message
      expect(cursor.hasMore, isTrue);

      final f2 = cursor.fetch(nativeBatchSize); // final 50 rows
      expect(cursor.hasMore, isFalse);
      final text = String.fromCharCodes(f2.where((b) => b >= 0x20 && b < 0x7f));
      expect(text, contains('ORA-01403'));
    });

    test('isNativeFetch and decodeNativeFetchCount read a FETCH call', () {
      final fetch = Uint8List.fromList(
          [0x03, 0x05, 0x07, 0x01, 0x09, 0x02, 0, 0, 0, 0x65, 0, 0, 0]);
      expect(isNativeFetch(fetch), isTrue);
      expect(decodeNativeFetchCount(fetch), 101);
      expect(isNativeFetch(Uint8List.fromList([0x11, 0x69, 0x00])), isFalse);
    });
  });
}

bool _contains(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}
