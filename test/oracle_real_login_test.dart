@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_db_server/oracle_thick_client.dart';
import 'package:test/test.dart';

/// Real-Oracle integration test for the thick client's native FAST_AUTH +
/// O8LOGON path. Gated on `RUN_ORACLE_TESTS=true` so CI without a database stays
/// green. Connection defaults target the project's Docker Oracle
/// (gvenzl/oracle-free, localhost:1521/FREEPDB1, system/TestPw1234); override
/// with ORACLE_HOST / ORACLE_PORT / ORACLE_USER / ORACLE_PASSWORD /
/// ORACLE_SERVICE.
void main() {
  final env = Platform.environment;
  final enabled = env['RUN_ORACLE_TESTS'] == 'true';

  group('real Oracle native login', () {
    test('FAST_AUTH + O8LOGON authenticates against a real listener', () async {
      final host = env['ORACLE_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['ORACLE_PORT'] ?? '1521') ?? 1521;
      final user = env['ORACLE_USER'] ?? 'system';
      final pass = env['ORACLE_PASSWORD'] ?? 'TestPw1234';
      final service = env['ORACLE_SERVICE'] ?? 'FREEPDB1';

      final client = await OracleThickClient.connect(port, host: host);
      try {
        final result = await client.loginReal(
          username: user,
          password: pass,
          serviceName: service,
        );
        expect(result.authenticated, isTrue,
            reason: 'AUTH_SVR_RESPONSE mutual-auth should validate');
        expect(result.params['AUTH_DBNAME'], isNotNull);
      } finally {
        await client.close();
      }
    });
  }, skip: enabled ? false : 'set RUN_ORACLE_TESTS=true to run (needs Oracle)');
}
