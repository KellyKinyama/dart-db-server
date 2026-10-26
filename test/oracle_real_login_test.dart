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

    test('canonical OALL8 query returns rows from real Oracle', () async {
      final host = env['ORACLE_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['ORACLE_PORT'] ?? '1521') ?? 1521;
      final user = env['ORACLE_USER'] ?? 'system';
      final pass = env['ORACLE_PASSWORD'] ?? 'TestPw1234';
      final service = env['ORACLE_SERVICE'] ?? 'FREEPDB1';

      final client = await OracleThickClient.connect(port, host: host);
      try {
        final login = await client.loginReal(
          username: user,
          password: pass,
          serviceName: service,
        );
        expect(login.authenticated, isTrue);

        // Scalar NUMBER.
        final one = await client.queryReal('SELECT 1 FROM dual');
        expect(one.rows, [
          [1]
        ]);

        // VARCHAR2 + NUMBER in one row.
        final mixed = await client
            .queryReal("SELECT 'hello' AS g, 42 AS a FROM dual");
        expect(mixed.columns.map((c) => c.name).toList(), ['G', 'A']);
        expect(mixed.rows, [
          ['hello', 42]
        ]);

        // Multi-row fetch across the prefetch window.
        final tables = await client.queryReal(
            'SELECT table_name FROM all_tables WHERE rownum <= 5');
        expect(tables.rows, hasLength(5));
        expect(tables.rows.first.first, isA<String>());

        // DATE decode.
        final now = await client.queryReal('SELECT sysdate FROM dual');
        expect(now.rows.first.first, isA<DateTime>());
      } finally {
        await client.close();
      }
    });
  }, skip: enabled ? false : 'set RUN_ORACLE_TESTS=true to run (needs Oracle)');
}
