import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'fixture_data083.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'reported source pages, complete joined balloons and original navigation',
    (t) async {
      await binding.convertFlutterSurfaceToImage();
      final base = (await native.invokeMethod<String>('directory'))!;
      final root = Directory('$base/regression-083-final');
      await root.create(recursive: true);
      final store = LibraryStore(root, {});
      final records = <String, dynamic>{};
      for (final name in [
        'reported-original-gray.jpg',
        'reported-original-window.jpg',
        'reported-original-bubbles.jpg',
      ]) {
        final source = File('${root.path}/$name');
        await source.writeAsBytes(base64Decode(regressionPages[name]!));
        final layout = await t.runAsync(() => store.recognize(source));
        expect(layout, isNotNull);
        final panels = layout!['panels'] as List;
        records[name] = {
          'panels': panels.length,
          'wholePage': layout['wholePage'],
          'bubbles': layout['bubbleCount'],
        };
        if (name.contains('gray')) {
          expect(panels.length, 3);
          expect(
            layout['wholePage'],
            false,
            reason: 'Grey stock must support actual panel steps',
          );
        }
        if (name.contains('window')) expect(panels.length, 2);
        final bytes = await t.runAsync(source.readAsBytes);
        final codec = await ui.instantiateImageCodec(bytes!);
        final image = (await codec.getNextFrame()).image;
        codec.dispose();
        List<dynamic>? balloon;
        if (name.contains('bubbles')) {
          for (final panel in panels) {
            for (final b in panel['bubbles'] as List) {
              final outline = polygon(b['polygon']);
              if (outline.contains(const Offset(410, 510))) {
                balloon = b['polygon'];
              }
            }
          }
          expect(
            balloon,
            isNotNull,
            reason: 'Reported central joined balloon must remain magnifiable',
          );
          final outline = polygon(balloon!);
          // All six lines in the left lobe and seven lines in the right lobe.
          for (final p in [
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
              outline.contains(p),
              true,
              reason: 'Dialogue must remain inside the outline: $p',
            );
          }
        }
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CustomPaint(
                painter: ComicPainter(
                  image,
                  layout,
                  Beat(
                    panels.length,
                    full: !name.contains('gray'),
                    bubble: balloon,
                  ),
                ),
                size: Size.infinite,
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final screenshot = await binding.takeScreenshot(name);
        await File('${root.path}/$name.png').writeAsBytes(screenshot);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.pump();
        image.dispose();
      }
      expect(swipePageDelta(const Offset(0, -180)), 1);
      expect(swipePageDelta(const Offset(180, 0)), 1);
      expect(swipePageDelta(const Offset(0, 180)), -1);
      expect(swipePageDelta(const Offset(-180, 0)), -1);
      await File('$base/regression-083-final/result.json')
          .writeAsString(jsonEncode(records));
    },
  );
}
