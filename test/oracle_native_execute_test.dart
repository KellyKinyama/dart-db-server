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
