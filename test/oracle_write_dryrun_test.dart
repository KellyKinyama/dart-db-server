// Dry-run (no database) encoding tests for the real-Oracle WRITE path.
//
// The OALL8 execute / LOB wire shape is field-version-independent except for
// the 23ai token (UB8, written only when field version >= 18). So a pre-23ai
// (e.g. 19c, field version 12) request must be byte-identical to the
// 23ai-proven (field version 24) request with the single token byte removed.
// Combined with the real-23ai DML/LOB gated tests, this validates the pre-23ai
// write encoding without connecting to any server — safe for prod-only targets.
library;

import 'dart:convert';
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

/// Reads (options, cursorId) from a field-12 execute request.
(int, int) _optsAndCursor12(Uint8List msg) {
  final r = ReadBuffer(msg);
  r.readUint8();
  r.readUint8();
  r.readUint8();
  return (r.readUB4(), r.readUB4());
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

    test('array DML emits exactly one ROW_DATA iteration per bulk row', () {
      final template = [NativeBind.value(0)];
      Uint8List build(int n) => buildDmlExecute(
          'INSERT INTO t (id) VALUES (:1)', template,
          // Identical value per row so each ROW_DATA block is the same size;
          // the only length change between N and M rows is the iteration count.
          bulkRows: [for (var i = 0; i < n; i++) const [5]],
          ttcFieldVersion: 12);
      final one = build(1);
      final three = build(3);
      final seven = build(7);
      // Linear growth: 6 extra rows add exactly 3x the bytes of 2 extra rows.
      expect(three.length, greaterThan(one.length));
      expect(seven.length - one.length, 3 * (three.length - one.length));
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

    test('statement-cache re-execute omits PARSE and the SQL text', () {
      const sql = 'SELECT id FROM employees';
      final fresh = buildQueryExecute(sql, ttcFieldVersion: 12);
      final reuse = buildQueryExecute(sql, ttcFieldVersion: 12, cursorId: 42);

      // Fresh parse: PARSE option bit (0x01) set, cursor id 0, SQL present.
      final (fOpts, fCursor) = _optsAndCursor12(fresh);
      expect(fOpts & 0x01, 0x01);
      expect(fCursor, 0);
      expect(_contains(fresh, utf8.encode(sql)), isTrue);

      // Re-execute: PARSE cleared, cursor id carried, SQL text not re-sent.
      final (rOpts, rCursor) = _optsAndCursor12(reuse);
      expect(rOpts & 0x01, 0);
      expect(rCursor, 42);
      expect(_contains(reuse, utf8.encode(sql)), isFalse);
      expect(reuse.length, lessThan(fresh.length));
    });

    test('fresh query parse (cursorId 0) sets PARSE and embeds the SQL', () {
      const sql = 'SELECT a FROM t';
      final fresh = buildQueryExecute(sql, ttcFieldVersion: 12);
      final (opts, cursor) = _optsAndCursor12(fresh);
      expect(opts & 0x01, 0x01); // PARSE
      expect(opts & 0x20, 0x20); // EXECUTE
      expect(cursor, 0);
      expect(_contains(fresh, utf8.encode(sql)), isTrue);
    });

    test('cached re-execute still re-sends bind metadata and values', () {
      const sql = 'SELECT :1 FROM dual';
      final reuseNoBind =
          buildQueryExecute(sql, cursorId: 7, ttcFieldVersion: 12);
      final reuseWithBind = buildQueryExecute(sql,
          binds: [1], cursorId: 7, ttcFieldVersion: 12);
      // The bound re-execute carries the extra bind metadata + ROW_DATA block
      // (new values are sent on every execute, cached cursor or not) and sets
      // the BIND option bit.
      expect(reuseWithBind.length, greaterThan(reuseNoBind.length));
      expect(_options12(reuseWithBind) & 0x08, 0x08); // BIND
      expect(_options12(reuseNoBind) & 0x08, 0);
    });

    test('token appears iff field version >= 18 (the 23.1-ext1 threshold)', () {
      const sql = 'SELECT 1 FROM dual';
      final v17 = buildQueryExecute(sql, ttcFieldVersion: 17);
      final v18 = buildQueryExecute(sql, ttcFieldVersion: 18);
      // 17 < 18: no token. 18 >= 18: a single UB8(0) token byte at offset 3.
      expect(v18.length, v17.length + 1);
      expect(v18[3], 0);
      expect(Uint8List.fromList([...v18.sublist(0, 3), ...v18.sublist(4)]),
          equals(v17));
    });
  });
}
