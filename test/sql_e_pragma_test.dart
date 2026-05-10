import 'package:dart_db_server/dart_db_server.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  setUp(() async {
    db = await Database.open();
  });

  group('E PRAGMA acceptance', () {
    test('PRAGMA setters accept any name and echo back', () async {
      await db.execute('PRAGMA journal_mode = WAL');
      final r = await db.execute('PRAGMA journal_mode');
      expect(r.rows.first.first.toString(), equalsIgnoringCase('WAL'));
    });

    test('Common PRAGMAs return defaults when unset', () async {
      final defaults = {
        'cache_size': -2000,
        'page_size': 4096,
        'busy_timeout': 0,
        'recursive_triggers': 1,
        'auto_vacuum': 0,
      };
      for (final e in defaults.entries) {
        final r = await db.execute('PRAGMA ${e.key}');
        expect(r.rows.first.first, e.value, reason: e.key);
      }
    });

    test('PRAGMA integrity_check returns ok', () async {
      final r = await db.execute('PRAGMA integrity_check');
      expect(r.rows.first.first, 'ok');
    });

    test('PRAGMA compile_options lists feature flags', () async {
      final r = await db.execute('PRAGMA compile_options');
      final flags = r.rows.map((e) => e[0] as String).toSet();
      expect(flags, contains('ENABLE_JSON1'));
      expect(flags, contains('ENABLE_FTS5'));
    });
  });
}
