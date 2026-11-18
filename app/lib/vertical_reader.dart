import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'data.dart';

bool isVerticalComic(int width, int height) =>
    width > 0 && height / width >= 2.5;

/// An independent, unmasked reading surface for long strips.
class VerticalComicReader extends StatefulWidget {
  final int initialPage, pageCount;
  final ui.Image initialImage;
  final Future<File> Function(int) loadPage;
  final Future<Json> Function(File)? recognizeBubbles;
  final ValueChanged<int> onPageChanged;
  final Future<void> Function() onEnd;

  const VerticalComicReader({
    super.key,
    required this.initialPage,
    required this.pageCount,
    required this.initialImage,
    required this.loadPage,
    this.recognizeBubbles,
    required this.onPageChanged,
    required this.onEnd,
  });

  @override
  State<VerticalComicReader> createState() => _VerticalComicReaderState();
}

class _VerticalComicReaderState extends State<VerticalComicReader> {
  final center = GlobalKey();
  final viewport = GlobalKey();
  final pages = <int, GlobalKey>{};
  final files = <int, Future<File>>{};
  bool scheduled = false;

  Future<File> file(int index) => files.putIfAbsent(index, () async {
    try {
      return await widget.loadPage(index);
    } catch (_) {
      files.remove(index);
      rethrow;
    }
  });

  void warm(int index) {
    for (var i = index + 1; i < math.min(widget.pageCount, index + 4); i++) {
      unawaited(
        file(i).then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    warm(widget.initialPage);
  }

  void track() {
    if (scheduled) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (!mounted) return;
      final surface = viewport.currentContext?.findRenderObject() as RenderBox?;
      if (surface == null || !surface.hasSize) return;
      int? visible;
      double nearest = double.infinity;
      for (final entry in pages.entries) {
        final box =
            entry.value.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize || !box.attached) continue;
        final top = box.localToGlobal(Offset.zero, ancestor: surface).dy;
        if (top + box.size.height <= 0 || top >= surface.size.height) continue;
        final distance = top <= 0 ? 0.0 : top;
        if (distance < nearest) {
          nearest = distance;
          visible = entry.key;
        }
      }
      if (visible != null) {
        widget.onPageChanged(visible);
        warm(visible);
      }
    });
  }

  Widget strip(int index) => _StripPage(
    key: pages.putIfAbsent(index, GlobalKey.new),
    initialImage: index == widget.initialPage ? widget.initialImage : null,
    load: () => file(index),
    recognize: widget.recognizeBubbles,
    onReady: track,
  );

  @override
  Widget build(BuildContext context) => SafeArea(
    child: NotificationListener<ScrollNotification>(
      onNotification: (_) {
        track();
        return false;
      },
      child: CustomScrollView(
        key: viewport,
        center: center,
        slivers: [
          if (widget.initialPage > 0)
            SliverList.builder(
              itemCount: widget.initialPage,
              itemBuilder: (_, i) => strip(widget.initialPage - 1 - i),
            ),
          SliverList.builder(
            key: center,
            itemCount: widget.pageCount - widget.initialPage,
            itemBuilder: (_, i) => strip(widget.initialPage + i),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: TextButton(
                onPressed: widget.onEnd,
                child: const Text('本章已读完 · 下一章'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _StripPage extends StatefulWidget {
  final ui.Image? initialImage;
  final Future<File> Function() load;
  final Future<Json> Function(File)? recognize;
  final VoidCallback onReady;
  const _StripPage({
    super.key,
    this.initialImage,
    required this.load,
    required this.recognize,
    required this.onReady,
  });

  @override
  State<_StripPage> createState() => _StripPageState();
}

class _StripPageState extends State<_StripPage> {
  ui.Image? image;
  Object? error;
  final bubbles = <Path>[];
  Path? active;
  bool owned = false;

  @override
  void initState() {
    super.initState();
    image = widget.initialImage;
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final file = await widget.load();
      if (!mounted) return;
      if (image == null) {
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() {
          image = frame.image;
          owned = true;
          error = null;
        });
      }
      widget.onReady();
      // Detection supplies hit targets only. No panel masks, beats or gestures
      // from the ordinary manga reader are applied to this scrolling surface.
      if (widget.recognize != null) {
        try {
          final layout = await widget.recognize!(file);
          if (!mounted) return;
          for (final panel in layout['panels'] ?? []) {
            for (final bubble in panel['bubbles'] ?? []) {
              final points = bubble['polygon'] as List?;
              if (points == null || points.length < 3) continue;
              bubbles.add(
                Path()..addPolygon([
                  for (final p in points)
                    Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
                ], true),
              );
            }
          }
        } catch (_) {
          /* Reading remains available if detection fails. */
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  void dispose() {
    if (owned) image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = image;
    if (source == null) {
      return SizedBox(
        height: MediaQuery.sizeOf(context).height,
        child: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : TextButton(
                  onPressed: () {
                    setState(() => error = null);
                    unawaited(load());
                  },
                  child: const Text('加载失败，点击重试'),
                ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (_, constraints) {
        final scale = constraints.maxWidth / source.width;
        return GestureDetector(
          onTapUp: (event) {
            if (active != null) {
              setState(() => active = null);
              return;
            }
            final point = event.localPosition / scale;
            for (final bubble in bubbles) {
              if (bubble.contains(point)) {
                setState(() => active = bubble);
                break;
              }
            }
          },
          child: CustomPaint(
            painter: _StripPainter(source, active),
            size: Size(constraints.maxWidth, source.height * scale),
          ),
        );
      },
    );
  }
}

class _StripPainter extends CustomPainter {
  final ui.Image image;
  final Path? bubble;
  _StripPainter(this.image, this.bubble);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / image.width;
    canvas.scale(scale);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImage(image, Offset.zero, paint);
    final path = bubble;
    if (path == null) return;
    final bounds = path.getBounds();
    final zoom = math.min(1.4, (image.width - 16 / scale) / bounds.width);
    if (zoom <= 1) return;
    final halfWidth = bounds.width * zoom / 2;
    final x = bounds.center.dx.clamp(halfWidth, image.width - halfWidth);
    canvas.translate(x, bounds.center.dy);
    canvas.scale(zoom);
    canvas.translate(-bounds.center.dx, -bounds.center.dy);
    canvas.drawShadow(path, Colors.black38, 6 / scale, true);
    canvas.clipPath(path);
    canvas.drawImage(image, Offset.zero, paint);
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.image != image || old.bubble != bubble;
}
