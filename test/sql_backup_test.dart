library;

import 'dart:io';

import 'package:dart_db_server/dart_db_server.dart';
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

/// Unique tmp file per test so parallel runs do not collide.
String _tmp(String tag) {
  final dir = Directory.systemTemp.createTempSync('ddbs_backup_');
  return '${dir.path}${Platform.pathSeparator}$tag.db';
}

void main() {
  group('Online backup', () {
    test('Database.backup() writes a file readable by package:sqlite3',
        () async {
      final src = await Database.open();
      try {
        await src.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
        await src
            .execute("INSERT INTO t VALUES (1,'alice'),(2,'bob'),(3,'carol')");

        final dest = _tmp('backup_basic');
        await src.backup(dest);
        expect(File(dest).existsSync(), isTrue);
        expect(File(dest).lengthSync(), greaterThan(0));

        final db = sq.sqlite3.open(dest);
        try {
          final rows = db.select('SELECT id, name FROM t ORDER BY id');
          expect(rows.length, 3);
          expect(rows[0]['id'], 1);
          expect(rows[0]['name'], 'alice');
          expect(rows[2]['name'], 'carol');
        } finally {
          db.dispose();
        }
      } finally {
        await src.close();
      }
    });

    test('VACUUM INTO writes a SQLite file at the given path', () async {
      final src = await Database.open();
      try {
        await src.execute('CREATE TABLE k(v INTEGER)');
        await src.execute('INSERT INTO k VALUES (10),(20),(30),(40)');

        final dest = _tmp('vacuum_into');
        await src.execute("VACUUM INTO '${dest.replaceAll(r'\', r'\\')}'");
        expect(File(dest).existsSync(), isTrue);

        final db = sq.sqlite3.open(dest);
        try {
          final rows = db.select('SELECT v FROM k ORDER BY v');
          expect(rows.map((r) => r['v']).toList(), [10, 20, 30, 40]);
        } finally {
          db.dispose();
        }
      } finally {
        await src.close();
      }
    });

    test('VACUUM (no INTO) is still a no-op success', () async {
      final db = await Database.open();
      try {
        await db.execute('CREATE TABLE x(i INTEGER)');
        final r = await db.execute('VACUUM');
        expect(r.message, contains('VACUUM'));
      } finally {
        await db.close();
      }
    });

    test('Backup of a database with an index is queryable in sqlite3',
        () async {
      final src = await Database.open();
      try {
        await src.execute('CREATE TABLE p(id INTEGER PRIMARY KEY, sku TEXT)');
        await src.execute('CREATE INDEX p_sku ON p(sku)');
        await src
            .execute("INSERT INTO p VALUES (1,'A'),(2,'B'),(3,'C'),(4,'A')");

        final dest = _tmp('backup_index');
        await src.backup(dest);

        final db = sq.sqlite3.open(dest);
        try {
          final rows =
              db.select("SELECT id FROM p WHERE sku = 'A' ORDER BY id");
          expect(rows.map((r) => r['id']).toList(), [1, 4]);
        } finally {
          db.dispose();
        }
      } finally {
        await src.close();
      }
    });
  });

  group('checkpointForBackup', () {
    test('in-memory database returns an empty file set', () async {
      final db = await Database.open();
      try {
        expect(await db.checkpointForBackup(), isEmpty);
      } finally {
        await db.close();
      }
    });

    test('path-backed JSON database flushes and reports its file set',
        () async {
      final file = _tmp('ckpt_json').replaceAll('.db', '.json');
      final db = await Database.open(file);
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)');
        await db.execute("INSERT INTO t VALUES (1,'alice'),(2,'bob')");
        final files = await db.checkpointForBackup();
        expect(files, contains(file));
        expect(File(file).existsSync(), isTrue);
        expect(File(file).lengthSync(), greaterThan(0));
      } finally {
        await db.close();
      }
    });

    test('backup set copied while quiesced restores identical rows', () async {
      final file = _tmp('ckpt_restore').replaceAll('.db', '.json');
      final db = await Database.open(file);
      try {
        await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, n TEXT)');
        await db.execute("INSERT INTO t VALUES (1,'a'),(2,'b'),(3,'c')");
        final files = await db.checkpointForBackup();
        final copyDir =
            Directory.systemTemp.createTempSync('ddbs_ckpt_copy_');
        for (final f in files) {
          final name = f.split(Platform.pathSeparator).last;
          File(f).copySync('${copyDir.path}${Platform.pathSeparator}$name');
        }
        final restored = await Database.open(
            '${copyDir.path}${Platform.pathSeparator}${file.split(Platform.pathSeparator).last}');
        try {
          final r = await restored.execute('SELECT id, n FROM t ORDER BY id');
          expect(r.rows, [
            [1, 'a'],
            [2, 'b'],
            [3, 'c'],
          ]);
        } finally {
          await restored.close();
        }
      } finally {
        await db.close();
      }
    });
  });
}
