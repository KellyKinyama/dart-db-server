/// Oracle DDL parity: idioms the real HR sample schema uses — inline named
/// column constraints, `ALTER TABLE ADD (CONSTRAINT …)`, and `COMMENT ON`.
library;

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  // F63: inline named column constraint — `col TYPE CONSTRAINT <name> NOT NULL`.
  test('inline named column constraint parses and enforces', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER CONSTRAINT id_nn NOT NULL, '
          'nm VARCHAR2(25))');
      await db.execute("INSERT INTO t VALUES (1, 'a')");
      await expectLater(db.execute("INSERT INTO t (nm) VALUES ('b')"),
          throwsA(isA<FormatException>())); // id is NOT NULL
    } finally {
      await db.close();
    }
  });

  // F64: `ALTER TABLE t ADD (CONSTRAINT <name> PRIMARY KEY (cols))`.
  test('ALTER TABLE ADD (parenthesized constraint) parses and enforces',
      () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER, nm VARCHAR2(10))');
      await db.execute('ALTER TABLE t ADD (CONSTRAINT t_pk PRIMARY KEY (id))');
      await db.execute("INSERT INTO t VALUES (1, 'a')");
      await expectLater(db.execute("INSERT INTO t VALUES (1, 'b')"),
          throwsA(anything)); // PK duplicate
      // Non-parenthesized form also works.
      await db.execute('CREATE TABLE u (id NUMBER, nm VARCHAR2(10))');
      await db.execute('ALTER TABLE u ADD CONSTRAINT u_uq UNIQUE (nm)');
    } finally {
      await db.close();
    }
  });

  // F65: `COMMENT ON TABLE/COLUMN … IS '…'` is accepted as a no-op.
  test('COMMENT ON TABLE/COLUMN is accepted', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER)');
      await db.execute("COMMENT ON TABLE t IS 'a table'");
      await db.execute("COMMENT ON COLUMN t.id IS 'the id'");
    } finally {
      await db.close();
    }
  });

  // F66: a trailing ORGANIZATION INDEX (IOT) storage clause is accepted+ignored.
  test('ORGANIZATION INDEX clause on CREATE TABLE is accepted', () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE TABLE t (id NUMBER, nm VARCHAR2(10), '
          'CONSTRAINT pk PRIMARY KEY (id)) ORGANIZATION INDEX');
      await db.execute("INSERT INTO t VALUES (1, 'a')");
      expect((await db.execute('SELECT id FROM t')).rows, [
        [1]
      ]);
    } finally {
      await db.close();
    }
  });

  // F67: an explicit column list renames the view's output columns.
  test('CREATE VIEW with an explicit column list renames the columns',
      () async {
    final db = await Database.open(null);
    try {
      await db.execute('CREATE VIEW v (a, b) AS SELECT 1, 2');
      final r = await db.execute('SELECT a, b FROM v');
      expect(r.columns, ['a', 'b']);
      expect(r.rows, [
        [1, 2]
      ]);
      // Star expansion over the view reports the renamed columns too.
      expect((await db.execute('SELECT * FROM v')).columns, ['a', 'b']);
    } finally {
      await db.close();
    }
  });
}
