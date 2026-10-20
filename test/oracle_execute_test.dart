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

    test('a large result set is split across packets and reassembled',
        () async {
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
          'CREATE TABLE big (id INTEGER PRIMARY KEY, pad TEXT)')));
      await frames.next();

      const rows = 400; // ~16 KB of result >> the 8 KB SDU -> multi-packet
      final pad = 'x' * 30;
      for (var i = 0; i < rows; i++) {
        socket.add(wrapData(
            buildExecuteRequest("INSERT INTO big VALUES ($i, '$pad')")));
        await frames.next();
      }

      socket.add(wrapData(buildExecuteRequest(
          'SELECT id, pad FROM big ORDER BY id', isQuery: true)));
      final sel = await readExecuteResponse(frames, isQuery: true);
      expect(sel.rows.length, rows);
      expect(sel.rows.first[0], 0);
      expect(sel.rows.last[0], rows - 1);
      expect(sel.rows[200][1], pad);
    });

    test('INTERVAL YEAR TO MONTH and DAY TO SECOND binds round-trip',
        () async {
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
          'CREATE TABLE spans (id INTEGER PRIMARY KEY, ym TEXT, ds TEXT)')));
      await frames.next();

      // INTERVAL YEAR TO MONTH '+2-06', INTERVAL DAY TO SECOND
      // '+3 04:05:06.123456789'.
      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO spans VALUES (:1, :2, :3)',
          binds: [
            1,
            intervalYMBind(2, 6),
            intervalDSBind(3, 4, 5, 6, 123456789),
          ])));
      expect(
          decodeExecuteResponse(ttcBody(await frames.next())).rowsAffected, 1);

      // A negative interval keeps a single sign across its components.
      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO spans VALUES (:1, :2, :3)',
          binds: [
            2,
            intervalYMBind(-1, -3),
            intervalDSBind(-2, -1, -2, -3, -500000000),
          ])));
      await frames.next();

      socket.add(wrapData(buildExecuteRequest(
          'SELECT ym, ds FROM spans ORDER BY id', isQuery: true)));
      final sel = await readExecuteResponse(frames, isQuery: true);
      expect(sel.rows, [
        ['+2-06', '+3 04:05:06.123456789'],
        ['-1-03', '-2 01:02:03.500000000'],
      ]);
    });

    test('VECTOR binds and columns round-trip (dense FLOAT32)', () async {
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
          'CREATE TABLE embeds (id INTEGER PRIMARY KEY, emb VECTOR)')));
      await frames.next();

      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO embeds VALUES (:1, :2)',
          binds: [
            1,
            VectorBind([1.5, -2.5, 3.25]),
          ])));
      expect(
          decodeExecuteResponse(ttcBody(await frames.next())).rowsAffected, 1);

      socket.add(wrapData(buildExecuteRequest(
          'SELECT emb FROM embeds ORDER BY id', isQuery: true)));
      final sel = await readExecuteResponse(frames, isQuery: true);
      expect(sel.rows.length, 1);
      expect(sel.rows[0][0], [1.5, -2.5, 3.25]);
    });

    test('a BINARY VECTOR binds and column round-trips', () async {
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
          'CREATE TABLE bv (id INTEGER PRIMARY KEY, emb VECTOR)')));
      await frames.next();

      final bits = Uint8List.fromList([0xA5, 0x3C]); // 16 packed dimensions
      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO bv VALUES (:1, :2)',
          binds: [1, VectorImageBind(encodeVectorImageBinary(bits))])));
      expect(
          decodeExecuteResponse(ttcBody(await frames.next())).rowsAffected, 1);

      socket.add(wrapData(buildExecuteRequest('SELECT emb FROM bv',
          isQuery: true)));
      final sel = await readExecuteResponse(frames, isQuery: true);
      expect(sel.rows[0][0], bits);
    });

    test('JSON binds and columns round-trip (OSON)', () async {
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
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, doc JSON)')));
      await frames.next();

      final doc = {
        'name': 'alice',
        'age': 30,
        'tags': ['x', 'y'],
        'nested': {'k': 1},
      };
      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO docs VALUES (:1, :2)',
          binds: [1, JsonBind(doc)])));
      expect(
          decodeExecuteResponse(ttcBody(await frames.next())).rowsAffected, 1);

      socket.add(wrapData(buildExecuteRequest(
          'SELECT doc FROM docs ORDER BY id', isQuery: true)));
      final sel = await readExecuteResponse(frames, isQuery: true);
      expect(sel.rows.length, 1);
      expect(sel.rows[0][0], doc);
    });

    test('JSON with DateTime, bytes and a long key round-trips (OSON)',
        () async {
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
          'CREATE TABLE docs (id INTEGER PRIMARY KEY, doc JSON)')));
      await frames.next();

      final longKey = 'k' * 300; // OSON version 3 long field name
      final doc = {
        'when': DateTime(2025, 3, 14, 9, 26, 53),
        'blob': Uint8List.fromList([1, 2, 3, 255]),
        longKey: 'long',
      };
      socket.add(wrapData(buildExecuteRequest(
          'INSERT INTO docs VALUES (:1, :2)',
          binds: [1, JsonBind(doc)])));
      expect(
          decodeExecuteResponse(ttcBody(await frames.next())).rowsAffected, 1);

      socket.add(wrapData(buildExecuteRequest(
          'SELECT doc FROM docs ORDER BY id', isQuery: true)));
      final sel = await readExecuteResponse(frames, isQuery: true);
      final back = sel.rows[0][0] as Map;
      expect(back['when'], DateTime(2025, 3, 14, 9, 26, 53));
      expect(back['blob'], [1, 2, 3, 255]);
      expect(back[longKey], 'long');
    });
  });
}
