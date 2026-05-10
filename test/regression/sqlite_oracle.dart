/// Test helpers for cross-checking dart-db-server against SQLite as an
/// oracle. The reference engine is `package:sqlite3`, which depends on
/// the platform's native `sqlite3` shared library. If that library cannot
/// be loaded (e.g. CI without sqlite installed) every test that uses
/// [SqliteOracle] is skipped automatically rather than failing.
///
/// Production code MUST NOT import this file. It exists only under
/// test/regression/ for parity checking.
library;

import 'package:dart_db_server/dart_db_server.dart' as ddb;
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

/// Singleton "is sqlite3 available?" probe. We attempt to open an
/// in-memory database once; if it throws (typically because the native
/// shared library is missing) we remember that and mark every subsequent
/// oracle test as skipped.
class _SqliteAvailability {
  static bool? _available;
  static String? _reason;

  static bool check() {
    if (_available != null) return _available!;
    try {
      final db = sq.sqlite3.openInMemory();
      db.dispose();
      _available = true;
    } catch (e) {
      _available = false;
      _reason = 'sqlite3 native library not available: $e';
    }
    return _available!;
  }

  static String? get skipReason => _available == true ? null : _reason;
}

/// Returns a non-null skip reason if SQLite isn't available on this host.
/// Use as `skip: sqliteSkipReason()` on individual tests/groups.
String? sqliteSkipReason() {
  if (_SqliteAvailability.check()) return null;
  return _SqliteAvailability.skipReason ??
      'sqlite3 native library not available';
}

/// A pair of (dart-db, sqlite) databases that you can drive in lockstep.
class SqliteOracle {
  final ddb.Database ours;
  final sq.Database ref;

  SqliteOracle._(this.ours, this.ref);

  static Future<SqliteOracle> open() async {
    if (!_SqliteAvailability.check()) {
      throw StateError(_SqliteAvailability.skipReason!);
    }
    final ours = await ddb.Database.open();
    final ref = sq.sqlite3.openInMemory();
    return SqliteOracle._(ours, ref);
  }

  void close() {
    ref.dispose();
  }

  /// Execute a non-query (DDL or DML without a result set) on both engines.
  /// We only assert that neither, or both, throw. If only one throws the
  /// test fails with the diverging error.
  Future<void> exec(String sql) async {
    Object? oursErr;
    Object? refErr;
    try {
      await ours.execute(sql);
    } catch (e) {
      oursErr = e;
    }
    try {
      ref.execute(sql);
    } catch (e) {
      refErr = e;
    }
    if ((oursErr == null) != (refErr == null)) {
      fail('Divergence on `$sql`:\n  ours: $oursErr\n  ref:  $refErr');
    }
  }

  /// Run a SELECT on both engines and assert the (normalized) result rows
  /// are identical. Always include `ORDER BY` in [sql] for stable
  /// comparison; ordering is asserted positionally.
  Future<void> expectSameRows(String sql, {String? reason}) async {
    final r1 = await ours.execute(sql);
    final r2 = ref.select(sql);

    final ours1 = r1.rows.map(_normalizeRow).toList();
    final refs1 = r2.rows.map(_normalizeRow).toList();

    expect(ours1, equals(refs1), reason: reason ?? 'Row mismatch for: `$sql`');
  }

  /// Like [expectSameRows] but also asserts column names match (case
  /// insensitively, since SQLite preserves the source casing while we
  /// generally do too).
  Future<void> expectSameResult(String sql, {String? reason}) async {
    final r1 = await ours.execute(sql);
    final r2 = ref.select(sql);

    final oursCols = r1.columns.map((c) => c.toLowerCase()).toList();
    final refsCols = r2.columnNames.map((c) => c.toLowerCase()).toList();
    expect(oursCols, equals(refsCols),
        reason: reason ?? 'Column-name mismatch for: `$sql`');

    final ours1 = r1.rows.map(_normalizeRow).toList();
    final refs1 = r2.rows.map(_normalizeRow).toList();
    expect(ours1, equals(refs1), reason: reason ?? 'Row mismatch for: `$sql`');
  }
}

List<Object?> _normalizeRow(Iterable<Object?> r) =>
    r.map(_normalizeValue).toList();

/// Normalise scalar values to a common shape so dart-db and sqlite results
/// can be compared.
///
/// - bool -> 0/1 (SQLite has no boolean type; it stores 0/1 ints).
/// - integer-valued double -> int (1.0 -> 1).
/// - other doubles are rounded to 12 significant digits to absorb
///   floating-point noise across two independent evaluators.
/// - BLOB-ish: Uint8List <-> List<int> are unified to List<int>.
Object? _normalizeValue(Object? v) {
  if (v == null) return null;
  if (v is bool) return v ? 1 : 0;
  if (v is double) {
    if (v.isFinite && v == v.truncateToDouble()) return v.toInt();
    return double.parse(v.toStringAsPrecision(12));
  }
  if (v is List<int>) return List<int>.from(v);
  return v;
}
