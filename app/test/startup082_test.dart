import 'dart:io';
import 'dart:convert';

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
  testWidgets('single stable wall paints across the full screen width', (
    t,
  ) async {
    final root = await t.runAsync(
      () => Directory.systemTemp.createTemp('muse-wall-'),
    );
    try {
      final folder = Directory('${root!.path}/startup/${StartupData.day()}');
      await t.runAsync(() async {
        await folder.create(recursive: true);
        await File('${folder.path}/feed.json').writeAsString('[[],[]]');
        await File(
          'test/fixtures/synthetic-page.png',
        ).copy('${folder.path}/wall-v3.png');
      });
      await t.pumpWidget(
        MaterialApp(home: MuseSplash(store: LibraryStore(root, {}))),
      );
      final finder = find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_WallPainter',
      );
      for (int i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
      expect(finder, findsOneWidget);
      expect(t.getSize(finder).width, 800);
      expect(t.takeException(), isNull);
      for (int i = 0; i < 100; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await t.pump();
      }
      final painter = t.widget<CustomPaint>(finder).painter;
      await t.pump(const Duration(milliseconds: 1900));
      expect(find.text('Suki Manga'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 900));
      expect(
        t.widget<CustomPaint>(finder).painter.runtimeType,
        painter.runtimeType,
      );
      await t.pump(const Duration(milliseconds: 2800));
      await t.pump(const Duration(milliseconds: 650));
      expect(finder, findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    } finally {
      StartupData.feeds.clear();
      await t.runAsync(() => root!.delete(recursive: true));
    }
  });
  test(
    'startup and homepage share daily snapshot and preload covers',
    () async {
      final root = await Directory.systemTemp.createTemp('muse-startup-');
      try {
        final image = File('${root.path}/sample.jpg');
        await image.writeAsBytes([1, 2, 3]);
        final store = WarmStore(root, {}, image);
        final rank = List.generate(
          4,
          (i) => Book('r$i', 'md', 'rank$i', 'cover').toJson(),
        );
        final daily = List.generate(
          6,
          (i) => Book('d$i', 'md', 'daily$i', 'cover').toJson(),
        );
        final snapshot = File(
          '${root.path}/startup/${StartupData.day()}/feed.json',
        );
        await snapshot.parent.create(recursive: true);
        await snapshot.writeAsString(jsonEncode([rank, daily]));
        final first = StartupData.home(store), second = StartupData.home(store);
        expect(identical(first, second), true);
        final files = await StartupData.prepare(store);
        expect(files.length, 6);
        expect(store.requests, 10);
        expect(store.startupBusy, false);
        expect((await first)[1].first.id, 'd0');
        await store.deleteCacheEntry(snapshot.parent);
        expect(await snapshot.exists(), false);
      } finally {
        StartupData.feeds.clear();
        await root.delete(recursive: true);
      }
    },
  );
}
