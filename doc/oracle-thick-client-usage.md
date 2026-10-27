# OracleThickClient — native real-Oracle usage

`OracleThickClient` is a self-contained, pure-Dart **native Oracle client**: it
speaks the Oracle TTC wire protocol directly (connect, O8LOGON auth, OALL8
execute/fetch, LOB ops) with no OCI/Instant Client and no external packages. It
is the counterpart to the thin `package:oracledb` driver, and is validated
against real Oracle across versions — the FAST_AUTH path on **23ai/26ai**
(Docker `gvenzl/oracle-free`) and the classic non-fast-auth path on **21c XE**
(reads + writes) and a live **19c** server (SID connect, reads). See
[oracle-thick-client-spec-plan.md](oracle-thick-client-spec-plan.md) for the
protocol details and phase history.

> The `loginReal` / `queryReal` / `callPlsql` / `executeDml` family targets a
> **real Oracle listener**. The separate `login` / `run` methods speak the
> in-process `dart-db-server` dialect and are not covered here.

## Install / import

```dart
import 'package:dart_db_server/oracle_thick_client.dart';
// Value types (NativeBind, NativeColumn, NativeImplicitResult, OracleYearMonth …)
import 'package:dart_db_server/oracle_native_execute.dart';
```

## Connecting & authenticating

```dart
final client = await OracleThickClient.connect(1521, host: '127.0.0.1');

final login = await client.loginReal(
  username: 'system',
  password: 'TestPw1234',
  serviceName: 'FREEPDB1',   // service-based (EZ-connect style)
);
if (!login.authenticated) {
  throw StateError('login failed: ${login.params['error']}');
}
// ... use the client ...
await client.close();
```

### Service name vs SID

Pass **exactly one** of `serviceName` or `sid` (an `ArgumentError` is thrown
otherwise):

```dart
// Service-based — can target a specific pluggable database (PDB):
await client.loginReal(username: u, password: p, serviceName: 'FREEPDB1');

// SID-based — reaches the instance / CDB root; required for pre-12c DBs that
// only register a SID (e.g. OMS `ORCLSID`):
await client.loginReal(username: u, password: p, sid: 'ORCLSID');
```

| Connect data | Descriptor sent | Reaches |
|---|---|---|
| `serviceName: 'FREEPDB1'` | `(CONNECT_DATA=(SERVICE_NAME=FREEPDB1)…)` | the **PDB** |
| `serviceName: 'FREE'` | `(CONNECT_DATA=(SERVICE_NAME=FREE)…)` | the CDB root |
| `sid: 'FREE'` | `(CONNECT_DATA=(SID=FREE)…)` | the CDB-root **instance** |

A SID only names an instance; a service name can select an individual PDB.

### Login errors fail fast

A wrong connect-string makes the listener return a TNS REFUSE, surfaced as an
`ORA-xxxxx` in `params['error']` (no hang):

```dart
final r = await client.loginReal(username: u, password: p, sid: 'NOSUCHSID');
// r.authenticated == false, r.params['error'] == 'ORA-12505'
```

## Server compatibility (handshake negotiation)

`loginReal` adapts to the server automatically from the TNS **ACCEPT** packet —
no version flag is needed:

- **23ai / 26ai** advertise FAST_AUTH: PROTOCOL, DATA-TYPES and AUTH_PHASE_ONE
  are bundled into one round trip.
- **Pre-23ai (12c/18c/19c/21c)** do not advertise FAST_AUTH: the client sends
  PROTOCOL, DATA-TYPES and AUTH_PHASE_ONE/TWO as separate round trips, and
  resends the CONNECT if the listener asks for it (TNS RESEND). Both paths use
  the same O8LOGON (12c PBKDF2) proof, so the account needs a 12c verifier
  (`SEC_CASE_SENSITIVE_LOGON` on by default in 12c+); a server offering only a
  legacy verifier is reported as an error rather than retried.

The **TTC field version** is negotiated from the server's PROTOCOL response and
bounds the OALL8 execute/fetch/LOB wire shape, so the same `queryReal` /
`executeDml` / `callPlsql` calls work unchanged across versions — a 19c server
(field version 12), a 21c server (field version 16), and a 26ai server
(field version 24).

> **Validated versions.** Read *and* write paths are exercised against real
> Oracle on three releases: **23ai/26ai** (FAST_AUTH, gated suite), **21c XE**
> (non-fast-auth, reads + writes live), and **19c** (non-fast-auth over SID,
> reads live). See
> [oracle-19c-validation-plan.md](oracle-19c-validation-plan.md) and the
> cross-version matrix in
> [oracle-thick-client-spec-plan.md](oracle-thick-client-spec-plan.md).

### Probing a listener without credentials

`probeConnect` performs a **CONNECT-only** handshake (no password sent), so it
is safe to point at an account with a lockout policy. It returns the listener's
negotiated capabilities, or an `ORA-xxxxx` on REFUSE:

```dart
final info = await client.probeConnect(sid: 'ORCLSID');
// info.accepted, info.version, info.supportsFastAuth, info.sdu
```

Open a fresh client per probe (a listener expects one CONNECT per connection).

## Queries

`queryReal` runs a row-returning statement, following FETCH round-trips until
the cursor is drained. Columns decode to idiomatic Dart types.

```dart
final result = await client.queryReal(
  'SELECT id, name, created FROM employees WHERE dept = :1 AND active = :2',
  binds: [10, 'Y'],
);
for (final col in result.columns) {
  print('${col.name} (oracleType=${col.oracleType})');
}
for (final row in result.rows) {
  final id = row[0] as num;
  final name = row[1] as String;
  final created = row[2] as DateTime;
}
```

### Type mapping (fetch)

| Oracle type | Dart value |
|---|---|
| NUMBER / INTEGER / FLOAT | `num` (`int` or `double`) |
| VARCHAR2 / CHAR / NVARCHAR2 / NCHAR | `String` |
| RAW | `Uint8List` |
| DATE / TIMESTAMP / TIMESTAMP WITH LOCAL TIME ZONE | `DateTime` |
| TIMESTAMP WITH TIME ZONE | `DateTime` (UTC instant) |
| INTERVAL DAY TO SECOND | `Duration` |
| INTERVAL YEAR TO MONTH | `OracleYearMonth` |
| BINARY_FLOAT / BINARY_DOUBLE | `double` |
| ROWID | `String` (18-char) |
| CLOB / NCLOB | `String` (materialized via LOB READ) |
| BLOB | `Uint8List` (materialized via LOB READ) |
| SQL `NULL` | `null` |

CLOB/BLOB cells are fetched as locators and transparently materialized by
`queryReal` (and the cursor/implicit-result readers).

## Binds

Positional binds (`:1`, `:2`, …) are passed in **appearance order** — Oracle
orders numbered binds by their first occurrence in the SQL text, not by number.

```dart
await client.queryReal('SELECT * FROM t WHERE a = :1 AND b = :2', binds: [1, 'x']);
```

Supported IN bind Dart types: `num` → NUMBER, `String` → VARCHAR2,
`Uint8List` → RAW, `DateTime` → TIMESTAMP, `null` → typed NULL.

## PL/SQL, OUT binds, and REF CURSORs

`callPlsql` runs a block with IN and/or OUT binds. Declare OUT binds with the
`NativeBind.out*` factories; decoded values arrive in `outBindValues`
(declaration order).

```dart
final r = await client.callPlsql(
  'BEGIN :1 := :2 * 10; :3 := SYSTIMESTAMP; END;',
  [
    NativeBind.outNumber(),          // :1 OUT
    NativeBind.value(7),             // :2 IN
    NativeBind.outTimestamp(),       // :3 OUT
  ],
);
final product = r.outBindValues[0] as num;      // 70
final now     = r.outBindValues[2] as DateTime;
```

OUT bind factories: `NativeBind.outNumber()`, `NativeBind.outVarchar({maxSize})`,
`NativeBind.outDate()`, `NativeBind.outTimestamp()`, `NativeBind.outCursor()`.

### REF CURSOR

`openRefCursor` executes a `BEGIN OPEN :1 FOR …; END;` block and drains the
opened cursor into rows:

```dart
final rc = await client.openRefCursor('''
  BEGIN OPEN :1 FOR SELECT id, name FROM employees ORDER BY id; END;
''');
print(rc.columns.map((c) => c.name));   // (ID, NAME)
for (final row in rc.rows) { /* ... */ }
```

### Implicit result sets

A block that calls `DBMS_SQL.RETURN_RESULT` exposes each result on
`implicitResults`; fetch each with `fetchImplicitResult`:

```dart
final res = await client.callPlsql('''
  DECLARE c SYS_REFCURSOR;
  BEGIN OPEN c FOR SELECT 1 a FROM dual; DBMS_SQL.RETURN_RESULT(c); END;
''', const []);
for (final r in res.implicitResults) {
  final rows = await client.fetchImplicitResult(r);
}
```

## DML, array DML, and RETURNING

```dart
// Single-row DML (and DDL) — returns rows affected.
final n = await client.executeDml(
  'INSERT INTO t (id, name) VALUES (:1, :2)', binds: [1, 'alice']);

// Array DML (executeMany): one inner list of IN values per iteration.
final m = await client.executeDml('INSERT INTO t (id, name) VALUES (:1, :2)',
  bulkRows: [[2, 'bob'], [3, 'carol'], [4, 'david']]);   // m == 3

// DML RETURNING … INTO an OUT bind — one value per affected row.
final ret = await client.executeReturning(
  'UPDATE t SET name = :1 WHERE id <= :2 RETURNING id INTO :3',
  [NativeBind.value('updated'), NativeBind.value(2), NativeBind.outNumber()],
);
final ids = ret.outBindValues[0] as List;   // e.g. [1, 2]
```

## Statement caching

Set `statementCacheEnabled = true` to have `queryReal` reuse a repeated
statement's open server cursor and cached describe, re-executing without a
re-parse (opt-in; off by default). A server-invalidated cursor transparently
falls back to a fresh parse.

```dart
client.statementCacheEnabled = true;
await client.queryReal('SELECT id FROM employees WHERE dept = :1', binds: [10]);
await client.queryReal('SELECT id FROM employees WHERE dept = :1', binds: [20]);
// ^ second call re-executes the cached cursor (no PARSE, SQL text not re-sent).
```

## Error handling

- Login problems: `loginReal` returns `NativeLoginResult(authenticated: false,
  params: {'error': 'ORA-xxxxx'})` rather than throwing.
- Statement errors: `queryReal` / `executeDml` / `executeReturning` / `callPlsql`
  throw `OracleThickException` carrying the numeric `code` and the `ORA-xxxxx:`
  `message`.

```dart
try {
  await client.queryReal('SELECT * FROM no_such_table');
} on OracleThickException catch (e) {
  print('${e.code}: ${e.message}');   // 942: ORA-00942: table or view does not exist
}
```

## Running the integration tests

The real-Oracle tests are gated behind an env flag so CI without a database
stays green:

```bash
# Service name (default FREEPDB1):
RUN_ORACLE_TESTS=true dart test test/oracle_real_login_test.dart

# Override target (host/port/user/password/service or SID):
RUN_ORACLE_TESTS=true ORACLE_HOST=db.example.internal ORACLE_SID=ORCLSID \
  ORACLE_USER=APPUSER ORACLE_PASSWORD=*** dart test test/oracle_real_login_test.dart
```

## One-off login runner (`tool/oracle_login.dart`)

For a quick manual check against a real listener, `tool/oracle_login.dart`
reads credentials from a **gitignored `.env`** and performs exactly **one**
login (so a wrong password cannot be retried into a lockout), then runs a couple
of read-only validation queries. It never prints the password.

```bash
# .env (gitignored) — fill in the values:
#   RUN_ORACLE_LOGIN=true
#   ORACLE_HOST=db.example.internal
#   ORACLE_PORT=1521
#   ORACLE_SID=ORCLSID          # or ORACLE_SERVICE=...
#   ORACLE_USER=...
#   ORACLE_PASSWORD=...
#   ORACLE_QUERY=SELECT ...      # optional: override the validation query
dart run tool/oracle_login.dart
```

