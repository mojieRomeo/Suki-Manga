import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/services.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'data.dart';
import 'screens.dart';

int swipePageDelta(Offset delta) {
  if (delta.distance < 50) return 0;
  if (delta.dx.abs() > delta.dy.abs() * 1.3) return delta.dx > 0 ? 1 : -1;
  if (delta.dy.abs() > delta.dx.abs() * 1.3) return delta.dy > 0 ? 1 : -1;
  return 0;
}

// During loading, swipes navigate pages rather than advancing panel reveals.
int loadingPageDelta(Offset delta) => swipePageDelta(delta);

class Beat {
  final int count;
  final List<dynamic>? bubble;
  final bool full;
  const Beat(this.count, {this.bubble, this.full = false});
}

// Separate full rows before columns, so a tall frame next to several short
// frames stays in the same reading column. Never mutate the cached layout.
List<dynamic> orderReadingPanels(List<dynamic> panels, {required bool rtl}) {
  if (panels.length < 2) return List<dynamic>.from(panels);
  for (final axis in [1, 0]) {
    final sorted = List<dynamic>.from(
      panels,
    )..sort((a, b) => (a['box'][axis] as num).compareTo(b['box'][axis] as num));
    double bestGap = double.negativeInfinity;
    int split = -1;
    for (int i = 1; i < sorted.length; i++) {
      double end = double.negativeInfinity;
      double start = double.infinity, smallest = double.infinity;
      for (int j = 0; j < sorted.length; j++) {
        final box = sorted[j]['box'] as List;
        final origin = (box[axis] as num).toDouble();
        final extent = (box[axis + 2] as num).toDouble();
        smallest = math.min(smallest, extent);
        if (j < i) {
          end = math.max(end, origin + extent);
        } else {
          start = math.min(start, origin);
        }
      }
      final gap = start - end;
      if (gap >= -smallest * .2 && gap > bestGap) {
        bestGap = gap;
        split = i;
      }
    }
    if (split > 0) {
      final first = orderReadingPanels(sorted.sublist(0, split), rtl: rtl);
      final second = orderReadingPanels(sorted.sublist(split), rtl: rtl);
      return axis == 0 && rtl ? [...second, ...first] : [...first, ...second];
    }
  }
  return List<dynamic>.from(panels)..sort((a, b) {
    final aa = a['box'] as List, bb = b['box'] as List;
    return (aa[1] as num).compareTo(bb[1] as num);
  });
}

List<Beat> readingBeats(Json layout, bool bubbles) {
  final panels = layout['panels'] as List? ?? [];
  if (panels.isEmpty ||
      layout['wholePage'] == true ||
      ((layout['width'] as num? ?? 0) / (layout['height'] as num? ?? 1) >=
          1.1)) {
    return [Beat(panels.length, full: true)];
  }
  // The native masks retain each complete balloon and protruding artwork.
  // Linked artwork is revealed as one cumulative reading step.
  final beats = [
    if ((layout['stockPaths'] as List?)?.isNotEmpty == true) const Beat(0),
    for (int i = 0; i < panels.length; i++)
      if (!(layout['revealGroups'] as List? ?? []).any(
        (g) => (g as List).first <= i && i < g.last,
      ))
        Beat(i + 1, full: i == panels.length - 1),
  ];

  return beats;
}

int legacyPanelStep(Json layout, int oldStep) {
  final panels = layout['panels'] as List? ?? [];
  if (panels.isEmpty) return 0;
  int index = 0;
  for (int i = 0; i < panels.length; i++) {
    final length = 1 + 2 * ((panels[i]['bubbles'] as List?)?.length ?? 0);
    if (oldStep < index + length) return i;
    index += length;
  }
  return panels.length - 1;
}

class ReaderPage extends StatefulWidget {
  final LibraryStore store;
  final Book book;
  final Chapter chapter;
  const ReaderPage({
    super.key,
    required this.store,
    required this.book,
    required this.chapter,
  });
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  ui.Image? image;
  Json layout = {};
  Object? error;
  bool loading = true, analyzing = false, original = false, controls = true;
  int page = 0, step = 0, ticket = 0;
  late Chapter chapter;
  List<Beat> beats = [const Beat(0, full: true)];
  final transform = TransformationController();
  double drag = 0;
  bool single = true;
  List<dynamic>? activeBubble;
  Offset? pointerStart;
  final Set<int> pointers = {};
  bool multiple = false;
  Size viewSize = Size.zero;
  Offset busyDrag = Offset.zero;
  bool busyGesture = false;
  void tapBubble(Offset local) {
    if (image == null || loading || analyzing) {
      return;
    }
    final scene = MatrixUtils.transformPoint(
      Matrix4.inverted(transform.value),
      local,
    );
    final viewport = ComicViewport(
      image!,
      layout,
      beats[step],
      single,
      viewSize,
    );
    final point = viewport.sourcePoint(scene);
    final panels = layout['panels'] as List? ?? [];
    final visible = single ? panels.take(beats[step].count) : panels;
    List<dynamic>? hit;
    for (final p in visible) {
      if (!widget.store.setting('bubbles', true)) continue;
      for (final b in p['bubbles'] ?? []) {
        final poly = b['polygon'] as List;
        if (polygon(poly).contains(point)) hit = poly;
      }
    }
    if (hit == null &&
        activeBubble == null &&
        single &&
        step < beats.length - 1) {
      setState(() => step++);
      unawaited(record());
      return;
    }
    setState(() => activeBubble = identical(hit, activeBubble) ? null : hit);
  }

  Future<void> mode(bool value) async {
    setState(() {
      single = value;
      original = !value;
      activeBubble = null;
    });
    transform.value = Matrix4.identity();
    await widget.store.setSetting('readerMode', value ? 'panel' : 'page');
  }

  bool preparing = false;
  int preparedThrough = -1;
  String? preparedChapter;
  int lookahead = 3;
  double inferenceMs = 1500, readingMs = 5000;
  DateTime? openedAt;
  Future<void> prepareAhead() async {
    if (preparing || !mounted || loading || analyzing) return;
    if (preparedChapter != chapter.id) {
      preparedThrough = -1;
      preparedChapter = chapter.id;
    }
    preparing = true;
    final targetChapter = chapter;
    final prepareTicket = ticket;
    try {
      while (mounted &&
          !loading &&
          !analyzing &&
          identical(chapter, targetChapter)) {
        final base = page;
        final end = math.min(chapter.pages.length - 1, base + lookahead);
        final candidates = [
          for (int i = math.max(base + 1, preparedThrough + 1); i <= end; i++)
            i,
        ];
        if (candidates.isEmpty) break;
        // Two download slots; one inference at a time, nearest page first.
        for (int i = 0; i < candidates.length; i += 2) {
          final batch = candidates.skip(i).take(2).toList();
          await Future.wait(
            batch.map(
              (index) => widget.store.page(widget.book, targetChapter, index),
            ),
          );
          for (final index in batch) {
            if (!mounted ||
                loading ||
                analyzing ||
                !identical(chapter, targetChapter)) {
              return;
            }
            if (index <= page) continue;
            final file = await widget.store.page(
              widget.book,
              targetChapter,
              index,
            );
            final watch = Stopwatch()..start();
            await widget.store.recognize(file, background: true);
            inferenceMs = inferenceMs * .7 + watch.elapsedMilliseconds * .3;
            preparedThrough = index;
          }
        }
      }
    } catch (_) {
      // Speculative work must never replace the current page with an error.
    } finally {
      preparing = false;
      if (mounted && prepareTicket != ticket && !loading && !analyzing) {
        unawaited(prepareAhead());
      }
    }
  }

  String? analysisError;
  @override
  void initState() {
    super.initState();
    chapter = widget.chapter;
    single = widget.store.state['readerMode'] != 'page';
    original = !single;
    final p = widget.store.progress(widget.book);
    if (p['chapter'] == chapter.id) {
      page = ((p['page'] ?? 0) as int).clamp(0, chapter.pages.length - 1);
      step = p['step'] ?? 0;
    }
    native.invokeMethod('awake', widget.store.setting('awake', true));
    load(page, restore: step, legacy: p['flowVersion'] != 2);
  }

  @override
  void dispose() {
    ticket++;
    native.invokeMethod('awake', false);
    image?.dispose();
    transform.dispose();
    super.dispose();
  }

  Future<void> load(
    int index, {
    int restore = 0,
    bool last = false,
    bool legacy = false,
  }) async {
    final now = DateTime.now();
    if (openedAt != null) {
      readingMs =
          readingMs * .7 +
          now.difference(openedAt!).inMilliseconds.clamp(500, 60000) * .3;
      lookahead = (inferenceMs / readingMs * 3 + 2).ceil().clamp(2, 5);
    }
    openedAt = now;
    final t = ++ticket;
    setState(() {
      loading = true;
      analyzing = false;
      error = null;
      analysisError = null;
      page = index;
      step = 0;
      original = !single;
      activeBubble = null;
    });
    transform.value = Matrix4.identity();
    try {
      final currentFile = widget.store.page(widget.book, chapter, index);
      // Warm later downloads even while the current page is still downloading.
      final warmChapter = chapter;
      for (
        int ahead = 1;
        ahead <= lookahead && index + ahead < warmChapter.pages.length;
        ahead++
      ) {
        unawaited(
          widget.store
              .page(widget.book, warmChapter, index + ahead)
              .then((_) {}, onError: (Object e) {}),
        );
      }
      final file = await currentFile;
      if (!mounted || t != ticket) return;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      Json display;
      try {
        display = await widget.store.prepareDisplay(
          file,
          frame.image.width,
          frame.image.height,
        );
      } catch (_) {
        frame.image.dispose();
        rethrow;
      }
      if (!mounted || t != ticket) {
        frame.image.dispose();
        return;
      }
      image?.dispose();
      setState(() {
        image = frame.image;
        layout = display;
        beats = [const Beat(0, full: true)];
        loading = false;
        analyzing = true;
      });
      if (analyzing) {
        try {
          final data = await widget.store.recognize(file);
          if (!mounted || t != ticket) return;
          // Display geometry belongs to this decoded page. Inference and cached
          // layouts must not change its position after the first visible frame.
          final resolved = Map<String, dynamic>.from(data)..addAll(display);
          if (!widget.store.setting('rtl', true)) {
            resolved['panels'] = orderReadingPanels(
              List<dynamic>.from(data['panels'] ?? []),
              rtl: false,
            );
            LibraryStore.groupArtwork(resolved);
          }
          setState(() {
            layout = resolved;
            beats = readingBeats(layout, widget.store.setting('bubbles', true));
            step = last
                ? beats.length - 1
                : (legacy ? legacyPanelStep(data, restore) : restore).clamp(
                    0,
                    beats.length - 1,
                  );
            analyzing = false;
          });
        } catch (e) {
          if (!mounted || t != ticket) return;
          if (e is PlatformException && e.code == 'CANCELLED') {
            unawaited(load(index, restore: restore));
            return;
          }
          setState(() {
            analyzing = false;
            analysisError = e.toString();
          });
        }
      }
      if (mounted && t == ticket) {
        await record();
        // Start only after the current page has been presented.
        if (mounted && t == ticket) unawaited(prepareAhead());
      }
    } catch (e) {
      if (mounted && t == ticket) {
        setState(() {
          loading = false;
          analyzing = false;
          error = e;
        });
      }
    }
  }

  Future<void> record() =>
      widget.store.record(widget.book, chapter, page, step);
  Future<void> flipPage(int delta) async {
    if (delta == 0) return;
    final target = page + delta;
    if (target < 0) {
      message(context, '已经是本章第一页');
      return;
    }
    if (target >= chapter.pages.length) {
      message(context, '已经是本章最后一页');
      return;
    }
    await load(target);
  }

  Future<void> next() async {
    if (loading || analyzing) {
      return;
    }
    if (single && step < beats.length - 1) {
      setState(() {
        step++;
        activeBubble = null;
      });
      await record();
      return;
    }
    if (page < chapter.pages.length - 1) {
      await load(page + 1);
      return;
    }
    final i = widget.book.chapters.indexWhere((c) => c.id == chapter.id);
    final proceed = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('本章已读完', style: Theme.of(c).textTheme.titleLarge),
              const SizedBox(height: 20),
              if (i + 1 < widget.book.chapters.length)
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('阅读下一章'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('返回章节目录'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (proceed == true) {
      final ch = widget.book.chapters[i + 1];
      setState(() => loading = true);
      try {
        await Sources.pages(widget.book, ch);
        await widget.store.remember(widget.book);
        chapter = ch;
        preparedThrough = -1;
        await load(0);
      } catch (e) {
        if (mounted) {
          setState(() {
            error = e;
            loading = false;
          });
        }
      }
    } else if (proceed == false) {
      Navigator.pop(context);
    }
  }

  Future<void> previous() async {
    if (loading || analyzing) {
      if (page > 0) await load(page - 1, last: true);
      return;
    }
    if (single && step > 0) {
      setState(() {
        step--;
        activeBubble = null;
      });
      await record();
    } else if (page > 0) {
      await load(page - 1, last: true);
    } else {
      message(context, '已经是本章第一页');
    }
  }

  Future<void> contents() async {
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(c).height * .75,
          child: ListView(
            children: [
              const ListTile(title: Text('章节与页码')),
              ListTile(title: Text('当前章节 · ${chapter.pages.length} 页')),
              for (int i = 0; i < chapter.pages.length; i++)
                ListTile(
                  selected: i == page,
                  title: Text('第 ${i + 1} 页'),
                  onTap: () => Navigator.pop(c, {'page': i}),
                ),
              const Divider(),
              const ListTile(title: Text('章节目录')),
              for (final ch in widget.book.chapters)
                ListTile(
                  selected: ch.id == chapter.id,
                  title: Text(ch.title),
                  onTap: () => Navigator.pop(c, {'chapter': ch}),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen['chapter'] is Chapter) {
      final ch = chosen['chapter'] as Chapter;
      setState(() => loading = true);
      try {
        await Sources.pages(widget.book, ch);
        if (!mounted) return;
        chapter = ch;
        preparedThrough = -1;
        await load(0);
      } catch (e) {
        if (mounted) {
          setState(() {
            loading = false;
            error = e;
          });
        }
      }
    } else {
      await load(chosen['page'] as int);
    }
  }

  Future<void> selectPage() async {
    final chosen = await showModalBottomSheet<int>(
      context: context,
      builder: (c) => SafeArea(
        child: SizedBox(
          height: 350,
          child: Column(
            children: [
              const ListTile(title: Text('跳转到页面')),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 75,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: chapter.pages.length,
                  itemBuilder: (c, i) => FilledButton.tonal(
                    onPressed: () => Navigator.pop(c, i),
                    child: Text('${i + 1}'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null && mounted) load(chosen);
  }

  Future<void> showBookmarks() async {
    final marks = widget.store.bookmarks(widget.book);
    final chosen = await showModalBottomSheet<Json>(
      context: context,
      builder: (c) => SafeArea(
        child: SizedBox(
          height: 350,
          child: marks.isEmpty
              ? const Center(child: Text('暂无书签，点击工具栏书签图标添加'))
              : ListView(
                  children: marks
                      .map(
                        (m) => ListTile(
                          leading: const Icon(Icons.bookmark),
                          title: Text(m['title']),
                          subtitle: Text('第 ${(m['page'] as int) + 1} 页'),
                          onTap: () => Navigator.pop(c, m),
                        ),
                      )
                      .toList(),
                ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final ch = widget.book.chapters
        .where((c) => c.id == chosen['chapter'])
        .firstOrNull;
    if (ch == null) return;
    setState(() => loading = true);
    try {
      await Sources.pages(widget.book, ch);
      if (!mounted) return;
      chapter = ch;
      await load(
        (chosen['page'] as int).clamp(0, ch.pages.length - 1),
        restore: chosen['step'] ?? 0,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext c) {
    final beat = single
        ? Beat(beats[step].count, bubble: activeBubble, full: beats[step].full)
        : Beat(0, full: true, bubble: activeBubble);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: controls
          ? AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.book.title,
                    style: const TextStyle(fontSize: 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    chapter.title,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              backgroundColor: Colors.white,
              foregroundColor: Theme.of(c).colorScheme.primary,
              actions: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: () => mode(true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 12,
                        ),
                        child: Text(
                          '逐格',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: single
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                    CupertinoSwitch(
                      value: !single,
                      onChanged: (v) => mode(!v),
                      activeTrackColor: Theme.of(c).colorScheme.primary,
                      inactiveTrackColor: Theme.of(c).colorScheme.primary
                          .withValues(alpha: .4),
                    ),
                    GestureDetector(
                      onTap: () => mode(false),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 12,
                        ),
                        child: Text(
                          '整页',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: !single
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: '章节与页码',
                  onPressed: contents,
                  icon: const Icon(Icons.auto_stories_outlined),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'help') {
                      showModalBottomSheet(
                        context: c,
                        builder: (_) => const SafeArea(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              '下滑：下一格，整页后翻页\n上滑：上一格\n右滑／左滑：下一页／上一页\n点击空白处：累积揭晓\n点击气泡：放大／收起',
                            ),
                          ),
                        ),
                      );
                    }
                    if (v == 'bookmark') {
                      widget.store
                          .toggleBookmark(widget.book, chapter, page, step)
                          .then((_) {
                            if (mounted) setState(() {});
                          });
                    }
                    if (v == 'restart') load(page);
                    if (v == 'settings') {
                      Navigator.push(
                        c,
                        MaterialPageRoute(
                          builder: (_) => SettingsPage(widget.store),
                        ),
                      );
                    }
                    if (v == 'bookmarks') showBookmarks();
                    if (v == 'retry') load(page);
                    if (v == 'info' && analysisError != null) {
                      message(c, analysisError!);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'help', child: Text('阅读操作')),
                    const PopupMenuItem(
                      value: 'bookmark',
                      child: Text('添加／移除本页书签'),
                    ),
                    const PopupMenuItem(
                      value: 'restart',
                      child: Text('从本页第一格重读'),
                    ),
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('阅读设置与缓存'),
                    ),
                    const PopupMenuItem(
                      value: 'bookmarks',
                      child: Text('我的书签'),
                    ),
                    const PopupMenuItem(value: 'retry', child: Text('重新加载本页')),
                    if (analysisError != null)
                      const PopupMenuItem(
                        value: 'info',
                        child: Text('识别未完成 · 查看原因'),
                      ),
                  ],
                ),
              ],
            )
          : null,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) {
          busyGesture = loading || analyzing || error != null;
          busyDrag = Offset.zero;
        },
        onVerticalDragUpdate: (d) {
          if (busyGesture) busyDrag += d.delta;
        },
        onVerticalDragEnd: (_) {
          if (busyGesture) flipPage(loadingPageDelta(busyDrag));
          busyGesture = false;
        },
        onHorizontalDragStart: (_) {
          busyGesture = loading || analyzing || error != null;
          busyDrag = Offset.zero;
        },
        onHorizontalDragUpdate: (d) {
          if (busyGesture) busyDrag += d.delta;
        },
        onHorizontalDragEnd: (_) {
          if (busyGesture) flipPage(loadingPageDelta(busyDrag));
          busyGesture = false;
        },
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: loading || (analyzing && single)
                    ? const Busy()
                    : error != null
                    ? Failure(error!, () => load(page))
                    : LayoutBuilder(
                        builder: (c, box) {
                          viewSize = box.biggest;
                          return Listener(
                            onPointerDown: (e) {
                              pointers.add(e.pointer);
                              if (pointers.length == 1) {
                                pointerStart = e.localPosition;
                                multiple = false;
                              } else {
                                multiple = true;
                              }
                            },
                            onPointerUp: (e) {
                              pointers.remove(e.pointer);
                              if (!multiple && pointerStart != null) {
                                final delta = e.localPosition - pointerStart!;
                                if (swipePageDelta(delta) != 0 &&
                                    transform.value.getMaxScaleOnAxis() <
                                        1.02) {
                                  if (delta.dy.abs() > delta.dx.abs()) {
                                    if (swipePageDelta(delta) > 0) {
                                      next();
                                    } else {
                                      previous();
                                    }
                                  } else {
                                    flipPage(swipePageDelta(delta));
                                  }
                                } else if (delta.distance < 12) {
                                  tapBubble(e.localPosition);
                                }
                              }
                              if (pointers.isEmpty) pointerStart = null;
                            },
                            onPointerCancel: (e) {
                              pointers.remove(e.pointer);
                              multiple = true;
                            },
                            child: GestureDetector(
                              onDoubleTap: () =>
                                  setState(() => controls = !controls),
                              child: InteractiveViewer(
                                transformationController: transform,
                                minScale: 1,
                                maxScale: 4,
                                child: CustomPaint(
                                  size: box.biggest,
                                  painter: ComicPainter(
                                    image!,
                                    layout,
                                    beat,
                                    single: single,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (!controls)
                Positioned(
                  top: 0,
                  left: 0,
                  child: IconButton(
                    tooltip: '显示工具栏',
                    onPressed: () => setState(() => controls = true),
                    icon: const Icon(Icons.more_horiz),
                  ),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: controls
          ? SafeArea(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Center(
                  heightFactor: 1,
                  child: TextButton(
                    onPressed: selectPage,
                    child: Text('${page + 1}/${chapter.pages.length}'),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

Path polygon(List<dynamic> points) {
  final p = Path();
  if (points.isEmpty) return p;
  for (int i = 0; i < points.length; i++) {
    final x = (points[i][0] as num).toDouble(),
        y = (points[i][1] as num).toDouble();
    if (i == 0) {
      p.moveTo(x, y);
    } else {
      p.lineTo(x, y);
    }
  }
  return p..close();
}

class ComicPainter extends CustomPainter {
  final ui.Image image;
  final Json layout;
  final Beat beat;
  final bool single;
  ComicPainter(this.image, this.layout, this.beat, {this.single = false});
  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width.toDouble(), h = image.height.toDouble();
    final viewport = ComicViewport(image, layout, beat, single, size);
    final scale = viewport.scale;
    canvas.drawColor(
      layout['background'] == '#000000' ? Colors.black : Colors.white,
      BlendMode.src,
    );
    canvas.save();
    canvas.translate(viewport.dx, viewport.dy);
    canvas.scale(scale);
    final rect = Rect.fromLTWH(0, 0, w, h);
    final paint = Paint()..filterQuality = FilterQuality.high;
    if (beat.full &&
        (!single ||
            layout['completeRegions'] != true ||
            layout['wholePage'] == true ||
            w / h >= 1.1 ||
            (layout['panels'] as List? ?? []).isEmpty)) {
      canvas.drawImageRect(image, rect, rect, paint);
    } else {
      // Reveal the original non-white page stock beneath every panel, including
      // its screentone and colour. Holes keep unrevealed scenes hidden.
      final stock = layout['stockPaths'] as List? ?? [];
      final paper = Path()..fillType = PathFillType.evenOdd;
      if (stock.isNotEmpty) {
        final colour =
            int.tryParse(
              (layout['stockColor'] as String? ?? '#ffffff').substring(1),
              radix: 16,
            ) ??
            0xffffff;
        canvas.drawRect(rect, Paint()..color = Color(0xff000000 | colour));
        final tile = layout['stockTile'] as List?;
        if (tile != null && tile.length == 4) {
          final source = Rect.fromLTWH(
            (tile[0] as num).toDouble(),
            (tile[1] as num).toDouble(),
            (tile[2] as num).toDouble(),
            (tile[3] as num).toDouble(),
          );
          final transforms = <ui.RSTransform>[];
          final sources = <Rect>[];
          for (double y = 0; y < rect.height; y += source.height) {
            for (double x = 0; x < rect.width; x += source.width) {
              transforms.add(ui.RSTransform(1, 0, x, y));
              sources.add(source);
            }
          }
          canvas.save();
          canvas.clipRect(rect);
          canvas.drawAtlas(
            image,
            transforms,
            sources,
            null,
            BlendMode.srcOver,
            null,
            Paint()..filterQuality = FilterQuality.none,
          );
          canvas.restore();
        }
        for (final points in stock) {
          paper.addPath(polygon(points), Offset.zero);
        }
      }
      final panels = layout['panels'] as List? ?? [];
      final revealRegions = <Path>[];
      for (final panel in panels.take(beat.count)) {
        final paths = panel['paths'] as List?;
        if (paths != null) {
          final region = Path()..fillType = PathFillType.evenOdd;
          for (final points in paths) {
            region.addPath(polygon(points), Offset.zero);
          }
          revealRegions.add(region);
        } else {
          revealRegions.add(polygon(panel['polygon']));
        }
      }
      // Mask the original source artwork using stable ownership regions.
      canvas.saveLayer(rect.inflate(4), Paint());
      canvas.drawImageRect(image, rect, rect, paint);
      canvas.saveLayer(rect.inflate(4), Paint()..blendMode = BlendMode.dstIn);
      canvas.drawPath(paper, Paint()..color = Colors.white);
      for (
        int regionIndex = 0;
        regionIndex < revealRegions.length;
        regionIndex++
      ) {
        final path = revealRegions[regionIndex];
        // Native regions follow exact pixel-cell boundaries. Keep them fixed:
        // contour dilation would reveal another region's source ink.
        canvas.drawPath(
          path,
          Paint()
            ..color = Colors.white
            ..isAntiAlias = false,
        );
        if (layout['completeRegions'] == true) {
          // Image resampling needs a small support band around source frames.
          // Restrict it to the measured frame, never balloon/text hole edges.
          final panel = panels[regionIndex];
          if (panel['source'] != 'corroborated-exterior-region') {
            final points = panel['polygon'] as List;
            final band = Path();
            for (int i = 0; i < points.length; i++) {
              final a = Offset(
                (points[i][0] as num).toDouble(),
                (points[i][1] as num).toDouble(),
              );
              final b = Offset(
                (points[(i + 1) % points.length][0] as num).toDouble(),
                (points[(i + 1) % points.length][1] as num).toDouble(),
              );
              final delta = b - a;
              final normal =
                  Offset(-delta.dy, delta.dx) *
                  (1 / math.max(1, delta.distance));
              band.addPolygon([
                a + normal,
                b + normal,
                b - normal,
                a - normal,
              ], true);
            }
            canvas.save();
            canvas.clipPath(band, doAntiAlias: false);
            canvas.drawPath(
              path,
              Paint()
                ..color = Colors.white
                ..style = PaintingStyle.stroke
                ..strokeWidth = 4
                ..isAntiAlias = false,
            );
            canvas.restore();
          }
        }
        if (layout['completeRegions'] != true) {
          canvas.drawPath(
            path,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4
              ..strokeJoin = StrokeJoin.round,
          );
        }
      }
      canvas.restore();
      canvas.restore();
    }
    if (beat.bubble != null) {
      final path = polygon(beat.bubble!);
      final center = path.getBounds().center;
      canvas.save();
      canvas.translate(center.dx, center.dy);
      final zoom = math
          .min(
            1.4,
            math.min(
              (size.width - 24) / (path.getBounds().width * scale),
              (size.height - 24) / (path.getBounds().height * scale),
            ),
          )
          .clamp(.1, 1.4);
      final bounds = path.getBounds();
      final target = Offset(
        center.dx.clamp(
          -viewport.dx / scale + bounds.width * zoom / 2 + 8 / scale,
          (size.width - viewport.dx) / scale -
              bounds.width * zoom / 2 -
              8 / scale,
        ),
        center.dy.clamp(
          -viewport.dy / scale + bounds.height * zoom / 2 + 8 / scale,
          (size.height - viewport.dy) / scale -
              bounds.height * zoom / 2 -
              8 / scale,
        ),
      );
      canvas.translate(target.dx - center.dx, target.dy - center.dy);
      canvas.scale(zoom);
      canvas.translate(-center.dx, -center.dy);
      canvas.drawShadow(
        path,
        Colors.black.withValues(alpha: .32),
        8 / scale,
        true,
      );
      canvas.clipPath(path);
      canvas.drawImageRect(image, rect, rect, paint);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ComicPainter old) =>
      old.image != image ||
      old.beat != beat ||
      old.layout != layout ||
      old.single != single;
}

class ComicViewport {
  late final double scale, dx, dy;
  ComicViewport(
    ui.Image image,
    Json layout,
    Beat beat,
    bool single,
    Size size,
  ) {
    final content = layout['contentBounds'] as List?;
    final bounds = content == null
        ? Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble())
        : Rect.fromLTWH(
            (content[0] as num).toDouble(),
            0,
            (content[2] as num).toDouble(),
            image.height.toDouble(),
          );
    // Equalise the margins around the artwork without clipping the original
    // paper, colour or drawings on the longer side of an asymmetric page.
    final span = 2 * math.max(bounds.center.dx, image.width - bounds.center.dx);
    scale = math.min(
      size.width * .95 / math.max(1, span),
      size.height * .92 / math.max(1, bounds.height),
    );
    dx = (size.width - bounds.width * scale) / 2 - bounds.left * scale;
    dy = (size.height - bounds.height * scale) / 2 - bounds.top * scale;
  }
  Offset sourcePoint(Offset p) =>
      Offset((p.dx - dx) / scale, (p.dy - dy) / scale);
}
