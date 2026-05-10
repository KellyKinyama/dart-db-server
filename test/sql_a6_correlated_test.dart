import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
    await db.execute('CREATE TABLE dept(id INTEGER, name TEXT)');
    await db
        .execute('CREATE TABLE emp(id INTEGER, dept_id INTEGER, sal INTEGER)');
    await db.execute("INSERT INTO dept VALUES (1,'eng'),(2,'sales')");
    await db.execute(
        'INSERT INTO emp VALUES (1,1,100),(2,1,200),(3,1,300),(4,2,150),(5,2,250)');
  });

  group('A6 correlated subqueries', () {
    test('scalar subquery references outer column', () async {
      final r = await db.execute(
          'SELECT name, (SELECT MAX(sal) FROM emp WHERE emp.dept_id = dept.id) AS m FROM dept ORDER BY id');
      expect(r.rows, [
        ['eng', 300],
        ['sales', 250]
      ]);
    });

    test('EXISTS correlated subquery', () async {
      final r = await db.execute('SELECT name FROM dept WHERE EXISTS '
          '(SELECT 1 FROM emp WHERE emp.dept_id = dept.id AND emp.sal > 250) ORDER BY id');
      expect(r.rows, [
        ['eng']
      ]);
    });

    test('IN correlated subquery', () async {
      final r = await db.execute('SELECT name FROM dept WHERE id IN '
          '(SELECT dept_id FROM emp WHERE sal >= 250) ORDER BY id');
      expect(r.rows, [
        ['eng'],
        ['sales']
      ]);
    });

    test('NOT EXISTS correlated', () async {
      // No empty departments here; result should be empty.
      final r = await db.execute('SELECT name FROM dept WHERE NOT EXISTS '
          '(SELECT 1 FROM emp WHERE emp.dept_id = dept.id)');
      expect(r.rows, isEmpty);
    });
  });
}
