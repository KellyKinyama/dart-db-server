// Tests for MySQL SQL-dialect surface added to the parser:
//   - backtick-quoted identifiers
//   - MySQL `LIMIT offset, count` form in SELECT / VALUES
//   - trailing MySQL CREATE TABLE options (ENGINE, CHARSET, COLLATE,
//     AUTO_INCREMENT, ROW_FORMAT, COMMENT, ...)
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('MySQL dialect', () {
    late Database db;

    setUp(() async {
      db = await Database.open(null);
    });

    test('backtick-quoted identifiers in DDL and DML', () async {
      await db.execute(
        'CREATE TABLE `users` (`id` INTEGER PRIMARY KEY, `full name` TEXT)',
      );
      await db.execute("INSERT INTO `users` VALUES (1, 'Alice')");
      final r = await db.execute('SELECT `id`, `full name` FROM `users`');
      expect(r.columns, ['id', 'full name']);
      expect(r.rows, [
        [1, 'Alice'],
      ]);
    });

    test('MySQL CREATE TABLE trailing options are accepted', () async {
      await db.execute('''
        CREATE TABLE t (
          id INT AUTO_INCREMENT PRIMARY KEY,
          name VARCHAR(64) NOT NULL,
          tag  VARCHAR(32) DEFAULT 'x'
        ) ENGINE=InnoDB AUTO_INCREMENT=100
          DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
          ROW_FORMAT=DYNAMIC COMMENT='hello'
      ''');
      await db.execute("INSERT INTO t (name) VALUES ('Alice'), ('Bob')");
      final r = await db.execute('SELECT id, name FROM t ORDER BY id');
      expect(r.rows.length, 2);
      expect(r.columns, ['id', 'name']);
      expect(r.rows[0][1], 'Alice');
    });

    test('LIMIT offset, count (MySQL form) on SELECT', () async {
      await db.execute('CREATE TABLE n (x INTEGER)');
      for (var i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO n VALUES ($i)');
      }
      final r = await db.execute('SELECT x FROM n ORDER BY x LIMIT 1, 2');
      expect(r.rows, [
        [2],
        [3],
      ]);
    });

    test('LIMIT offset, count on VALUES', () async {
      final r = await db.execute(
        'VALUES (1),(2),(3),(4) ORDER BY 1 LIMIT 1, 2',
      );
      expect(r.rows.length, 2);
      expect(r.rows[0][0], 2);
      expect(r.rows[1][0], 3);
    });
  });
}
