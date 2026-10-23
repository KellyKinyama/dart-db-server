/// Oracle MEDIAN precision, CO-load blockers, and OE object-type gaps closed in
/// the round-36..38 sweeps: exact-decimal MEDIAN, IS JSON predicate, JSON_TABLE
/// in a view/FROM, TO_TIMESTAMP FF, object-type constructors, and object-
/// attribute navigation.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  Future<Object?> scalar(Database db, String sql) async =>
      (await db.execute(sql)).rows.first.first;

  test('MEDIAN of two middle values is exact decimal', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (v NUMBER(8,2))');
      await db.execute('INSERT INTO t VALUES (1.01), (1.02)');
      expect((await scalar(db, 'SELECT MEDIAN(v) FROM t')).toString(), '1.015');
    } finally {
      await db.close();
    }
  });

  test('IS JSON check constraint allows a valid JSON payload', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE p (id NUMBER PRIMARY KEY, details BLOB)');
      await db.execute(
          'ALTER TABLE p ADD CONSTRAINT p_json CHECK (details is json)');
      await db.execute("INSERT INTO p (id, details) VALUES "
          "(1, UTL_RAW.CAST_TO_RAW('{\"colour\":\"white\"}'))");
      expect(await scalar(db, 'SELECT COUNT(*) FROM p'), 1);
    } finally {
      await db.close();
    }
  });

  test('IS JSON / IS NOT JSON predicate', () async {
    final db = await Database.open(null);
    try {
      expect(await scalar(db, "SELECT CASE WHEN '{\"a\":1}' IS JSON "
          'THEN 1 ELSE 0 END'), 1);
      expect(await scalar(db, "SELECT CASE WHEN 'not json' IS JSON "
          'THEN 1 ELSE 0 END'), 0);
    } finally {
      await db.close();
    }
  });

  test('JSON_TABLE in a view / lateral FROM parses', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE p2 (id NUMBER, details BLOB)');
      await db.execute('''CREATE OR REPLACE VIEW pr AS
        SELECT p.id, r.rating,
          ROUND(AVG(r.rating) OVER (PARTITION BY p.id), 2) avg_rating
        FROM p2 p,
          JSON_TABLE(p.details, '\$' COLUMNS (rating NUMBER PATH '\$.rating')) r''');
    } finally {
      await db.close();
    }
  });

  test('TO_TIMESTAMP parses a 9-digit FF fraction', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE o (id NUMBER, ts TIMESTAMP NOT NULL)');
      await db.execute("INSERT INTO o VALUES (1, TO_TIMESTAMP("
          "'05-MAR-2019 09.24.19.123456789','DD-MON-YYYY HH24.MI.SS.FF'))");
      expect(await scalar(db, 'SELECT COUNT(*) FROM o'), 1);
    } finally {
      await db.close();
    }
  });

  test('object-type constructor and attribute navigation', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TYPE addr_typ AS OBJECT '
          '(street VARCHAR2(40), city VARCHAR2(30))');
      await db.execute('CREATE TABLE c (id NUMBER, addr addr_typ)');
      await db.execute("INSERT INTO c VALUES (1, addr_typ('1 Main St','Austin'))");
      expect(await scalar(db, 'SELECT c.addr.city FROM c c'), 'Austin');
    } finally {
      await db.close();
    }
  });

  test('JSON_VALUE decodes a BLOB column holding JSON', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE jb (id NUMBER, details BLOB)');
      await db.execute("INSERT INTO jb VALUES "
          "(1, UTL_RAW.CAST_TO_RAW('{\"colour\":\"white\"}'))");
      expect(await scalar(db, "SELECT JSON_VALUE(details, '\$.colour') FROM jb"),
          'white');
    } finally {
      await db.close();
    }
  });
}
