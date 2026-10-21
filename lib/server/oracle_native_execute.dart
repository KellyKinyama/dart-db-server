/// Native (thick OCI/OCCI) query response encoder.
///
/// The native client marshals the TTC describe/row/status stream in its own
/// representation (4-byte little-endian scalars, `U8(len)`-prefixed strings)
/// rather than the thin UB-varint layout, so [buildNativeQueryResponse] builds
/// the describe-info (message type 16) + inline row + `ORA-01403` terminal the
/// OCI client expects. Scope: a single result row of NUMBER / VARCHAR2 columns
/// — enough for `SELECT … FROM dual`, scalar/aggregate queries, and the probes
/// a driver issues at connect time.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'oracle_codec.dart';
import 'oracle_number.dart';
import 'result.dart';

/// The 54-byte block a real listener emits between the column records and the
/// row data (a describe timestamp + fixed prefetch metadata), captured verbatim
/// — none of it is column- or value-dependent.
final Uint8List _midBlock = Uint8List.fromList(<int>[
  0x07, 0x00, 0x00, 0x00, 0x07, 0x78, 0x7e, 0x0a, 0x15, 0x0b, 0x09, 0x0e, //
  0x00, 0x00, 0x00, 0x00, 0xe8, 0x1f, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
  0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x22, 0x01, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]);

/// The 142-byte status/terminal block after the row data, ending in the
/// `ORA-01403: no data found` end-of-fetch marker, captured verbatim. Its
/// embedded counters are session sequence numbers the client does not validate.
final Uint8List _statusBlock = Uint8List.fromList(<int>[
  0x08, 0x06, 0x00, 0x29, 0x52, 0x23, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, //
  0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04,
  0x05, 0x00, 0x01, 0x00, 0x1b, 0x00, 0x01, 0x00, 0x00, 0x00, 0x7b, 0x05,
  0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x13, 0x00, 0x03, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x01,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x7b, 0x05, 0x00, 0x00, 0x01, 0x01, 0x03,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x19, 0x4f, 0x52, 0x41, 0x2d,
  0x30, 0x31, 0x34, 0x30, 0x33, 0x3a, 0x20, 0x6e, 0x6f, 0x20, 0x64, 0x61,
  0x74, 0x61, 0x20, 0x66, 0x6f, 0x75, 0x6e, 0x64, 0x0a, 0x1d,
]);

/// A fixed 7-byte Oracle date (describe timestamp); the client does not use it.
const List<int> _date7 = [0x78, 0x7e, 0x0a, 0x15, 0x0b, 0x09, 0x0e];

void _u32(WriteBuffer b, int v) {
  b.writeUint8(v & 0xFF);
  b.writeUint8((v >> 8) & 0xFF);
  b.writeUint8((v >> 16) & 0xFF);
  b.writeUint8((v >> 24) & 0xFF);
}

/// True when every non-null value in [rows] column [col] is an Oracle-number.
bool _isNumberColumn(List<List<Object?>> rows, int col) {
  var sawValue = false;
  for (final row in rows) {
    if (col >= row.length || row[col] == null) continue;
    sawValue = true;
    if (!(row[col] is num && isOracleNumberRepresentable(row[col] as num))) {
      return false;
    }
  }
  return sawValue;
}

/// Encodes one column value: NUMBER in base-100, otherwise UTF-8 text.
Uint8List _encodeValue(Object? cell, bool isNumber) {
  if (cell == null) return Uint8List(0);
  if (isNumber && cell is num) return encodeOracleNumber(cell);
  return Uint8List.fromList(utf8.encode(cell.toString()));
}

/// Writes a native column describe record for a NUMBER or VARCHAR2 [name].
void _writeColumnRecord(WriteBuffer b, String name, bool isNumber, int maxLen) {
  final nameBytes = Uint8List.fromList(utf8.encode(name));
  if (isNumber) {
    b.writeBytes(Uint8List.fromList(const [0x82, 0x02, 0x00, 0x00, 0x81, 0x02, 0x00, 0x00]));
    b.writeBytes(Uint8List(23));
  } else {
    b.writeBytes(Uint8List.fromList(const [0x82, 0x60, 0x80, 0x00, 0x00]));
    _u32(b, maxLen);
    b.writeBytes(Uint8List(11));
    b.writeBytes(Uint8List.fromList(const [0x69, 0x03, 0x01])); // charset AL32UTF8
    _u32(b, maxLen);
    b.writeBytes(Uint8List.fromList(const [0xfe, 0x3f, 0x00, 0x00]));
  }
  b.writeUint8(0x01);
  b.writeUint8(nameBytes.length);
  _u32(b, nameBytes.length);
  b.writeUint8(nameBytes.length);
  b.writeBytes(nameBytes);
  b.writeBytes(Uint8List(32)); // trailing padding
}

/// Returns true when [result] is a single-row, single-column set of a NUMBER or
/// VARCHAR2 value — the shape [buildNativeQueryResponse] can encode. The fixed
/// describe/status blocks were captured for one column; multi-column and
/// multi-row results need their own (column-count-dependent) blocks.
bool canEncodeNativeQuery(QueryResult result) =>
    result.columns.length == 1 && result.rows.length == 1;

/// Builds the native describe-info + row + `ORA-01403` response for a
/// single-row [result]. Call [canEncodeNativeQuery] first.
Uint8List buildNativeQueryResponse(QueryResult result) {
  final row = result.rows.first;
  final ncols = result.columns.length;
  final isNumber = [for (var i = 0; i < ncols; i++) _isNumberColumn(result.rows, i)];
  final values = [
    for (var i = 0; i < ncols; i++)
      _encodeValue(i < row.length ? row[i] : null, isNumber[i]),
  ];
  final rowBytes = values.fold<int>(0, (s, v) => s + v.length);

  final b = WriteBuffer();
  b.writeUint8(0x10); // message type 16: describe info
  _u32(b, 23);
  b.writeBytes(Uint8List(16)); // describe signature (not validated)
  b.writeBytes(Uint8List.fromList(_date7));
  _u32(b, rowBytes);
  _u32(b, ncols);
  for (var i = 0; i < ncols; i++) {
    _writeColumnRecord(b, result.columns[i], isNumber[i],
        values[i].isEmpty ? 1 : values[i].length);
  }
  b.writeBytes(_midBlock);
  b.writeUint8(0x07); // row-data marker
  for (final v in values) {
    b.writeUint8(v.length);
    b.writeBytes(v);
  }
  b.writeBytes(_statusBlock);
  return b.toBytes();
}
