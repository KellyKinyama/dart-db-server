/// Phase-0 unification scaffold regression: both in-memory and paged
/// tables expose themselves through the shared [TableBackend] interface
/// via [Database.lookupBackend] and [Database.backends].
///
/// This test exists to lock in the API shape so the per-site executor
/// migration in subsequent phases can rely on it without surprises.
library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpRoot;

  setUp(() async {
    tmpRoot = await Directory.systemTemp.createTemp('ddb_table_backend_');
  });

  tearDown(() async {
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  String dbPath() => '${tmpRoot.path}${Platform.pathSeparator}store.json';

  test('in-memory table exposes TableBackend via lookupBackend', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');

      final tb = db.lookupBackend('t');
      expect(tb, isNotNull);
      expect(tb!.kind, TableBackendKind.memory);
      expect(tb.tableName, 't');
      expect(tb.columnNames, ['id', 'name']);

      expect(db.lookupBackend('does_not_exist'), isNull);
    } finally {
      await db.close();
    }
  });

  test('paged table exposes TableBackend via lookupBackend', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE p ('
          'id INTEGER PRIMARY KEY, label TEXT) USING paged');

      final tb = db.lookupBackend('p');
      expect(tb, isNotNull);
      expect(tb!.kind, TableBackendKind.paged);
      expect(tb.tableName, 'p');
      expect(tb.columnNames, ['id', 'label']);
    } finally {
      await db.close();
    }
  });

  test('paged table tableName survives close/reopen', () async {
    final path = dbPath();
    {
      final db = await Database.open(path);
      try {
        await db.execute('CREATE TABLE p ('
            'id INTEGER PRIMARY KEY, label TEXT) USING paged');
        await db.execute("INSERT INTO p VALUES (1, 'alpha')");
      } finally {
        await db.close();
      }
    }
    final db2 = await Database.open(path);
    try {
      final tb = db2.lookupBackend('p');
      expect(tb, isNotNull);
      expect(tb!.kind, TableBackendKind.paged);
      expect(tb.tableName, 'p');
      expect(tb.columnNames, ['id', 'label']);
    } finally {
      await db2.close();
    }
  });

  test('backends iterable yields both kinds with correct metadata', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE m (id INTEGER PRIMARY KEY, x TEXT)');
      await db.execute('CREATE TABLE p ('
          'id INTEGER PRIMARY KEY, y TEXT) USING paged');

      final byName = <String, TableBackend>{
        for (final b in db.backends) b.tableName: b,
      };
      expect(byName.keys.toSet(), {'m', 'p'});
      expect(byName['m']!.kind, TableBackendKind.memory);
      expect(byName['p']!.kind, TableBackendKind.paged);
      expect(byName['m']!.columnNames, ['id', 'x']);
      expect(byName['p']!.columnNames, ['id', 'y']);
    } finally {
      await db.close();
    }
  });

  test('DROP TABLE removes the backend from lookupBackend', () async {
    final db = await Database.open(dbPath());
    try {
      await db.execute('CREATE TABLE p ('
          'id INTEGER PRIMARY KEY, label TEXT) USING paged');
      expect(db.lookupBackend('p'), isNotNull);
      await db.execute('DROP TABLE p');
      expect(db.lookupBackend('p'), isNull);

      await db.execute('CREATE TABLE m (id INTEGER PRIMARY KEY)');
      expect(db.lookupBackend('m'), isNotNull);
      await db.execute('DROP TABLE m');
      expect(db.lookupBackend('m'), isNull);
    } finally {
      await db.close();
    }
  });
}
