#!/usr/bin/env python3
"""Real-Oracle (thick / OCI) test runner — "Gun 3" of the triple-threat suite.

This is the Python counterpart to the PHP ``oci8`` client we already drive
dart_db_server with. It uses ``python-oracledb`` in **thick mode**, which loads
the same Oracle Instant Client (``libclntsh`` / ``oci.dll``) the PHP ``oci8``
extension uses — so it exercises the exact closed-source native wire path, not
the open-source thin protocol.

It runs the same connect -> ALTER SESSION -> query/DML/bind -> drop lifecycle a
Laravel ``yajra/laravel-oci8`` app issues, and prints the results as JSON so the
differential harness can diff them against SQLite / the thin client / the
pure-Dart thick client.

Prerequisites
-------------
    pip install oracledb
    # Oracle Instant Client installed (same one PHP oci8 uses). On Windows it is
    # already present if `oci_connect` works from PHP. Point --lib-dir at it if
    # it is not on PATH.

Start the server first (PBKDF2 user is REQUIRED for thick clients)::

    dart run bin/dart_db_server.dart --memory \
        --oracle-port 1521 --oracle-pbkdf2-user native/Secret123

Run::

    python tool/oci8_runner.py
    python tool/oci8_runner.py --host 127.0.0.1 --port 1521 \
        --service FREEPDB1 --user native --password Secret123

Exit code is 0 only if every step succeeds (so it is CI-friendly).
"""

from __future__ import annotations

import argparse
import json
import os
import sys

try:
    import oracledb
except ImportError:
    sys.exit("python-oracledb is not installed. Run: pip install oracledb")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Real-Oracle (thick/OCI) test runner")
    # Defaults match sqlnet.log / the triple-threat guide: the PHP oci8 client
    # connects to dart_db_server on 127.0.0.1:1521/FREEPDB1.
    p.add_argument("--host", default=os.environ.get("ORA_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("ORA_PORT", "1521")))
    p.add_argument("--service", default=os.environ.get("ORA_SERVICE", "FREEPDB1"))
    p.add_argument("--user", default=os.environ.get("ORA_USER", "native"))
    p.add_argument("--password", default=os.environ.get("ORA_PASSWORD", "Secret123"))
    p.add_argument(
        "--lib-dir",
        default=os.environ.get("ORA_LIB_DIR"),
        help="Instant Client directory (omit if libclntsh/oci.dll is on PATH).",
    )
    p.add_argument(
        "--keep",
        action="store_true",
        help="Leave the test table behind (skip the final DROP).",
    )
    return p.parse_args()


def connect(args: argparse.Namespace) -> oracledb.Connection:
    # Switch to THICK mode: without this python-oracledb stays thin and would
    # NOT exercise the native OCI wire path (the whole point of Gun 3).
    oracledb.init_oracle_client(lib_dir=args.lib_dir)
    dsn = oracledb.makedsn(args.host, args.port, service_name=args.service)
    return oracledb.connect(user=args.user, password=args.password, dsn=dsn)


def run(conn: oracledb.Connection, keep: bool) -> dict:
    """Runs the yajra-style lifecycle and returns a result dict for diffing."""
    out: dict = {"steps": []}

    def step(name, value):
        out["steps"].append({"name": name, "result": value})

    with conn.cursor() as cur:
        # yajra emits a single combined ALTER SESSION at connect time; mirror it
        # so the server sees the same session bootstrap a real Laravel app sends.
        cur.execute(
            "ALTER SESSION SET NLS_TIME_FORMAT = 'HH24:MI:SS' "
            "NLS_NUMERIC_CHARACTERS = '.,'"
        )
        step("alter_session", "ok")

        cur.execute(
            "CREATE TABLE oci8_probe (id INTEGER PRIMARY KEY, name VARCHAR2(40))"
        )
        step("create_table", "ok")

        # Named binds, the oci_bind_by_name equivalent.
        cur.execute(
            "INSERT INTO oci8_probe (id, name) VALUES (:id, :name)",
            id=1,
            name="alice",
        )
        cur.execute(
            "INSERT INTO oci8_probe (id, name) VALUES (:id, :name)",
            id=2,
            name="bob",
        )
        step("insert_affected", cur.rowcount)  # 1 for the last insert
        conn.commit()

        cur.execute("SELECT id, name FROM oci8_probe ORDER BY id")
        step("select_all", [list(r) for r in cur.fetchall()])

        cur.execute(
            "SELECT id, name FROM oci8_probe WHERE id > :min ORDER BY id", min=1
        )
        step("select_bound", [list(r) for r in cur.fetchall()])

        cur.execute("UPDATE oci8_probe SET name = :n WHERE id = :id", n="carol", id=2)
        step("update_affected", cur.rowcount)
        conn.commit()

        cur.execute("SELECT COUNT(*) FROM oci8_probe")
        step("count", cur.fetchone()[0])

        if not keep:
            cur.execute("DROP TABLE oci8_probe")
            step("drop_table", "ok")

    return out


def main() -> int:
    args = parse_args()
    try:
        conn = connect(args)
    except oracledb.Error as e:
        print(
            json.dumps(
                {"ok": False, "phase": "connect", "error": str(e)}, indent=2
            )
        )
        return 1

    try:
        result = run(conn, keep=args.keep)
        result["ok"] = True
        print(json.dumps(result, indent=2))
        return 0
    except oracledb.Error as e:
        print(json.dumps({"ok": False, "phase": "run", "error": str(e)}, indent=2))
        return 1
    finally:
        try:
            conn.close()
        except oracledb.Error:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
