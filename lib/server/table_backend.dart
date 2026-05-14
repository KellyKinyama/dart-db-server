/// Phase 0 unification scaffold.
///
/// `TableBackend` is the minimal shared surface between the in-memory
/// [Table] and the out-of-core [PagedTable]. Today the SQL executor in
/// [Database] still branches on the concrete backend type, but every
/// new caller should prefer this interface so the per-site migration
/// to a uniform dispatch path can be done incrementally.
///
/// The interface is intentionally tiny — it exposes only the metadata
/// needed for "does table X exist?" / "what columns does it have?" /
/// "which backend is it?" queries. The real divergence in row I/O
/// (sync iteration vs async streams) stays on the concrete classes
/// until the executor is ready to be unified.
library;

/// Which storage engine backs a [TableBackend].
enum TableBackendKind {
  /// JSON-persisted in-RAM table (the default backend).
  memory,

  /// Out-of-core paged table stored in `<dbpath>.paged/<name>.{heap,idx,…}`.
  paged,
}

/// Common metadata surface for in-memory and paged tables.
///
/// Implementations: [Table] (memory) and [PagedTable] (paged).
abstract class TableBackend {
  /// User-visible table name as known to the SQL layer.
  String get tableName;

  /// Column names in declaration order.
  List<String> get columnNames;

  /// Which storage engine backs this table.
  TableBackendKind get kind;
}
