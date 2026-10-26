/// Phase 4 tests for server-side cursors: a cached statement re-executes by
/// cursor id with no SQL on the wire, and a close-cursors piggyback frees it.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

import 'oracle_support.dart';

void main() {
  group('statement cursor cache', () {
    late Database db;
    late OracleServer server;
    late Socket socket;
    late FrameReader frames;

    setUp(() async {
      db = await Database.open(null);
      server = OracleServer(db, port: 0, users: {'testuser': 'testpassword'});
      await server.start();
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.boundPort,
      );
      frames = FrameReader(socket);
      await handshakeAndLogin(socket, frames,
          username: 'testuser', password: 'testpassword');
      socket.add(wrapData(buildExecuteRequest(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)')));
      await frames.next();
      socket.add(wrapData(
          buildExecuteRequest("INSERT INTO t VALUES (1, 'alice')")));
      await frames.next();
    });

    tearDown(() async {
      await socket.close();
      await server.stop();
    });

    test('a cached cursor re-executes by id with no SQL', () async {
      // Fresh execute: the server assigns and echoes a cursor id.
      socket.add(wrapData(buildExecuteRequest(
          'SELECT id, name FROM t', isQuery: true)));
      final first = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(first.rows, [
        [1, 'alice'],
      ]);
      expect(first.cursorId, greaterThan(0));

      // Re-execute by cursor id only — no SQL bytes on the wire.
      socket.add(wrapData(buildExecuteRequest('',
          isQuery: true, cursorId: first.cursorId)));
      final second = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(second.rows, [
        [1, 'alice'],
      ]);
      expect(second.cursorId, first.cursorId);
    });

    test('close-cursors piggyback frees the cursor', () async {
      socket.add(wrapData(buildExecuteRequest(
          'SELECT id FROM t', isQuery: true)));
      final first = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      final id = first.cursorId;
      expect(id, greaterThan(0));

      // A close-cursors piggyback prefixed to a PING frees the cursor.
      socket.add(wrapData(concatBytes(
        buildCloseCursorsPiggyback([id]),
        buildFunctionRequest(ttcFuncPing),
      )));
      expect(decodeExecuteResponse(ttcBody(await frames.next())).errorNum, 0);

      // Re-executing the freed cursor now fails with an invalid-cursor error.
      socket.add(wrapData(buildExecuteRequest('',
          isQuery: true, cursorId: id)));
      final reused = decodeExecuteResponse(ttcBody(await frames.next()),
          isQuery: true);
      expect(reused.errorNum, 1001);
    });
  });
}
