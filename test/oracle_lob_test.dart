/// Self-contained mirror of the Oracle `ttcLobOp` (function 0x60) handler: it
/// builds the request bodies the client's `LobOpRequest.encode` produces and
/// drives [handleLobOp] through CREATE_TEMP → WRITE → GET_LENGTH → READ,
/// decoding each response the way the client's `_walkLobOpMessage` does.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_execute.dart';
import 'package:dart_db_server/server/oracle_lob.dart';
import 'package:dart_db_server/server/oracle_ttc.dart';
import 'package:dart_db_server/server/result.dart';
import 'package:test/test.dart';

import 'oracle_support.dart';

// LOB op codes (client tnsLobOp*).
const int _opGetLength = 0x0001;
const int _opRead = 0x0002;
const int _opWrite = 0x0040;
const int _opCreateTemp = 0x0110;

/// Builds a `ttcLobOp` request body (past the function header), mirroring the
/// client's `LobOpRequest.encode`.
Uint8List _lobReq(
  int operation, {
  Uint8List? locator,
  int sourceOffset = 0,
  bool sendAmount = false,
  int amount = 0,
  Uint8List? data,
}) {
  final b = WriteBuffer();
  b.writeUB8(0); // token number
  if (locator == null) {
    b.writeUint8(0);
    b.writeUB4(0);
  } else {
    b.writeUint8(1);
    b.writeUB4(locator.length);
  }
  b.writeUint8(0); // dest locator pointer
  b.writeUB4(0); // dest locator length / duration
  b.writeUB4(0); // short source offset
  b.writeUB4(0); // short dest offset
  b.writeUint8(operation == _opCreateTemp ? 1 : 0); // charset pointer
  b.writeUint8(0); // short amount pointer
  b.writeUint8(operation == _opCreateTemp ? 1 : 0); // boolean-out pointer
  b.writeUB4(operation);
  b.writeUint8(0); // SCN pointer
  b.writeUint8(0); // SCN array length
  b.writeUB8(sourceOffset);
  b.writeUB8(0); // dest offset
  b.writeUint8(sendAmount ? 1 : 0);
  for (var i = 0; i < 3; i++) {
    b.writeUint16BE(0);
  }
  if (locator != null) b.writeBytes(locator);
  if (operation == _opCreateTemp) b.writeUB4(873); // UTF-8 charset
  if (data != null) {
    b.writeUint8(ttcMsgTypeLobData);
    b.writeBytesWithLength(data);
  }
  if (sendAmount) b.writeUB8(amount);
  return b.toBytes();
}

/// Reads the echoed locator (raw [lobLocatorSize] bytes) from a RETURN_PARAMETER
/// message in a LOB op response. Returns the first locator found.
Uint8List _locatorOf(Uint8List response) {
  final r = ReadBuffer(response);
  while (r.hasRemaining) {
    final msg = r.readUint8();
    if (msg == ttcMsgTypeParameter) {
      return Uint8List.fromList(r.readBytes(lobLocatorSize));
    }
    if (msg == ttcMsgTypeStatus) {
      break;
    }
    if (msg == ttcMsgTypeLobData) {
      r.readBytesWithLength();
    }
  }
  throw StateError('no locator in response');
}

/// Reads the LOB_DATA payload and the SB8 amount from a READ response.
({Uint8List data, int amount}) _readResult(Uint8List response) {
  final r = ReadBuffer(response);
  Uint8List data = Uint8List(0);
  var amount = 0;
  while (r.hasRemaining) {
    final msg = r.readUint8();
    if (msg == ttcMsgTypeLobData) {
      data = Uint8List.fromList(r.readBytesWithLength());
    } else if (msg == ttcMsgTypeParameter) {
      r.readBytes(lobLocatorSize); // echoed locator
      amount = r.readUB8();
    } else if (msg == ttcMsgTypeStatus) {
      break;
    }
  }
  return (data: data, amount: amount);
}

/// Reads the SB8 amount from a GET_LENGTH-style response.
int _amountOf(Uint8List response) {
  final r = ReadBuffer(response);
  while (r.hasRemaining) {
    final msg = r.readUint8();
    if (msg == ttcMsgTypeParameter) {
      r.readBytes(lobLocatorSize);
      return r.readUB8();
    }
    if (msg == ttcMsgTypeStatus) break;
  }
  throw StateError('no amount in response');
}

void main() {
  test('CREATE_TEMP, WRITE, GET_LENGTH and READ round-trip', () {
    final store = LobStore();

    // CREATE_TEMP → a fresh locator.
    final created = handleLobOp(ReadBuffer(_lobReq(_opCreateTemp,
        locator: Uint8List(lobLocatorSize), sourceOffset: 1)), store);
    final locator = _locatorOf(created);
    expect(locator.length, lobLocatorSize);

    // WRITE 5 bytes at offset 1.
    final payload = Uint8List.fromList([9, 8, 7, 6, 5]);
    handleLobOp(
        ReadBuffer(_lobReq(_opWrite,
            locator: locator, sourceOffset: 1, data: payload)),
        store);

    // GET_LENGTH → 5.
    final len = handleLobOp(
        ReadBuffer(_lobReq(_opGetLength,
            locator: locator, sendAmount: true, amount: 0)),
        store);
    expect(_amountOf(len), 5);

    // READ 5 units at offset 1 → the payload.
    final read = handleLobOp(
        ReadBuffer(_lobReq(_opRead,
            locator: locator, sourceOffset: 1, sendAmount: true, amount: 5)),
        store);
    final result = _readResult(read);
    expect(result.data, payload);
    expect(result.amount, 5);

    // The bound locator resolves to the written bytes.
    expect(store.resolve(locator), payload);
  });

  test('a CLOB column is described as CLOB (112) and read via its locator', () {
    final store = LobStore();
    final result = QueryResult(
      columns: ['txt'],
      columnTypes: ['CLOB'],
      rows: [
        ['hello from column'],
      ],
    );
    final resp = decodeExecuteResponse(
        buildQueryResponse(result, lobStore: store),
        isQuery: true);
    expect(resp.columnTypes, [112]); // described as CLOB
    final locator = resp.rows[0][0] as Uint8List;

    // The client reads the column LOB back via a ttcLobOp READ.
    final read = handleLobOp(
        ReadBuffer(_lobReq(_opRead,
            locator: locator, sourceOffset: 1, sendAmount: true, amount: 100)),
        store);
    expect(utf8.decode(_readResult(read).data), 'hello from column');
  });

  test('a BLOB column is described as BLOB (113) and read via its locator', () {
    final store = LobStore();
    final bytes = Uint8List.fromList([1, 2, 3, 250, 255]);
    final result = QueryResult(
      columns: ['data'],
      columnTypes: ['BLOB'],
      rows: [
        [bytes],
      ],
    );
    final resp = decodeExecuteResponse(
        buildQueryResponse(result, lobStore: store),
        isQuery: true);
    expect(resp.columnTypes, [113]); // described as BLOB
    final locator = resp.rows[0][0] as Uint8List;

    final read = handleLobOp(
        ReadBuffer(_lobReq(_opRead,
            locator: locator, sourceOffset: 1, sendAmount: true, amount: 100)),
        store);
    expect(_readResult(read).data, bytes);
  });
}
