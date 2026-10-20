/// TLS (TCPS) smoke test for the Oracle wire server: when an [OracleServer] is
/// given a [SecurityContext] it binds a [SecureServerSocket], so the whole
/// connection is TLS from the first byte and the ordinary TNS/TTC handshake
/// runs unchanged above it.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

import 'oracle_support.dart';

void main() {
  test('handshake and a query round-trip over a TLS listener', () async {
    final db = await Database.open(null);
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/mysql_test_cert.pem')
      ..usePrivateKey('test/fixtures/mysql_test_key.pem');
    final server = OracleServer(db, port: 0, users: {
      'testuser': 'testpassword',
    }, securityContext: ctx);
    await server.start();
    addTearDown(() async => server.stop());

    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      server.boundPort,
      onBadCertificate: (_) => true, // self-signed fixture
    );
    addTearDown(() async => socket.close());

    final frames = FrameReader(socket);
    await handshakeAndLogin(socket, frames,
        username: 'testuser', password: 'testpassword');

    socket.add(wrapData(buildExecuteRequest(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)')));
    await frames.next();
    socket.add(wrapData(buildExecuteRequest("INSERT INTO t VALUES (1, 'ok')")));
    await frames.next();
    socket.add(wrapData(
        buildExecuteRequest('SELECT v FROM t', isQuery: true)));
    final sel = await readExecuteResponse(frames, isQuery: true);
    expect(sel.rows, [
      ['ok'],
    ]);
  });
}
