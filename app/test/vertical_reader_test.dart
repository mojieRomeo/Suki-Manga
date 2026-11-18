import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/vertical_reader.dart';

void main() {
  test('long strips are distinct from portrait pages and spreads', () {
    expect(isVerticalComic(800, 3600), isTrue);
    expect(isVerticalComic(800, 1200), isFalse);
    expect(isVerticalComic(1600, 1200), isFalse);
    expect(isVerticalComic(0, 3600), isFalse);
  });

  testWidgets('long strip fits width and scrolls without turning the page', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 100, 600),
      Paint()..color = Colors.blue,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(100, 600);
    picture.dispose();
    var endCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VerticalComicReader(
            initialPage: 0,
            pageCount: 1,
            initialImage: image,
            loadPage: (_) async => File('unused-in-memory-page'),
            onPageChanged: (_) {},
            onEnd: () async {
              endCalls++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final painted = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_StripPainter',
    );
    final size = tester.getSize(painted);
    expect(size.width, 800);
    expect(size.height, 4800);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(painted).dy, lessThan(-400));
    expect(endCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    image.dispose();
  });

  testWidgets('scrolling strips retain bubble tap enlargement and collapse', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(100, 600);
    picture.dispose();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VerticalComicReader(
            initialPage: 0,
            pageCount: 1,
            initialImage: image,
            loadPage: (_) async => File('unused-in-memory-page'),
            recognizeBubbles: (_) async => {
              'panels': [
                {
                  'bubbles': [
                    {
                      'polygon': [
                        [40, 20],
                        [60, 20],
                        [60, 40],
                        [40, 40],
                      ],
                    },
                  ],
                },
              ],
            },
            onPageChanged: (_) {},
            onEnd: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final painted = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_StripPainter',
    );
    dynamic painter() => tester.widget<CustomPaint>(painted).painter;
    expect(painter().bubble, isNull);
    await tester.tapAt(const Offset(400, 240));
    await tester.pump();
    expect(painter().bubble, isNotNull);
    await tester.tapAt(const Offset(400, 240));
    await tester.pump();
    expect(painter().bubble, isNull);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(painted).dy, lessThan(0));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    image.dispose();
  });
}
