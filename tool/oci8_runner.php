<?php
/**
 * Real-Oracle (thick / OCI) test runner — "Gun 3" of the triple-threat suite.
 *
 * Uses the PHP `oci8` extension (the client we already drive dart_db_server
 * with) so it exercises the exact closed-source native wire path — the same
 * `libclntsh` / `oci.dll` the yajra/laravel-oci8 app loads.
 *
 * It runs the connect -> ALTER SESSION -> query/DML/bind -> drop lifecycle a
 * Laravel `yajra/laravel-oci8` app issues, and prints the results as JSON so the
 * differential harness can diff them against SQLite / the thin client / the
 * pure-Dart thick client.
 *
 * Prerequisites
 * -------------
 *   - PHP with the `oci8` extension enabled (`php -m` should list `oci8`).
 *   - Oracle Instant Client on PATH (already present if `oci_connect` works).
 *
 * Start the server first (PBKDF2 user is REQUIRED for thick clients):
 *
 *   dart run bin/dart_db_server.dart --memory \
 *       --oracle-port 1521 --oracle-pbkdf2-user native/Secret123
 *
 * Run:
 *
 *   php tool/oci8_runner.php
 *   ORA_HOST=127.0.0.1 ORA_PORT=1521 ORA_SERVICE=FREEPDB1 \
 *       ORA_USER=native ORA_PASSWORD=Secret123 php tool/oci8_runner.php
 *
 * Exit code is 0 only if every step succeeds (so it is CI-friendly).
 */

declare(strict_types=1);

if (!extension_loaded('oci8')) {
    fwrite(STDERR, "the oci8 extension is not loaded (check php -m)\n");
    exit(1);
}

function env(string $key, string $default): string
{
    $v = getenv($key);
    return $v === false || $v === '' ? $default : $v;
}

// Defaults match sqlnet.log / the triple-threat guide: the PHP oci8 client
// connects to dart_db_server on 127.0.0.1:1521/FREEPDB1.
$host     = env('ORA_HOST', '127.0.0.1');
$port     = env('ORA_PORT', '1521');
$service  = env('ORA_SERVICE', 'FREEPDB1');
$user     = env('ORA_USER', 'native');
$password = env('ORA_PASSWORD', 'Secret123');
$keep     = in_array('--keep', $argv, true); // leave the table behind

$dsn = "//$host:$port/$service";

function fail(string $phase, string $message): never
{
    echo json_encode(['ok' => false, 'phase' => $phase, 'error' => trim($message)],
        JSON_PRETTY_PRINT) . "\n";
    exit(1);
}

$conn = @oci_connect($user, $password, $dsn, 'AL32UTF8');
if (!$conn) {
    $e = oci_error();
    fail('connect', $e['message'] ?? 'oci_connect failed');
}

$steps = [];
$step = function (string $name, $result) use (&$steps): void {
    $steps[] = ['name' => $name, 'result' => $result];
};

/** Parses + executes a statement, failing hard on any ORA error. */
$exec = function (string $sql, array $binds = [], int $mode = OCI_COMMIT_ON_SUCCESS)
    use ($conn): array {
    $stmt = @oci_parse($conn, $sql);
    if (!$stmt) {
        $e = oci_error($conn);
        fail('parse', $e['message'] ?? "oci_parse failed for: $sql");
    }
    foreach ($binds as $name => $value) {
        oci_bind_by_name($stmt, $name, $binds[$name]);
    }
    if (!@oci_execute($stmt, $mode)) {
        $e = oci_error($stmt);
        fail('execute', $e['message'] ?? "oci_execute failed for: $sql");
    }
    return [$stmt, oci_num_rows($stmt)];
};

// yajra emits a single combined ALTER SESSION at connect time; mirror it so the
// server sees the same session bootstrap a real Laravel app sends.
$exec("ALTER SESSION SET NLS_TIME_FORMAT = 'HH24:MI:SS' NLS_NUMERIC_CHARACTERS = '.,'");
$step('alter_session', 'ok');

$exec('CREATE TABLE oci8_probe (id INTEGER PRIMARY KEY, name VARCHAR2(40))');
$step('create_table', 'ok');

// Named binds, the oci_bind_by_name path.
$id = 1; $name = 'alice';
[$ins] = $exec('INSERT INTO oci8_probe (id, name) VALUES (:id, :name)',
    [':id' => $id, ':name' => $name]);
$id = 2; $name = 'bob';
[$ins, $insAffected] = $exec('INSERT INTO oci8_probe (id, name) VALUES (:id, :name)',
    [':id' => $id, ':name' => $name]);
$step('insert_affected', $insAffected);

[$sel] = $exec('SELECT id, name FROM oci8_probe ORDER BY id');
$all = [];
while ($row = oci_fetch_array($sel, OCI_NUM + OCI_RETURN_NULLS)) {
    $all[] = [(int) $row[0], $row[1]];
}
$step('select_all', $all);

$min = 1;
[$selB] = $exec('SELECT id, name FROM oci8_probe WHERE id > :min ORDER BY id',
    [':min' => $min]);
$bound = [];
while ($row = oci_fetch_array($selB, OCI_NUM + OCI_RETURN_NULLS)) {
    $bound[] = [(int) $row[0], $row[1]];
}
$step('select_bound', $bound);

$n = 'carol'; $uid = 2;
[$upd, $updAffected] = $exec('UPDATE oci8_probe SET name = :n WHERE id = :id',
    [':n' => $n, ':id' => $uid]);
$step('update_affected', $updAffected);

[$cnt] = $exec('SELECT COUNT(*) FROM oci8_probe');
$row = oci_fetch_array($cnt, OCI_NUM);
$step('count', (int) $row[0]);

if (!$keep) {
    $exec('DROP TABLE oci8_probe');
    $step('drop_table', 'ok');
}

oci_close($conn);

echo json_encode(['ok' => true, 'steps' => $steps], JSON_PRETTY_PRINT) . "\n";
exit(0);
