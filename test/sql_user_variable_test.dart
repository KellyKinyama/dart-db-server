/// Tests Phase 3d MySQL session user-variables (`SET @x`, `SELECT @x`) and
/// stored-procedure OUT/INOUT parameter writeback (`CALL p(@out)`).
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late Map<String, Object?> uv;
  setUp(() async {
    db = await Database.open(null);
    uv = <String, Object?>{};
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO t VALUES (1), (2), (3)');
  });

  Future<Object?> scalar(String sql) async =>
      (await db.execute(sql, userVars: uv)).rows.first.first;

  test('SET and read back a user variable', () async {
    await db.execute('SET @x = 10', userVars: uv);
    expect(await scalar('SELECT @x'), 10);
  });

  test('multiple assignments, with cross-reference', () async {
    await db.execute('SET @a = 3, @b = @a + 4', userVars: uv);
    final r = await db.execute('SELECT @a, @b', userVars: uv);
    expect(r.rows.first.toList(), [3, 7]);
  });

  test('SET with := operator', () async {
    await db.execute('SET @x := 42', userVars: uv);
    expect(await scalar('SELECT @x'), 42);
  });

  test('unset variable reads as NULL', () async {
    expect(await scalar('SELECT @missing'), isNull);
  });

  test('user variable usable in WHERE', () async {
    await db.execute('SET @threshold = 1', userVars: uv);
    final r = await db.execute(
      'SELECT id FROM t WHERE id > @threshold ORDER BY id',
      userVars: uv,
    );
    expect(r.rows.map((x) => x.first).toList(), [2, 3]);
  });

  test('OUT parameter writeback', () async {
    await db.execute('''
      CREATE PROCEDURE get_count(OUT c INT)
      BEGIN
        SELECT COUNT(*) INTO c FROM t;
      END
    ''');
    await db.execute('CALL get_count(@n)', userVars: uv);
    expect(await scalar('SELECT @n'), 3);
  });

  test('INOUT parameter reads current value and writes back', () async {
    await db.execute('''
      CREATE PROCEDURE bump(INOUT v INT)
      BEGIN
        SET v = v + 100;
      END
    ''');
    await db.execute('SET @m = 5', userVars: uv);
    await db.execute('CALL bump(@m)', userVars: uv);
    expect(await scalar('SELECT @m'), 105);
  });

  test('multiple OUT parameters', () async {
    await db.execute('''
      CREATE PROCEDURE minmax(OUT lo INT, OUT hi INT)
      BEGIN
        SELECT MIN(id) INTO lo FROM t;
        SELECT MAX(id) INTO hi FROM t;
      END
    ''');
    await db.execute('CALL minmax(@lo, @hi)', userVars: uv);
    final r = await db.execute('SELECT @lo, @hi', userVars: uv);
    expect(r.rows.first.toList(), [1, 3]);
  });

  test('per-connection isolation', () async {
    await db.execute('SET @x = 99', userVars: uv);
    final uv2 = <String, Object?>{};
    expect((await db.execute('SELECT @x', userVars: uv2)).rows.first.first,
        isNull);
    expect((await db.execute('SELECT @x', userVars: uv)).rows.first.first, 99);
  });

  test('generic SET (SESSION/NAMES) is still a no-op', () async {
    await db.execute("SET NAMES utf8mb4", userVars: uv);
    await db.execute('SET SESSION sql_mode = \'\'', userVars: uv);
    await db.execute('SET autocommit = 1', userVars: uv);
  });
}
