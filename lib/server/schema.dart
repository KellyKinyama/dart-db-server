/// Schema primitives: data types, columns, constraints, table schema.
library;

import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

/// Sentinel key used to encode BLOB values when serialising rows to JSON
/// (both for on-disk persistence and the wire protocol). A BLOB is written
/// as `{"$blob": "<lowercase hex>"}` so it round-trips losslessly and is
/// distinguishable from a regular `List<int>`.
const String kBlobJsonTag = r'$blob';

/// Encode any Dart value coming out of the engine into a form `jsonEncode`
/// will accept and that [jsonValueToStorage] can losslessly reverse.
///
/// In particular, BLOBs (`List<int>` / `Uint8List`) are wrapped as
/// `{"$blob":"<hex>"}` so we don't confuse them with regular integer
/// arrays on reload.
Object? storageToJsonValue(Object? v) {
  if (v == null) return null;
  if (v is bool || v is num || v is String) return v;
  if (v is Uint8List) return {kBlobJsonTag: _bytesToHex(v)};
  if (v is List<int>) return {kBlobJsonTag: _bytesToHex(v)};
  if (v is List) return v.map(storageToJsonValue).toList();
  if (v is Map) {
    return v.map((k, val) => MapEntry(k.toString(), storageToJsonValue(val)));
  }
  return v.toString();
}

/// Reverse of [storageToJsonValue]: decode a value coming out of
/// `jsonDecode` back to its in-memory storage form. Tagged BLOB sentinels
/// become `Uint8List`.
Object? jsonValueToStorage(Object? v) {
  if (v == null) return null;
  if (v is bool || v is num || v is String) return v;
  if (v is List) return v.map(jsonValueToStorage).toList();
  if (v is Map) {
    final m = v.cast<String, Object?>();
    if (m.length == 1 && m.containsKey(kBlobJsonTag)) {
      final hex = m[kBlobJsonTag];
      if (hex is String) return _hexToBytes(hex);
    }
    return m.map((k, val) => MapEntry(k, jsonValueToStorage(val)));
  }
  return v;
}

String _bytesToHex(List<int> b) {
  const digits = '0123456789abcdef';
  final buf = StringBuffer();
  for (final byte in b) {
    final v = byte & 0xff;
    buf.writeCharCode(digits.codeUnitAt(v >> 4));
    buf.writeCharCode(digits.codeUnitAt(v & 0xf));
  }
  return buf.toString();
}

Uint8List _hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('BLOB hex must have even length: $hex');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Supported SQL data types.
///
/// `numeric` — SQLite NUMERIC affinity: INTEGER if it fits, REAL if it
/// looks like a float, otherwise TEXT (string round-tripped unchanged).
/// `any` — SQLite ANY affinity (STRICT-table escape hatch): values are
/// stored exactly as supplied with no coercion.
///
/// NULL is represented by Dart `null` regardless of column type (subject
/// to NOT NULL constraints).
enum DataType { integer, real, text, boolean, blob, numeric, any }

/// Set of declared type names (lower case) accepted by `STRICT` tables.
/// Matches SQLite: INT, INTEGER, REAL, TEXT, BLOB, ANY.
const Set<String> kStrictAllowedTypeNames = {
  'int',
  'integer',
  'real',
  'text',
  'blob',
  'any',
};

/// Parse a raw type token using SQLite's affinity rules. Unknown / empty
/// declarations don't throw — they get NUMERIC affinity (or BLOB when
/// completely empty), matching what real-world DDL relies on.
DataType parseDataType(String s) {
  final low = s.toLowerCase();
  if (low.isEmpty) return DataType.blob;
  // MySQL datetime types are stored as ISO-8601 TEXT (YEAR as INTEGER).
  // Listed before the "contains int" rule so DATETIME / TIMESTAMP do
  // not accidentally hit INTEGER via the substring 'int' in 'int'erval-
  // free names. (They don't contain 'int' today, but be defensive.)
  if (low == 'date' ||
      low == 'datetime' ||
      low == 'timestamp' ||
      low == 'time') {
    return DataType.text;
  }
  if (low == 'year') return DataType.integer;
  // 1. Contains "INT" -> INTEGER (catches INT, INTEGER, BIGINT, SMALLINT…)
  if (low.contains('int')) return DataType.integer;
  // 2. Contains TEXT/CHAR/CLOB -> TEXT.
  if (low.contains('char') ||
      low.contains('clob') ||
      low.contains('text') ||
      low == 'string' ||
      low == 'varchar') {
    return DataType.text;
  }
  // 3. Contains BLOB -> BLOB.
  if (low.contains('blob')) return DataType.blob;
  // 4. Contains REAL/FLOA/DOUB -> REAL.
  if (low.contains('real') || low.contains('floa') || low.contains('doub')) {
    return DataType.real;
  }
  // 5. BOOLEAN keeps a strict boolean affinity (ours, not SQLite's).
  if (low == 'bool' || low == 'boolean') return DataType.boolean;
  // 6. ANY (STRICT escape hatch).
  if (low == 'any') return DataType.any;
  // 7. Default per SQLite affinity rule 5 — NUMERIC.
  return DataType.numeric;
}

String dataTypeName(DataType t) {
  switch (t) {
    case DataType.integer:
      return 'INTEGER';
    case DataType.real:
      return 'REAL';
    case DataType.text:
      return 'TEXT';
    case DataType.boolean:
      return 'BOOLEAN';
    case DataType.blob:
      return 'BLOB';
    case DataType.numeric:
      return 'NUMERIC';
    case DataType.any:
      return 'ANY';
  }
}

/// A single column definition.
class ColumnDef {
  final String name;
  final DataType type;
  final bool primaryKey;
  final bool notNull;
  final bool unique;
  final bool autoIncrement;
  final Object? defaultValue;

  /// `DEFAULT (<expr>)` source text (column-level). Mutually optional
  /// with [defaultValue]; when both are present [defaultValue] wins as
  /// the cheap fast-path for plain literals.
  final String? defaultExprSql;

  /// CHECK expression source text (column-level). The DB engine re-parses
  /// this on demand. Stored as text so it survives JSON serialization.
  final String? checkExprSql;

  /// FOREIGN KEY target ("table" or "table(column)") for column-level FK.
  final ForeignKeyRef? references;

  /// `GENERATED ALWAYS AS (<expr>) [VIRTUAL|STORED]` source. When set, the
  /// column's value is computed from this expression at INSERT/UPDATE time.
  final String? generatedExprSql;
  final bool generatedStored;

  /// V30: `VECTOR(dim=384, kind=hnsw, metric=cosine, ...)` inline spec.
  /// Consumed by CREATE TABLE to auto-register a vector index on this
  /// column. Map keys are lowercased attribute names.
  final Map<String, String>? vectorSpec;

  const ColumnDef(
    this.name,
    this.type, {
    this.primaryKey = false,
    this.notNull = false,
    this.unique = false,
    this.autoIncrement = false,
    this.defaultValue,
    this.defaultExprSql,
    this.checkExprSql,
    this.references,
    this.generatedExprSql,
    this.generatedStored = false,
    this.vectorSpec,
  });

  Map<String, Object?> toJson() => {
        'name': name,
        'type': type.name,
        if (primaryKey) 'primaryKey': true,
        if (notNull) 'notNull': true,
        if (unique) 'unique': true,
        if (autoIncrement) 'autoIncrement': true,
        if (defaultValue != null) 'default': defaultValue,
        if (defaultExprSql != null) 'defaultExpr': defaultExprSql,
        if (checkExprSql != null) 'check': checkExprSql,
        if (references != null) 'references': references!.toJson(),
        if (generatedExprSql != null) 'generated': generatedExprSql,
        if (generatedStored) 'generatedStored': true,
        if (vectorSpec != null) 'vectorSpec': vectorSpec,
      };

  factory ColumnDef.fromJson(Map<String, Object?> j) => ColumnDef(
        j['name'] as String,
        DataType.values.byName(j['type'] as String),
        primaryKey: j['primaryKey'] == true,
        notNull: j['notNull'] == true,
        unique: j['unique'] == true,
        autoIncrement: j['autoIncrement'] == true,
        defaultValue: j['default'],
        defaultExprSql: j['defaultExpr'] as String?,
        checkExprSql: j['check'] as String?,
        references: j['references'] == null
            ? null
            : ForeignKeyRef.fromJson(
                (j['references'] as Map).cast<String, Object?>(),
              ),
        generatedExprSql: j['generated'] as String?,
        generatedStored: j['generatedStored'] == true,
        vectorSpec: (j['vectorSpec'] as Map?)?.cast<String, String>(),
      );
}

/// Foreign key reference target.
class ForeignKeyRef {
  final String table;
  final String? column; // null => use referenced table's primary key
  final String onDelete; // 'NO ACTION', 'CASCADE', 'SET NULL', 'RESTRICT'
  final String onUpdate;
  const ForeignKeyRef(
    this.table, {
    this.column,
    this.onDelete = 'NO ACTION',
    this.onUpdate = 'NO ACTION',
  });

  Map<String, Object?> toJson() => {
        'table': table,
        if (column != null) 'column': column,
        if (onDelete != 'NO ACTION') 'onDelete': onDelete,
        if (onUpdate != 'NO ACTION') 'onUpdate': onUpdate,
      };

  factory ForeignKeyRef.fromJson(Map<String, Object?> j) => ForeignKeyRef(
        j['table'] as String,
        column: j['column'] as String?,
        onDelete: (j['onDelete'] as String?) ?? 'NO ACTION',
        onUpdate: (j['onUpdate'] as String?) ?? 'NO ACTION',
      );
}

/// Table-level constraint (composite PK, multi-column UNIQUE, table CHECK,
/// table-level FOREIGN KEY).
abstract class TableConstraint {
  Map<String, Object?> toJson();
  static TableConstraint fromJson(Map<String, Object?> j) {
    switch (j['kind']) {
      case 'pk':
        return PrimaryKeyConstraint(
          (j['columns'] as List).cast<String>().toList(),
        );
      case 'unique':
        return UniqueConstraint((j['columns'] as List).cast<String>().toList());
      case 'check':
        return CheckConstraint(j['sql'] as String);
      case 'fk':
        return ForeignKeyConstraint(
          (j['columns'] as List).cast<String>().toList(),
          ForeignKeyRef.fromJson(
            (j['references'] as Map).cast<String, Object?>(),
          ),
        );
    }
    throw FormatException('Unknown table constraint: ${j['kind']}');
  }
}

class PrimaryKeyConstraint extends TableConstraint {
  final List<String> columns;
  PrimaryKeyConstraint(this.columns);
  @override
  Map<String, Object?> toJson() => {'kind': 'pk', 'columns': columns};
}

class UniqueConstraint extends TableConstraint {
  final List<String> columns;
  UniqueConstraint(this.columns);
  @override
  Map<String, Object?> toJson() => {'kind': 'unique', 'columns': columns};
}

class CheckConstraint extends TableConstraint {
  final String sql;
  CheckConstraint(this.sql);
  @override
  Map<String, Object?> toJson() => {'kind': 'check', 'sql': sql};
}

class ForeignKeyConstraint extends TableConstraint {
  final List<String> columns;
  final ForeignKeyRef references;
  ForeignKeyConstraint(this.columns, this.references);
  @override
  Map<String, Object?> toJson() => {
        'kind': 'fk',
        'columns': columns,
        'references': references.toJson(),
      };
}

/// Coerce a raw value (from parser literal or client JSON) into the storage
/// representation for [type], or throw [FormatException] if it cannot.
Object? coerce(Object? value, DataType type) {
  if (value == null) return null;
  switch (type) {
    case DataType.integer:
      if (value is int) return value;
      if (value is double && value == value.truncateToDouble()) {
        return value.toInt();
      }
      if (value is bool) return value ? 1 : 0;
      if (value is String) {
        final v = int.tryParse(value);
        if (v != null) return v;
      }
      throw FormatException('Cannot coerce $value to INTEGER');
    case DataType.real:
      if (value is num) return value.toDouble();
      if (value is String) {
        final v = double.tryParse(value);
        if (v != null) return v;
      }
      throw FormatException('Cannot coerce $value to REAL');
    case DataType.text:
      return value.toString();
    case DataType.boolean:
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final s = value.toLowerCase();
        if (s == 'true' || s == '1') return true;
        if (s == 'false' || s == '0') return false;
      }
      throw FormatException('Cannot coerce $value to BOOLEAN');
    case DataType.blob:
      if (value is Uint8List) return value;
      if (value is List<int>) return Uint8List.fromList(value);
      if (value is String) return Uint8List.fromList(utf8.encode(value));
      throw FormatException('Cannot coerce $value to BLOB');
    case DataType.numeric:
      // SQLite NUMERIC affinity: prefer INTEGER, then REAL, otherwise the
      // value is left in whatever form it arrived in (TEXT or BLOB).
      if (value is int) return value;
      if (value is double) {
        if (value.isFinite && value == value.truncateToDouble()) {
          return value.toInt();
        }
        return value;
      }
      if (value is bool) return value ? 1 : 0;
      if (value is String) {
        final s = value.trim();
        final i = int.tryParse(s);
        if (i != null) return i;
        final d = double.tryParse(s);
        if (d != null) {
          if (d.isFinite && d == d.truncateToDouble()) return d.toInt();
          return d;
        }
        return value; // keep as TEXT — SQLite NUMERIC keeps non-numeric text
      }
      return value;
    case DataType.any:
      // STRICT ANY columns store the value verbatim.
      return value;
  }
}
