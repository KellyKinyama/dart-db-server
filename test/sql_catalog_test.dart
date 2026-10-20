/// Tests the catalog / data-dictionary views: MySQL INFORMATION_SCHEMA.* and
/// Oracle USER_*/ALL_* (plus the TABS/COLS synonyms).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE users ('
        'id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, bio CLOB)');
    await db.execute('CREATE TABLE orders (id INTEGER PRIMARY KEY, total NUMBER)');
    await db.execute('CREATE VIEW active AS SELECT id FROM users');
    await db.execute('CREATE SEQUENCE user_seq START WITH 100 INCREMENT BY 5');
  });

  Future<List<List<Object?>>> rows(String sql) async =>
      (await db.execute(sql)).rows.map((r) => r.toList()).toList();

  group('MySQL INFORMATION_SCHEMA', () {
    test('TABLES lists base tables and views', () async {
      expect(
        await rows('SELECT table_name, table_type FROM '
            'information_schema.tables ORDER BY table_name'),
        [
          ['active', 'VIEW'],
          ['orders', 'BASE TABLE'],
          ['users', 'BASE TABLE'],
        ],
      );
    });

    test('COLUMNS exposes names, nullability and key', () async {
      expect(
        await rows('SELECT column_name, is_nullable, column_key FROM '
            "information_schema.columns WHERE table_name = 'users' "
            'ORDER BY ordinal_position'),
        [
          ['id', 'NO', 'PRI'],
          ['name', 'NO', ''],
          ['bio', 'YES', ''],
        ],
      );
    });

    test('SCHEMATA reports the current schema (= DATABASE())', () async {
      expect(await rows('SELECT schema_name FROM information_schema.schemata'),
          [['main']]);
    });

    test('VIEWS exposes the view definition', () async {
      expect(
        await rows('SELECT table_name, view_definition FROM '
            'information_schema.views'),
        [
          ['active', 'SELECT id FROM users'],
        ],
      );
    });

    test('table_schema aligns with DATABASE() for the common filter', () async {
      final r = await rows('SELECT table_name FROM information_schema.tables '
          'WHERE table_schema = DATABASE() AND table_type = \'BASE TABLE\' '
          'ORDER BY table_name');
      expect(r, [
        ['orders'],
        ['users'],
      ]);
    });

    test('SELECT * expands the synthesized columns', () async {
      final r = await db.execute(
          "SELECT * FROM information_schema.tables WHERE table_name = 'orders'");
      expect(r.columns, contains('TABLE_NAME'));
      expect(r.rows.length, 1);
    });
  });

  group('Oracle data dictionary', () {
    test('USER_TABLES lists tables', () async {
      expect(
        await rows('SELECT table_name FROM user_tables ORDER BY table_name'),
        [
          ['orders'],
          ['users'],
        ],
      );
    });

    test('USER_TAB_COLUMNS reports Oracle-style types and nullability',
        () async {
      expect(
        await rows('SELECT column_name, data_type, nullable, column_id FROM '
            "user_tab_columns WHERE table_name = 'users' ORDER BY column_id"),
        [
          ['id', 'INTEGER', 'N', 1],
          ['name', 'VARCHAR', 'N', 2],
          ['bio', 'CLOB', 'Y', 3],
        ],
      );
    });

    test('COLS and TABS synonyms work', () async {
      expect((await rows("SELECT column_name FROM cols WHERE table_name = "
              "'orders' ORDER BY column_id"))
          .map((r) => r.first)
          .toList(), ['id', 'total']);
      expect(
        (await rows('SELECT table_name FROM tabs ORDER BY table_name'))
            .map((r) => r.first)
            .toList(),
        ['orders', 'users'],
      );
    });

    test('USER_VIEWS exposes view text', () async {
      expect(await rows('SELECT view_name, text FROM user_views'), [
        ['active', 'SELECT id FROM users'],
      ]);
    });

    test('USER_SEQUENCES reports sequence metadata', () async {
      expect(
        await rows('SELECT sequence_name, increment_by, last_number FROM '
            'user_sequences'),
        [
          ['user_seq', 5, 100],
        ],
      );
    });
  });

  test('a real table shadows a catalog view of the same name', () async {
    await db.execute('CREATE TABLE user_tables (x INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO user_tables VALUES (42)');
    expect(await rows('SELECT x FROM user_tables'), [
      [42],
    ]);
  });
}
