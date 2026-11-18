import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';
import 'package:gejian/splash.dart';

void main() {
  test('four swipe directions always indicate whole-page navigation', () {
    expect(swipePageDelta(const Offset(0, -200)), 1);
    expect(swipePageDelta(const Offset(200, 0)), 1);
    expect(swipePageDelta(const Offset(0, 200)), -1);
    expect(swipePageDelta(const Offset(-200, 0)), -1);
    expect(swipePageDelta(const Offset(10, 10)), 0);
  });
  test('overlapping poster composition falls back to whole page', () {
    final layout = <String, dynamic>{
      'width': 1000,
      'height': 1500,
      'panels': [
        {
          'polygon': [
            [0, 0],
            [900, 0],
            [900, 1450],
            [0, 1450],
          ],
          'box': [0, 0, 900, 1450],
        },
        {
          'polygon': [
            [650, 100],
            [950, 100],
            [950, 500],
            [650, 500],
          ],
          'box': [650, 100, 300, 400],
        },
      ],
    };
    LibraryStore.groupArtwork(layout);
    expect(layout['wholePage'], true);
    expect(readingBeats(layout, true).single.full, true);
  });
  test(
    'chapter completion requires both images and valid recognition files',
    () async {
      final root = await Directory.systemTemp.createTemp('muse-ready-');
      try {
        final store = LibraryStore(root, {}), b = Book('b', 'md', 'b', '');
        final ch = Chapter('c', 'c', pages: ['https://example.com/page']);
        final image = File('${store.chapterDir(b, ch).path}/0.img');
        await image.parent.create(recursive: true);
        await image.writeAsBytes([1, 2, 3]);
        expect(await store.chapterReady(b, ch), false);
        final hash = sha256.convert([1, 2, 3]);
        final cache = File('${root.path}/analysis/et15-geometry26-$hash.json');
        await cache.parent.create();
        await cache.writeAsString(jsonEncode({'panels': [], 'width': 10}));
        expect(await store.chapterReady(b, ch), true);
        await cache.writeAsString('broken');
        expect(await store.chapterReady(b, ch), false);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  testWidgets('startup title fits the viewport and disposes its timer', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: MuseSplash(store: LibraryStore(Directory.systemTemp, {})),
      ),
    );
    await t.pump(const Duration(milliseconds: 250));

    expect(find.byType(Image), findsWidgets);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
}
