# Patch request: SID-based connect for `loginReal` (OMS ORCLSID)

**From:** zdms_portal integration side · **Date:** 2026-10-26
**Target:** `lib/oracle_thick_client.dart` (`OracleThickClient`)
**Priority:** blocks OMS integration; nothing else depends on it yet.

## Why
The portal needs to reach the live **OMS** database, which is **SID-based**, not
service-based:

| Target | Value |
|---|---|
| Host:port | `db.example.internal:1521` (confirmed reachable via raw TCP) |
| Connect data | **`SID=ORCLSID`** (`OMS_DB_DATABASE=ORCLSID`, `OMS_DB_SERVICE_NAME` empty) |
| User | `APPUSER` |
| Server version | **11g** (per Laravel `config/oracle.php` → `server_version => '11g'`) |

`oci8` connects with `(DESCRIPTION=(ADDRESS=...)(CONNECT_DATA=(SID=ORCLSID)))`.
The thin `package:oracledb` can't (EZ-connect/service only) → `ORA-12514`.

## What I observed (one live attempt, 2026-10-26)
`loginReal(serviceName: 'ORCLSID')` against the real listener:
```
TCP + TNS socket: connected
ATTEMPT ERROR: Bad state: timed out waiting for a TNS frame
```
The socket connects, the CONNECT is sent, but the listener never returns a usable
ACCEPT. No credentials were transmitted (the stall is at `parseAccept`, before
O8LOGON), so **no failed-login hit the `APPUSER` account** — zero lockout risk.

Root cause = the two gaps below.

## Gap 1 — `loginReal` is SERVICE_NAME-only
`lib/oracle_thick_client.dart`, `loginReal` (~L697–L705):

```dart
Future<NativeLoginResult> loginReal({
  required String username,
  required String password,
  required String serviceName,          // <- only option
  String? alterSession,
}) async {
  final descriptor = '(DESCRIPTION=(CONNECT_DATA=(SERVICE_NAME=$serviceName)'
      '(CID=(PROGRAM=dart-thick)(HOST=localhost)(USER=$username))))';
  ...
```

With `serviceName: 'ORCLSID'` this sends `SERVICE_NAME=ORCLSID`; the listener
has no such **service** (ORCLSID is a **SID**) → refuses at CONNECT.

### Requested change
Let the caller specify a SID (or a full connect-data override). Suggested
backward-compatible signature:

```dart
Future<NativeLoginResult> loginReal({
  required String username,
  required String password,
  String? serviceName,   // one of serviceName / sid required
  String? sid,
  String? alterSession,
}) async {
  assert((serviceName == null) != (sid == null),
      'pass exactly one of serviceName / sid');
  final connectData = sid != null
      ? 'SID=$sid'
      : 'SERVICE_NAME=$serviceName';
  final descriptor = '(DESCRIPTION=(CONNECT_DATA=($connectData)'
      '(CID=(PROGRAM=dart-thick)(HOST=localhost)(USER=$username))))';
  ...
```

(The low-level `login()` already accepts an arbitrary `descriptor`, but it runs
the **dart-db-server** O5LOGON dialect, not the real-Oracle O8LOGON — so it isn't
a path to a real listener. The SID option needs to live on `loginReal`.)

## Gap 2 — a listener REFUSE is swallowed as a timeout
When the connect-string is wrong (service/SID mismatch, etc.) the listener
returns a TNS **REFUSE** packet (packet type 4) carrying the `ORA-12514`/`ORA-12505`
text. `parseAccept(await _frames.next())` expects an ACCEPT and the reader instead
times out. Please detect the REFUSE packet and surface the embedded `ORA-xxxxx`
(throw `OracleThickException` or return `NativeLoginResult(authenticated:false,
params:{'error': 'ORA-12505'})`) so a bad descriptor fails fast and legibly
instead of hanging.

## Known risk to verify (not blocking the patch)
`loginReal` is documented/verified for 19c+/26ai. OMS is **11g**. Once the SID
descriptor reaches the server, the O5LOGON/O8LOGON verifier and the TTC v319/v320
negotiation may differ on 11g. Please treat first real-11g contact as its own
checkpoint.

## Acceptance criteria
1. `loginReal(sid: 'ORCLSID', ...)` emits `(CONNECT_DATA=(SID=ORCLSID)...)`.
2. A wrong connect-string yields a clean `ORA-xxxxx` (no timeout/hang).
3. Existing `serviceName:` callers and the gated 8-test real-Oracle suite stay green.
4. (Stretch) a documented result of a real 11g login attempt against ORCLSID.

## How I'll re-verify (read-only, my side)
A one-shot probe: `OracleThickClient.connect(1521, host:'db.example.internal')` →
`loginReal(username:'APPUSER', password: <from .env>, sid:'ORCLSID')` →
`queryReal('SELECT 1 FROM dual')`. Single attempt only (lockout-safe); creds read
from `.env`, never logged.
