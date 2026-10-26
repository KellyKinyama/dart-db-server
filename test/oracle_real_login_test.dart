@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/oracle_thick_client.dart';
import 'package:dart_db_server/oracle_native_execute.dart'
    show OracleYearMonth, NativeBind;
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

    test('a wrong connect-string surfaces an ORA error, not a hang', () async {
      final host = env['ORACLE_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['ORACLE_PORT'] ?? '1521') ?? 1521;

      final client = await OracleThickClient.connect(port, host: host);
      try {
        // An unknown SID draws a listener REFUSE (ORA-12505); it must fail fast
        // rather than time out waiting for an ACCEPT.
        final result = await client
            .loginReal(username: 'x', password: 'y', sid: 'NOSUCHSID')
            .timeout(const Duration(seconds: 5));
        expect(result.authenticated, isFalse);
        expect(result.params['error'], startsWith('ORA-'));
      } finally {
        await client.close();
      }
    });

    test('SID-based login authenticates against a real listener', () async {
      // The gvenzl/oracle-free listener registers its CDB instance as a SID
      // ('FREE'), so (CONNECT_DATA=(SID=FREE)) resolves. Override with
      // ORACLE_SID for other databases (e.g. the OMS ISDTRAIN instance).
      final host = env['ORACLE_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['ORACLE_PORT'] ?? '1521') ?? 1521;
      final user = env['ORACLE_USER'] ?? 'system';
      final pass = env['ORACLE_PASSWORD'] ?? 'TestPw1234';
      final sid = env['ORACLE_SID'] ?? 'FREE';

      final client = await OracleThickClient.connect(port, host: host);
      try {
        final result = await client
            .loginReal(username: user, password: pass, sid: sid)
            .timeout(const Duration(seconds: 8));
        expect(result.authenticated, isTrue);
        final rows = await client.queryReal('SELECT 1 FROM dual');
        expect(rows.rows, [
          [1]
        ]);
      } finally {
        await client.close();
      }
    });

    test('loginReal requires exactly one of serviceName / sid', () async {
      final host = env['ORACLE_HOST'] ?? '127.0.0.1';
      final port = int.tryParse(env['ORACLE_PORT'] ?? '1521') ?? 1521;
      final client = await OracleThickClient.connect(port, host: host);
      try {
        expect(
            () => client.loginReal(username: 'x', password: 'y'),
            throwsArgumentError);
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

    test('CLOB / BLOB materialize from real Oracle', () async {
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
            TO_CLOB('hello clob world') AS c,
            TO_BLOB(UTL_RAW.CAST_TO_RAW('BLOBDATA')) AS b,
            TO_CLOB(RPAD(TO_CLOB('z'), 9000, 'z')) AS bigc,
            TO_CLOB('') AS emptyc
          FROM dual
        ''');
        final row = r.rows.first;
        expect(row[0], 'hello clob world');
        expect(row[1], [66, 76, 79, 66, 68, 65, 84, 65]); // 'BLOBDATA'
        expect((row[2] as String).length, 9000); // multi-read CLOB
        expect(row[3], isNull); // TO_CLOB('') is NULL in Oracle
      } finally {
        await client.close();
      }
    });

    test('REF CURSOR OUT bind drains rows from real Oracle', () async {
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
        final r = await client.openRefCursor('''
          BEGIN
            OPEN :1 FOR
              SELECT level AS n, 'row' || level AS label
              FROM dual CONNECT BY level <= 5;
          END;
        ''');
        expect(r.columns.map((c) => c.name).toList(), ['N', 'LABEL']);
        expect(r.rows, [
          [1, 'row1'],
          [2, 'row2'],
          [3, 'row3'],
          [4, 'row4'],
          [5, 'row5'],
        ]);
      } finally {
        await client.close();
      }
    });

    test('scalar OUT binds + implicit results from real Oracle', () async {
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
        // NUMBER + VARCHAR2 + DATE OUT binds (appearance order :1,:2,:3).
        final r = await client.callPlsql('''
          BEGIN
            :1 := 42 * 2;
            :2 := 'hello out';
            :3 := DATE '2026-10-26';
          END;
        ''', [
          NativeBind.outNumber(),
          NativeBind.outVarchar(),
          NativeBind.outDate(),
        ]);
        expect(r.outBindValues[0], 84);
        expect(r.outBindValues[1], 'hello out');
        expect(r.outBindValues[2], DateTime(2026, 10, 26));

        // IN feeding an OUT (appearance order :1 OUT, :2 IN).
        final r2 = await client.callPlsql('BEGIN :1 := :2 * 10; END;', [
          NativeBind.outNumber(),
          NativeBind.value(7),
        ]);
        expect(r2.outBindValues, [70]);

        // Implicit result set (DBMS_SQL.RETURN_RESULT).
        final ir = await client.callPlsql('''
          DECLARE c SYS_REFCURSOR;
          BEGIN
            OPEN c FOR SELECT 100 AS a, 'x' AS b FROM dual;
            DBMS_SQL.RETURN_RESULT(c);
          END;
        ''', const []);
        expect(ir.implicitResults, hasLength(1));
        final rows = await client.fetchImplicitResult(ir.implicitResults.first);
        expect(rows, [
          [100, 'x']
        ]);
      } finally {
        await client.close();
      }
    });

    test('DML, array DML, and RETURNING against real Oracle', () async {
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
        await client
            .executeDml('DROP TABLE t_thick_it PURGE')
            .catchError((_) => 0);
        await client.executeDml(
            'CREATE TABLE t_thick_it (id NUMBER, name VARCHAR2(40))');
        try {
          // Single-row DML with binds.
          expect(
              await client.executeDml('INSERT INTO t_thick_it VALUES (:1, :2)',
                  binds: [1, 'alice']),
              1);
          // Array DML (executeMany) with varying string lengths.
          expect(
              await client.executeDml('INSERT INTO t_thick_it VALUES (:1, :2)',
                  bulkRows: [
                    [2, 'bob'],
                    [3, 'carol'],
                    [4, 'david'],
                  ]),
              3);
          final all = await client
              .queryReal('SELECT id, name FROM t_thick_it ORDER BY id');
          expect(all.rows, [
            [1, 'alice'],
            [2, 'bob'],
            [3, 'carol'],
            [4, 'david'],
          ]);
          // DML RETURNING INTO an OUT bind (one value per affected row).
          final ret = await client.executeReturning(
              'UPDATE t_thick_it SET name = :1 WHERE id <= :2 '
              'RETURNING id INTO :3',
              [
                NativeBind.value('updated'),
                NativeBind.value(2),
                NativeBind.outNumber(),
              ]);
          expect(ret.outBindValues, [
            [1, 2]
          ]);
        } finally {
          await client.executeDml('DROP TABLE t_thick_it PURGE');
        }
      } finally {
        await client.close();
      }
    });

    test('large binds and big array DML fragment across SDU packets', () async {
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
        // A bind larger than one SDU packet must be fragmented and round-trip
        // intact (END_OF_RPC only on the final packet).
        final big = 'x' * 30000;
        final r = await client
            .queryReal('SELECT LENGTH(:1) FROM dual', binds: [big]);
        expect(r.rows.first.first, 30000);

        // A 500-row array DML is a large multi-packet request.
        await client
            .executeDml('DROP TABLE t_thick_split PURGE')
            .catchError((_) => 0);
        await client.executeDml(
            'CREATE TABLE t_thick_split (id NUMBER, v VARCHAR2(100))');
        try {
          final rows = [for (var i = 0; i < 500; i++) [i, 'row_$i']];
          expect(
              await client.executeDml(
                  'INSERT INTO t_thick_split VALUES (:1, :2)', bulkRows: rows),
              500);
          final cnt =
              await client.queryReal('SELECT COUNT(*) FROM t_thick_split');
          expect(cnt.rows.first.first, 500);
        } finally {
          await client.executeDml('DROP TABLE t_thick_split PURGE');
        }
      } finally {
        await client.close();
      }
    });

    test('oversized String bind routes through a temporary CLOB', () async {
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
        // > 32767 bytes: must bind as a temp CLOB, not a VARCHAR2.
        final big = 'Z' * 50000;
        final r = await client
            .queryReal('SELECT LENGTH(:1) FROM dual', binds: [big]);
        expect(r.rows.first.first, 50000);

        // Insert into a CLOB column via bind and read it back intact.
        await client
            .executeDml('DROP TABLE t_thick_clob PURGE')
            .catchError((_) => 0);
        await client
            .executeDml('CREATE TABLE t_thick_clob (id NUMBER, body CLOB)');
        try {
          expect(
              await client.executeDml('INSERT INTO t_thick_clob VALUES (:1, :2)',
                  binds: [1, big]),
              1);
          final back = await client.queryReal(
              'SELECT body FROM t_thick_clob WHERE id = 1');
          expect(back.rows.first.first, big);
        } finally {
          await client.executeDml('DROP TABLE t_thick_clob PURGE');
        }
      } finally {
        await client.close();
      }
    });

    test('oversized Uint8List bind routes through a temporary BLOB', () async {
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
        final big =
            Uint8List.fromList(List.generate(60000, (i) => i % 256));
        await client
            .executeDml('DROP TABLE t_thick_blob PURGE')
            .catchError((_) => 0);
        await client
            .executeDml('CREATE TABLE t_thick_blob (id NUMBER, data BLOB)');
        try {
          expect(
              await client.executeDml('INSERT INTO t_thick_blob VALUES (:1, :2)',
                  binds: [1, big]),
              1);
          final back = await client
              .queryReal('SELECT data FROM t_thick_blob WHERE id = 1');
          expect(back.rows.first.first, big);
        } finally {
          await client.executeDml('DROP TABLE t_thick_blob PURGE');
        }
      } finally {
        await client.close();
      }
    });
  }, skip: enabled ? false : 'set RUN_ORACLE_TESTS=true to run (needs Oracle)');
}
