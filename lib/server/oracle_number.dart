/// Oracle NUMBER base-100 codec — a faithful port of the client's
/// `../dart-oracledb/lib/src/protocol/data_types.dart` NUMBER routines so the
/// server emits the exact bytes the client's `decodeNumber` reads.
///
/// Oracle NUMBER is a variable-length (1–22 byte) base-100 format:
/// - byte 0 is the exponent (positive: `0xC0 + exp`; negative: the complement),
/// - following bytes are base-100 mantissa digit pairs (positive: `digit + 1`;
///   negative: `101 - digit`, terminated by `102`).
library;

import 'dart:typed_data';

import 'oracle_codec.dart';

/// Whether [encodeOracleNumber] can represent [value]: every `int`, zero, and
/// every finite `double` whose magnitude lies in `[1E-130, 1E126)`.
bool isOracleNumberRepresentable(num value) {
  if (value is! double) return true;
  if (!value.isFinite) return false;
  if (value == 0) return true;
  final magnitude = value.abs();
  return magnitude >= 1e-130 && magnitude < 1e126;
}

/// Encodes [value] as Oracle NUMBER bytes. Caller must ensure
/// [isOracleNumberRepresentable]; throws [ArgumentError] otherwise.
Uint8List encodeOracleNumber(num value) {
  if (!isOracleNumberRepresentable(value)) {
    throw ArgumentError('value not representable as Oracle NUMBER: $value');
  }
  if (value == 0) {
    return Uint8List.fromList([0x80]); // zero is the lone byte 0x80
  }

  final isNegative = value < 0;
  final absValue = value.abs();

  final decimalStr = _decimalString(absValue);
  final dotIdx = decimalStr.indexOf('.');
  var intPart = dotIdx < 0 ? decimalStr : decimalStr.substring(0, dotIdx);
  var fracPart = dotIdx < 0 ? '' : decimalStr.substring(dotIdx + 1);

  fracPart = fracPart.replaceAll(RegExp(r'0+$'), '');
  intPart = intPart.replaceFirst(RegExp(r'^0+'), '');
  if (intPart.isEmpty) intPart = '0';

  if (intPart != '0' && intPart.length % 2 == 1) {
    intPart = '0$intPart';
  }
  if (fracPart.isNotEmpty && fracPart.length % 2 == 1) {
    fracPart = '${fracPart}0';
  }

  int exponent;
  if (intPart != '0') {
    exponent = intPart.length ~/ 2;
  } else {
    exponent = 0;
    for (var i = 0; i < fracPart.length; i += 2) {
      final pair = int.parse(fracPart.substring(i, i + 2));
      if (pair == 0) {
        exponent--;
      } else {
        break;
      }
    }
  }

  final allDigits = intPart == '0' ? fracPart : intPart + fracPart;
  final digits = <int>[];
  for (var i = 0; i < allDigits.length; i += 2) {
    final digit = int.parse(allDigits.substring(i, i + 2));
    if (digit != 0 || digits.isNotEmpty) {
      digits.add(digit);
    }
  }
  while (digits.length > 1 && digits.last == 0) {
    digits.removeLast();
  }

  final result = <int>[];
  if (isNegative) {
    result.add((~(192 + exponent)) & 0xFF);
    for (final digit in digits) {
      result.add(101 - digit);
    }
    result.add(102); // negative terminator
  } else {
    result.add(192 + exponent);
    for (final digit in digits) {
      result.add(digit + 1);
    }
  }
  return Uint8List.fromList(result);
}

String _decimalString(num absValue) {
  if (absValue is int) return absValue.toString();
  final s = absValue.toString();
  final eIdx = s.indexOf(RegExp(r'[eE]'));
  if (eIdx < 0) return s;
  final mantissa = s.substring(0, eIdx);
  final exp = int.parse(s.substring(eIdx + 1));
  final dotIdx = mantissa.indexOf('.');
  final intDigits = dotIdx < 0 ? mantissa : mantissa.substring(0, dotIdx);
  final fracDigits = dotIdx < 0 ? '' : mantissa.substring(dotIdx + 1);
  final allDigits = intDigits + fracDigits;
  final pointIdx = intDigits.length + exp;
  if (pointIdx <= 0) {
    return '0.${'0' * (-pointIdx)}$allDigits';
  }
  if (pointIdx >= allDigits.length) {
    return '$allDigits${'0' * (pointIdx - allDigits.length)}';
  }
  return '${allDigits.substring(0, pointIdx)}.${allDigits.substring(pointIdx)}';
}

const List<double> _exactPowersOfTen = [
  1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, //
  1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
];

/// Decodes an Oracle NUMBER from [buffer]. Verbatim port of the client's
/// `decodeNumber`; used by tests to prove the encode round-trips.
num decodeOracleNumber(ReadBuffer buffer,
    {int? length, bool forceDouble = false}) {
  if (length == 0) {
    throw const FormatException('NUMBER field has zero length');
  }
  final startPos = buffer.position;
  final firstByte = buffer.readUint8();

  final isLoneByte = length != null ? length == 1 : !buffer.hasRemaining;
  if (firstByte == 0x80 && isLoneByte) {
    return forceDouble ? 0.0 : 0;
  }

  final isNegative = (firstByte & 0x80) == 0;
  int exponent;
  if (isNegative) {
    exponent = ((~firstByte) & 0xFF) - 192;
  } else {
    exponent = firstByte - 192;
  }

  final digits = <int>[];
  bool boundReached() {
    if (length != null && buffer.position - startPos >= length) return true;
    return !buffer.hasRemaining;
  }

  while (!boundReached()) {
    final byte = buffer.readUint8();
    if (isNegative && byte == 102) break;
    final digit = isNegative ? 101 - byte : byte - 1;
    if (digit < 0 || digit > 99) break;
    digits.add(digit);
  }

  var result = 0.0;
  if (digits.isNotEmpty) {
    final e10 = 2 * (exponent - digits.length);
    if (digits.length <= 7) {
      var mantissa = 0;
      for (final digit in digits) {
        mantissa = mantissa * 100 + digit;
      }
      if (e10 >= 0 && e10 <= 22) {
        result = mantissa * _exactPowersOfTen[e10];
      } else if (e10 < 0 && e10 >= -22) {
        result = mantissa / _exactPowersOfTen[-e10];
      } else {
        result = double.parse('${mantissa}e$e10');
      }
    } else {
      final text = StringBuffer();
      for (final digit in digits) {
        if (digit < 10) text.write('0');
        text.write(digit);
      }
      result = double.parse('${text}e$e10');
    }
  }

  if (isNegative) result = -result;
  if (!result.isFinite) {
    throw const FormatException('decoded NUMBER overflowed double range');
  }

  const maxSafeInt = 9007199254740992; // 2^53
  if (!forceDouble &&
      result == result.truncateToDouble() &&
      result.abs() <= maxSafeInt) {
    return result.toInt();
  }
  return result;
}
