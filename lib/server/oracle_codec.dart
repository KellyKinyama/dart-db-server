/// Binary read/write buffers for the Oracle TNS/TTC wire protocol.
///
/// Byte-for-byte compatible port of the codec used by the sibling pure-Dart
/// Oracle *client* (`../dart-oracledb/lib/src/protocol/buffer.dart`, Apache
/// 2.0). The server front-end must encode/decode exactly as the client does,
/// so this is kept deliberately faithful to that implementation.
///
/// TNS framing is big-endian; several TTC fields are little-endian, hence the
/// explicit `BE`/`LE` method names. Oracle's variable-length integers (UB2/
/// UB4/UB8, SB1..SB8) use a leading size byte (high bit = signed-negative).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Thrown when a buffer read/write cannot be satisfied.
class OracleBufferException implements Exception {
  const OracleBufferException(this.message);
  final String message;
  @override
  String toString() => 'OracleBufferException: $message';
}

/// Thrown specifically when a read runs past the end of the buffer — the
/// "more bytes may be coming" signal the packet receive loop watches for.
class OracleBufferUnderflow extends OracleBufferException {
  const OracleBufferUnderflow(super.message);
  @override
  String toString() => 'OracleBufferUnderflow: $message';
}

const int _tnsLongLengthIndicator = 0xFE;
const int _tnsNullLengthIndicator = 0xFF;

/// A cursor over an immutable byte list with explicit-endian readers.
class ReadBuffer {
  ReadBuffer(this._data) : _position = 0;

  final Uint8List _data;
  int _position;

  int get position => _position;
  int get remaining => _data.length - _position;
  bool get hasRemaining => _position < _data.length;
  int get length => _data.length;

  void _need(int bytes) {
    if (_position + bytes > _data.length) {
      throw OracleBufferUnderflow(
        'need $bytes bytes at position $_position, '
        'only ${_data.length - _position} available',
      );
    }
  }

  int readUint8() {
    _need(1);
    return _data[_position++];
  }

  int readUint16BE() {
    _need(2);
    final v = (_data[_position] << 8) | _data[_position + 1];
    _position += 2;
    return v;
  }

  int readUint16LE() {
    _need(2);
    final v = _data[_position] | (_data[_position + 1] << 8);
    _position += 2;
    return v;
  }

  int readUint32BE() {
    _need(4);
    final v = (_data[_position] << 24) |
        (_data[_position + 1] << 16) |
        (_data[_position + 2] << 8) |
        _data[_position + 3];
    _position += 4;
    return v;
  }

  int readUint32LE() {
    _need(4);
    final v = _data[_position] |
        (_data[_position + 1] << 8) |
        (_data[_position + 2] << 16) |
        (_data[_position + 3] << 24);
    _position += 4;
    return v;
  }

  Uint8List readBytes(int length) {
    if (length == 0) return Uint8List(0);
    _need(length);
    final bytes = Uint8List.sublistView(_data, _position, _position + length);
    _position += length;
    return bytes;
  }

  String readString(int length) => utf8.decode(readBytes(length));

  void skip(int bytes) {
    _need(bytes);
    _position += bytes;
  }

  void reset() => _position = 0;

  void seek(int offset) {
    if (offset < 0 || offset > _data.length) {
      throw OracleBufferException(
        'invalid seek $offset (length ${_data.length})',
      );
    }
    _position = offset;
  }

  int peekUint8() {
    _need(1);
    return _data[_position];
  }

  int _readInteger(int maxSize, {required bool signed}) {
    var size = readUint8();
    if (size == 0) return 0;
    var isNegative = false;
    if ((size & 0x80) != 0) {
      if (!signed) {
        throw OracleBufferException(
          'unexpected negative integer (size byte '
          '0x${size.toRadixString(16)}) at ${_position - 1}',
        );
      }
      isNegative = true;
      size &= 0x7F;
    }
    if (size > maxSize) {
      throw OracleBufferException('integer too large: $size > $maxSize');
    }
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = (value << 8) | readUint8();
    }
    return isNegative ? -value : value;
  }

  int readUB2() => _readInteger(2, signed: false);
  int readUB4() => _readInteger(4, signed: false);
  int readUB8() => _readInteger(8, signed: false);
  int readSB1() => _readInteger(1, signed: true);
  int readSB2() => _readInteger(2, signed: true);
  int readSB4() => _readInteger(4, signed: true);
  int readSB8() => _readInteger(8, signed: true);

  void skipUB1() => skip(1);
  void skipUB2() => _readInteger(2, signed: false);
  void skipUB4() => _readInteger(4, signed: false);

  /// Reads bytes with a single-byte length prefix (0/0xFF = empty, 0xFE =
  /// chunked, otherwise an inline count).
  Uint8List readBytesWithLength() {
    final numBytes = readUint8();
    if (numBytes == 0 || numBytes == _tnsNullLengthIndicator) {
      return Uint8List(0);
    }
    if (numBytes != _tnsLongLengthIndicator) {
      return readBytes(numBytes);
    }
    final chunks = <Uint8List>[];
    while (true) {
      final chunkSize = readUB4();
      if (chunkSize == 0) break;
      chunks.add(readBytes(chunkSize));
    }
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final c in chunks) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }

  String readStringWithLength() {
    final bytes = readBytesWithLength();
    return bytes.isEmpty ? '' : utf8.decode(bytes);
  }
}

/// A growable byte builder with explicit-endian writers.
class WriteBuffer {
  WriteBuffer() : _data = BytesBuilder(copy: false);

  final BytesBuilder _data;

  int get length => _data.length;

  void writeUint8(int value) => _data.addByte(value & 0xFF);

  void writeUint16BE(int value) {
    _data.addByte((value >> 8) & 0xFF);
    _data.addByte(value & 0xFF);
  }

  void writeUint16LE(int value) {
    _data.addByte(value & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
  }

  void writeUint32BE(int value) {
    _data.addByte((value >> 24) & 0xFF);
    _data.addByte((value >> 16) & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
    _data.addByte(value & 0xFF);
  }

  void writeUint32LE(int value) {
    _data.addByte(value & 0xFF);
    _data.addByte((value >> 8) & 0xFF);
    _data.addByte((value >> 16) & 0xFF);
    _data.addByte((value >> 24) & 0xFF);
  }

  void writeBytes(Uint8List bytes) => _data.add(bytes);

  void writeString(String value) => _data.add(utf8.encode(value));

  void writeUB2(int value) {
    if (value == 0) {
      writeUint8(0);
    } else if (value <= 0xFF) {
      writeUint8(1);
      writeUint8(value);
    } else {
      writeUint8(2);
      writeUint16BE(value);
    }
  }

  void writeUB4(int value) {
    if (value == 0) {
      writeUint8(0);
    } else if (value <= 0xFF) {
      writeUint8(1);
      writeUint8(value);
    } else if (value <= 0xFFFF) {
      writeUint8(2);
      writeUint16BE(value);
    } else {
      writeUint8(4);
      writeUint32BE(value);
    }
  }

  void writeUB8(int value) {
    if (value == 0) {
      writeUint8(0);
    } else if (value <= 0xFF) {
      writeUint8(1);
      writeUint8(value);
    } else if (value <= 0xFFFF) {
      writeUint8(2);
      writeUint16BE(value);
    } else if (value <= 0xFFFFFFFF) {
      writeUint8(4);
      writeUint32BE(value);
    } else {
      writeUint8(8);
      writeUint32BE((value >> 32) & 0xFFFFFFFF);
      writeUint32BE(value & 0xFFFFFFFF);
    }
  }

  /// Writes bytes with a single-byte length prefix, chunking past 252 bytes.
  void writeBytesWithLength(Uint8List bytes) {
    final numBytes = bytes.length;
    if (numBytes <= 252) {
      writeUint8(numBytes);
      if (numBytes > 0) writeBytes(bytes);
    } else {
      writeUint8(_tnsLongLengthIndicator);
      var offset = 0;
      while (offset < numBytes) {
        final chunkSize =
            (numBytes - offset > 65535) ? 65535 : numBytes - offset;
        writeUB4(chunkSize);
        writeBytes(Uint8List.sublistView(bytes, offset, offset + chunkSize));
        offset += chunkSize;
      }
      writeUB4(0);
    }
  }

  Uint8List toBytes() => _data.toBytes();

  void clear() => _data.clear();
}
