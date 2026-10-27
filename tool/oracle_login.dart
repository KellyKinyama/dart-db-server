// Single real-Oracle login attempt driven by the gitignored `.env` file.
//
// Reads credentials directly from `.env` (never from arguments or stdout) and
// performs exactly ONE `loginReal`, so a wrong password cannot be retried into
// an account lockout. Prints only the non-secret outcome.
//
// Usage: set the values in `.env`, then run:
//   dart run tool/oracle_login.dart
import 'dart:io';

import 'package:dart_db_server/oracle_thick_client.dart';

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
      // ORACLE_VALIDATE=v1 runs the SELECT-decode battery (Phase V1); otherwise
      // a couple of smoke queries, overridable with ORACLE_QUERY.
      final battery = <(String, String)>[];
      if ((env['ORACLE_VALIDATE'] ?? '').toLowerCase() == 'v1') {
        battery.addAll(const [
          ('NUMBER', 'SELECT 1, -2, 3.5, 123456789012 FROM dual'),
          ('VARCHAR2/CHAR', "SELECT 'abc', CAST('x' AS CHAR(3)) FROM dual"),
          ('NCHAR/NVARCHAR2',
              "SELECT N'uni', CAST(N'y' AS NVARCHAR2(3)) FROM dual"),
          ('DATE/TIMESTAMP', 'SELECT SYSDATE, SYSTIMESTAMP FROM dual'),
          ('TSTZ',
              "SELECT CAST(SYSTIMESTAMP AS TIMESTAMP WITH TIME ZONE) FROM dual"),
          ('TS LTZ',
              "SELECT CAST(SYSTIMESTAMP AS TIMESTAMP WITH LOCAL TIME ZONE) FROM dual"),
          ('INTERVAL DS', "SELECT INTERVAL '2 03:04:05' DAY TO SECOND FROM dual"),
          ('INTERVAL YM', "SELECT INTERVAL '3-6' YEAR TO MONTH FROM dual"),
          ('BINARY_FLOAT/DOUBLE',
              'SELECT CAST(1.5 AS BINARY_FLOAT), CAST(2.5 AS BINARY_DOUBLE) FROM dual'),
          ('RAW', "SELECT HEXTORAW('DEADBEEF') FROM dual"),
          ('ROWID', 'SELECT ROWID FROM dual'),
          ('NULLs', 'SELECT NULL, CAST(NULL AS NUMBER) FROM dual'),
          ('multi-row',
              'SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 5'),
        ]);
      } else {
        battery.add(('smoke', 'SELECT USER, SYSDATE FROM dual'));
        battery.add(('version', "SELECT banner FROM v\$version WHERE ROWNUM <= 5"));
        final custom = env['ORACLE_QUERY'];
        if (custom != null && custom.isNotEmpty) {
          battery
            ..clear()
            ..add(('custom', custom));
        }
      }
      for (final (label, sql) in battery) {
        stdout.writeln('\n[$label] $sql');
        try {
          final resp = await client
              .queryReal(sql, prefetch: 50)
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
