/// Tests MySQL stored procedures (Phase 3b): CREATE PROCEDURE / CALL /
/// DROP PROCEDURE over the shared procedural core.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open(null);
    await db.execute('CREATE TABLE users ('
        'id INTEGER PRIMARY KEY, name TEXT, tier TEXT)');
  });

  test('procedure with IN params, control flow and embedded DML', () async {
    await db.execute('''
      CREATE PROCEDURE add_users(IN start_id INT, IN cnt INT)
      BEGIN
        DECLARE i INT DEFAULT 0;
        DECLARE t TEXT;
        WHILE i < cnt DO
          IF i = 0 THEN
            SET t = 'gold';
          ELSEIF i = 1 THEN
            SET t = 'silver';
          ELSE
            SET t = 'bronze';
          END IF;
          INSERT INTO users VALUES (start_id + i, 'u' || (start_id + i), t);
          SET i = i + 1;
        END WHILE;
      END
    ''');
    await db.execute('CALL add_users(10, 3)');
    final r = await db.execute('SELECT id, name, tier FROM users ORDER BY id');
    expect(r.rows.map((x) => x.toList()).toList(), [
      [10, 'u10', 'gold'],
      [11, 'u11', 'silver'],
      [12, 'u12', 'bronze'],
    ]);
  });

  test('a procedure can return a result set', () async {
    await db.execute("INSERT INTO users VALUES (1, 'a', 'gold')");
    await db.execute("INSERT INTO users VALUES (2, 'b', 'silver')");
    await db.execute('''
      CREATE PROCEDURE golds()
      BEGIN
        SELECT id, name FROM users WHERE tier = 'gold' ORDER BY id;
      END
    ''');
    final r = await db.execute('CALL golds()');
    expect(r.rows.map((x) => x.toList()).toList(), [
      [1, 'a'],
    ]);
  });

  test('SELECT INTO and a computed argument', () async {
    await db.execute("INSERT INTO users VALUES (1, 'a', 'gold')");
    await db.execute("INSERT INTO users VALUES (2, 'b', 'gold')");
    await db.execute("INSERT INTO users VALUES (3, 'c', 'silver')");
    await db.execute('''
      CREATE PROCEDURE count_tier(IN want TEXT)
      BEGIN
        DECLARE c INT;
        SELECT COUNT(*) INTO c FROM users WHERE tier = want;
        SELECT c AS n;
      END
    ''');
    expect((await db.execute("CALL count_tier('gold')")).rows.first.first, 2);
  });

  test('REPEAT ... UNTIL loop', () async {
    await db.execute('CREATE TABLE nums (n INTEGER PRIMARY KEY)');
    await db.execute('''
      CREATE PROCEDURE fill()
      BEGIN
        DECLARE k INT DEFAULT 1;
        REPEAT
          INSERT INTO nums VALUES (k);
          SET k = k + 1;
        UNTIL k > 3 END REPEAT;
      END
    ''');
    await db.execute('CALL fill()');
    final r = await db.execute('SELECT n FROM nums ORDER BY n');
    expect(r.rows.map((x) => x.first).toList(), [1, 2, 3]);
  });

  test('LOOP with LEAVE', () async {
    await db.execute('CREATE TABLE nums (n INTEGER PRIMARY KEY)');
    await db.execute('''
      CREATE PROCEDURE fill2()
      BEGIN
        DECLARE k INT DEFAULT 1;
        my_loop: LOOP
          IF k > 3 THEN
            LEAVE my_loop;
          END IF;
          INSERT INTO nums VALUES (k);
          SET k = k + 1;
        END LOOP;
      END
    ''');
    await db.execute('CALL fill2()');
    final r = await db.execute('SELECT n FROM nums ORDER BY n');
    expect(r.rows.map((x) => x.first).toList(), [1, 2, 3]);
  });

  test('duplicate CREATE errors; DROP removes', () async {
    await db.execute('CREATE PROCEDURE p() BEGIN SELECT 1; END');
    expect(() => db.execute('CREATE PROCEDURE p() BEGIN SELECT 1; END'),
        throwsA(isA<StateError>()));
    await db.execute('DROP PROCEDURE p');
    expect(() => db.execute('CALL p()'), throwsA(isA<StateError>()));
    final r = await db.execute('DROP PROCEDURE IF EXISTS p');
    expect(r.message, contains('did not exist'));
  });

  test('a local variable shadows a same-named column in embedded SQL', () async {
    // `name` is both a column and a procedure variable; the bare reference in
    // the INSERT must resolve to the variable.
    await db.execute('''
      CREATE PROCEDURE ins(IN id INT, IN name TEXT)
      BEGIN
        INSERT INTO users(id, name, tier) VALUES (id, name, 'x');
      END
    ''');
    await db.execute("CALL ins(5, 'zoe')");
    final r = await db.execute('SELECT name FROM users WHERE id = 5');
    expect(r.rows.first.first, 'zoe');
  });

  test('DELIMITER is accepted as a no-op', () async {
    final r = await db.execute('DELIMITER //');
    expect(r, isNotNull);
  });
}
