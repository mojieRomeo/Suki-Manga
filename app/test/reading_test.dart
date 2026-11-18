import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/reader.dart';
import 'package:gejian/data.dart';

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gejian/screens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cover validation rejects a verification page and accepts a real image',
    () async {
      expect(
        await LibraryStore.validImage(
          utf8.encode('<html>Browser verification</html>'),
        ),
        false,
      );
      final bytes = await File(
        'test/fixtures/synthetic-page.png',
      ).readAsBytes();
      expect(await LibraryStore.validImage(bytes), true);
    },
  );
  test('legacy bubble steps migrate to the same panel', () {
    final layout = {
      'panels': [
        {
          'bubbles': [{}, {}],
        },
        {'bubbles': []},
      ],
    };
    expect(legacyPanelStep(layout, 0), 0);
    expect(legacyPanelStep(layout, 4), 0);
    expect(legacyPanelStep(layout, 5), 1);
    expect(legacyPanelStep(layout, 99), 1);
  });
  test(
    'native errors display their message without the PlatformException wrapper',
    () {
      expect(
        friendlyError(PlatformException(code: 'SOURCE', message: '已取消验证')),
        '已取消验证',
      );
    },
  );
  testWidgets(
    'entering discovery or switching an empty source does not open verification',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (call) async {
            calls.add(call.method);
            return null;
          });
      final store = LibraryStore(Directory.systemTemp, {});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DiscoverPage(store: store, embedded: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('输入漫画名称开始搜索'), findsOneWidget);
      await tester.tap(find.byTooltip('切换书源'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '拷贝漫画'),
      );
      await tester.pumpAndSettle();
      expect(find.text('在 拷贝漫画 中搜索漫画'), findsOneWidget);
      expect(find.text('输入漫画名称开始搜索'), findsOneWidget);
      expect(calls, isEmpty);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null);
    },
  );
  test('EPUB follows spine order instead of archive filenames', () {
    final archive = Archive();
    void add(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add(
      'META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    );
    add(
      'OPS/book.opf',
      '<package><manifest><item id="first" href="z.xhtml"/><item id="second" href="a.xhtml"/></manifest><spine><itemref idref="first"/><itemref idref="second"/></spine></package>',
    );
    add('OPS/z.xhtml', '<html><body><img src="images/2.jpg"/></body></html>');
    add('OPS/a.xhtml', '<html><body><img src="images/1.jpg"/></body></html>');
    add('OPS/images/1.jpg', 'one');
    add('OPS/images/2.jpg', 'two');
    expect(epubImages(archive).map((f) => f.name), [
      'OPS/images/2.jpg',
      'OPS/images/1.jpg',
    ]);
  });
  test('deleting chapter cache retains progress and other chapters', () async {
    final root = await Directory.systemTemp.createTemp('gejian-test');
    try {
      final s = LibraryStore(root, {});
      final a = Chapter('a', '第一章', pages: ['/a']),
          b = Chapter('b', '第二章', pages: ['/b']);
      final book = Book('book', 'md', '作品', '', chapters: [a, b]);
      await s.remember(book);
      await s.record(book, a, 0, 2);
      for (final ch in [a, b]) {
        final dir = s.chapterDir(book, ch);
        await dir.create(recursive: true);
        await File('${dir.path}/0.img').writeAsBytes([1, 2, 3]);
      }
      await s.deleteChapter(book, a);
      expect(await s.chapterDir(book, a).exists(), false);
      expect(await s.chapterDir(book, b).exists(), true);
      expect(s.progress(book)['step'], 2);
      final saved = jsonDecode(
        await File('${root.path}/library.json').readAsString(),
      );
      expect(saved['progress'][book.key]['chapter'], 'a');
    } finally {
      await root.delete(recursive: true);
    }
  });
  test('no reliable panels immediately displays original', () {
    final beats = readingBeats({'panels': []}, true);
    expect(beats.length, 1);
    expect(beats.single.full, true);
  });
  test('swiping advances panels without opening or closing bubbles', () {
    final beats = readingBeats({
      'panels': [
        {
          'bubbles': [
            {
              'polygon': [
                [1, 2],
                [3, 2],
                [2, 5],
              ],
            },
          ],
        },
        {'bubbles': []},
      ],
    }, true);
    expect(beats.map((b) => b.count).toList(), [1, 2]);
    expect(beats[1].bubble, isNull);
    expect(beats[0].bubble, isNull);
    expect(beats.last.full, true);
  });
  test('turning off bubbles keeps panel progression and full original', () {
    final beats = readingBeats({
      'panels': [
        {
          'bubbles': [
            {'polygon': []},
          ],
        },
        {'bubbles': []},
      ],
    }, false);
    expect(beats.length, 2);
    expect(beats.every((b) => b.bubble == null), true);
    expect(beats.last.full, true);
  });
  test('natural archive order places page 2 before page 10', () {
    final a = ['page10.png', 'page2.png', 'page1.png']..sort(naturalCompare);
    expect(a, ['page1.png', 'page2.png', 'page10.png']);
  });
}
