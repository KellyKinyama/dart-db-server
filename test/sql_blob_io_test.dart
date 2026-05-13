library;

import 'dart:typed_data';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  group('Incremental BLOB I/O', () {
    test('read streams bytes out of a BLOB column without copying it whole',
        () async {
      final db = await Database.open();
      try {
        await db
            .execute('CREATE TABLE files(id INTEGER PRIMARY KEY, data BLOB)');
        // 256-byte blob: 0,1,2,...,255
        final src = Uint8List.fromList(List.generate(256, (i) => i));
        final stmt = db.prepare('INSERT INTO files VALUES (1, ?)');
        await stmt.execute(positional: [src]);

        final h = db.openBlob(table: 'files', column: 'data', rowid: 1);
        expect(h.length, 256);
        expect(h.position, 0);

        final first16 = h.read(16);
        expect(first16, Uint8List.fromList(List.generate(16, (i) => i)));
        expect(h.position, 16);

        // Random-access read via offset
        final mid = h.read(4, offset: 100);
        expect(mid, Uint8List.fromList([100, 101, 102, 103]));
        expect(h.position, 104);

        // Read past end clamps
        final tail = h.read(1000, offset: 250);
        expect(tail.length, 6);
        expect(tail, Uint8List.fromList([250, 251, 252, 253, 254, 255]));

        h.close();
      } finally {
        await db.close();
      }
    });

    test('write requires writable=true and cannot grow the blob', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE k(id INTEGER PRIMARY KEY, b BLOB)');
        await db.execute('INSERT INTO k VALUES (7, zeroblob(32))');

        final ro = db.openBlob(table: 'k', column: 'b', rowid: 7);
        expect(ro.length, 32);
        expect(() => ro.write([1, 2, 3]), throwsStateError);
        ro.close();

        final rw =
            db.openBlob(table: 'k', column: 'b', rowid: 7, writable: true);
        rw.write(Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]));
        expect(rw.position, 4);
        rw.write(Uint8List.fromList([0x11, 0x22]), offset: 30);
        expect(rw.position, 32);

        // Growing past end is rejected
        expect(() => rw.write([1], offset: 32), throwsRangeError);
        rw.close();

        // Re-open and verify the bytes round-trip via SQL
        final r = await db.execute('SELECT b FROM k WHERE id = 7');
        final bytes = r.rows.first[0] as Uint8List;
        expect(bytes.length, 32);
        expect(bytes.sublist(0, 4), [0xAA, 0xBB, 0xCC, 0xDD]);
        expect(bytes.sublist(30, 32), [0x11, 0x22]);
        // Bytes in the gap remain zero
        expect(bytes.sublist(4, 30), List.filled(26, 0));
      } finally {
        await db.close();
      }
    });

    test('open by 1-based row position when no INTEGER PK is present',
        () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE bare(payload BLOB)');
        final stmt = db.prepare('INSERT INTO bare VALUES (?)');
        await stmt.execute(positional: [
          Uint8List.fromList([10, 20, 30])
        ]);
        await stmt.execute(positional: [
          Uint8List.fromList([40, 50, 60, 70])
        ]);

        final h2 = db.openBlob(table: 'bare', column: 'payload', rowid: 2);
        expect(h2.length, 4);
        expect(h2.read(4), [40, 50, 60, 70]);
        h2.close();
      } finally {
        await db.close();
      }
    });

    test('rejects non-blob columns and missing rows', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE m(id INTEGER PRIMARY KEY, name TEXT)');
        await db.execute("INSERT INTO m VALUES (1, 'alpha')");

        expect(() => db.openBlob(table: 'm', column: 'name', rowid: 1),
            throwsArgumentError);
        expect(() => db.openBlob(table: 'm', column: 'name', rowid: 999),
            throwsArgumentError);
        expect(() => db.openBlob(table: 'nope', column: 'name', rowid: 1),
            throwsArgumentError);
      } finally {
        await db.close();
      }
    });

    test('handle is unusable after close()', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE z(id INTEGER PRIMARY KEY, b BLOB)');
        await db.execute('INSERT INTO z VALUES (1, zeroblob(8))');
        final h = db.openBlob(table: 'z', column: 'b', rowid: 1);
        h.close();
        expect(h.isClosed, isTrue);
        expect(() => h.read(1), throwsStateError);
      } finally {
        await db.close();
      }
    });
  });
}
