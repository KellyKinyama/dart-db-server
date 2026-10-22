library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

import 'parity_support.dart';

/// Loads the real Oracle **HR** sample schema (`hr_create.sql`) through the
/// shared engine — after stripping SQL*Plus client directives — and reports how
/// much of Oracle's DDL the engine accepts. Report-oriented; skips when the
/// git-ignored dataset is absent (see `parity/test-data.md`).
void main() {
  final create = datasetFile([
    'oracle-db-sample-schemas/db-sample-schemas-main/human_resources/hr_create.sql',
  ]);

  group('Oracle HR parity', () {
    test(
      'schema load coverage',
      () async {
        final db = await Database.open();
        final sql = stripSqlPlusLines(create!.readAsStringSync());
        final report = await loadScript(db, sql);
        final tables = await tableNames(db);
        print(report.summary('oracle HR schema'));
        print('  tables created: ${tables.length}'
            '${tables.isEmpty ? '' : ' → ${(tables.toList()..sort()).join(', ')}'}');

        expect(report.total, greaterThan(0));

        // If the canonical HR tables load, exercise Oracle idioms the parity
        // docs claim: DUAL, NVL, and a hierarchical-friendly self-join shape.
        if (tables.contains('employees')) {
          // The job_id FK now loads and enforces (ALTER TABLE ADD CONSTRAINT),
          // so seed the referenced jobs row before the single-employee probe.
          if (tables.contains('jobs')) {
            await db.execute(
              "INSERT INTO jobs (job_id, job_title) VALUES ('AD_PRES','President')",
            );
          }
          await db.execute(
            "INSERT INTO employees (employee_id, last_name, email, hire_date, job_id, salary) "
            "VALUES (100,'King','SKING','2003-06-17','AD_PRES',24000)",
          );
          final r = await db.execute(
            'SELECT NVL(commission_pct, 0) AS comm, last_name '
            'FROM employees WHERE employee_id = 100',
          );
          print('  sample query rows: ${r.rows}');
          expect(r.rows.first.last, 'King');
        }
      },
      skip: create == null
          ? 'Oracle HR dataset not downloaded (see parity/test-data.md)'
          : null,
    );
  });
}
