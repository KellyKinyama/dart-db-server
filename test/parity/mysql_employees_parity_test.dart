library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

import 'parity_support.dart';

/// Loads the real MySQL **employees** (`test_db`) schema through the shared
/// engine and exercises it with analytic queries where the load succeeds.
/// Report-oriented; skips when the git-ignored dataset is absent.
void main() {
  final schema = datasetFile([
    'mysql-employees/test_db-master/employees.sql',
  ]);

  group('MySQL employees parity', () {
    test(
      'schema load coverage + queries',
      () async {
        final db = await Database.open();
        final report = await loadScript(db, schema!.readAsStringSync());
        final tables = await tableNames(db);
        print(report.summary('employees schema'));
        print('  tables created: ${tables.length}'
            '${tables.isEmpty ? '' : ' → ${(tables.toList()..sort()).join(', ')}'}');

        expect(report.total, greaterThan(0));

        // Seed a little data by hand into whichever base tables loaded, then
        // run a join + aggregate to prove the loaded schema is queryable.
        if (tables.contains('employees') && tables.contains('salaries')) {
          await db.execute(
            "INSERT INTO employees (emp_no, birth_date, first_name, last_name, gender, hire_date) "
            "VALUES (1,'1980-01-01','Ada','Lovelace','F','2001-01-01'),"
            "(2,'1975-05-05','Alan','Turing','M','1999-06-01')",
          );
          await db.execute(
            "INSERT INTO salaries (emp_no, salary, from_date, to_date) "
            "VALUES (1,90000,'2001-01-01','2002-01-01'),"
            "(1,95000,'2002-01-01','2003-01-01'),"
            "(2,80000,'1999-06-01','2000-06-01')",
          );
          final r = await db.execute(
            'SELECT e.last_name, MAX(s.salary) AS top '
            'FROM employees e JOIN salaries s ON e.emp_no = s.emp_no '
            'GROUP BY e.last_name ORDER BY top DESC',
          );
          print('  sample query rows: ${r.rows}');
          expect(r.rows.first.last, 95000);
        }
      },
      skip: schema == null
          ? 'employees dataset not downloaded (see parity/test-data.md)'
          : null,
    );
  });
}
