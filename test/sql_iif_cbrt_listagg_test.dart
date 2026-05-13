/// IIF, CBRT, LISTAGG.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('IIF returns correct branch', () async {
    final db = await Database.open();
    try {
      final r = await db.execute(
          "SELECT IIF(1<2,'yes','no'), IIF(0,'a','b'), IIF(NULL,'a','b')");
      expect(r.rows.first, ['yes', 'b', 'b']);
    } finally {
      await db.close();
    }
  });

  test('CBRT computes cube root', () async {
    final db = await Database.open();
    try {
      final r = await db.execute('SELECT CBRT(27.0), CBRT(-8.0), CBRT(0)');
      expect((r.rows.first[0] as num).toDouble(), closeTo(3.0, 1e-9));
      expect((r.rows.first[1] as num).toDouble(), closeTo(-2.0, 1e-9));
      expect((r.rows.first[2] as num).toDouble(), closeTo(0.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('LISTAGG aliases GROUP_CONCAT', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(s TEXT)');
      await db.execute("INSERT INTO t VALUES('a'),('b'),('c')");
      final r = await db.execute("SELECT LISTAGG(s,'|') FROM t");
      expect(r.rows.first[0], 'a|b|c');
    } finally {
      await db.close();
    }
  });
}
