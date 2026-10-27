// Decode fixtures captured from a live Oracle 19c (pre-23ai, TTC field version
// 12) server — no database needed to run. These lock the real wire shape so
// pre-23ai decode cannot silently regress, and reproduce the untyped-NULL edge
// case for diagnosis.
library;

import 'dart:typed_data';

import 'package:dart_db_server/oracle_native_execute.dart';
import 'package:test/test.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

void main() {
  group('19c decode fixtures (field version 12)', () {
    // `SELECT NULL FROM dual` — execute (describe) response body.
    final describeBody = _hex(
        '10172735d50ca41ebc8fd4dd6a5d1199febb787e0a1b0a1b35'
        '0001015c01800000000000000001010100023ffe01040104044e554c4c'
        '00000000010707787e0a1b0a1b3500021fe80102010200080106040f74796b'
        '012e01010000000000000401010222cc00000000010101110300000000000000'
        '0000000001000101000000000000');

    // `SELECT NULL FROM dual` — fetch response body (row data + ORA-01403 end).
    final fetchBody = _hex(
        '06220101000132000000070401010222cd010102057b000001010003'
        '00000000000000000000000300000000000002057b0101194f52412d3031343033'
        '3a206e6f206461746120666f756e640a');

    test('describe: untyped NULL is a VARCHAR2(0) column named NULL', () {
      final r = decodeExecuteResponse(describeBody,
          isQuery: true, ttcFieldVersion: 12);
      expect(r.columns, hasLength(1));
      expect(r.columns.first.name, 'NULL');
      expect(r.columns.first.oracleType, 1); // VARCHAR2
      expect(r.columns.first.maxLength, 0); // the degenerate VARCHAR2(0)
    });

    test('fetch: the single untyped-NULL row decodes to null', () {
      final describe = decodeExecuteResponse(describeBody,
          isQuery: true, ttcFieldVersion: 12);
      final r = decodeExecuteResponse(fetchBody,
          isQuery: true,
          expectedColumns: describe.columns,
          ttcFieldVersion: 12);
      expect(r.rows, [
        [null]
      ]);
    });
  });
}
