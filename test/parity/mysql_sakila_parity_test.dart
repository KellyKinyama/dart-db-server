library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

import 'parity_support.dart';

/// Loads the real MySQL **sakila** sample schema through the shared engine and
/// reports how much of the dialect the engine accepts. Report-oriented: it
/// passes as long as the engine processes the script, and prints a coverage
/// summary (`-r expanded`). Skips when the git-ignored dataset is absent
/// (see `parity/test-data.md`).
void main() {
  final schema = datasetFile([
    'mysql-sakila/sakila-main/mysql-sakila-db/mysql-sakila-schema.sql',
  ]);

  group('MySQL sakila parity', () {
    test(
      'schema load coverage',
      () async {
        final db = await Database.open();
        final report = await loadScript(db, schema!.readAsStringSync());
        final tables = await tableNames(db);
        print(report.summary('sakila schema'));
        print('  tables created: ${tables.length}'
            '${tables.isEmpty ? '' : ' → ${(tables.toList()..sort()).join(', ')}'}');

        // Harness ran end-to-end over every statement.
        expect(report.total, greaterThan(0));
        // Known gap (captured, not asserted away): the engine's parser rejects
        // MySQL `INT UNSIGNED`, so every sakila CREATE TABLE fails and no tables
        // materialize. The printed report is the parity signal.
      },
      skip: schema == null
          ? 'sakila dataset not downloaded (see parity/test-data.md)'
          : null,
    );
  });
}
