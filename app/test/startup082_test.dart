import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/startup.dart';
import 'package:gejian/splash.dart';
import 'package:flutter/material.dart';

class WarmStore extends LibraryStore {
  final File sample;
  int requests = 0;
  WarmStore(super.root, super.state, this.sample);
  @override
  Future<File> cover(Book b) async {
    requests++;
    return sample;
  }
}

void main() {
  for (final reduceMotion in [false, true]) {
    testWidgets('opening can be skipped with reduced motion $reduceMotion', (
      t,
    ) async {
      final root = await t.runAsync(
        () => Directory.systemTemp.createTemp('suki-skip-'),
      );
      final store = LibraryStore(root!, {});
      var ready = false;
      try {
        StartupData.feeds['${root.path}:${StartupData.day()}'] = Future.value(
          <List<Book>>[[], []],
        );
        await t.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: MuseSplash(
                store: store,
                onArtworkReady: () => ready = true,
              ),
            ),
          ),
        );
        for (var i = 0; i < 100 && !ready; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump();
        }
        expect(ready, isTrue);
        await t.pump(const Duration(milliseconds: 600));
        final titleImage = t.widget<RawImage>(find.byType(RawImage)).image;
        final titleOpacity = find.ancestor(
          of: find.byType(RawImage),
          matching: find.byType(Opacity),
        );
        expect(t.widget<Opacity>(titleOpacity.first).opacity, 1);
        await t.tapAt(const Offset(400, 300));
        await t.pump();
        await t.pump(const Duration(milliseconds: 100));
        // Skip fades the same title directly into the homepage.
        expect(
          t.widget<RawImage>(find.byType(RawImage)).image,
          same(titleImage),
        );
        expect(
          t.widget<Opacity>(titleOpacity.first).opacity,
          inExclusiveRange(0, 1),
        );
        await t.pump(const Duration(milliseconds: 450));
        expect(find.bySemanticsLabel('Suki Manga'), findsNothing);
        expect(find.byType(RawImage), findsNothing);
        expect(t.takeException(), isNull);
      } finally {
        await t.pumpWidget(const SizedBox());
        for (var i = 0; i < 100 && store.startupBusy; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump();
        }
        expect(store.startupBusy, isFalse);
        StartupData.feeds.clear();
        await t.runAsync(() => root.delete(recursive: true));
      }
    });
  }
  testWidgets('wordmark fades directly into the homepage', (t) async {
    final root = await t.runAsync(
      () => Directory.systemTemp.createTemp('suki-title-'),
    );
    final store = LibraryStore(root!, {});
    var ready = false;
    try {
      StartupData.feeds['${root.path}:${StartupData.day()}'] = Future.value(
        <List<Book>>[[], []],
      );
      await t.pumpWidget(
        MaterialApp(
          home: MuseSplash(store: store, onArtworkReady: () => ready = true),
        ),
      );
      for (var i = 0; i < 100 && !ready; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
      expect(ready, isTrue);
      await t.pump();
      final titleOpacity = find.ancestor(
        of: find.byType(RawImage),
        matching: find.byType(Opacity),
      );
      final titleImage = t.widget<RawImage>(find.byType(RawImage)).image;
      await t.pump(const Duration(milliseconds: 1900));
      expect(t.widget<Opacity>(titleOpacity.first).opacity, 1);
      await t.pump(const Duration(milliseconds: 350));
      expect(
        t.widget<Opacity>(titleOpacity.first).opacity,
        inExclusiveRange(0, 1),
      );
      expect(t.widget<RawImage>(find.byType(RawImage)).image, same(titleImage));
      expect(find.byType(Image), findsNothing);
      await t.pump(const Duration(milliseconds: 300));
      // The slower transition must still be fading after the former endpoint.
      expect(
        t.widget<Opacity>(titleOpacity.first).opacity,
        inExclusiveRange(0, 1),
      );
      await t.pump(const Duration(milliseconds: 700));
      await t.pump();
      expect(find.byType(RawImage), findsNothing);
      expect(find.bySemanticsLabel('Suki Manga'), findsNothing);
      expect(t.takeException(), isNull);
    } finally {
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 100 && store.startupBusy; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
      StartupData.feeds.clear();
      await t.runAsync(() => root.delete(recursive: true));
    }
  });
  test('startup preloads home covers without saving daily artwork', () async {
    final root = await Directory.systemTemp.createTemp('muse-startup-');
    try {
      final image = File('${root.path}/sample.jpg');
      await image.writeAsBytes([1, 2, 3]);
      final store = WarmStore(root, {}, image);
      final rank = List.generate(
        4,
        (i) => Book('r$i', 'md', 'rank$i', 'cover'),
      );
      final daily = List.generate(
        6,
        (i) => Book('d$i', 'md', 'daily$i', 'cover'),
      );
      StartupData.feeds['${root.path}:${StartupData.day()}'] = Future.value([
        rank,
        daily,
      ]);
      final first = StartupData.home(store), second = StartupData.home(store);
      expect(identical(first, second), true);
      await StartupData.prepare(store);
      expect(await Directory('${root.path}/startup').exists(), false);
      expect(store.requests, 10);
      expect(store.startupBusy, false);
      expect((await first)[1].first.id, 'd0');
    } finally {
      StartupData.feeds.clear();
      await root.delete(recursive: true);
    }
  });
  test(
    'upgrade deletes retired startup files and preserves library data',
    () async {
      final root = await Directory.systemTemp.createTemp('suki-migrate-');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(native, (call) async => root.path);
      try {
        final legacy = File('${root.path}/startup/2026-11-17/feed.json');
        await legacy.parent.create(recursive: true);
        await legacy.writeAsString('[]');
        final cover = File('${root.path}/covers/keep.jpg');
        await cover.parent.create(recursive: true);
        await cover.writeAsBytes([1, 2, 3]);
        await LibraryStore.open();
        expect(await legacy.parent.parent.exists(), false);
        expect(await cover.readAsBytes(), [1, 2, 3]);
        await LibraryStore.open();
        expect(await legacy.parent.parent.exists(), false);
      } finally {
        messenger.setMockMethodCallHandler(native, null);
        await root.delete(recursive: true);
      }
    },
  );
}
