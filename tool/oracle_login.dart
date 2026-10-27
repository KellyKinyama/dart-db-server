// Single real-Oracle login attempt driven by the gitignored `.env` file.
//
// Reads credentials directly from `.env` (never from arguments or stdout) and
// performs exactly ONE `loginReal`, so a wrong password cannot be retried into
// an account lockout. Prints only the non-secret outcome.
//
// Usage: set the values in `.env`, then run:
//   dart run tool/oracle_login.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_db_server/oracle_thick_client.dart';
import 'package:dart_db_server/oracle_native_execute.dart'
    show NativeBind, NativeNestedCursor;

Map<String, String> _loadDotEnv(File file) {
  final env = <String, String>{};
  if (!file.existsSync()) return env;
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    env[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return env;
}

Future<void> main() async {
  final env = _loadDotEnv(File('.env'));

  final enabled = env['RUN_ORACLE_LOGIN']?.toLowerCase();
  if (enabled != 'true' && enabled != '1' && enabled != 'yes') {
    stderr.writeln('RUN_ORACLE_LOGIN is not set to true in .env — aborting. '
        'No login attempt made.');
    exitCode = 2;
    return;
  }

  final host = env['ORACLE_HOST'];
  final port = int.tryParse(env['ORACLE_PORT'] ?? '');
  final service = (env['ORACLE_SERVICE'] ?? '').isEmpty
      ? null
      : env['ORACLE_SERVICE'];
  final sid = (env['ORACLE_SID'] ?? '').isEmpty ? null : env['ORACLE_SID'];
  final user = env['ORACLE_USER'];
  final pass = env['ORACLE_PASSWORD'];

  if (host == null || host.isEmpty || port == null) {
    stderr.writeln('ORACLE_HOST / ORACLE_PORT missing in .env.');
    exitCode = 2;
    return;
  }
  if ((service == null) == (sid == null)) {
    stderr.writeln('Set exactly ONE of ORACLE_SERVICE or ORACLE_SID in .env.');
    exitCode = 2;
    return;
  }
  if (user == null || user.isEmpty || pass == null || pass.isEmpty) {
    stderr.writeln('ORACLE_USER / ORACLE_PASSWORD missing in .env.');
    exitCode = 2;
    return;
  }

  final target = service != null ? 'SERVICE_NAME=$service' : 'SID=$sid';
  stdout.writeln('Connecting to $host:$port ($target) as $user …');

  final client = await OracleThickClient.connect(port, host: host);
  try {
    final result = await client
        .loginReal(
          username: user,
          password: pass,
          serviceName: service,
          sid: sid,
        )
        .timeout(const Duration(seconds: 20));
    if (result.authenticated) {
      stdout.writeln('AUTHENTICATED ✓');
      final dbname = result.params['AUTH_DBNAME'] ??
          result.params['AUTH_SC_DBUNIQUE_NAME'];
      if (dbname != null) stdout.writeln('  database: $dbname');
      final ver = result.params['AUTH_VERSION_NO'];
      if (ver != null) stdout.writeln('  version no: $ver');

      // Read-only end-to-end validation of the execute/fetch path.
      // ORACLE_VALIDATE=v1 runs the SELECT-decode battery (Phase V1); =v2 runs
      // the positional-bind battery (Phase V2); otherwise a couple of smoke
      // queries, overridable with ORACLE_QUERY.
      final battery = <(String, String, List<Object?>)>[];
      final mode = (env['ORACLE_VALIDATE'] ?? '').toLowerCase();
      if (mode == 'v1') {
        battery.addAll(const [
          ('NUMBER', 'SELECT 1, -2, 3.5, 123456789012 FROM dual', []),
          ('VARCHAR2/CHAR', "SELECT 'abc', CAST('x' AS CHAR(3)) FROM dual", []),
          ('NCHAR/NVARCHAR2',
              "SELECT N'uni', CAST(N'y' AS NVARCHAR2(3)) FROM dual", []),
          ('DATE/TIMESTAMP', 'SELECT SYSDATE, SYSTIMESTAMP FROM dual', []),
          ('TSTZ',
              "SELECT CAST(SYSTIMESTAMP AS TIMESTAMP WITH TIME ZONE) FROM dual",
              []),
          ('TS LTZ',
              "SELECT CAST(SYSTIMESTAMP AS TIMESTAMP WITH LOCAL TIME ZONE) FROM dual",
              []),
          ('INTERVAL DS',
              "SELECT INTERVAL '2 03:04:05' DAY TO SECOND FROM dual", []),
          ('INTERVAL YM', "SELECT INTERVAL '3-6' YEAR TO MONTH FROM dual", []),
          ('BINARY_FLOAT/DOUBLE',
              'SELECT CAST(1.5 AS BINARY_FLOAT), CAST(2.5 AS BINARY_DOUBLE) FROM dual',
              []),
          ('RAW', "SELECT HEXTORAW('DEADBEEF') FROM dual", []),
          ('ROWID', 'SELECT ROWID FROM dual', []),
          ('typed NULLs',
              'SELECT CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR2(5)) FROM dual',
              []),
          ('multi-row', 'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 5', []),
        ]);
      } else if (mode == 'v2') {
        battery.addAll([
          ('scalars', 'SELECT :1 a, :2 b, :3 c, :4 d FROM dual',
              [42, 'hi', DateTime.utc(2021, 2, 3, 4, 5, 6), null]),
          ('two binds + add', 'SELECT :1 + :2 AS s FROM dual', [5, 3]),
          ('where-only binds', 'SELECT 1 AS k FROM dual WHERE :1 > :2', [5, 3]),
          ('where-only false', 'SELECT 1 AS k FROM dual WHERE :1 > :2', [1, 3]),
          ('reuse in where', 'SELECT 1 AS k FROM dual WHERE :1 > 0 AND :1 < 9',
              [5]),
          ('select-bind + where',
              'SELECT :1 n FROM dual WHERE :1 > :2', [5, 3]),
          ('raw bind', 'SELECT :1 r FROM dual',
              [Uint8List.fromList([1, 2, 3, 255])]),
          ('bind reuse / order', 'SELECT :1 x, :2 y FROM dual WHERE :2 = :1',
              [7, 7]),
        ]);
      } else if (mode != 'v5' && mode != 'v6') {
        battery.add(('smoke', 'SELECT USER, SYSDATE FROM dual', []));
        battery
            .add(('version', "SELECT banner FROM v\$version WHERE ROWNUM <= 5", []));
        final custom = env['ORACLE_QUERY'];
        if (custom != null && custom.isNotEmpty) {
          battery
            ..clear()
            ..add(('custom', custom, []));
        }
      }
      if (mode == 'v5') await _validatePlsql(client);
      if (mode == 'v6') await _validateCursors(client);
      for (final (label, sql, binds) in battery) {
        stdout.writeln('\n[$label] $sql'
            '${binds.isEmpty ? '' : '  binds=$binds'}');
        try {
          final resp = await client
              .queryReal(sql, binds: binds, prefetch: 50)
              .timeout(const Duration(seconds: 20));
          stdout.writeln(
              '  columns: ${resp.columns.map((c) => c.name).join(', ')}');
          for (final row in resp.rows.take(6)) {
            final cells = row
                .map((v) => '${v?.runtimeType ?? 'Null'}=$v')
                .join(' | ');
            stdout.writeln('  $cells');
          }
          stdout.writeln('  (${resp.rows.length} row(s))');
        } catch (e) {
          stdout.writeln('  FAILED: $e');
        }
      }
    } else {
      final err = result.params['error'];
      stdout.writeln('NOT authenticated'
          '${err != null ? ' — $err' : ''}');
    }
  } finally {
    await client.close();
  }
}

String _fmtRow(List<Object?> row) =>
    row.map((v) => '${v?.runtimeType ?? 'Null'}=$v').join(' | ');

/// Phase V5 — PL/SQL with OUT/IN OUT binds (compute-only, no data changes).
Future<void> _validatePlsql(OracleThickClient client) async {
  Future<void> call(
      String label, String sql, List<NativeBind> binds) async {
    stdout.writeln('\n[$label] $sql');
    try {
      final r = await client.callPlsql(sql, binds).timeout(
          const Duration(seconds: 20));
      stdout.writeln('  out: ${_fmtRow(r.outBindValues)}');
    } catch (e) {
      stdout.writeln('  FAILED: $e');
    }
  }

  await call('scalar OUT (num*10 + timestamp)',
      'BEGIN :1 := :2 * 10; :3 := SYSTIMESTAMP; END;',
      [NativeBind.outNumber(), NativeBind.value(7), NativeBind.outTimestamp()]);
  await call('OUT varchar',
      "BEGIN :1 := 'hello ' || :2; END;",
      [NativeBind.outVarchar(), NativeBind.value('19c')]);
  await call('IN OUT',
      "BEGIN :1 := :1 || '_x'; END;", [NativeBind.inOut('hi')]);
  await call('OUT date', 'BEGIN :1 := SYSDATE; END;', [NativeBind.outDate()]);
}

/// Phase V6 — REF CURSOR / nested cursor / implicit results (all SELECT-based).
Future<void> _validateCursors(OracleThickClient client) async {
  stdout.writeln('\n[REF CURSOR]');
  try {
    final rc = await client.openRefCursor(
        "BEGIN OPEN :1 FOR SELECT LEVEL AS n, 'row'||LEVEL AS label "
        "FROM dual CONNECT BY LEVEL <= 5; END;");
    stdout.writeln('  columns: ${rc.columns.map((c) => c.name).join(', ')}');
    for (final row in rc.rows.take(6)) {
      stdout.writeln('  ${_fmtRow(row)}');
    }
    stdout.writeln('  (${rc.rows.length} row(s))');
  } catch (e) {
    stdout.writeln('  FAILED: $e');
  }

  stdout.writeln('\n[nested CURSOR() column]');
  try {
    final resp = await client.queryReal(
        'SELECT 1 AS id, '
        'CURSOR(SELECT LEVEL FROM dual CONNECT BY LEVEL <= 3) AS c FROM dual');
    for (final row in resp.rows) {
      stdout.writeln('  id=${row[0]} inner=${row[1]}');
    }
  } catch (e) {
    stdout.writeln('  FAILED: $e');
  }

  stdout.writeln('\n[implicit result set]');
  try {
    final resp = await client.callPlsql(
        'DECLARE c SYS_REFCURSOR; '
        "BEGIN OPEN c FOR SELECT 1 AS a, 'x' AS b FROM dual; "
        'DBMS_SQL.RETURN_RESULT(c); END;',
        const []);
    for (final ir in resp.implicitResults) {
      final rows = await client.fetchImplicitResult(ir);
      stdout.writeln('  result rows: ${rows.map(_fmtRow).join(' ; ')}');
    }
  } catch (e) {
    stdout.writeln('  FAILED: $e');
  }

  stdout.writeln('\n[multiple REF CURSOR OUT binds]');
  try {
    final resp = await client.callPlsql(
        'BEGIN OPEN :1 FOR SELECT 1 FROM dual; '
        'OPEN :2 FOR SELECT 2 FROM dual UNION ALL SELECT 3 FROM dual; END;',
        [NativeBind.outCursor(), NativeBind.outCursor()]);
    for (final v in resp.outBindValues) {
      if (v is NativeNestedCursor) {
        final rows = await client.fetchCursor(v);
        stdout.writeln('  cursor rows: ${rows.map(_fmtRow).join(' ; ')}');
      }
    }
  } catch (e) {
    stdout.writeln('  FAILED: $e');
  }
}

