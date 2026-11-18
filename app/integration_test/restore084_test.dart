import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';

import 'fixture_data083.dart';
import 'acceptance_data084.dart';
import 'source_border085.dart';
import 'source_pages086.dart';
import 'stock_pages087.dart';
import 'source_pages088.dart';
import 'source_pages089.dart';
import 'source_pages090.dart';
import 'source_pages091.dart';

class GatedStore extends LibraryStore {
  final backgroundFiles = <String>{};
  Completer<void>? gate;
  Completer<void>? displayReady;
  GatedStore(super.root, super.state);
  @override
  Future<Json> prepareDisplay(File file, int width, int height) async {
    final result = await super.prepareDisplay(file, width, height);
    if (displayReady?.isCompleted == false) displayReady!.complete();
    return result;
  }

  @override
  Future<Json> recognize(File file, {bool background = false}) async {
    if (background) backgroundFiles.add(file.path);
    if (gate != null && !background) await gate!.future;
    return super.recognize(file, background: background);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('source frames, cumulative reveals, intact balloons and reader controls', (
    t,
  ) async {
    await binding.convertFlutterSurfaceToImage();
    final evidenceBase = (await native.invokeMethod<String>('directory'))!;
    final evidence = Directory('$evidenceBase/qa091-evidence');
    await evidence.create(recursive: true);
    Future<void> screenshot(String name) async {
      // Let Android present the rasterized frame before reading its surface.
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      final bytes = await binding.takeScreenshot(name);
      await File('${evidence.path}/$name.png').writeAsBytes(bytes);
      binding.reportData?.remove('screenshots');
    }

    final base = (await native.invokeMethod<String>('directory'))!;
    final root = Directory(
      '$base/qa084-${DateTime.now().millisecondsSinceEpoch}',
    );
    await root.create(recursive: true);
    final store = GatedStore(root, {});
    final results = <String, dynamic>{};
    final pages = {
      ...regressionPages,
      ...acceptancePages,
      ...sourceBorder085,
      ...sourcePages086,
      ...stockPages087,
      ...sourcePages088,
      ...sourcePages089,
      ...sourcePages090,
      ...sourcePages091,
    };
    for (final name in pages.keys) {
      debugPrint('QA088_PAGE $name');
      final file = File('${root.path}/$name');
      await file.writeAsBytes(base64Decode(pages[name]!));
      final layout = (await t.runAsync(() => store.recognize(file)))!;
      final panels = layout['panels'] as List;
      final beats = readingBeats(layout, true);
      final recoveredCount = {'shounin-28.jpg': 5, 'yuusha-21.jpg': 8}[name];
      if (recoveredCount != null) {
        expect(layout['completeRegions'], true, reason: name);
        expect(layout['wholePage'], false, reason: name);
        expect(panels.length, recoveredCount, reason: name);
        expect(
          beats.map((b) => b.count),
          List.generate(recoveredCount, (i) => i + 1),
          reason: name,
        );
      }
      if (name == 'mushoku-15.jpg') {
        expect(beats.map((b) => b.count), [1, 2, 5]);
      }
      if (name == 'mushoku-91-05.jpg') {
        expect(beats.map((b) => b.count), [2, 4, 5, 6]);
      }
      final expected086 = {
        'mushoku-04.jpg': 4,
        'mushoku-06.jpg': 4,
        'opm-02.jpg': 3,
        'opm-07.jpg': 5,
        'opm-15.jpg': 3,
      }[name];
      if (expected086 != null) {
        expect(panels.length, expected086, reason: name);
        expect(layout['wholePage'], false, reason: name);
        expect(
          beats.map((b) => b.count),
          List.generate(expected086, (i) => i + 1),
          reason: name,
        );
      }
      if (name.contains('gray') || name == 'reported-blue.png') {
        expect(panels.length, 3);
        expect(layout['wholePage'], false);
        expect(beats.length, 4);
      }
      if ((layout['stockPaths'] as List?)?.isNotEmpty == true) {
        expect(beats.first.count, 0, reason: name);
        expect((layout['stockTile'] as List).length, 4, reason: name);
        expect(
          beats.map((b) => b.count),
          List.generate(panels.length + 1, (i) => i),
          reason: name,
        );
      }
      if (name == 'yuusha-05.jpg' ||
          name.startsWith('reported-') &&
              [
                'pink',
                'green',
                'yellow',
                'darkpurple',
                'black',
                'blue',
              ].any(name.contains)) {
        expect((layout['stockPaths'] as List).isNotEmpty, true, reason: name);
      }
      if (name.contains('window')) {
        expect(panels.length, 2);
        expect(layout['wholePage'], false);
        expect(beats.length, 2);
      }
      if (name == 'actual-spread.jpg') {
        expect(layout['wholePage'], true);
        expect(beats.single.full, true);
      }
      if (name == 'actual-ambiguous.jpg') {
        expect(layout['uncertainGaps'], true);
        expect(beats.single.full, true);
      }
      if (name == 'user-slanted.png') {
        expect(beats.length, 2);
      }
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final image = (await codec.getNextFrame()).image;
      codec.dispose();
      final renderWidth = math.min(900, image.width);
      final renderHeight = (renderWidth * image.height / image.width).round();
      final size = Size(renderWidth.toDouble(), renderHeight.toDouble());
      final bounds = layout['contentBounds'] as List;
      final view = ComicViewport(image, layout, beats.first, true, size);
      final left = view.dx + (bounds[0] as num) * view.scale;
      final right =
          size.width -
          (view.dx + ((bounds[0] as num) + (bounds[2] as num)) * view.scale);
      expect(left, closeTo(right, .01));
      expect(view.dx, greaterThanOrEqualTo(-.01));
      expect(
        view.dx + image.width * view.scale,
        lessThanOrEqualTo(size.width + .01),
      );
      Future<List<int>> render(Beat beat, {bool original = false}) async {
        final recorder = ui.PictureRecorder();
        ComicPainter(
          image,
          original ? {...layout, 'completeRegions': false} : layout,
          beat,
          single: true,
        ).paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final out = await picture.toImage(renderWidth, renderHeight);
        picture.dispose();
        final bytes = (await out.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        out.dispose();
        return bytes;
      }

      final full = await render(
        Beat(panels.length, full: true),
        original: true,
      );
      if (layout['wholePage'] != true && panels.isNotEmpty) {
        final completed = await render(beats.last);
        expect(
          await render(Beat(panels.length)),
          completed,
          reason:
              '$name: completing the page must not reveal unassigned artwork',
        );
        int missing = 0, ink = 0;
        for (int k = 0; k < full.length; k += 4) {
          if (full[k] < 200 || full[k + 1] < 200 || full[k + 2] < 200) {
            ink++;
            if ((completed[k] - full[k]).abs() > 35 ||
                (completed[k + 1] - full[k + 1]).abs() > 35 ||
                (completed[k + 2] - full[k + 2]).abs() > 35) {
              missing++;
            }
          }
        }
        expect(
          missing / math.max(1, ink),
          lessThan(.015),
          reason:
              '$name: final region must complete source without full-page fallback ($missing/$ink)',
        );
      }
      if (beats.first.count == 0 && !beats.first.full) {
        final background = await render(beats.first);
        final c = int.parse(
          (layout['stockColor'] as String).substring(1),
          radix: 16,
        );
        final expected = [(c >> 16) & 255, (c >> 8) & 255, c & 255];
        for (final panel in panels) {
          final box = polygon(panel['polygon']).getBounds();
          final x = (view.dx + box.center.dx * view.scale).round();
          final y = (view.dy + box.center.dy * view.scale).round();
          for (int channel = 0; channel < 3; channel++) {
            double sum = 0;
            for (int dy = -12; dy < 12; dy++) {
              for (int dx = -12; dx < 12; dx++) {
                sum +=
                    background[((y + dy) * renderWidth + x + dx) * 4 + channel];
              }
            }
            expect(
              sum / 576,
              closeTo(expected[channel], 20),
              reason:
                  'Future panel must contain paper colour, not artwork: $name',
            );
          }
        }
        final x = (view.dx + 20 * view.scale).round();
        final y = (view.dy + 20 * view.scale).round();
        final p = (y * renderWidth + x) * 4;
        expect(
          background.sublist(p, p + 3),
          full.sublist(p, p + 3),
          reason:
              'Original stock pixels must retain their texture and colour: $name',
        );
      }
      final backgroundOnly = await render(const Beat(0));
      List<int>? previous;
      for (int i = 0; i < beats.length; i++) {
        final now = await render(beats[i]);
        if (name == 'thought-10.jpg') {
          expect(beats.map((b) => b.count), [1, 2, 3, 4, 5]);
          expect(layout['wholePage'], false);
          Future<void> verifyRegion(
            List<double> region,
            bool visible,
            Beat beat,
          ) async {
            final pixels = await render(beat);
            int sourceInk = 0, incorrect = 0;
            for (
              int y = (view.dy + region[1] * view.scale).ceil();
              y < view.dy + region[3] * view.scale;
              y++
            ) {
              for (
                int x = (view.dx + region[0] * view.scale).ceil();
                x < view.dx + region[2] * view.scale;
                x++
              ) {
                final p = (y * renderWidth + x) * 4;
                if (full[p] < 120 && full[p + 1] < 120 && full[p + 2] < 120) {
                  sourceInk++;
                  if (visible
                      ? (pixels[p] - full[p]).abs() > 2
                      : pixels[p] < 245) {
                    incorrect++;
                  }
                }
              }
            }
            expect(sourceInk, greaterThan(300));
            expect(
              incorrect,
              0,
              reason:
                  'thought-10 source region $region must be ${visible ? "complete" : "hidden"} at step ${beat.count}',
            );
          }

          await verifyRegion(
            [295, 795, 504, 1068],
            beats[i].count == 5,
            beats[i],
          );
          await verifyRegion(
            [205, 1070, 358, 1195],
            beats[i].count == 5,
            beats[i],
          );
          if (beats[i].count == 4) {
            await verifyRegion([525, 990, 750, 1080], true, beats[i]);
          }
          // Also check the left scene without the final full-page fallback.
          if (beats[i].count == 5) {
            await verifyRegion([295, 795, 504, 1068], true, const Beat(5));
            await verifyRegion([205, 1070, 358, 1195], true, const Beat(5));
          }
        }

        if (name.startsWith('rezero-')) {
          final isDoor = name == 'rezero-12.jpg';
          expect(layout['wholePage'], false, reason: name);
          expect(beats.map((b) => b.count), isDoor ? [1, 2] : [1, 2, 3]);
          final region = isDoor
              ? <double>[10, 90, 135, 470]
              : <double>[2, 448, 170, 650];
          Future<void> verifyOwnedRegion(Beat beat, bool visible) async {
            final pixels = await render(beat);
            int ink = 0, incorrect = 0;
            for (
              int y = (view.dy + region[1] * view.scale).ceil();
              y < view.dy + region[3] * view.scale;
              y++
            ) {
              for (
                int x = (view.dx + region[0] * view.scale).ceil();
                x < view.dx + region[2] * view.scale;
                x++
              ) {
                final p = (y * renderWidth + x) * 4;
                if (full[p] < 120 && full[p + 1] < 120 && full[p + 2] < 120) {
                  ink++;
                  if (visible
                      ? (pixels[p] - full[p]).abs() > 2
                      : pixels[p] < 245) {
                    incorrect++;
                  }
                }
              }
            }
            if (isDoor) {
              int borderInk = 0;
              for (
                int y = (view.dy + 1080 * view.scale).ceil();
                y < view.dy + 1130 * view.scale;
                y++
              ) {
                final sourceY = (y - view.dy) / view.scale;
                final borderX = 311 + (sourceY - 1080) * .16;
                for (
                  int x = (view.dx + (borderX - 3) * view.scale).ceil();
                  x < view.dx + (borderX + 3) * view.scale;
                  x++
                ) {
                  final p = (y * renderWidth + x) * 4;
                  if (full[p] < 120) {
                    borderInk++;
                    if (visible
                        ? (pixels[p] - full[p]).abs() > 2
                        : pixels[p] < 245) {
                      incorrect++;
                    }
                  }
                }
              }
              expect(borderInk, greaterThan(5));
            }
            expect(ink, greaterThan(300));
            expect(
              incorrect,
              0,
              reason:
                  '$name neighbouring source region must be '
                  '${visible ? "complete" : "hidden"} at step ${beat.count}',
            );
          }

          await verifyOwnedRegion(beats[i], beats[i].count == panels.length);
          if (beats[i].count == panels.length) {
            // The owning panel itself must contain the scene: full-page
            // fallback may not conceal missing source artwork.
            await verifyOwnedRegion(Beat(panels.length), true);
          }
        }

        if (beats[i].count > 0) {
          expect(
            List.generate(now.length ~/ 4, (p) => p * 4)
                .where(
                  (p) =>
                      now[p] < 150 &&
                      now[p + 1] < 150 &&
                      now[p + 2] < 150 &&
                      now[p] == full[p] &&
                      now[p + 1] == full[p + 1] &&
                      now[p + 2] == full[p + 2],
                )
                .length,
            greaterThan(100),
            reason: 'Every revealed step must show source artwork: $name/$i',
          );
        }
        if (previous != null) {
          int ink = 0, lost = 0;
          for (int p = 0; p < now.length; p += 4) {
            // Matching background pixels do not establish revealed artwork.
            if ((previous[p] != backgroundOnly[p] ||
                    previous[p + 1] != backgroundOnly[p + 1] ||
                    previous[p + 2] != backgroundOnly[p + 2]) &&
                previous[p] < 150 &&
                previous[p + 1] < 150 &&
                previous[p + 2] < 150 &&
                previous[p] == full[p] &&
                previous[p + 1] == full[p + 1] &&
                previous[p + 2] == full[p + 2]) {
              ink++;
              if ((now[p] - full[p]).abs() > 1 ||
                  (now[p + 1] - full[p + 1]).abs() > 1 ||
                  (now[p + 2] - full[p + 2]).abs() > 1) {
                lost++;
              }
            }
          }
          if (beats[i - 1].count > 0) expect(ink, greaterThan(100));
          expect(
            lost,
            0,
            reason: 'Revealed original pixels must remain at step $i on $name',
          );
        }
        previous = now;
        // Independently chosen source regions contain the missing original
        // frame strokes, the limb in the gutter, and disconnected sound text.
        final regions086 = <String, List<double>>{
          'mushoku-06.jpg': [3, 510, 405, 650, 438],
          'opm-15.jpg': [2, 800, 1295, 1450, 1430],
        };
        final region = regions086[name];
        if (region != null && i + 1 == region[0]) {
          int ink = 0, missing = 0;
          for (
            int y = (view.dy + region[2] * view.scale).ceil();
            y < view.dy + region[4] * view.scale;
            y++
          ) {
            for (
              int x = (view.dx + region[1] * view.scale).ceil();
              x < view.dx + region[3] * view.scale;
              x++
            ) {
              final p = (y * renderWidth + x) * 4;
              if (full[p] < 120 && full[p + 1] < 120 && full[p + 2] < 120) {
                ink++;
                if ((now[p] - full[p]).abs() > 2) missing++;
              }
            }
          }
          expect(ink, greaterThan(50), reason: 'Original ink region: $name');
          expect(
            missing,
            0,
            reason: 'Source objects must be intact before final reveal: $name',
          );
        }
        if (name == 'mushoku-04.jpg' && beats[i].count == 2) {
          int sampled = 0;
          for (int sx = 250; sx < 650; sx++) {
            final sy = 307 + (350 - 307) * (sx - 60) / 770;
            final x = (view.dx + sx * view.scale).round();
            final y = (view.dy + sy * view.scale).round();
            final p = (y * renderWidth + x) * 4;
            if (full[p] < 90 && full[p + 1] < 90 && full[p + 2] < 90) {
              sampled++;
              expect(
                now[p],
                greaterThan(245),
                reason: 'Future panel frame must stay hidden at $sx',
              );
            }
          }
          expect(sampled, greaterThan(100));
        }
        if (name == 'mushoku-04.jpg' && i == 2) {
          int ink = 0, missing = 0;
          for (final line in [
            [60.0, 307.0, 830.0, 350.0],
            [60.0, 674.0, 830.0, 736.0],
          ]) {
            for (int n = 0; n <= 770; n++) {
              // Sample the frame and its interior side. The exterior side
              // contains sound lettering belonging to the unrevealed panel.
              for (int dy = -4; dy <= 0; dy++) {
                final sx = line[0] + (line[2] - line[0]) * n / 770;
                final sy = line[1] + (line[3] - line[1]) * n / 770 + dy;
                final x = (view.dx + sx * view.scale).round();
                final y = (view.dy + sy * view.scale).round();
                final p = (y * renderWidth + x) * 4;
                if (full[p] < 90 && full[p + 1] < 90 && full[p + 2] < 90) {
                  ink++;
                  if ((now[p] - full[p]).abs() > 2) {
                    missing++;
                    debugPrint(
                      'FRAME_MISSING source=$sx,$sy screen=$x,$y sourceInk=${full[p]} rendered=${now[p]}',
                    );
                  }
                }
              }
            }
          }
          expect(ink, greaterThan(500));
          expect(
            missing,
            0,
            reason:
                'Both original slanted frame strokes must already be present',
          );
        }
        if (name.contains('gray') && beats[i].count == 1) {
          final view = ComicViewport(image, layout, beats[i], true, size);
          final paperX = (view.dx + 20 * view.scale).round();
          final paperY = (view.dy + 20 * view.scale).round();
          final paperPixel = (paperY * renderWidth + paperX) * 4;
          expect(
            now.sublist(paperPixel, paperPixel + 3),
            full.sublist(paperPixel, paperPixel + 3),
            reason: 'Original page stock must already be visible',
          );
          int black = 0, missing = 0;
          // Independently trace the entire original ink contour, not four spots.
          for (final point in originalGrayFrame) {
            final x = point[0], y = point[1];
            final sx = (view.dx + x * view.scale).round(),
                sy = (view.dy + y * view.scale).round();
            final p = (sy * renderWidth + sx) * 4;
            if (full[p] < 90 && full[p + 1] < 90 && full[p + 2] < 90) {
              black++;
              if ((now[p] - full[p]).abs() > 1 ||
                  (now[p + 1] - full[p + 1]).abs() > 1 ||
                  (now[p + 2] - full[p + 2]).abs() > 1) {
                missing++;
              }
            }
          }
          expect(
            black,
            greaterThan(500),
            reason: 'Test must sample the actual black frame',
          );
          expect(
            missing,
            0,
            reason: 'Reveal must keep the original black frame: $name',
          );
        }
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomPaint(
                painter: ComicPainter(image, layout, beats[i], single: true),
                size: Size.infinite,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        if (!name.contains('bubbles')) {
          await screenshot('$name-step-${i + 1}');
        }
      }
      if (name.contains('bubbles')) {
        List<dynamic>? bubble;
        for (final p in panels) {
          for (final b in p['bubbles'] as List) {
            if (polygon(b['polygon']).contains(const Offset(410, 510))) {
              bubble = b['polygon'];
            }
          }
        }
        expect(bubble, isNotNull);
        for (final point in [
          const Offset(410, 475),
          const Offset(410, 505),
          const Offset(410, 535),
          const Offset(410, 565),
          const Offset(540, 420),
          const Offset(540, 450),
          const Offset(540, 485),
          const Offset(540, 515),
          const Offset(540, 540),
        ]) {
          expect(
            polygon(bubble!).contains(point),
            true,
            reason: 'Missing dialogue at $point',
          );
        }
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomPaint(
                painter: ComicPainter(
                  image,
                  layout,
                  Beat(panels.length, full: true, bubble: bubble),
                ),
                size: Size.infinite,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        await screenshot('intact-central-balloon');
      }
      results[name] = {
        'panels': panels.length,
        'steps': beats.length,
        'wholePage': layout['wholePage'],
        'contentBounds': layout['contentBounds'],
        'leftRightGap': [left, right],
        'pixelChecks': 'passed',
      };
      await t.pumpWidget(const SizedBox());
      await t.pump();
      image.dispose();
    }
    // Hold analysis back deliberately to observe the true first visible frame.
    // Geometry still comes from the production decoder and real model results.
    Finder visibleScene() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ComicPainter,
    );
    for (final mode in ['page', 'panel']) {
      for (final name in [
        'reported-original-gray.jpg',
        'reported-blue.png',
        'reported-black.png',
        'actual-spread.jpg',
      ]) {
        store.state['readerMode'] = mode;
        store.gate = Completer<void>();
        store.displayReady = Completer<void>();
        final chapter = Chapter(
          'first-$mode-$name',
          '首次显示',
          pages: ['${root.path}/$name'],
        );
        final book = Book(
          'first-$mode-$name',
          'local',
          '首次居中',
          '',
          chapters: [chapter],
        );
        await t.pumpWidget(
          MaterialApp(
            home: ReaderPage(store: store, book: book, chapter: chapter),
          ),
        );
        await t.runAsync(
          () => store.displayReady!.future.timeout(const Duration(seconds: 20)),
        );
        await t.pump();
        List<double>? initial;
        List<double> geometry() {
          final paint =
              t.widget<CustomPaint>(visibleScene().first).painter!
                  as ComicPainter;
          final size = t.getSize(visibleScene().first);
          final v = ComicViewport(
            paint.image,
            paint.layout,
            paint.beat,
            paint.single,
            size,
          );
          final bounds = paint.layout['contentBounds'] as List;
          expect(
            v.dx + (bounds[0] as num) * v.scale,
            closeTo(
              size.width -
                  v.dx -
                  ((bounds[0] as num) + (bounds[2] as num)) * v.scale,
              .01,
            ),
          );
          return [v.dx, v.dy, v.scale];
        }

        if (mode == 'page') {
          expect(visibleScene(), findsOneWidget);
          initial = geometry();
          await screenshot('first-$mode-$name');
        } else {
          expect(
            visibleScene(),
            findsNothing,
            reason: 'Panel mode must not flash the whole page before analysis',
          );
        }
        store.gate!.complete();
        for (int i = 0; i < 150; i++) {
          await t.pump(const Duration(milliseconds: 100));
          if (visibleScene().evaluate().isNotEmpty &&
              (t.widget<CustomPaint>(visibleScene().first).painter!
                          as ComicPainter)
                      .layout['panels'] !=
                  null) {
            break;
          }
        }
        expect(visibleScene(), findsOneWidget);
        initial ??= geometry();
        for (int i = 0; i < 12; i++) {
          expect(
            geometry(),
            initial,
            reason: 'Visible page moved after loading: $mode/$name',
          );
          await t.pump(const Duration(milliseconds: 16));
        }
        await screenshot('settled-$mode-$name');
        await t.pumpWidget(const SizedBox());
        await t.pump();
        store.gate = null;
        store.displayReady = null;
      }
    }
    // Keep inference pending while exercising the real Android loading screen.
    store.state['readerMode'] = 'panel';
    store.gate = Completer<void>();
    final waitPaths = regressionPages.keys
        .take(3)
        .map((n) => '${root.path}/$n')
        .toList();
    final waitChapter = Chapter('loading087', '加载翻页', pages: waitPaths);
    final waitBook = Book(
      'loading087',
      'local',
      '加载翻页',
      '',
      chapters: [waitChapter],
    );
    await t.pumpWidget(
      MaterialApp(
        home: ReaderPage(store: store, book: waitBook, chapter: waitChapter),
      ),
    );
    for (final move in [
      const Offset(0, 180),
      const Offset(0, -180),
      const Offset(180, 0),
      const Offset(-180, 0),
    ]) {
      for (
        int i = 0;
        i < 50 && find.byType(CircularProgressIndicator).evaluate().isEmpty;
        i++
      ) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.drag(find.byType(CircularProgressIndicator), move);
      await t.pump(const Duration(milliseconds: 100));
      expect(
        find.text(move.dx > 0 || move.dy > 0 ? '2/3' : '1/3'),
        findsOneWidget,
      );
    }
    await t.pumpWidget(const SizedBox());
    store.gate!.complete();
    store.gate = null;
    await t.pump(const Duration(milliseconds: 100));
    store.state['readerMode'] = 'panel';
    // Exercise the actual ReaderPage: bubbles disabled must still allow reveals.
    final paths = regressionPages.keys.map((n) => '${root.path}/$n').toList();
    final chapter = Chapter('qa', '原图回归', pages: paths);
    final book = Book('qa', 'local', '原图回归', '', chapters: [chapter]);
    store.state['bubbles'] = false;
    await t.pumpWidget(
      MaterialApp(
        home: ReaderPage(store: store, book: book, chapter: chapter),
      ),
    );
    Finder scene() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is ComicPainter,
    );
    Future<ComicPainter> ready() async {
      for (int i = 0; i < 150; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (scene().evaluate().isNotEmpty) {
          return t.widget<CustomPaint>(scene().first).painter! as ComicPainter;
        }
      }
      fail('Reader failed to load');
    }

    var painter = await ready();
    for (int i = 0; i < 150 && !store.backgroundFiles.contains(paths[1]); i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(
      store.backgroundFiles,
      contains(paths[1]),
      reason: 'Following pages must be analysed in the background while page one is visible',
    );
    final initial = painter.beat.count;
    await t.drag(scene().first, const Offset(0, 180));
    await t.pump(const Duration(milliseconds: 200));
    painter = await ready();
    expect(
      painter.beat.count,
      greaterThan(initial),
      reason: 'Vertical swipe must reveal the next panel on the same page',
    );
    final oldImage = painter.image;
    await t.drag(scene().first, const Offset(0, 180));
    await t.pump(const Duration(milliseconds: 200));
    painter = await ready();
    if (initial == 0) {
      expect(painter.beat.count, 2);
      await t.drag(scene().first, const Offset(0, 180));
      await t.pump(const Duration(milliseconds: 200));
      painter = await ready();
    }
    expect(painter.image, same(oldImage));
    expect(
      painter.beat.full,
      true,
      reason:
          'The last reveal must show the complete source page before turning',
    );
    expect(store.progress(book)['page'], 0);
    await screenshot('reader-complete-before-turn');
    await t.drag(scene().first, const Offset(0, 180));
    for (int i = 0; i < 100; i++) {
      await t.pump(const Duration(milliseconds: 100));
      if (store.progress(book)['page'] == 1 && scene().evaluate().isNotEmpty) {
        break;
      }
    }
    expect((await ready()).image, isNot(same(oldImage)));
    expect(store.progress(book)['page'], 1);
    await screenshot('reader-after-swipe');
    Future<void> swipe(Offset delta, int page) async {
      await t.drag(scene().first, delta);
      for (int i = 0; i < 100; i++) {
        await t.pump(const Duration(milliseconds: 100));
        if (store.progress(book)['page'] == page &&
            scene().evaluate().isNotEmpty) {
          break;
        }
      }
      await ready();
      expect(store.progress(book)['page'], page);
    }

    await swipe(const Offset(0, -180), 0);
    await swipe(const Offset(180, 0), 1);
    await swipe(const Offset(-180, 0), 0);
    await swipe(const Offset(180, 0), 1);
    await t.tap(find.text('整页'));
    await t.pump(const Duration(milliseconds: 100));
    expect((await ready()).single, false);
    expect(store.state['readerMode'], 'page');
    await t.tap(find.text('逐格'));
    await t.pump(const Duration(milliseconds: 100));
    expect((await ready()).single, true);
    expect(store.state['readerMode'], 'panel');
    await swipe(const Offset(180, 0), 2);
    final pageBeforePinch = store.progress(book)['page'];
    final center = t.getCenter(scene().first);
    final finger1 = await t.startGesture(
      center - const Offset(35, 0),
      pointer: 1,
    );
    final finger2 = await t.startGesture(
      center + const Offset(35, 0),
      pointer: 2,
    );
    await finger1.moveTo(center - const Offset(75, 0));
    await finger2.moveTo(center + const Offset(75, 0));
    await t.pump(const Duration(milliseconds: 100));
    await finger1.up();
    await finger2.up();
    await t.pump(const Duration(milliseconds: 100));
    expect(store.progress(book)['page'], pageBeforePinch);
    final viewer = t.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(
      viewer.transformationController!.value.getMaxScaleOnAxis(),
      greaterThan(1),
    );
    viewer.transformationController!.value =
        viewer.transformationController!.value.clone()..setIdentity();
    await t.pump();
    store.state['bubbles'] = true;
    painter = await ready();
    final renderBox = t.renderObject<RenderBox>(scene().first);
    final viewport = ComicViewport(
      painter.image,
      painter.layout,
      painter.beat,
      painter.single,
      renderBox.size,
    );
    final target = renderBox.localToGlobal(
      Offset(
        viewport.dx + 410 * viewport.scale,
        viewport.dy + 510 * viewport.scale,
      ),
    );
    await t.tapAt(target);
    await t.pump(const Duration(milliseconds: 150));
    expect((await ready()).beat.bubble, isNotNull);
    await screenshot('reader-balloon-expanded');
    await t.tapAt(target);
    await t.pump(const Duration(milliseconds: 150));
    expect((await ready()).beat.bubble, isNull);
    await swipe(const Offset(-180, 0), 1);

    await t.pumpWidget(const SizedBox());
    await t.pump();
    final progress = store.progress(book);
    expect(progress['flowVersion'], 2);
    expect(progress['page'], 1);
    await t.pumpWidget(
      MaterialApp(
        home: ReaderPage(store: store, book: book, chapter: chapter),
      ),
    );
    await ready();
    expect(store.progress(book)['page'], 1);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    for (final name in [...sourcePages086.keys, ...sourcePages088.keys]) {
      final source = '${root.path}/$name';
      final exactChapter = Chapter(
        'qa086-$name',
        name,
        pages: [source, '${root.path}/reported-original-gray.jpg'],
      );
      final exactBook = Book(
        'qa086-$name',
        'local',
        name,
        '',
        chapters: [exactChapter],
      );
      store.state['bubbles'] = false;
      store.state['readerMode'] = 'panel';
      await t.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            store: store,
            book: exactBook,
            chapter: exactChapter,
          ),
        ),
      );
      final first = await ready();
      final counts =
          {
            'mushoku-15.jpg': [1, 2, 5],
            'mushoku-91-05.jpg': [2, 4, 5, 6],
          }[name] ??
          List.generate(
            {
              'mushoku-04.jpg': 4,
              'mushoku-06.jpg': 4,
              'opm-02.jpg': 3,
              'opm-07.jpg': 5,
              'opm-15.jpg': 3,
            }[name]!,
            (i) => i + 1,
          );
      expect(first.beat.count, counts.first, reason: name);
      expect(first.beat.full, false, reason: name);
      for (int step = 1; step < counts.length; step++) {
        await t.drag(scene().first, const Offset(0, 180));
        await t.pump(const Duration(milliseconds: 200));
        final next = await ready();
        expect(
          next.image,
          same(first.image),
          reason: '$name/$step must stay on this page',
        );
        expect(
          next.beat.count,
          counts[step],
          reason: '$name must reveal exactly one panel per swipe',
        );
        expect(next.beat.full, step == counts.length - 1, reason: name);
        expect(store.progress(exactBook)['page'], 0);
        await screenshot('swipe-$name-$step');
      }
      await t.drag(scene().first, const Offset(0, 180));
      for (int wait = 0; wait < 150; wait++) {
        await t.pump(const Duration(milliseconds: 100));
        if (store.progress(exactBook)['page'] == 1 &&
            scene().evaluate().isNotEmpty) {
          break;
        }
      }
      expect(store.progress(exactBook)['page'], 1);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    }
    await File('${evidence.path}/results.json')
        .writeAsString(jsonEncode(results));
    binding.reportData = {
      'pixelChecks': results,
      'evidenceDirectory': evidence.path,
    };
    debugPrint('QA084_RESULTS ${jsonEncode(results)}');
  });
}
