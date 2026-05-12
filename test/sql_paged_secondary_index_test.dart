import 'dart:io';

import 'package:dart_db_server/server/paged_table.dart';
import 'package:test/test.dart';

/// Step 8: equality-lookup secondary indexes on PagedTable.
///
/// Validates the storage-layer surface directly (no SQL) — the SQL
/// wiring is exercised in `sql_paged_index_test.dart`.
void main() {
  String tmpBase(String suffix) {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'ddb_paged_secidx_${stamp}_$suffix';
  }

  Future<void> cleanup(String base) async {
    for (final s in [
      '$base.heap',
      '$base.heap.journal',
      '$base.idx',
      '$base.idx.journal',
      '$base.meta.json',
      '$base.meta.json.tmp',
    ]) {
      final f = File(s);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    // Sweep any idx_<name> sidecars.
    final dir = Directory(File(base).parent.path);
    if (await dir.exists()) {
      final stem = File(base).uri.pathSegments.last;
      await for (final ent in dir.list(followLinks: false)) {
        if (ent is! File) continue;
        final n = ent.uri.pathSegments.last;
        if (n.startsWith('$stem.idx_')) {
          try {
            await ent.delete();
          } catch (_) {}
        }
      }
    }
  }

  test('createIndex backfills + indexLookup returns matching rows', () async {
    final base = tmpBase('backfill');
    addTearDown(() => cleanup(base));
    final pt = await PagedTable.create(base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('name', PagedColumnType.textType),
        ],
        primaryKey: 'id');
    for (var i = 1; i <= 6; i++) {
      await pt.insert({'id': i, 'name': i.isEven ? 'even' : 'odd'});
    }
    await pt.commit();
    await pt.createIndex('by_name', ['name']);
    expect(pt.secondaryIndexNames, ['by_name']);
    expect(pt.indexColumn('by_name'), 'name');

    final odds = <int>[];
    await for (final r in pt.indexLookup('by_name', ['odd'])) {
      odds.add(r['id'] as int);
    }
    odds.sort();
    expect(odds, [1, 3, 5]);

    final evens = <int>[];
    await for (final r in pt.indexLookup('by_name', ['even'])) {
      evens.add(r['id'] as int);
    }
    evens.sort();
    expect(evens, [2, 4, 6]);

    // Unknown value returns empty.
    expect(await pt.indexLookup('by_name', ['nope']).toList(), isEmpty);
    // Unknown index returns empty.
    expect(await pt.indexLookup('does_not_exist', ['odd']).toList(), isEmpty);
    await pt.close();
  });

  test('insert / update / delete keep the index consistent', () async {
    final base = tmpBase('mutate');
    addTearDown(() => cleanup(base));
    final pt = await PagedTable.create(base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('tag', PagedColumnType.textType),
        ],
        primaryKey: 'id');
    await pt.createIndex('by_tag', ['tag']);
    await pt.insert({'id': 1, 'tag': 'red'});
    await pt.insert({'id': 2, 'tag': 'red'});
    await pt.insert({'id': 3, 'tag': 'blue'});
    await pt.commit();

    expect(
        (await pt.indexLookup('by_tag', ['red']).toList()).map((r) => r['id']),
        unorderedEquals([1, 2]));

    // Mutate id=1's tag — index must drop the old entry and add a new one.
    await pt.update(1, {'id': 1, 'tag': 'green'});
    await pt.commit();
    expect(
        (await pt.indexLookup('by_tag', ['red']).toList()).map((r) => r['id']),
        [2]);
    expect(
        (await pt.indexLookup('by_tag', ['green']).toList())
            .map((r) => r['id']),
        [1]);

    // Delete id=3.
    expect(await pt.delete(3), isTrue);
    await pt.commit();
    expect(await pt.indexLookup('by_tag', ['blue']).toList(), isEmpty);

    // Update to NULL — entry is removed; back to value — entry comes back.
    await pt.update(2, {'id': 2, 'tag': null});
    await pt.commit();
    expect(await pt.indexLookup('by_tag', ['red']).toList(), isEmpty);
    await pt.update(2, {'id': 2, 'tag': 'red'});
    await pt.commit();
    expect(
        (await pt.indexLookup('by_tag', ['red']).toList()).map((r) => r['id']),
        [2]);
    await pt.close();
  });

  test('indexes survive close / reopen', () async {
    final base = tmpBase('reopen');
    addTearDown(() => cleanup(base));
    {
      final pt = await PagedTable.create(base,
          columns: const [
            PagedColumn('id', PagedColumnType.intType),
            PagedColumn('city', PagedColumnType.textType),
          ],
          primaryKey: 'id');
      for (var i = 0; i < 10; i++) {
        await pt.insert({'id': i, 'city': i < 5 ? 'paris' : 'berlin'});
      }
      await pt.createIndex('by_city', ['city']);
      await pt.commit();
      await pt.close();
    }
    {
      final pt = await PagedTable.open(base);
      expect(pt.secondaryIndexNames, ['by_city']);
      final paris = await pt.indexLookup('by_city', ['paris']).toList();
      expect(paris.length, 5);
      expect(paris.map((r) => r['id']).toSet(), {0, 1, 2, 3, 4});
      // Mutations after reopen still maintain the index.
      await pt.insert({'id': 99, 'city': 'paris'});
      await pt.commit();
      final p2 = await pt.indexLookup('by_city', ['paris']).toList();
      expect(p2.length, 6);
      await pt.close();
    }
  });

  test('dropIndex removes files and is idempotent', () async {
    final base = tmpBase('drop');
    addTearDown(() => cleanup(base));
    final pt = await PagedTable.create(base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('k', PagedColumnType.textType),
        ],
        primaryKey: 'id');
    await pt.createIndex('by_k', ['k']);
    await pt.insert({'id': 1, 'k': 'a'});
    await pt.commit();
    expect(await File('$base.idx_by_k').exists(), isTrue);

    expect(await pt.dropIndex('by_k'), isTrue);
    expect(pt.secondaryIndexNames, isEmpty);
    expect(await File('$base.idx_by_k').exists(), isFalse);
    expect(await File('$base.idx_by_k.journal').exists(), isFalse);

    // Idempotent.
    expect(await pt.dropIndex('by_k'), isFalse);

    // Re-creating the same name now works (clean slate).
    await pt.createIndex('by_k', ['k']);
    expect((await pt.indexLookup('by_k', ['a']).toList()).map((r) => r['id']),
        [1]);
    await pt.close();
  });

  test('integer-column secondary index', () async {
    final base = tmpBase('intidx');
    addTearDown(() => cleanup(base));
    final pt = await PagedTable.create(base,
        columns: const [
          PagedColumn('id', PagedColumnType.textType),
          PagedColumn('age', PagedColumnType.intType),
        ],
        primaryKey: 'id');
    await pt.createIndex('by_age', ['age']);
    await pt.insert({'id': 'a', 'age': 30});
    await pt.insert({'id': 'b', 'age': 30});
    await pt.insert({'id': 'c', 'age': 25});
    await pt.commit();
    expect((await pt.indexLookup('by_age', [30]).toList()).map((r) => r['id']),
        unorderedEquals(['a', 'b']));
    expect((await pt.indexLookup('by_age', [25]).toList()).map((r) => r['id']),
        ['c']);
    await pt.close();
  });

  test('rejects duplicate index name, unknown column, and PK column', () async {
    final base = tmpBase('errors');
    addTearDown(() => cleanup(base));
    final pt = await PagedTable.create(base,
        columns: const [
          PagedColumn('id', PagedColumnType.intType),
          PagedColumn('v', PagedColumnType.textType),
        ],
        primaryKey: 'id');
    await pt.createIndex('ok', ['v']);
    await expectLater(pt.createIndex('ok', ['v']), throwsA(isA<StateError>()));
    await expectLater(
        pt.createIndex('bad', ['missing']), throwsA(isA<ArgumentError>()));
    await expectLater(
        pt.createIndex('also_bad', ['id']), throwsA(isA<ArgumentError>()));
    await expectLater(
        pt.createIndex('bad name!', ['v']), throwsA(isA<ArgumentError>()));
    await pt.close();
  });
}
