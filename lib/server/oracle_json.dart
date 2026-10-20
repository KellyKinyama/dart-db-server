/// OSON (Oracle binary JSON) codec for the native `JSON` data type (type 119)
/// — the server side of `../dart-oracledb/lib/src/protocol/oson.dart`.
///
/// Inverts the client's `encodeOson` / `decodeOson` for the standard JSON
/// value set the engine round-trips: `Map<String, Object?>`, `List<Object?>`,
/// `String`, `num`, `bool` and `null`. [decodeOson] reads a bind document the
/// client encoded; [encodeOson] emits a document the client decodes (OSON
/// version 1, byte-compatible with the client encoder for these node types).
/// Oracle-specific scalar nodes (date/time, binary, interval, VECTOR) are not
/// produced here and are rejected on decode.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'oracle_codec.dart';
import 'oracle_number.dart';

const int _magic1 = 0xff;
const int _magic2 = 0x4a;
const int _magic3 = 0x5a;

const int _versionMaxFname255 = 1;
const int _versionMaxFname65535 = 3;

// Primary header flags.
const int _flagRelOffsetMode = 0x01;
const int _flagInlineLeaf = 0x02;
const int _flagNumFnamesUint32 = 0x08;
const int _flagIsScalar = 0x10;
const int _flagHashIdUint8 = 0x0100;
const int _flagNumFnamesUint16 = 0x0400;
const int _flagFnamesSegUint32 = 0x0800;
const int _flagTreeSegUint32 = 0x1000;
const int _flagTinyNodesStat = 0x2000;

const int _flagSecFnamesSegUint16 = 0x100;

// Tree-segment node types.
const int _nodeNull = 0x30;
const int _nodeTrue = 0x31;
const int _nodeFalse = 0x32;
const int _nodeStringLenUint8 = 0x33;
const int _nodeNumberLenUint8 = 0x34;
const int _nodeBinaryDouble = 0x36;
const int _nodeStringLenUint16 = 0x37;
const int _nodeStringLenUint32 = 0x38;
const int _nodeObject = 0x84;
const int _nodeArray = 0xc0;

const int _maxShortFieldNameBytes = 255;

/// Thrown for a malformed OSON document or an unsupported node / value.
class OsonException implements Exception {
  OsonException(this.message);
  final String message;
  @override
  String toString() => 'OsonException: $message';
}

// ===========================================================================
// Encoder
// ===========================================================================

/// Encodes a Dart JSON value into an OSON document the client decodes.
Uint8List encodeOson(Object? value) => _OsonEncoder().encode(value);

/// Growable byte buffer with big-endian writes and random-access patching —
/// the OSON tree segment reserves child-offset slots and patches them once the
/// child nodes are written.
class _OsonWriteBuffer {
  Uint8List _buf = Uint8List(256);
  int pos = 0;

  void _ensure(int extra) {
    if (pos + extra <= _buf.length) return;
    var newLen = _buf.length * 2;
    while (newLen < pos + extra) {
      newLen *= 2;
    }
    final grown = Uint8List(newLen)..setRange(0, pos, _buf);
    _buf = grown;
  }

  void writeUint8(int value) {
    _ensure(1);
    _buf[pos++] = value & 0xff;
  }

  void writeUint16BE(int value) {
    _ensure(2);
    _buf[pos++] = (value >> 8) & 0xff;
    _buf[pos++] = value & 0xff;
  }

  void writeUint32BE(int value) {
    _ensure(4);
    _buf[pos++] = (value >> 24) & 0xff;
    _buf[pos++] = (value >> 16) & 0xff;
    _buf[pos++] = (value >> 8) & 0xff;
    _buf[pos++] = value & 0xff;
  }

  void writeBytes(List<int> bytes) {
    _ensure(bytes.length);
    _buf.setRange(pos, pos + bytes.length, bytes);
    pos += bytes.length;
  }

  int reserve(int count) {
    _ensure(count);
    final start = pos;
    _buf.fillRange(start, start + count, 0);
    pos += count;
    return start;
  }

  void patchUint8(int at, int value) => _buf[at] = value & 0xff;

  void patchUint16BE(int at, int value) {
    _buf[at] = (value >> 8) & 0xff;
    _buf[at + 1] = value & 0xff;
  }

  void patchUint32BE(int at, int value) {
    _buf[at] = (value >> 24) & 0xff;
    _buf[at + 1] = (value >> 16) & 0xff;
    _buf[at + 2] = (value >> 8) & 0xff;
    _buf[at + 3] = value & 0xff;
  }

  Uint8List view() => Uint8List.sublistView(_buf, 0, pos);
}

class _OsonFieldName {
  _OsonFieldName(this.name) : nameBytes = Uint8List.fromList(utf8.encode(name)) {
    if (nameBytes.length > _maxShortFieldNameBytes) {
      throw OsonException(
          'JSON field names over $_maxShortFieldNameBytes UTF-8 bytes are not '
          'supported (got ${nameBytes.length})');
    }
    hash = _hash(nameBytes);
  }

  final String name;
  final Uint8List nameBytes;
  int hash = 0;
  int offset = 0;
  int fieldId = 0;

  int get hashId => hash & 0xff;

  static int _hash(Uint8List bytes) {
    var h = 0x811C9DC5;
    for (final b in bytes) {
      h = ((h ^ b) * 16777619) & 0xffffffff;
    }
    return h;
  }
}

class _OsonEncoder {
  final _fieldNamesMap = <String, _OsonFieldName>{};
  final _names = <_OsonFieldName>[];
  final _nameBytes = _OsonWriteBuffer();
  final _treeSeg = _OsonWriteBuffer();
  int _fieldIdSize = 1;
  final Set<Object> _open = HashSet<Object>.identity();

  Uint8List encode(Object? value) {
    final isContainer = (value is Map || value is List);

    var flags = _flagInlineLeaf;
    if (isContainer) {
      _examine(value);
      _assignFieldIds();
      flags |= _flagHashIdUint8 | _flagTinyNodesStat;
      final total = _names.length;
      if (total > 65535) {
        flags |= _flagNumFnamesUint32;
        _fieldIdSize = 4;
      } else if (total > 255) {
        flags |= _flagNumFnamesUint16;
        _fieldIdSize = 2;
      } else {
        _fieldIdSize = 1;
      }
      if (_nameBytes.pos > 65535) flags |= _flagFnamesSegUint32;
    } else {
      flags |= _flagIsScalar;
    }

    _encodeNode(value);
    if (_treeSeg.pos > 65535) flags |= _flagTreeSegUint32;

    final out = _OsonWriteBuffer()
      ..writeUint8(_magic1)
      ..writeUint8(_magic2)
      ..writeUint8(_magic3)
      ..writeUint8(_versionMaxFname255)
      ..writeUint16BE(flags);

    if (isContainer) {
      final numShort = _names.length;
      if (_fieldIdSize == 1) {
        out.writeUint8(numShort);
      } else if (_fieldIdSize == 2) {
        out.writeUint16BE(numShort);
      } else {
        out.writeUint32BE(numShort);
      }
      if (_nameBytes.pos > 65535) {
        out.writeUint32BE(_nameBytes.pos);
      } else {
        out.writeUint16BE(_nameBytes.pos);
      }
    }

    if (_treeSeg.pos < 65536) {
      out.writeUint16BE(_treeSeg.pos);
    } else {
      out.writeUint32BE(_treeSeg.pos);
    }

    if (isContainer) {
      out.writeUint16BE(0); // tiny-node count (always zero)
      // Hash-id array, then the name-offset array, then the packed names.
      for (final f in _names) {
        out.writeUint8(f.hashId);
      }
      final wide = _nameBytes.pos > 65535;
      for (final f in _names) {
        if (wide) {
          out.writeUint32BE(f.offset);
        } else {
          out.writeUint16BE(f.offset);
        }
      }
      out.writeBytes(_nameBytes.view());
    }

    out.writeBytes(_treeSeg.view());
    return out.view();
  }

  void _examine(Object? value) {
    if (value is List) {
      _enter(value);
      for (final e in value) {
        _examine(e);
      }
      _open.remove(value);
    } else if (value is Map) {
      _enter(value);
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw OsonException('JSON object keys must be String (got '
              '${key.runtimeType})');
        }
        if (!_fieldNamesMap.containsKey(key)) {
          final fn = _OsonFieldName(key);
          fn.offset = _nameBytes.pos;
          _nameBytes.writeUint8(fn.nameBytes.length);
          _nameBytes.writeBytes(fn.nameBytes);
          _fieldNamesMap[key] = fn;
          _names.add(fn);
        }
        _examine(entry.value);
      }
      _open.remove(value);
    }
  }

  void _enter(Object container) {
    if (!_open.add(container)) {
      throw OsonException('JSON value is cyclic');
    }
  }

  /// Sorts names by 8-bit hash id, then byte length, then name — the client's
  /// short-segment order — and numbers them from 1.
  void _assignFieldIds() {
    _names.sort((a, b) {
      if (a.hashId != b.hashId) return a.hashId.compareTo(b.hashId);
      if (a.nameBytes.length != b.nameBytes.length) {
        return a.nameBytes.length.compareTo(b.nameBytes.length);
      }
      return a.name.compareTo(b.name);
    });
    for (var i = 0; i < _names.length; i++) {
      _names[i].fieldId = i + 1;
    }
  }

  void _encodeNode(Object? value) {
    if (value == null) {
      _treeSeg.writeUint8(_nodeNull);
    } else if (value is bool) {
      _treeSeg.writeUint8(value ? _nodeTrue : _nodeFalse);
    } else if (value is num) {
      if (isOracleNumberRepresentable(value)) {
        final numberBytes = encodeOracleNumber(value);
        _treeSeg.writeUint8(_nodeNumberLenUint8);
        _treeSeg.writeUint8(numberBytes.length);
        _treeSeg.writeBytes(numberBytes);
      } else {
        _treeSeg.writeUint8(_nodeBinaryDouble);
        _treeSeg.writeBytes(_encodeBinaryDouble(value.toDouble()));
      }
    } else if (value is String) {
      final bytes = utf8.encode(value);
      if (bytes.length < 256) {
        _treeSeg.writeUint8(_nodeStringLenUint8);
        _treeSeg.writeUint8(bytes.length);
      } else if (bytes.length < 65536) {
        _treeSeg.writeUint8(_nodeStringLenUint16);
        _treeSeg.writeUint16BE(bytes.length);
      } else {
        _treeSeg.writeUint8(_nodeStringLenUint32);
        _treeSeg.writeUint32BE(bytes.length);
      }
      if (bytes.isNotEmpty) _treeSeg.writeBytes(bytes);
    } else if (value is List) {
      _encodeContainerHeader(_nodeArray, value.length);
      var offsetSlot = _treeSeg.reserve(value.length * 4);
      for (final e in value) {
        _treeSeg.patchUint32BE(offsetSlot, _treeSeg.pos);
        offsetSlot += 4;
        _encodeNode(e);
      }
    } else if (value is Map) {
      _encodeContainerHeader(_nodeObject, value.length);
      var idSlot = _treeSeg.reserve(value.length * _fieldIdSize);
      var offsetSlot = _treeSeg.reserve(value.length * 4);
      for (final entry in value.entries) {
        final fn = _fieldNamesMap[entry.key]!;
        if (_fieldIdSize == 1) {
          _treeSeg.patchUint8(idSlot, fn.fieldId);
        } else if (_fieldIdSize == 2) {
          _treeSeg.patchUint16BE(idSlot, fn.fieldId);
        } else {
          _treeSeg.patchUint32BE(idSlot, fn.fieldId);
        }
        idSlot += _fieldIdSize;
        _treeSeg.patchUint32BE(offsetSlot, _treeSeg.pos);
        offsetSlot += 4;
        _encodeNode(entry.value);
      }
    } else {
      throw OsonException('unsupported JSON member type ${value.runtimeType}');
    }
  }

  void _encodeContainerHeader(int nodeType, int numChildren) {
    var type = nodeType | 0x20; // offsets are uint32 on encode
    if (numChildren > 65535) {
      type |= 0x10;
    } else if (numChildren > 255) {
      type |= 0x08;
    }
    _treeSeg.writeUint8(type);
    if (numChildren < 256) {
      _treeSeg.writeUint8(numChildren);
    } else if (numChildren < 65536) {
      _treeSeg.writeUint16BE(numChildren);
    } else {
      _treeSeg.writeUint32BE(numChildren);
    }
  }

  static Uint8List _encodeBinaryDouble(double value) {
    final bytes = Uint8List(8);
    final data = ByteData.sublistView(bytes);
    if (value.isNaN) {
      data.setUint32(0, 0x7ff80000, Endian.big);
    } else {
      data.setFloat64(0, value, Endian.big);
    }
    if ((bytes[0] & 0x80) == 0) {
      bytes[0] |= 0x80;
    } else {
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] ^= 0xff;
      }
    }
    return bytes;
  }
}

// ===========================================================================
// Decoder
// ===========================================================================

/// Decodes an OSON document into Dart JSON values (`Map`, `List`, `String`,
/// `num`, `bool`, `null`). Fails loud on a malformed document or an
/// Oracle-specific scalar node this server does not produce.
Object? decodeOson(Uint8List data) => _OsonDecoder(data).decode();

class _OsonDecoder {
  _OsonDecoder(Uint8List data) : _buf = ReadBuffer(data);

  final ReadBuffer _buf;
  late List<String> _fieldNames;
  int _fieldIdLength = 1;
  bool _relativeOffsets = false;
  int _treeSegPos = 0;

  Object? decode() {
    if (_buf.readUint8() != _magic1 ||
        _buf.readUint8() != _magic2 ||
        _buf.readUint8() != _magic3) {
      throw OsonException('OSON magic bytes mismatch');
    }
    final version = _buf.readUint8();
    if (version != _versionMaxFname255 && version != _versionMaxFname65535) {
      throw OsonException('unsupported OSON version $version');
    }
    final primaryFlags = (_buf.readUint8() << 8) | _buf.readUint8();
    _relativeOffsets = (primaryFlags & _flagRelOffsetMode) != 0;

    if ((primaryFlags & _flagIsScalar) != 0) {
      _buf.skip((primaryFlags & _flagTreeSegUint32) != 0 ? 4 : 2);
      _treeSegPos = _buf.position;
      return _decodeNode();
    }

    int numShortFieldNames;
    if ((primaryFlags & _flagNumFnamesUint32) != 0) {
      numShortFieldNames = _buf.readUint32BE();
      _fieldIdLength = 4;
    } else if ((primaryFlags & _flagNumFnamesUint16) != 0) {
      numShortFieldNames = _buf.readUint16BE();
      _fieldIdLength = 2;
    } else {
      numShortFieldNames = _buf.readUint8();
      _fieldIdLength = 1;
    }

    int shortOffsetsSize;
    int shortSegSize;
    if ((primaryFlags & _flagFnamesSegUint32) != 0) {
      shortOffsetsSize = 4;
      shortSegSize = _buf.readUint32BE();
    } else {
      shortOffsetsSize = 2;
      shortSegSize = _buf.readUint16BE();
    }

    var numLongFieldNames = 0;
    var longOffsetsSize = 4;
    var longSegSize = 0;
    if (version == _versionMaxFname65535) {
      final secondaryFlags = (_buf.readUint8() << 8) | _buf.readUint8();
      if ((secondaryFlags & _flagSecFnamesSegUint16) != 0) longOffsetsSize = 2;
      numLongFieldNames = _buf.readUint32BE();
      longSegSize = _buf.readUint32BE();
    }

    _buf.skip((primaryFlags & _flagTreeSegUint32) != 0 ? 4 : 2); // tree size
    _buf.skip(2); // tiny-node count

    _fieldNames = List<String>.filled(numShortFieldNames + numLongFieldNames, '');
    if (numShortFieldNames > 0) {
      _readFieldNames(0, numShortFieldNames, shortOffsetsSize, shortSegSize, 1);
    }
    if (numLongFieldNames > 0) {
      _readFieldNames(
          numShortFieldNames, numLongFieldNames, longOffsetsSize, longSegSize, 2);
    }

    _treeSegPos = _buf.position;
    return _decodeNode();
  }

  void _readFieldNames(
      int arrStart, int numFields, int offsetsSize, int segSize, int fieldNamesSize) {
    _buf.skip(numFields * fieldNamesSize); // hash-id array
    final offsetsPos = _buf.position;
    _buf.skip(numFields * offsetsSize);
    final seg = Uint8List.fromList(_buf.readBytes(segSize));
    final finalPos = _buf.position;

    _buf.seek(offsetsPos);
    for (var i = arrStart; i < arrStart + numFields; i++) {
      final offset =
          offsetsSize == 2 ? _buf.readUint16BE() : _buf.readUint32BE();
      final nameLen = fieldNamesSize == 1
          ? seg[offset]
          : (seg[offset] << 8) | seg[offset + 1];
      final start = offset + fieldNamesSize;
      _fieldNames[i] =
          utf8.decode(Uint8List.sublistView(seg, start, start + nameLen));
    }
    _buf.seek(finalPos);
  }

  Object? _decodeNode() {
    final nodeType = _buf.readUint8();
    if ((nodeType & 0x80) != 0) return _decodeContainerNode(nodeType);

    switch (nodeType) {
      case _nodeNull:
        return null;
      case _nodeTrue:
        return true;
      case _nodeFalse:
        return false;
      case _nodeStringLenUint8:
        return utf8.decode(_buf.readBytes(_buf.readUint8()));
      case _nodeStringLenUint16:
        return utf8.decode(_buf.readBytes(_buf.readUint16BE()));
      case _nodeStringLenUint32:
        return utf8.decode(_buf.readBytes(_buf.readUint32BE()));
      case _nodeNumberLenUint8:
        final len = _buf.readUint8();
        return len == 0 ? 0 : decodeOracleNumber(ReadBuffer(_buf.readBytes(len)));
      case _nodeBinaryDouble:
        return _decodeBinaryDouble(_buf.readBytes(8));
    }

    final typeBits = nodeType & 0xf0;
    if (typeBits == 0x20 || typeBits == 0x60) {
      return decodeOracleNumber(ReadBuffer(_buf.readBytes((nodeType & 0x0f) + 1)));
    }
    if (typeBits == 0x40 || typeBits == 0x50) {
      final length = nodeType & 0x0f;
      return length == 0
          ? 0
          : decodeOracleNumber(ReadBuffer(_buf.readBytes(length)));
    }
    if ((nodeType & 0xe0) == 0) {
      return nodeType == 0 ? '' : utf8.decode(_buf.readBytes(nodeType));
    }
    throw OsonException(
        'unsupported OSON node type 0x${nodeType.toRadixString(16)}');
  }

  Object? _decodeContainerNode(int nodeType) {
    final containerOffset = _buf.position - _treeSegPos - 1;
    final isObject = (nodeType & 0x40) == 0;

    var numChildren = _readNumChildren(nodeType);
    int fieldIdsPos;
    int offsetsPos;
    if (numChildren == null) {
      final offset = _readOffset(nodeType);
      offsetsPos = _buf.position;
      _buf.seek(_treeSegPos + offset);
      final sharedNodeType = _buf.readUint8();
      numChildren = _readNumChildren(sharedNodeType);
      if (numChildren == null) {
        throw OsonException('OSON shared container points at another shared one');
      }
      fieldIdsPos = _buf.position;
    } else if (isObject) {
      fieldIdsPos = _buf.position;
      offsetsPos = fieldIdsPos + _fieldIdLength * numChildren;
    } else {
      fieldIdsPos = 0;
      offsetsPos = _buf.position;
    }

    final Object container =
        isObject ? <String, Object?>{} : List<Object?>.filled(numChildren, null, growable: true);

    for (var i = 0; i < numChildren; i++) {
      String? name;
      if (isObject) {
        _buf.seek(fieldIdsPos);
        final int fieldId;
        if (_fieldIdLength == 1) {
          fieldId = _buf.readUint8();
        } else if (_fieldIdLength == 2) {
          fieldId = _buf.readUint16BE();
        } else {
          fieldId = _buf.readUint32BE();
        }
        fieldIdsPos = _buf.position;
        if (fieldId < 1 || fieldId > _fieldNames.length) {
          throw OsonException('OSON field id $fieldId out of range');
        }
        name = _fieldNames[fieldId - 1];
      }
      _buf.seek(offsetsPos);
      var offset = _readOffset(nodeType);
      if (_relativeOffsets) offset += containerOffset;
      offsetsPos = _buf.position;
      _buf.seek(_treeSegPos + offset);
      final child = _decodeNode();
      if (isObject) {
        (container as Map<String, Object?>)[name!] = child;
      } else {
        (container as List<Object?>)[i] = child;
      }
    }
    return container;
  }

  int? _readNumChildren(int nodeType) {
    switch (nodeType & 0x18) {
      case 0x00:
        return _buf.readUint8();
      case 0x08:
        return _buf.readUint16BE();
      case 0x10:
        return _buf.readUint32BE();
      default:
        return null; // shared field ids
    }
  }

  int _readOffset(int nodeType) =>
      (nodeType & 0x20) != 0 ? _buf.readUint32BE() : _buf.readUint16BE();

  static double _decodeBinaryDouble(Uint8List b) {
    final bytes = Uint8List.fromList(b);
    if ((bytes[0] & 0x80) != 0) {
      bytes[0] &= 0x7f;
    } else {
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] ^= 0xff;
      }
    }
    return ByteData.sublistView(bytes).getFloat64(0, Endian.big);
  }
}
