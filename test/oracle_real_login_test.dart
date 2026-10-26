@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/oracle_thick_client.dart';
import 'package:dart_db_server/oracle_native_execute.dart' show OracleYearMonth;
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

    test('scalar type decoders round-trip from real Oracle', () async {
      final host = env['ORACLE_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['ORACLE_PORT'] ?? '1521') ?? 1521;
      final user = env['ORACLE_USER'] ?? 'system';
      final pass = env['ORACLE_PASSWORD'] ?? 'TestPw1234';
      final service = env['ORACLE_SERVICE'] ?? 'FREEPDB1';

      final client = await OracleThickClient.connect(port, host: host);
      try {
        await client.loginReal(
          username: user,
          password: pass,
          serviceName: service,
        );
        final r = await client.queryReal('''
          SELECT
            CAST(TIMESTAMP '2026-10-26 11:22:33.456789' AS TIMESTAMP) AS ts,
            CAST(TIMESTAMP '2026-10-26 11:22:33.456 +02:00'
                 AS TIMESTAMP WITH TIME ZONE) AS tstz,
            INTERVAL '5 03:14:15.926' DAY TO SECOND AS ids,
            INTERVAL '3-7' YEAR TO MONTH AS iym,
            TO_BINARY_FLOAT('3.5') AS bf,
            TO_BINARY_DOUBLE('2.71828') AS bd,
            UTL_RAW.CAST_TO_RAW('abc') AS rawcol,
            CAST('hi' AS NVARCHAR2(10)) AS nv,
            ROWID AS rid
          FROM dual
        ''');
        final row = r.rows.first;
        expect(row[0], DateTime(2026, 10, 26, 11, 22, 33, 456, 789));
        // TIMESTAMP WITH TIME ZONE normalizes to the UTC instant.
        expect(row[1], DateTime.utc(2026, 10, 26, 9, 22, 33, 456));
        expect(row[2], const Duration(
            days: 5, hours: 3, minutes: 14, seconds: 15, milliseconds: 926));
        expect(row[3], const OracleYearMonth(3, 7));
        expect(row[4], closeTo(3.5, 1e-6));
        expect(row[5], closeTo(2.71828, 1e-9));
        expect(row[6], [97, 98, 99]);
        expect(row[7], 'hi');
        expect(row[8], isA<String>());
        expect((row[8] as String).length, 18);
      } finally {
        await client.close();
      }
    });

    test('typed binds round-trip through real Oracle', () async {
      final host = env['ORACLE_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['ORACLE_PORT'] ?? '1521') ?? 1521;
      final user = env['ORACLE_USER'] ?? 'system';
      final pass = env['ORACLE_PASSWORD'] ?? 'TestPw1234';
      final service = env['ORACLE_SERVICE'] ?? 'FREEPDB1';

      final client = await OracleThickClient.connect(port, host: host);
      try {
        await client.loginReal(
          username: user,
          password: pass,
          serviceName: service,
        );
        final r = await client.queryReal(
          'SELECT :1 AS n, :2 AS s, :3 AS r, :4 AS t, :5 AS z FROM dual',
          binds: [
            42.5,
            'hello world',
            Uint8List.fromList([1, 2, 3, 255]),
            DateTime(2026, 10, 26, 11, 22, 33, 456),
            null,
          ],
        );
        final row = r.rows.first;
        expect(row[0], 42.5);
        expect(row[1], 'hello world');
        expect(row[2], [1, 2, 3, 255]);
        expect(row[3], DateTime(2026, 10, 26, 11, 22, 33, 456));
        expect(row[4], isNull);

        // A bind in a WHERE clause filters server-side.
        final filtered = await client.queryReal(
          'SELECT n FROM (SELECT 1 n FROM dual UNION ALL SELECT 2 FROM dual '
          'UNION ALL SELECT 3 FROM dual) WHERE n > :1',
          binds: [1],
        );
        expect(filtered.rows, [
          [2],
          [3]
        ]);
      } finally {
        await client.close();
      }
    });
  }, skip: enabled ? false : 'set RUN_ORACLE_TESTS=true to run (needs Oracle)');
}
