import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/reader.dart';
import 'package:gejian/data.dart';

void main() {
  testWidgets(
    'shared analysis task runs once and cached content bounds survive reuse',
    (t) async {
      int calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (call) async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return jsonEncode({'width': 1080, 'height': 1525, 'panels': []});
          });
      try {
        await t.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp('gejian-analysis-');
          try {
            final store = LibraryStore(dir, {});
            final image = File(
              'test/fixtures/synthetic-page.png',
            );
            final result = await Future.wait([
              store.recognize(image),
              store.recognize(image),
            ]);
            expect(calls, 1);
            expect(result.first['contentBounds'], isNotNull);
            await store.recognize(image);
            expect(calls, 1);
          } finally {
            await dir.delete(recursive: true);
          }
        });
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(native, null);
      }
    },
  );
  final a = [
    [0, 0],
    [100, 0],
    [100, 100],
    [0, 100],
  ];
  final b = [
    [0, 100],
    [100, 100],
    [100, 200],
    [0, 200],
  ];
  test('linked cross-frame balloon reveals both scenes together', () {
    final beats = readingBeats({
      'revealGroups': [
        [0, 1],
      ],
      'panels': [
        {
          'polygon': a,
          'bubbles': [
            {
              'polygon': [
                [30, 70],
                [70, 70],
                [70, 130],
                [30, 130],
              ],
            },
          ],
        },
        {'polygon': b, 'bubbles': []},
      ],
    }, true);
    expect(beats.map((b) => b.count), [2]);
    expect(beats.first.full, true);
    expect(beats.last.full, true);
  });
  testWidgets(
    'fixed canvas preserves revealed pixels and last reveal equals original',
    (t) async {
      await t.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final c = Canvas(recorder);
        c.drawRect(
          const Rect.fromLTWH(0, 0, 100, 100),
          Paint()..color = const Color(0xffff0000),
        );
        c.drawRect(
          const Rect.fromLTWH(0, 100, 100, 100),
          Paint()..color = const Color(0xff0000ff),
        );
        final image = await recorder.endRecording().toImage(100, 200);
        final centered = ComicViewport(
          image,
          {
            'contentBounds': [10, 0, 80, 200],
          },
          const Beat(1),
          true,
          const Size(200, 500),
        );
        final left = centered.dx + 10 * centered.scale;
        final right = 200 - (centered.dx + 90 * centered.scale);
        expect(left, closeTo(right, .00001));
        final layout = {
          'panels': [
            {'polygon': a, 'bubbles': []},
            {'polygon': b, 'bubbles': []},
          ],
        };
        final beats = readingBeats(layout, true);
        final first = ComicViewport(
          image,
          layout,
          beats.first,
          true,
          const Size(200, 500),
        );
        final last = ComicViewport(
          image,
          layout,
          beats.last,
          true,
          const Size(200, 500),
        );
        expect(
          [first.scale, first.dx, first.dy],
          [last.scale, last.dx, last.dy],
        );
        expect(first.scale, 1.9);
        expect(first.dx, 5);
        Future<List<int>> pixel(Beat beat, int x, int y) async {
          final r = ui.PictureRecorder();
          ComicPainter(
            image,
            layout,
            beat,
            single: true,
          ).paint(Canvas(r), const Size(200, 500));
          final out = await r.endRecording().toImage(200, 500);
          final data = await out.toByteData();
          final bytes = data!.buffer.asUint8List();
          final offset = (y * 200 + x) * 4;
          final rgba = bytes.sublist(offset, offset + 4);
          out.dispose();
          return rgba;
        }

        expect(await pixel(beats.first, 100, 100), [255, 0, 0, 255]);
        final edge = await pixel(beats.first, 5, 100);
        expect(
          edge,
          [255, 0, 0, 255],
          reason:
              'Reveal must preserve source pixels without adding synthetic ink',
        );
        expect(await pixel(beats.last, 5, 100), edge);
        expect(await pixel(beats.first, 100, 300), [255, 255, 255, 255]);
        expect(await pixel(beats.last, 100, 100), [255, 0, 0, 255]);
        expect(await pixel(beats.last, 100, 300), [0, 0, 255, 255]);
        expect(beats.last.full, true);
        image.dispose();
      });
    },
  );
}
