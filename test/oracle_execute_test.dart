/// Phase 3 tests for the Oracle EXECUTE path.
///
/// Unit tests validate the request decoder (round-trip) and the response
/// encoders (decoded with mirrors of the client's response decoders). A live
/// test drives a real server through login + CREATE/INSERT/SELECT over a
/// socket.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oracle_codec.dart';
import 'package:dart_db_server/server/oracle_execute.dart';
import 'package:test/test.dart';

import 'oracle_support.dart';

void main() {
  group('EXECUTE request decode', () {
    test('recovers the SQL text of a no-bind statement', () {
      final req = buildExecuteRequest('SELECT 1 FROM dual', isQuery: true);
      // Skip the 3-byte TTC function header the dispatcher consumes.
      final info = decodeExecuteRequest(ReadBuffer(req)..skip(3));
      expect(info.sql, 'SELECT 1 FROM dual');
      expect(info.cursorId, 0);
      expect(info.numParams, 0);
      expect(info.hasBinds, isFalse);
    });

    test('recovers a longer DML statement', () {
      const sql = "INSERT INTO t (id, name) VALUES (1, 'alice')";
      final req = buildExecuteRequest(sql);
      final info = decodeExecuteRequest(ReadBuffer(req)..skip(3));
      expect(info.sql, sql);
    });
  });

  group('response encoding (decoded with client mirrors)', () {
    test('query response carries columns and rows', () {
      const result = QueryResult(
        columns: ['ID', 'NAME'],
        rows: [
          [1, 'alice'],
          [2, null],
        ],
      );
      final resp = decodeExecuteResponse(buildQueryResponse(result),
          isQuery: true);
      expect(resp.errorNum, 0); // ORA-01403 maps to end-of-fetch
      expect(resp.columns, ['ID', 'NAME']);
      expect(resp.rows, [
        [1, 'alice'],
        [2, null],
      ]);
    });

    test('empty query response has no rows', () {
      const result = QueryResult(columns: ['X'], rows: []);
      final resp = decodeExecuteResponse(buildQueryResponse(result),
          isQuery: true);
      expect(resp.columns, ['X']);
      expect(resp.rows, isEmpty);
    });

    test('numeric columns round-trip as native NUMBER values', () {
      const result = QueryResult(
        columns: ['N'],
        rows: [
          [0],
          [42],
          [-7],
          [1234567],
          [3.14],
          [-0.5],
          [2.5],
          [null],
        ],
      );
      final resp = decodeExecuteResponse(buildQueryResponse(result),
          isQuery: true);
      expect(resp.columnTypes.single, 2); // Oracle NUMBER
      expect(resp.rows, [
        [0],
        [42],
        [-7],
        [1234567],
        [3.14],
        [-0.5],
        [2.5],
        [null],
      ]);
    });

    test('mixed numeric/text column falls back to VARCHAR2 strings', () {
      const result = QueryResult(
        columns: ['M'],
        rows: [
          [1],
          ['two'],
        ],
      );
      final resp = decodeExecuteResponse(buildQueryResponse(result),
          isQuery: true);
      expect(resp.columnTypes.single, 1); // VARCHAR2
      expect(resp.rows, [
        ['1'],
        ['two'],
      ]);
    });

    test('byte-buffer columns round-trip as native RAW', () {
      final result = QueryResult(
        columns: const ['B'],
        rows: [
          [Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF])],
          [Uint8List.fromList([])],
          [null],
        ],
      );
      final resp = decodeExecuteResponse(buildQueryResponse(result),
          isQuery: true);
      expect(resp.columnTypes.single, 23); // Oracle RAW
      expect(resp.rows[0].single, [0xDE, 0xAD, 0xBE, 0xEF]);
      // An empty byte buffer is indistinguishable from NULL on the wire.
      expect(resp.rows[1].single, isNull);
      expect(resp.rows[2].single, isNull);
    });

    test('DML response reports the affected row count', () {
      const result = QueryResult(affected: 3);
      final resp = decodeExecuteResponse(buildDmlResponse(result));
      expect(resp.rowsAffected, 3);
      expect(resp.errorNum, 0);
    });

    test('execute error carries the ORA code and message', () {
      final resp =
          decodeExecuteResponse(buildExecuteError(942, 'table not found'));
      expect(resp.errorNum, 942);
      expect(resp.errorMessage, 'table not found');
    });
  });

  group('live end-to-end execute', () {
    test('login, CREATE/INSERT/SELECT round-trips over a socket', () async {
      final db = await Database.open(null);
      final server = OracleServer(db, port: 0, users: {
        'testuser': 'testpassword',
      });
      await server.start();
      addTearDown(() async => server.stop());

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      addTearDown(() async => socket.close());
      final frames = FrameReader(socket);

      await handshakeAndLogin(socket, frames,
          username: 'testuser', password: 'testpassword');

      // CREATE TABLE (DDL)
      socket.add(wrapData(buildExecuteRequest(
          'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)')));
      final ddl = decodeExecuteResponse(ttcBody(await frames.next()));
      expect(ddl.errorNum, 0);

      // INSERT (DML)
      socket.add(wrapData(buildExecuteRequest(
          "INSERT INTO people VALUES (1, 'alice')")));
      final ins = decodeExecuteResponse(ttcBody(await frames.next()));
      expect(ins.errorNum, 0);
      expect(ins.rowsAffected, 1);

      socket.add(wrapData(buildExecuteRequest(
          "INSERT INTO people VALUES (2, 'bob')")));
      decodeExecuteResponse(ttcBody(await frames.next()));

      // SELECT (query)
      socket.add(wrapData(buildExecuteRequest(
          'SELECT id, name FROM people ORDER BY id',
          isQuery: true)));
      final sel = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(sel.errorNum, 0);
      expect(sel.columns, ['id', 'name']);
      expect(sel.rows, [
        [1, 'alice'],
        [2, 'bob'],
      ]);
    });

    test('positional and named bind variables round-trip', () async {
      final db = await Database.open(null);
      final server = OracleServer(db, port: 0, users: {
        'testuser': 'testpassword',
      });
      await server.start();
      addTearDown(() async => server.stop());

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      addTearDown(() async => socket.close());
      final frames = FrameReader(socket);
      await handshakeAndLogin(socket, frames,
          username: 'testuser', password: 'testpassword');

      socket.add(wrapData(buildExecuteRequest(
          'CREATE TABLE emp (id INTEGER PRIMARY KEY, name TEXT, dept INTEGER)')));
      await frames.next();

      // Positional binds (:1, :2, :3).
      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO emp VALUES (:1, :2, :3)',
          binds: [1, 'alice', 10])));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).rowsAffected, 1);
      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO emp VALUES (:1, :2, :3)',
          binds: [2, 'bob', 20])));
      await frames.next();

      // Named bind.
      socket.add(wrapData(buildExecuteRequest(
          'SELECT name FROM emp WHERE dept = :dept ORDER BY id',
          isQuery: true,
          binds: [10])));
      final sel = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(sel.rows, [
        ['alice'],
      ]);
    });
  });
}
