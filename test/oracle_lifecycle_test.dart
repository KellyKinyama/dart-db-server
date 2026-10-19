/// Phase 4 tests for the Oracle transaction / lifecycle calls: COMMIT (14),
/// ROLLBACK (15), and PING (0x93). Each is a bare FUNCTION RPC that the server
/// acknowledges with a success STATUS the client reads as end-of-call.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:dart_db_server/server/oracle_execute.dart' show buildStatusOk;
import 'package:test/test.dart';

import 'oracle_support.dart';

void main() {
  group('status acknowledgement', () {
    test('buildStatusOk decodes as a successful end-of-call', () {
      final resp = decodeExecuteResponse(buildStatusOk());
      expect(resp.errorNum, 0);
      expect(resp.errorMessage, isNull);
    });
  });

  group('live lifecycle calls', () {
    test('COMMIT, ROLLBACK, and PING each get a success status', () async {
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

      // Seed a row, then exercise each lifecycle call.
      socket.add(wrapData(buildExecuteRequest(
          'CREATE TABLE t (id INTEGER PRIMARY KEY)')));
      await frames.next();
      socket.add(wrapData(buildExecuteRequest('INSERT INTO t VALUES (1)')));
      final ins = decodeExecuteResponse(ttcBody(await frames.next()));
      expect(ins.rowsAffected, 1);

      socket.add(wrapData(buildFunctionRequest(ttcFuncCommit)));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).errorNum, 0);

      socket.add(wrapData(buildFunctionRequest(ttcFuncRollback)));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).errorNum, 0);

      socket.add(wrapData(buildFunctionRequest(ttcFuncPing)));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).errorNum, 0);

      // The connection stays usable after the lifecycle calls.
      socket.add(wrapData(buildExecuteRequest(
          'SELECT id FROM t', isQuery: true)));
      final sel = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(sel.rows, [
        [1],
      ]);
    });

    test('ROLLBACK undoes work inside an explicit transaction', () async {
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
          'CREATE TABLE acct (id INTEGER PRIMARY KEY)')));
      await frames.next();

      // Open a transaction, insert, then roll it back via the TTC call.
      socket.add(wrapData(buildExecuteRequest('BEGIN')));
      await frames.next();
      socket.add(wrapData(buildExecuteRequest('INSERT INTO acct VALUES (1)')));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).rowsAffected, 1);
      socket.add(wrapData(buildFunctionRequest(ttcFuncRollback)));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).errorNum, 0);

      socket.add(wrapData(buildExecuteRequest(
          'SELECT id FROM acct', isQuery: true)));
      final afterRollback = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(afterRollback.rows, isEmpty); // the insert was undone

      // A committed transaction persists its work.
      socket.add(wrapData(buildExecuteRequest('BEGIN')));
      await frames.next();
      socket.add(wrapData(buildExecuteRequest('INSERT INTO acct VALUES (2)')));
      await frames.next();
      socket.add(wrapData(buildFunctionRequest(ttcFuncCommit)));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).errorNum, 0);

      socket.add(wrapData(buildExecuteRequest(
          'SELECT id FROM acct', isQuery: true)));
      final afterCommit = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(afterCommit.rows, [
        [2],
      ]);
    });
  });
}
