// Real tests live in db_server_test.dart. This file is kept to satisfy the
// pub default test path and acts as a smoke test for the public API.
import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('Database.open returns a usable instance', () async {
    final db = await Database.open();
    final r = await db.execute('SHOW TABLES');
    expect(r.rows, isEmpty);
  });
}
