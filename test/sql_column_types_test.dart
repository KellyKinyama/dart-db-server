/// Tests that [QueryResult.columnTypes] exposes the declared DDL type per
/// result column for simple single-table SELECTs, and is null elsewhere.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE t ('
        'id INTEGER PRIMARY KEY, '
        'txt CLOB, '
        'data BLOB, '
        'doc JSON, '
        'name VARCHAR, '
        'n NUMBER)');
  });

  test('a direct column projection exposes declared types', () async {
    final r = await db.execute('SELECT id, txt, data, doc, name, n FROM t');
    expect(r.columnTypes, ['INTEGER', 'CLOB', 'BLOB', 'JSON', 'VARCHAR', 'NUMBER']);
  });

  test('SELECT * exposes every column type in order', () async {
    final r = await db.execute('SELECT * FROM t');
    expect(r.columnTypes, ['INTEGER', 'CLOB', 'BLOB', 'JSON', 'VARCHAR', 'NUMBER']);
  });

  test('an aliased column keeps its source type', () async {
    final r = await db.execute('SELECT txt AS body FROM t');
    expect(r.columnTypes, ['CLOB']);
  });

  test('an expression column is null, direct columns keep their type',
      () async {
    final r = await db.execute('SELECT id + 1 AS x, txt FROM t');
    expect(r.columnTypes, [null, 'CLOB']);
  });

  test('a joined SELECT leaves columnTypes null', () async {
    await db.execute('CREATE TABLE u (id INTEGER PRIMARY KEY, label CLOB)');
    final r = await db.execute(
        'SELECT t.txt, u.label FROM t JOIN u ON t.id = u.id');
    expect(r.columnTypes, isNull);
  });

  test('case-insensitive column names resolve', () async {
    final r = await db.execute('SELECT TXT, Data FROM t');
    expect(r.columnTypes, ['CLOB', 'BLOB']);
  });
}
