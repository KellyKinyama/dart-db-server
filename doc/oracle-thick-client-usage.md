# OracleThickClient — native real-Oracle usage

`OracleThickClient` is a self-contained, pure-Dart **native Oracle client**: it
speaks the Oracle TTC wire protocol directly (connect, O8LOGON auth, OALL8
execute/fetch, LOB ops) with no OCI/Instant Client and no external packages. It
is the counterpart to the thin `package:oracledb` driver, and is validated
against real Oracle (Docker `gvenzl/oracle-free`, 26ai) — see
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
// only register a SID (e.g. OMS `ISDTRAIN`):
await client.loginReal(username: u, password: p, sid: 'ISDTRAIN');
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

`loginReal` is validated on 19c+/21c/23ai/26ai. Pre-12c servers (11g) may
negotiate a lower protocol version or an older verifier — treat first 11g
contact as its own checkpoint.

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
RUN_ORACLE_TESTS=true ORACLE_HOST=10.1.101.127 ORACLE_SID=ISDTRAIN \
  ORACLE_USER=AWARENESS ORACLE_PASSWORD=*** dart test test/oracle_real_login_test.dart
```
