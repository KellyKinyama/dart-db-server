// Dry-run (no database) encoding tests for the real-Oracle WRITE path.
//
// The OALL8 execute / LOB wire shape is field-version-independent except for
// the 23ai token (UB8, written only when field version >= 18). So a pre-23ai
// (e.g. 19c, field version 12) request must be byte-identical to the
// 23ai-proven (field version 24) request with the single token byte removed.
// Combined with the real-23ai DML/LOB gated tests, this validates the pre-23ai
// write encoding without connecting to any server — safe for prod-only targets.
library;

import 'dart:typed_data';

import 'package:dart_db_server/oracle_native_execute.dart';
import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:test/test.dart';

const int _msgTypeFunction = 3;
const int _funcExecute = 94;
const int _funcLobOp = 0x60;

/// Asserts the field-12 request equals the field-24 request minus the single
/// UB8(0) token byte at offset 3 (right after the [msgType, func, seq] header).
void _expectTokenInvariant(Uint8List v12, Uint8List v24) {
  expect(v24.length, v12.length + 1, reason: 'field-24 adds one token byte');
  expect(v24[3], 0, reason: 'token is UB8(0) = 0x00 at offset 3');
  final stripped =
      Uint8List.fromList([...v24.sublist(0, 3), ...v24.sublist(4)]);
  expect(stripped, equals(v12),
      reason: 'pre-23ai request == 23ai request without the token');
}

/// Reads the options word from a field-12 (no-token) execute request.
int _options12(Uint8List msg) {
  final r = ReadBuffer(msg);
  r.readUint8(); // msg type
  r.readUint8(); // function
  r.readUint8(); // sequence
  return r.readUB4(); // options
}

void main() {
  group('write-path dry run (no DB): pre-23ai == 23ai minus token', () {
    test('single-row INSERT with a bind', () {
      final binds = [NativeBind.value(1)];
      final v12 = buildDmlExecute('INSERT INTO t (id) VALUES (:1)', binds,
          ttcFieldVersion: 12);
      final v24 = buildDmlExecute('INSERT INTO t (id) VALUES (:1)', binds,
          ttcFieldVersion: 24);
      expect(v12[0], _msgTypeFunction);
      expect(v12[1], _funcExecute);
      _expectTokenInvariant(v12, v24);
      // Options: parse | execute | notPlSql | bind.
      expect(_options12(v12), 0x01 | 0x20 | 0x8000 | 0x08);
    });

    test('array DML (executeMany) keeps the invariant', () {
      final binds = [NativeBind.value(1)];
      final bulk = [
        [1],
        [2],
        [3],
      ];
      final v12 = buildDmlExecute('INSERT INTO t (id) VALUES (:1)', binds,
          bulkRows: bulk, ttcFieldVersion: 12);
      final v24 = buildDmlExecute('INSERT INTO t (id) VALUES (:1)', binds,
          bulkRows: bulk, ttcFieldVersion: 24);
      _expectTokenInvariant(v12, v24);
    });

    test('DML RETURNING keeps the invariant', () {
      final binds = [NativeBind.value('x'), NativeBind.outNumber()];
      final v12 = buildDmlExecute(
          'UPDATE t SET name = :1 RETURNING id INTO :2', binds,
          returning: true, ttcFieldVersion: 12);
      final v24 = buildDmlExecute(
          'UPDATE t SET name = :1 RETURNING id INTO :2', binds,
          returning: true, ttcFieldVersion: 24);
      _expectTokenInvariant(v12, v24);
    });

    test('batch-errors DML sets its option flag and keeps the invariant', () {
      final binds = [NativeBind.value(1)];
      final bulk = [
        [1],
        [2],
      ];
      final v12 = buildDmlExecute('INSERT INTO t (id) VALUES (:1)', binds,
          bulkRows: bulk, batchErrors: true, ttcFieldVersion: 12);
      final v24 = buildDmlExecute('INSERT INTO t (id) VALUES (:1)', binds,
          bulkRows: bulk, batchErrors: true, ttcFieldVersion: 24);
      _expectTokenInvariant(v12, v24);
      // Options include the batch-errors flag (0x80000).
      expect(_options12(v12) & 0x80000, 0x80000);
    });

    test('temp CLOB and BLOB create keep the invariant', () {
      for (final ora in const [112, 113]) {
        final csfrm = ora == 112 ? 1 : 0;
        final v12 =
            buildLobCreateTemp(oraType: ora, csfrm: csfrm, ttcFieldVersion: 12);
        final v24 =
            buildLobCreateTemp(oraType: ora, csfrm: csfrm, ttcFieldVersion: 24);
        expect(v12[0], _msgTypeFunction);
        expect(v12[1], _funcLobOp);
        _expectTokenInvariant(v12, v24);
      }
    });

    test('LOB write keeps the invariant', () {
      final locator = Uint8List(40);
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final v12 =
          buildLobWrite(locator, 1, data, ttcFieldVersion: 12);
      final v24 =
          buildLobWrite(locator, 1, data, ttcFieldVersion: 24);
      expect(v12[1], _funcLobOp);
      _expectTokenInvariant(v12, v24);
    });

    test('query / fetch / PL-SQL execute keep the invariant', () {
      final q12 = buildQueryExecute('SELECT :1 FROM dual',
          binds: [1], ttcFieldVersion: 12);
      final q24 = buildQueryExecute('SELECT :1 FROM dual',
          binds: [1], ttcFieldVersion: 24);
      _expectTokenInvariant(q12, q24);

      final f12 = buildFetch(5, 50, ttcFieldVersion: 12);
      final f24 = buildFetch(5, 50, ttcFieldVersion: 24);
      _expectTokenInvariant(f12, f24);

      final p12 = buildPlsqlExecute('BEGIN :1 := 1; END;',
          [NativeBind.outNumber()], ttcFieldVersion: 12);
      final p24 = buildPlsqlExecute('BEGIN :1 := 1; END;',
          [NativeBind.outNumber()], ttcFieldVersion: 24);
      _expectTokenInvariant(p12, p24);
    });
  });
}
