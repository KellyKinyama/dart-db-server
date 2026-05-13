/// COVAR_POP / COVAR_SAMP / CORR aggregates.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('COVAR_POP and CORR for perfectly correlated data', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(x REAL, y REAL)');
      // y = 2x for x in 1..5.
      await db.execute(
          'INSERT INTO t VALUES(1,2),(2,4),(3,6),(4,8),(5,10)');
      final r = await db.execute(
          'SELECT COVAR_POP(x,y), COVAR_SAMP(x,y), CORR(x,y) FROM t');
      // var_pop(x)=2, covar_pop=4. covar_samp=5. CORR=1.
      expect((r.rows.first[0] as num).toDouble(), closeTo(4.0, 1e-9));
      expect((r.rows.first[1] as num).toDouble(), closeTo(5.0, 1e-9));
      expect((r.rows.first[2] as num).toDouble(), closeTo(1.0, 1e-9));
    } finally {
      await db.close();
    }
  });

  test('CORR returns NULL when one column is constant', () async {
    final db = await Database.open();
    try {
      await db.execute('CREATE TABLE t(x INT, y INT)');
      await db.execute('INSERT INTO t VALUES(1,5),(2,5),(3,5)');
      final r = await db.execute('SELECT CORR(x,y) FROM t');
      expect(r.rows.first[0], isNull);
    } finally {
      await db.close();
    }
  });
}
