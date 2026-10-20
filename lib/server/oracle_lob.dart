/// Server-side LOB (CLOB/BLOB) support — the verifier of the client's
/// `ttcLobOp` RPC (TTC function **0x60**) and the locator it binds.
///
/// Inverts the client's `lob_op_message.dart` / `lob_locator.dart`. A temporary
/// LOB the client creates (`createTemporaryClob/Blob`) lives in a per-connection
/// [LobStore] keyed by an id embedded in the 40-byte locator. The client drives
/// it with CREATE_TEMP, GET_CHUNK_SIZE, WRITE, READ, GET_LENGTH, TRIM and
/// FREE_TEMP; when such a locator is later bound to an INSERT, the EXECUTE path
/// resolves it back to its bytes (see `oracle_execute.dart`).
///
/// LOBs are held as opaque bytes. A CLOB without the variable-length-charset
/// flag travels as UTF-8 and the client counts units in characters; for
/// single-byte (ASCII) text the character and byte counts coincide, which is
/// what the length/amount fields report here.
library;

import 'dart:typed_data';

import 'oracle_codec.dart';
import 'oracle_ttc.dart';

/// TTC RPC function code for a LOB operation (OLOBOPS).
const int ttcFuncLobOp = 0x60;

// LOB operation codes (client `tnsLobOp*`).
const int _lobOpGetLength = 0x0001;
const int _lobOpRead = 0x0002;
const int _lobOpTrim = 0x0020;
const int _lobOpWrite = 0x0040;
const int _lobOpGetChunkSize = 0x4000;
const int _lobOpCreateTemp = 0x0110;
const int _lobOpFreeTemp = 0x0111;

/// Bytes in a LOB locator (client `tnsLobLocatorBufferSize`).
const int lobLocatorSize = 40;

/// Chunk size reported for a temporary LOB (bytes / characters).
const int _lobChunkSize = 8132;

/// Field-version gate for the 23ai token number (client
/// `ttcCcapFieldVersion23_1Ext1`), matching the EXECUTE decoder.
const int _fvTokenNumber = 18;

// Locator flag offsets the client reads (`tnsLobLocOffset*`).
const int _flagTempOffset = 7; // tnsLobLocOffsetFlag4
const int _flagTempBit = 0x01; // tnsLobLocFlagsTemp

/// Offset of the embedded LOB id inside the locator (a UB4 big-endian slot
/// chosen clear of the flag bytes the client inspects).
const int _idOffset = 16;

/// A temporary LOB held on the server: opaque bytes plus its locator id.
class _ServerLob {
  _ServerLob(this.id);
  final int id;
  List<int> bytes = <int>[];
}

/// Per-connection store of temporary LOBs created via CREATE_TEMP.
class LobStore {
  final Map<int, _ServerLob> _byId = <int, _ServerLob>{};
  int _nextId = 1;

  _ServerLob _create() {
    final lob = _ServerLob(_nextId++);
    _byId[lob.id] = lob;
    return lob;
  }

  _ServerLob? _lookup(Uint8List locator) {
    if (locator.length < _idOffset + 4) return null;
    final id = (locator[_idOffset] << 24) |
        (locator[_idOffset + 1] << 16) |
        (locator[_idOffset + 2] << 8) |
        locator[_idOffset + 3];
    return _byId[id];
  }

  /// Resolves the bytes behind a bound LOB [locator], or null when unknown.
  Uint8List? resolve(Uint8List locator) {
    final lob = _lookup(locator);
    return lob == null ? null : Uint8List.fromList(lob.bytes);
  }

  Uint8List _locatorFor(_ServerLob lob) {
    final loc = Uint8List(lobLocatorSize);
    loc[_flagTempOffset] = _flagTempBit; // temporary LOB
    loc[_idOffset] = (lob.id >> 24) & 0xFF;
    loc[_idOffset + 1] = (lob.id >> 16) & 0xFF;
    loc[_idOffset + 2] = (lob.id >> 8) & 0xFF;
    loc[_idOffset + 3] = lob.id & 0xFF;
    return loc;
  }
}

/// A decoded `ttcLobOp` request.
class _LobOpRequest {
  _LobOpRequest({
    required this.operation,
    required this.locator,
    required this.sourceOffset,
    required this.sendAmount,
    required this.amount,
    required this.data,
  });

  final int operation;
  final Uint8List? locator;
  final int sourceOffset; // 1-based for read/write; csfrm for CREATE_TEMP
  final bool sendAmount;
  final int amount;
  final Uint8List? data;
}

/// Decodes a `ttcLobOp` request body, positioned just past the TTC function
/// header (message type, function code, sequence already consumed). Inverts the
/// client's `LobOpRequest.encode`.
_LobOpRequest _decodeLobOp(ReadBuffer body, {required int ttcFieldVersion}) {
  if (ttcFieldVersion >= _fvTokenNumber) {
    body.readUB8(); // token number
  }
  final srcPtr = body.readUint8();
  final srcLen = body.readUB4();
  body.readUint8(); // dest locator pointer
  body.readUB4(); // dest locator length / temp-LOB duration
  body.readUB4(); // short source offset
  body.readUB4(); // short dest offset
  body.readUint8(); // charset pointer
  body.readUint8(); // short amount pointer
  body.readUint8(); // boolean-out pointer
  final operation = body.readUB4();
  body.readUint8(); // SCN pointer
  body.readUint8(); // SCN array length
  final sourceOffset = body.readUB8();
  body.readUB8(); // dest offset
  final amountPtr = body.readUint8();
  for (var i = 0; i < 3; i++) {
    body.readUint16BE(); // three fixed two-byte zero fields
  }
  Uint8List? locator;
  if (srcPtr != 0) {
    locator = Uint8List.fromList(body.readBytes(srcLen));
  }
  if (operation == _lobOpCreateTemp) {
    body.readUB4(); // charset id
  }
  Uint8List? data;
  if (body.hasRemaining && body.peekUint8() == ttcMsgTypeLobData) {
    body.readUint8();
    data = Uint8List.fromList(body.readBytesWithLength());
  }
  var amount = 0;
  if (amountPtr != 0) {
    amount = body.readUB8();
  }
  return _LobOpRequest(
    operation: operation,
    locator: locator,
    sourceOffset: sourceOffset,
    sendAmount: amountPtr != 0,
    amount: amount,
    data: data,
  );
}

/// Handles a `ttcLobOp` request against [store] and returns the TTC response
/// body (no TNS framing): the per-operation LOB_DATA / RETURN_PARAMETER
/// messages followed by a terminal STATUS, laid out as the client's
/// `_walkLobOpMessage` reads them.
Uint8List handleLobOp(ReadBuffer body, LobStore store,
    {int ttcFieldVersion = 24}) {
  final req = _decodeLobOp(body, ttcFieldVersion: ttcFieldVersion);
  final b = WriteBuffer();

  switch (req.operation) {
    case _lobOpCreateTemp:
      final lob = store._create();
      final loc = store._locatorFor(lob);
      b.writeUint8(ttcMsgTypeParameter);
      b.writeBytes(loc); // echoed (new) locator, raw bytes
      b.writeUB2(req.sourceOffset); // charset form echo
      b.writeUint8(0); // trailing flags
      break;

    case _lobOpGetChunkSize:
      _writeAmountParameter(b, req.locator, _lobChunkSize);
      break;

    case _lobOpGetLength:
      final lob = req.locator == null ? null : store._lookup(req.locator!);
      _writeAmountParameter(b, req.locator, lob?.bytes.length ?? 0);
      break;

    case _lobOpWrite:
      final lob = req.locator == null ? null : store._lookup(req.locator!);
      if (lob != null && req.data != null) {
        _writeInto(lob, req.sourceOffset, req.data!);
      }
      _writeLocatorParameter(b, req.locator);
      break;

    case _lobOpRead:
      final lob = req.locator == null ? null : store._lookup(req.locator!);
      final bytes = lob?.bytes ?? const <int>[];
      final start = (req.sourceOffset - 1).clamp(0, bytes.length);
      final end = (start + req.amount).clamp(0, bytes.length);
      final slice = Uint8List.fromList(bytes.sublist(start, end));
      b.writeUint8(ttcMsgTypeLobData);
      b.writeBytesWithLength(slice);
      _writeAmountParameter(b, req.locator, slice.length);
      break;

    case _lobOpTrim:
      final lob = req.locator == null ? null : store._lookup(req.locator!);
      if (lob != null && req.amount < lob.bytes.length) {
        lob.bytes = lob.bytes.sublist(0, req.amount);
      }
      _writeLocatorParameter(b, req.locator);
      break;

    case _lobOpFreeTemp:
      final lob = req.locator == null ? null : store._lookup(req.locator!);
      if (lob != null) store._byId.remove(lob.id);
      _writeLocatorParameter(b, req.locator);
      break;

    default:
      _writeLocatorParameter(b, req.locator);
  }

  // Terminal STATUS (the server negotiates version < 319, so no end-of-request).
  b.writeUint8(ttcMsgTypeStatus);
  b.writeUB4(0); // call status
  b.writeUB2(0); // end-to-end sequence
  return b.toBytes();
}

/// Writes data into [lob] at 1-based [offset], extending as needed.
void _writeInto(_ServerLob lob, int offset, Uint8List data) {
  final start = offset < 1 ? 0 : offset - 1;
  final needed = start + data.length;
  if (lob.bytes.length < needed) {
    lob.bytes = List<int>.of(lob.bytes)
      ..addAll(List<int>.filled(needed - lob.bytes.length, 0));
  } else {
    lob.bytes = List<int>.of(lob.bytes);
  }
  lob.bytes.setRange(start, needed, data);
}

/// RETURN_PARAMETER echoing the locator only.
void _writeLocatorParameter(WriteBuffer b, Uint8List? locator) {
  b.writeUint8(ttcMsgTypeParameter);
  if (locator != null) b.writeBytes(locator);
}

/// RETURN_PARAMETER echoing the locator then an SB8 [amount].
void _writeAmountParameter(WriteBuffer b, Uint8List? locator, int amount) {
  b.writeUint8(ttcMsgTypeParameter);
  if (locator != null) b.writeBytes(locator);
  b.writeUB8(amount); // SB8 amount (non-negative)
}
