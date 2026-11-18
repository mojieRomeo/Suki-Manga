import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';
import 'package:gejian/screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'live isekai titles, chapter pages, vertical panel navigation and tap bubbles',
    (tester) async {
      final proxy = await native.invokeMethod<String>('systemProxy');
      if (proxy != null && proxy.isNotEmpty) {
        Sources.client.findProxy = (_) => 'PROXY $proxy';
      }
      final feed = await tester.runAsync(
        () => Future.wait([Sources.ranking(), Sources.daily()]),
      );
      expect(feed![0], isNotEmpty);
      expect(feed[1], isNotEmpty);
      final opm = await tester.runAsync(() async {
        final found = await Sources.search('md', 'One Punch-Man');
        final b = found.firstWhere((b) => b.title == 'One Punch-Man');
        final watch = Stopwatch()..start();
        await Sources.chapters(b);
        expect(b.chapters.length, lessThanOrEqualTo(100));
        final first = b.chapterOffset;
        expect(b.chapterTotal, greaterThan(first));
        await Sources.moreChapters(b);
        expect(b.chapterOffset, greaterThan(first));
        // ignore: avoid_print
        print(
          'OPM_PAGINATION total=${b.chapterTotal}, loaded=${b.chapters.length}, twoBatchesMs=${watch.elapsedMilliseconds}',
        );
        return b;
      });
      expect(opm, isNotNull);
      final books = await tester.runAsync(
        () =>
            Sources.search('md', 'isekai').timeout(const Duration(seconds: 60)),
      );
      const ids = [
        'bd6d0982-0091-4945-ad70-c028ed3c0917',
        '0da358e6-37b7-4068-b1d7-100e4344485d',
      ];
      for (final id in ids) {
        expect(
          books!.any((b) => b.id == id),
          true,
          reason: 'Expected title must be present in the live isekai response',
        );
      }
      final base = await native.invokeMethod<String>('directory');
      final directory = Directory('$base/integration-071');
      await tester.runAsync(() => directory.create(recursive: true));
      final store = LibraryStore(directory, {});
      final results = <Json>[];
      File? flowImage;
      Json? flowLayout;
      for (final id in ids) {
        final book = books!.firstWhere((b) => b.id == id);
        expect(book.cover, isNotEmpty);
        // Simulate the HTML response mistakenly cached by the previous release.
        final brokenCover = File(
          '${directory.path}/covers/${keyFor(book.key)}.img',
        );
        await tester.runAsync(() async {
          await brokenCover.parent.create(recursive: true);
          await brokenCover.writeAsString('<html>Browser verification</html>');
        });
        final cover = await tester.runAsync(() => store.cover(book));
        final coverBytes = await tester.runAsync(() => cover!.readAsBytes());
        expect(
          await tester.runAsync(() => LibraryStore.validImage(coverBytes!)),
          true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 200,
              height: 300,
              child: Cover(book, store: store),
            ),
          ),
        );
        for (int i = 0; i < 30 && find.byType(Image).evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
        expect(
          find.byType(Image),
          findsOneWidget,
          reason: 'A decoded cover must be displayed instead of a title placeholder',
        );
        await tester.runAsync(
          () => Sources.chapters(book).timeout(const Duration(seconds: 120)),
        );
        final chapter = book.chapters.firstWhere(
          (c) => c.title.contains('· en'),
          orElse: () => book.chapters.first,
        );
        await tester.runAsync(
          () =>
              Sources.pages(book, chapter).timeout(const Duration(seconds: 60)),
        );
        expect(chapter.pages, isNotEmpty);
        final index = id == ids.first ? 4 : 3;
        final file = File('${directory.path}/$id.jpg');
        await tester.runAsync(() async {
          await file.writeAsBytes(
            await Sources.bytes(
              chapter.pages[index],
              referer: 'https://mangadex.org/',
            ),
          );
        });
        final layout = await tester.runAsync(() => store.recognize(file));
        expect(layout!['panels'], isNotEmpty);
        results.add({
          'id': id,
          'title': book.title,
          'searchFound': true,
          'coverBytes': coverBytes!.length,
          'coverDecoded': true,
          'coverHtmlCacheRepaired': true,
          'chapter': chapter.id,
          'chapterCount': book.chapters.length,
          'pages': chapter.pages.length,
          'downloadedPage': index + 1,
          'panels': (layout['panels'] as List).length,
          'background': layout['background'],
        });
        if (id == ids.first) {
          flowImage = file;
          flowLayout = layout;
        }
      }
      for (final sample in [
        ['spread', 'c9f74401-462a-4f53-b83a-43bd71296b52', 3],
        ['strips', 'de20ef70-7b70-4195-be95-2786a78751e7', 14],
        ['balloon', '1259bde6-d806-439d-8798-a5258469a2b8', 0],
        ['ambiguous-opm', 'c9f74401-462a-4f53-b83a-43bd71296b52', 15],
        ['ambiguous-mushoku', '577bfc24-9287-4479-b8df-cdb6be2bde49', 16],
      ]) {
        final layout = await tester.runAsync(() async {
          final ch = Chapter(sample[1] as String, 'sample');
          final b = Book('sample', 'md', 'sample', '');
          await Sources.pages(b, ch);
          final file = File('${directory.path}/${sample[0]}.jpg');
          await file.writeAsBytes(
            await Sources.bytes(ch.pages[sample[2] as int]),
          );
          return store.recognize(file);
        });
        // ignore: avoid_print
        print(
          'COMPOSITION_${sample[0]} ${jsonEncode({'wholePage': layout!['wholePage'], 'groups': layout['revealGroups'], 'boxes': (layout['panels'] as List).map((p) => p['box']).toList()})}',
        );
        if (sample[0] == 'balloon') {
          final boxes = <List<double>>[];
          for (final panel in layout['panels']) {
            for (final bubble in panel['bubbles']) {
              final rect = polygon(bubble['polygon']).getBounds();
              boxes.add([rect.left, rect.top, rect.width, rect.height]);
            }
          }
          // ignore: avoid_print
          print(
            'BALLOON_SAMPLE ${jsonEncode({'width': layout['width'], 'height': layout['height'], 'boxes': boxes})}',
          );
          expect(
            boxes.any(
              (b) =>
                  b[0] > 450 &&
                  b[0] < 750 &&
                  b[1] > 750 &&
                  b[1] < 1000 &&
                  b[3] > 300,
            ),
            true,
            reason: 'Complete third caption must include its lower half',
          );
        }
        if ((sample[0] as String).startsWith('ambiguous')) {
          expect(layout['wholePage'], true);
        }
        if (sample[0] == 'spread') {
          expect(layout['wholePage'], true);
        } else if (sample[0] == 'strips') {
          expect(layout['revealGroups'] as List, isNotEmpty);
        }
      }
      final report = File('$base/integration-live-071.json');
      await tester.runAsync(
        () => report.writeAsString(jsonEncode({'liveSources': results})),
      );
      await tester.runAsync(() => store.clearAnalysis());
      final chapter = Chapter(
        'flow',
        '手势验收',
        pages: [flowImage!.path, '${directory.path}/${ids.last}.jpg'],
      );
      final book = Book('flow-071', 'local', '阅读操作验收', '', chapters: [chapter]);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(store: store, book: book, chapter: chapter),
        ),
      );
      final paintFinder = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is ComicPainter,
      );
      for (int i = 0; i < 100 && paintFinder.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(paintFinder, findsOneWidget);
      int prepared = 0;
      for (int i = 0; i < 200; i++) {
        prepared = (await tester.runAsync(
          () async =>
              Directory('${directory.path}/analysis')
                  .listSync()
                  .where((f) => f.path.endsWith('.json'))
                  .length,
        ))!;
        if (prepared >= 2) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(
        prepared,
        greaterThanOrEqualTo(2),
        reason: 'Next page must finish recognition while page one is still displayed',
      );
      expect(find.text('1/2'), findsOneWidget);

      ComicPainter painter() =>
          (tester.widget<CustomPaint>(paintFinder).painter as ComicPainter);
      expect(painter().single, true);
      expect(painter().beat.count, readingBeats(flowLayout!, true).first.count);
      expect(painter().beat.bubble, isNull);
      Future<void> reveal() async {
        final box = tester.renderObject<RenderBox>(paintFinder);
        await tester.tapAt(box.localToGlobal(Offset(2, box.size.height - 2)));
        await tester.pump();
      }

      expect(painter().beat.bubble, isNull);
      final panels = flowLayout['panels'] as List;
      final balloonPanel = panels.indexWhere(
        (p) => (p['bubbles'] as List).isNotEmpty,
      );
      expect(
        balloonPanel,
        greaterThanOrEqualTo(0),
        reason: 'Real dialogue sample must expose a selectable balloon',
      );
      while (painter().beat.count <= balloonPanel) {
        await reveal();
      }
      final active = painter();
      final render = tester.renderObject<RenderBox>(paintFinder);
      final viewport = ComicViewport(
        active.image,
        active.layout,
        active.beat,
        true,
        render.size,
      );
      final outline = polygon(panels[balloonPanel]['bubbles'][0]['polygon']);
      final bounds = outline.getBounds();
      Offset? inside;
      for (int y = 1; y < 20 && inside == null; y++) {
        for (int x = 1; x < 20; x++) {
          final point = Offset(
            bounds.left + bounds.width * x / 20,
            bounds.top + bounds.height * y / 20,
          );
          if (outline.contains(point)) {
            inside = point;
            break;
          }
        }
      }
      expect(inside, isNotNull);
      final tap = render.localToGlobal(
        Offset(
          viewport.dx + inside!.dx * viewport.scale,
          viewport.dy + inside.dy * viewport.scale,
        ),
      );
      await tester.tapAt(tap);
      await tester.pump();
      expect(painter().beat.bubble, isNotNull);
      await tester.tapAt(tap);
      await tester.pump();
      expect(painter().beat.bubble, isNull);
      await tester.tap(find.text('整页'));
      await tester.pump();
      expect(painter().single, false);
      expect(painter().beat.full, true);
      await tester.tap(find.text('逐格'));
      await tester.pump();
      expect(painter().single, true);
      final paintSize = tester.renderObject<RenderBox>(paintFinder).size;
      final before = ComicViewport(
        painter().image,
        painter().layout,
        painter().beat,
        true,
        paintSize,
      );
      while (!painter().beat.full) {
        await reveal();
        final now = ComicViewport(
          painter().image,
          painter().layout,
          painter().beat,
          true,
          paintSize,
        );
        expect(
          [now.scale, now.dx, now.dy],
          [before.scale, before.dx, before.dy],
        );
      }
      expect(find.text('1/2'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('1/2'), findsOneWidget);
      await tester.fling(
        find.byType(InteractiveViewer),
        const Offset(220, 0),
        800,
      );
      for (int i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        if (paintFinder.evaluate().isNotEmpty) break;
      }
      expect(find.text('2/2'), findsOneWidget);
      for (final direction in [
        const Offset(-220, 0),
        const Offset(0, -220),
        const Offset(0, 220),
      ]) {
        await tester.fling(find.byType(InteractiveViewer), direction, 800);
        for (int i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
          if (paintFinder.evaluate().isNotEmpty) break;
        }
        expect(find.text(direction.dy < 0 ? '2/2' : '1/2'), findsOneWidget);
      }

      await tester.runAsync(
        () => report.writeAsString(
          jsonEncode({
            'liveSources': results,
            'verticalNextPrevious': true,
            'tapOnlyBubble': true,
            'wholePageAndSinglePanel': true,
          }),
        ),
      );
      // ignore: avoid_print, prefer_interpolation_to_compose_strings
      print(
        'GEJIAN_INTEGRATION_RESULT ${jsonEncode({'liveSources': results, 'verticalNextPrevious': true, 'tapOnlyBubble': true, 'wholePageAndSinglePanel': true})}',
      );
      expect(
        await tester.runAsync(() => store.chapterReady(book, chapter)),
        true,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BookDetail(store: store, book: book),
        ),
      );
      for (
        int i = 0;
        i < 100 && find.byTooltip('已下载并识别完成').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(find.byTooltip('已下载并识别完成'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: BookDetail(store: store, book: opm!),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'zzzzmissing');
      await tester.pump();
      expect(find.textContaining('加载更多章节'), findsNothing);
      for (int i = 0; i < 1000 && opm.chapterOffset < opm.chapterTotal; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(opm.chapterOffset, opm.chapterTotal);
      await tester.pump();
      expect(find.text('没有匹配的章节'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: DiscoverPage(store: store, query: 'isekai'),
        ),
      );
      for (
        int i = 0;
        i < 300 && find.byType(BookGrid).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(tester.widget<BookGrid>(find.byType(BookGrid)).books.length, 30);
      await tester.tap(find.byTooltip('下一页搜索结果'));
      await tester.pump();
      for (
        int i = 0;
        i < 300 && find.byType(BookGrid).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(find.text('第 2 页 · 每页 30 本'), findsOneWidget);
      await tester.tap(find.byTooltip('上一页搜索结果'));
      await tester.pump();
      expect(find.text('第 1 页 · 每页 30 本'), findsOneWidget);
      await tester.pumpWidget(MaterialApp(home: LibraryHome(store: store)));
      await tester.pump();
      await tester.tap(find.text('发现'));
      await tester.pump();
      await tester.enterText(find.byType(SearchBar).last, 'isekai');
      await tester.pump();
      await tester.tap(find.text('书库'));
      await tester.pump();
      await tester.tap(find.text('发现'));
      await tester.pump();
      expect(find.text('isekai'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('我的书库'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
