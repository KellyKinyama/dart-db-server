// Tests for MySQL datetime types (DATE/DATETIME/TIMESTAMP/TIME/YEAR) and
// the MySQL-flavored datetime scalar functions (NOW, CURDATE, UNIX_TIMESTAMP,
// FROM_UNIXTIME, YEAR/MONTH/DAY, DATE_FORMAT, DATEDIFF, etc.).
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('MySQL datetime types', () {
    test('DATE/DATETIME/TIMESTAMP/TIME columns are accepted', () async {
      final db = await Database.open(null);
      await db.execute('''
        CREATE TABLE events (
          id INTEGER PRIMARY KEY,
          d DATE,
          dt DATETIME,
          ts TIMESTAMP,
          t TIME,
          y YEAR
        )
      ''');
      await db.execute(
          "INSERT INTO events VALUES (1, '2024-06-15', '2024-06-15 10:30:00', '2024-06-15 10:30:00', '10:30:00', 2024)");
      final r = await db.execute('SELECT d, dt, ts, t, y FROM events');
      expect(r.rows.single, [
        '2024-06-15',
        '2024-06-15 10:30:00',
        '2024-06-15 10:30:00',
        '10:30:00',
        2024,
      ]);
    });
  });

  group('MySQL datetime functions', () {
    late Database db;

    setUp(() async {
      db = await Database.open(null);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, ts TEXT)');
      await db
          .execute("INSERT INTO t VALUES (1, '2024-06-15 14:25:36')");
    });

    test('NOW / CURDATE / CURTIME return strings', () async {
      final r = await db.execute('SELECT NOW(), CURDATE(), CURTIME()');
      final row = r.rows.single;
      expect(row[0], isA<String>());
      expect(row[0], matches(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'));
      expect(row[1], matches(r'^\d{4}-\d{2}-\d{2}$'));
      expect(row[2], matches(r'^\d{2}:\d{2}:\d{2}$'));
    });

    test('YEAR / MONTH / DAY extract components', () async {
      final r = await db
          .execute('SELECT YEAR(ts), MONTH(ts), DAY(ts) FROM t WHERE id=1');
      expect(r.rows.single, [2024, 6, 15]);
    });

    test('HOUR / MINUTE / SECOND extract components', () async {
      final r = await db.execute(
          'SELECT HOUR(ts), MINUTE(ts), SECOND(ts) FROM t WHERE id=1');
      expect(r.rows.single, [14, 25, 36]);
    });

    test('DAYNAME and MONTHNAME', () async {
      final r =
          await db.execute('SELECT DAYNAME(ts), MONTHNAME(ts) FROM t WHERE id=1');
      expect(r.rows.single, ['Saturday', 'June']);
    });

    test('DAYOFWEEK / DAYOFYEAR / WEEKDAY', () async {
      final r = await db.execute(
          'SELECT DAYOFWEEK(ts), DAYOFYEAR(ts), WEEKDAY(ts) FROM t WHERE id=1');
      // 2024-06-15 = Saturday. MySQL DAYOFWEEK: 1=Sun..7=Sat -> 7.
      // DAYOFYEAR: 167 (leap year). WEEKDAY: 0=Mon..6=Sun -> 5 (Sat).
      expect(r.rows.single, [7, 167, 5]);
    });

    test('UNIX_TIMESTAMP and FROM_UNIXTIME roundtrip', () async {
      final r = await db.execute(
          "SELECT UNIX_TIMESTAMP('2024-06-15 14:25:36'), FROM_UNIXTIME(1718461536)");
      expect(r.rows.single[0], 1718461536);
      expect(r.rows.single[1], '2024-06-15 14:25:36');
    });

    test('LAST_DAY', () async {
      final r = await db.execute("SELECT LAST_DAY('2024-02-10')");
      expect(r.rows.single.single, '2024-02-29');
    });

    test('DATEDIFF returns integer days', () async {
      final r =
          await db.execute("SELECT DATEDIFF('2024-06-15', '2024-06-10')");
      expect(r.rows.single.single, 5);
    });

    test('DATE_FORMAT MySQL specifiers', () async {
      final r = await db.execute(
          "SELECT DATE_FORMAT('2024-06-15 14:25:36', '%Y-%m-%d %H:%i:%s')");
      expect(r.rows.single.single, '2024-06-15 14:25:36');
    });

    test('DATE_FORMAT with month/day names', () async {
      final r = await db.execute(
          "SELECT DATE_FORMAT('2024-06-15', '%W, %M %e, %Y')");
      expect(r.rows.single.single, 'Saturday, June 15, 2024');
    });

    test('DATE_FORMAT with 12-hour clock + AM/PM', () async {
      final r = await db.execute(
          "SELECT DATE_FORMAT('2024-06-15 14:25:36', '%h:%i %p')");
      expect(r.rows.single.single, '02:25 PM');
    });
  });
}
