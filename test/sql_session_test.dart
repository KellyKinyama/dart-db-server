library;

import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Session / changeset', () {
    test('records INSERT/UPDATE/DELETE on watched table only', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE a(id INTEGER PRIMARY KEY, v TEXT)');
        await db.execute('CREATE TABLE b(id INTEGER PRIMARY KEY, v TEXT)');

        final s = db.beginSession()..attach('a');
        await db.execute("INSERT INTO a VALUES (1,'x'),(2,'y')");
        await db.execute("INSERT INTO b VALUES (10,'ignored')");
        await db.execute("UPDATE a SET v='Y' WHERE id = 2");
        await db.execute("DELETE FROM a WHERE id = 1");

        expect(s.changes.length, 4);
        expect(s.changes.map((c) => c.op).toList(),
            ['INSERT', 'INSERT', 'UPDATE', 'DELETE']);
        expect(s.changes.every((c) => c.table == 'a'), isTrue);

        final upd = s.changes[2];
        expect(upd.oldValues, [2, 'y']);
        expect(upd.newValues, [2, 'Y']);

        final del = s.changes[3];
        expect(del.oldValues, [1, 'x']);
        expect(del.newValues, isNull);

        s.close();
      } finally {
        await db.close();
      }
    });

    test('changeset round-trips and applies cleanly to a fresh database',
        () async {
      // Source DB.
      final src = await Database.open();
      late final Uint8List blob;
      try {
        await src.execute(
            'CREATE TABLE k(id INTEGER PRIMARY KEY, name TEXT, val INTEGER)');
        final s = src.beginSession();
        await src.execute("INSERT INTO k VALUES (1,'alpha',10),(2,'beta',20)");
        await src.execute("UPDATE k SET val = 99 WHERE id = 1");
        await src.execute("DELETE FROM k WHERE id = 2");
        blob = s.changeset();
        s.close();
      } finally {
        await src.close();
      }

      // Destination DB starts empty with the same schema.
      final dst = await Database.open();
      try {
        await dst.execute(
            'CREATE TABLE k(id INTEGER PRIMARY KEY, name TEXT, val INTEGER)');
        final n = await dst.applyChangeset(blob);
        expect(n, greaterThan(0));

        final r = await dst.execute('SELECT id, name, val FROM k ORDER BY id');
        expect(r.rows.length, 1);
        expect(r.rows.first, [1, 'alpha', 99]);
      } finally {
        await dst.close();
      }
    });

    test('apply with default handler skips conflicts (missing rows)',
        () async {
      final src = await Database.open();
      late final Uint8List blob;
      try {
        await src.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
        final s = src.beginSession();
        await src.execute("INSERT INTO t VALUES (1,'a'),(2,'b')");
        await src.execute("UPDATE t SET v='aa' WHERE id = 1");
        blob = s.changeset();
      } finally {
        await src.close();
      }

      final dst = await Database.open();
      try {
        await dst.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)');
        // Pre-populate id=1 so the INSERT collides.
        await dst.execute("INSERT INTO t VALUES (1,'pre')");
        final n = await dst.applyChangeset(blob);
        // INSERT(1) skipped, INSERT(2) applied, UPDATE(1) hit existing 'pre'
        // (oldValues won't match) so finds via PK and updates.
        expect(n, greaterThanOrEqualTo(2));

        final r = await dst.execute('SELECT id, v FROM t ORDER BY id');
        expect(r.rows.length, 2);
        expect(r.rows[1], [2, 'b']);
      } finally {
        await dst.close();
      }
    });

    test('disable() pauses recording, enable() resumes', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE q(id INTEGER PRIMARY KEY, v TEXT)');
        final s = db.beginSession();
        await db.execute("INSERT INTO q VALUES (1,'a')");
        s.disable();
        await db.execute("INSERT INTO q VALUES (2,'b')");
        s.enable();
        await db.execute("INSERT INTO q VALUES (3,'c')");
        expect(s.changes.length, 2);
        expect(s.changes.map((c) => (c.newValues!)[0]).toList(), [1, 3]);
      } finally {
        await db.close();
      }
    });
  });
}
