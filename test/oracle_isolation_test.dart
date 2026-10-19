/// Phase 4 per-session transaction isolation: a session never sees another
/// session's uncommitted writes. Because the shared engine keeps a single
/// global transaction, isolation is enforced by serializing sessions — a
/// second session's statements block until the transaction owner commits or
/// rolls back.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

import 'oracle_support.dart';

void main() {
  late Database db;
  late OracleServer server;

  setUp(() async {
    db = await Database.open(null);
    server = OracleServer(db, port: 0, users: {'u': 'p'});
    await server.start();
  });

  tearDown(() async => server.stop());

  Future<(Socket, FrameReader)> login() async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.boundPort,
    );
    final frames = FrameReader(socket);
    await handshakeAndLogin(socket, frames, username: 'u', password: 'p');
    return (socket, frames);
  }

  test('uncommitted writes are invisible and blocked until rollback', () async {
    final (sa, fa) = await login();
    addTearDown(() async => sa.close());

    sa.add(wrapData(buildExecuteRequest(
        'CREATE TABLE t (id INTEGER PRIMARY KEY)')));
    await fa.next();

    // A opens a transaction and inserts (uncommitted).
    sa.add(wrapData(buildExecuteRequest('BEGIN')));
    await fa.next();
    sa.add(wrapData(buildExecuteRequest('INSERT INTO t VALUES (1)')));
    expect(decodeExecuteResponse(ttcBody(await fa.next())).rowsAffected, 1);

    final (sb, fb) = await login();
    addTearDown(() async => sb.close());

    // B's SELECT must block while A holds the transaction.
    sb.add(wrapData(buildExecuteRequest('SELECT id FROM t', isQuery: true)));
    var bResponded = false;
    final bFuture = fb.next().then((f) {
      bResponded = true;
      return f;
    });
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(bResponded, isFalse, reason: 'B saw into an open transaction');

    // A rolls back; B now runs and never observed the uncommitted row.
    sa.add(wrapData(buildFunctionRequest(ttcFuncRollback)));
    expect(decodeExecuteResponse(ttcBody(await fa.next())).errorNum, 0);
    final bResp = decodeExecuteResponse(ttcBody(await bFuture), isQuery: true);
    expect(bResp.rows, isEmpty);
  });

  test('a committed write becomes visible to the other session', () async {
    final (sa, fa) = await login();
    addTearDown(() async => sa.close());

    sa.add(wrapData(buildExecuteRequest(
        'CREATE TABLE t (id INTEGER PRIMARY KEY)')));
    await fa.next();
    sa.add(wrapData(buildExecuteRequest('BEGIN')));
    await fa.next();
    sa.add(wrapData(buildExecuteRequest('INSERT INTO t VALUES (7)')));
    await fa.next();

    final (sb, fb) = await login();
    addTearDown(() async => sb.close());

    // B's SELECT blocks until A commits, then sees the committed row.
    sb.add(wrapData(buildExecuteRequest('SELECT id FROM t', isQuery: true)));
    final bFuture = fb.next();

    sa.add(wrapData(buildFunctionRequest(ttcFuncCommit)));
    expect(decodeExecuteResponse(ttcBody(await fa.next())).errorNum, 0);

    final bResp = decodeExecuteResponse(ttcBody(await bFuture), isQuery: true);
    expect(bResp.rows, [
      [7],
    ]);
  });

  test('disconnecting mid-transaction releases the gate for others', () async {
    final (sa, fa) = await login();
    sa.add(wrapData(buildExecuteRequest(
        'CREATE TABLE t (id INTEGER PRIMARY KEY)')));
    await fa.next();
    sa.add(wrapData(buildExecuteRequest('BEGIN')));
    await fa.next();
    sa.add(wrapData(buildExecuteRequest('INSERT INTO t VALUES (1)')));
    await fa.next();

    final (sb, fb) = await login();
    addTearDown(() async => sb.close());

    // A drops its connection mid-transaction; the server must roll back and
    // free the gate so B can proceed.
    await sa.close();

    sb.add(wrapData(buildExecuteRequest('SELECT id FROM t', isQuery: true)));
    final bResp = decodeExecuteResponse(ttcBody(await fb.next()), isQuery: true);
    expect(bResp.rows, isEmpty); // A's insert was rolled back on disconnect
  });

  test('reads from many sessions run concurrently (no transaction)', () async {
    final (seed, seedFrames) = await login();
    addTearDown(() async => seed.close());
    seed.add(wrapData(buildExecuteRequest(
        'CREATE TABLE t (id INTEGER PRIMARY KEY)')));
    await seedFrames.next();
    seed.add(wrapData(buildExecuteRequest('INSERT INTO t VALUES (42)')));
    await seedFrames.next();

    // Three sessions each fire a SELECT without awaiting; with the shared lock
    // they proceed concurrently (no transaction is open) and all see the row.
    final sessions = await Future.wait([login(), login(), login()]);
    addTearDown(() async {
      for (final (s, _) in sessions) {
        await s.close();
      }
    });
    final pending = <Future<ExecuteResponse>>[];
    for (final (s, f) in sessions) {
      s.add(wrapData(buildExecuteRequest('SELECT id FROM t', isQuery: true)));
      pending.add(f.next().then((frame) =>
          decodeExecuteResponse(ttcBody(frame), isQuery: true)));
    }
    for (final resp in await Future.wait(pending)) {
      expect(resp.rows, [
        [42],
      ]);
    }
  });
}
