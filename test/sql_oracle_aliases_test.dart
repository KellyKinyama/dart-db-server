/// Oracle-style aliases and trig extensions.
library;

import 'dart:math' as math;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  test('NVL returns first non-null', () async {
    final db = await Database.open();
    try {
      final r = await db.execute("SELECT NVL(NULL,'x'), NVL('y','z')");
      expect(r.rows.first, ['x', 'y']);
    } finally {
      await db.close();
    }
  });

  test('NVL2(expr, a, b) picks a when not null else b', () async {
    final db = await Database.open();
    try {
      final r = await db.execute('SELECT NVL2(1,10,20), NVL2(NULL,10,20)');
      expect(r.rows.first, [10, 20]);
    } finally {
      await db.close();
    }
  });

  test('DECODE matches and falls through to default', () async {
    final db = await Database.open();
    try {
      final r = await db
          .execute("SELECT DECODE(2, 1,'one', 2,'two', 3,'three', '?')");
      expect(r.rows.first[0], 'two');
      final r2 =
          await db.execute("SELECT DECODE(9, 1,'one', 2,'two', 'other')");
      expect(r2.rows.first[0], 'other');
      final r3 = await db.execute("SELECT DECODE(9, 1,'one')");
      expect(r3.rows.first[0], isNull);
    } finally {
      await db.close();
    }
  });

  test('COT and ACOT are reciprocal', () async {
    final db = await Database.open();
    try {
      final r = await db.execute('SELECT COT(1.0), ACOT(1.0)');
      final cot = (r.rows.first[0] as num).toDouble();
      final acot = (r.rows.first[1] as num).toDouble();
      expect(cot, closeTo(1.0 / math.tan(1.0), 1e-12));
      expect(acot, closeTo(math.atan(1.0), 1e-12));
    } finally {
      await db.close();
    }
  });
}
