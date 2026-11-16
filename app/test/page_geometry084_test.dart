import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';

void main() {
  test('reading columns stay together in both reading directions', () {
    final panels = [
      {
        'id': 'bottom',
        'box': [10, 510, 790, 300],
      },
      {
        'id': 'left',
        'box': [10, 10, 380, 480],
      },
      {
        'id': 'right-bottom',
        'box': [410, 270, 390, 220],
      },
      {
        'id': 'right-top',
        'box': [410, 10, 390, 240],
      },
    ];
    expect(orderReadingPanels(panels, rtl: true).map((p) => p['id']), [
      'right-top',
      'right-bottom',
      'left',
      'bottom',
    ]);
    expect(orderReadingPanels(panels, rtl: false).map((p) => p['id']), [
      'left',
      'right-top',
      'right-bottom',
      'bottom',
    ]);
    expect(panels.first['id'], 'bottom');
  });
  testWidgets(
    'centering keeps every source edge and stays fixed through reveals',
    (t) async {
      await t.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.pink, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(200, 300);
        picture.dispose();
        final layout = <String, dynamic>{
          'contentBounds': [40, 0, 140, 300],
        };
        final first = ComicViewport(
          image,
          layout,
          const Beat(1),
          true,
          const Size(400, 400),
        );
        final last = ComicViewport(
          image,
          layout,
          const Beat(3, full: true),
          true,
          const Size(400, 400),
        );
        expect(
          first.dx + 40 * first.scale,
          closeTo(400 - (first.dx + 180 * first.scale), .001),
        );
        expect(first.dx, greaterThanOrEqualTo(0));
        expect(first.dx + 200 * first.scale, lessThanOrEqualTo(400));
        expect(
          [first.dx, first.dy, first.scale],
          [last.dx, last.dy, last.scale],
        );
        image.dispose();
      });
    },
  );
  for (final stock in [
    const [255, 255, 255],
    const [0, 0, 0],
    const [150, 150, 150],
    const [190, 130, 170],
  ]) {
    test('asymmetric margins are measured against RGB stock $stock', () {
      const width = 200, height = 300;
      final pixels = Uint8List(width * height * 4);
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final i = (y * width + x) * 4;
          final ink = x >= 40 && x <= 179 && y >= 20 && y <= 279;
          for (int c = 0; c < 3; c++) {
            pixels[i + c] = ink ? (stock[0] < 45 ? 230 : 15) : stock[c];
          }
          pixels[i + 3] = 255;
        }
      }
      final bounds = LibraryStore.contentExtent(pixels, width, height);
      expect(bounds[0], closeTo(40, 4));
      expect(bounds[0] + bounds[2], closeTo(180, 4));
      expect(bounds[2], lessThan(160));
    });
  }
  test('wide spread is complete regardless of detected panel count', () {
    for (final count in [0, 1, 2, 3, 6]) {
      final layout = <String, dynamic>{
        'width': 1600,
        'height': 1000,
        'panels': List.generate(
          count,
          (i) => {
            'box': [i * 200, 0, 180, 800],
            'polygon': [
              [i * 200, 0],
              [i * 200 + 180, 0],
              [i * 200 + 180, 800],
              [i * 200, 800],
            ],
            'source': 'closed-source-frame',
            'bubbles': [],
          },
        ),
      };
      LibraryStore.groupArtwork(layout);
      expect(layout['wideSpread'], true);
      expect(layout['wholePage'], true);
      expect(readingBeats(layout, true).single.full, true);
    }
  });
  test('unverified boundaries remain a full-page view', () {
    final layout = <String, dynamic>{
      'width': 900,
      'height': 1300,
      'panels': [
        {
          'box': [10, 10, 850, 500],
          'source': 'detector-container',
          'bubbles': [],
        },
      ],
    };
    LibraryStore.groupArtwork(layout);
    expect(layout['uncertainGaps'], true);
    expect(readingBeats(layout, true).single.full, true);
  });
}
