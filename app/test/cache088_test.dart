import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';
import 'package:gejian/screens.dart';

void main() {
  test('loading and ready gestures use the same directions', () {
    for (final d in [const Offset(0, -200), const Offset(200, 0)]) {
      expect(loadingPageDelta(d), 1);
      expect(swipePageDelta(d), 1);
      expect(loadingPageDelta(-d), -1);
      expect(swipePageDelta(-d), -1);
    }
  });
  test(
    'linked artwork survives reading-order changes and stays cumulative',
    () {
      final panels = [
        {'artworkGroup': -1},
        {'artworkGroup': 2},
        {'artworkGroup': 2},
        {'artworkGroup': 2},
      ];
      final layout = <String, dynamic>{
        'width': 100,
        'height': 200,
        'panels': panels,
      };
      LibraryStore.groupArtwork(layout);
      expect(readingBeats(layout, false).map((b) => b.count), [1, 4]);
      expect(readingBeats(layout, false).last.full, true);
      layout['panels'] = panels.reversed.toList();
      LibraryStore.groupArtwork(layout);
      expect(readingBeats(layout, false).map((b) => b.count), [3, 4]);
    },
  );
  test(
    'batch deletion validates all targets first and preserves library state',
    () async {
      final root = await Directory.systemTemp.createTemp('cache088-');
      final outside = await Directory.systemTemp.createTemp('outside088-');
      try {
        final store = LibraryStore(root, {
          'progress': {'book': 7},
        });
        final entries = <File>[];
        for (int i = 0; i < 65; i++) {
          final f = File('${root.path}/analysis/$i.json');
          await f.parent.create(recursive: true);
          await f.writeAsString('cache');
          entries.add(f);
        }
        final protected = File('${outside.path}/keep')
          ..writeAsStringSync('original');
        await expectLater(
          store.deleteCacheEntries([entries.first, protected]),
          throwsStateError,
        );
        expect(await entries.first.exists(), true);
        int deleted = 0;
        await store.deleteCacheEntries(entries, onDeleted: (_) => deleted++);
        expect(deleted, 65);
        expect(await scanCacheFolder('${root.path}/analysis', true), isEmpty);
        expect(store.state['progress'], {'book': 7});
        expect(await protected.readAsString(), 'original');
      } finally {
        await root.delete(recursive: true);
        await outside.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'cache list paginates and categories remain in one scrollable row',
    (t) async {
      final root = (await t.runAsync(
        () => Directory.systemTemp.createTemp('cache-ui088-'),
      ))!;
      try {
        await t.runAsync(() async {
          final folder = Directory('${root.path}/analysis');
          await folder.create();
          for (int i = 0; i < 45; i++) {
            await File('${folder.path}/$i.json').writeAsString('{}');
          }
        });
        await t.pumpWidget(
          MaterialApp(home: CacheBrowser(LibraryStore(root, {}))),
        );
        for (int i = 0; i < 100; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump();
          if (find.text('1 / 3 页 · 1–20 项').evaluate().isNotEmpty) break;
        }
        expect(find.text('1 / 3 页 · 1–20 项'), findsOneWidget);
        expect(find.text('${root.path}/analysis/'), findsOneWidget);
        final scroll = t.widgetList<SingleChildScrollView>(
          find.byType(SingleChildScrollView),
        );
        expect(scroll.any((w) => w.scrollDirection == Axis.horizontal), true);
        await t.tap(find.byTooltip('下一页'));
        await t.pump();
        expect(find.text('2 / 3 页 · 21–40 项'), findsOneWidget);
        await t.tap(find.byTooltip('下一页'));
        await t.pump();
        expect(find.text('3 / 3 页 · 41–45 项'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      } finally {
        await t.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
