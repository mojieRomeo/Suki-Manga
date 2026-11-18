import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

part 'web_sources.dart';

const native = MethodChannel('gejian/native');
String keyFor(String value) => sha256.convert(utf8.encode(value)).toString();
typedef Json = Map<String, dynamic>;

class SourceVerificationRequired implements Exception {
  final String url;
  SourceVerificationRequired(this.url);
  @override
  String toString() => 'MangaDex 要求浏览器验证，请点击“验证书源”后再重试。';
}

class Book {
  final String id, source, title, cover;
  String description;
  List<Chapter> chapters;
  int chapterOffset = 0, chapterTotal = 0;
  Book(
    this.id,
    this.source,
    this.title,
    this.cover, {
    this.description = '',
    List<Chapter>? chapters,
  }) : chapters = chapters ?? [];
  String get key => '$source:$id';
  Json toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'cover': cover,
    'description': description,
    'chapterOffset': chapterOffset,
    'chapterTotal': chapterTotal,
    'chapters': chapters.map((c) => c.toJson()).toList(),
  };
  factory Book.fromJson(Json j) =>
      Book(
          j['id'],
          j['source'],
          j['title'],
          j['cover'] ?? '',
          description: j['description'] ?? '',
          chapters: (j['chapters'] as List? ?? [])
              .map((c) => Chapter.fromJson(Map<String, dynamic>.from(c)))
              .toList(),
        )
        ..chapterOffset =
            (j['chapterOffset'] ?? (j['chapters'] as List? ?? []).length)
        ..chapterTotal =
            (j['chapterTotal'] ?? (j['chapters'] as List? ?? []).length);
}

class Chapter {
  final String id, title;
  List<String> pages;
  Chapter(this.id, this.title, {List<String>? pages}) : pages = pages ?? [];
  Json toJson() => {'id': id, 'title': title, 'pages': pages};
  factory Chapter.fromJson(Json j) =>
      Chapter(j['id'], j['title'], pages: List<String>.from(j['pages'] ?? []));
}

class LibraryStore extends ChangeNotifier {
  bool startupBusy = false;
  final Set<String> _validCovers = {};
  final Directory root;
  Json state;
  final Map<String, Future<File>> _pending = {};
  Future<void> _writing = Future.value();
  LibraryStore(this.root, this.state);
  static Future<LibraryStore> open() async {
    final path = await native.invokeMethod<String>('directory');
    final root = Directory(path!);
    await root.create(recursive: true);
    // Remove retired artwork splash files, preserving all reading data.
    final legacyStartup = Directory('${root.path}/startup');
    if (await legacyStartup.exists()) {
      await legacyStartup.delete(recursive: true);
    }
    Json data = {};
    final file = File('${root.path}/library.json');
    if (await file.exists()) {
      try {
        data = jsonDecode(await file.readAsString());
      } catch (_) {
        final backup = File('${root.path}/library.backup.json');
        if (await backup.exists()) {
          data = jsonDecode(await backup.readAsString());
        }
      }
    }
    return LibraryStore(root, data);
  }

  List<Book> get books => (state['books'] as List? ?? [])
      .map((j) => Book.fromJson(Map<String, dynamic>.from(j)))
      .toList();
  List<String> get favorites => List<String>.from(state['favorites'] ?? []);
  Json progress(Book b) =>
      Map<String, dynamic>.from((state['progress'] ?? {})[b.key] ?? {});
  bool setting(String k, bool fallback) => state[k] as bool? ?? fallback;
  Future<void> save() {
    final encoded = jsonEncode(state);
    _writing = _writing.catchError((_) {}).then((_) async {
      final f = File('${root.path}/library.json');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      if (await f.exists()) await f.copy('${root.path}/library.backup.json');
      await tmp.rename(f.path);
    });
    notifyListeners();
    return _writing;
  }

  Future<void> remember(Book b) async {
    final list = books;
    final i = list.indexWhere((x) => x.key == b.key);
    if (i < 0) {
      list.add(b);
    } else {
      list[i] = b;
    }
    state['books'] = list.map((b) => b.toJson()).toList();
    await save();
  }

  Future<void> favorite(Book b) async {
    await remember(b);
    final f = favorites;
    if (!f.remove(b.key)) f.add(b.key);
    state['favorites'] = f;
    await save();
  }

  Future<void> record(Book b, Chapter c, int page, int step) async {
    final p = Map<String, dynamic>.from(state['progress'] ?? {});
    p[b.key] = {
      'chapter': c.id,
      'page': page,
      'step': step,
      'flowVersion': 2,
      'total': c.pages.length,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
    state['progress'] = p;
    await save();
  }

  Future<void> setSetting(String k, dynamic v) async {
    state[k] = v;
    await save();
  }

  Directory chapterDir(Book b, Chapter c) =>
      Directory('${root.path}/pages/${keyFor('${b.key}:${c.id}')}');
  Future<File> page(Book b, Chapter c, int i) async {
    final dir = chapterDir(b, c);
    await dir.create(recursive: true);
    final file = File('${dir.path}/$i.img');
    if (await file.exists() && await file.length() > 0) return file;
    return _pending.putIfAbsent(file.path, () async {
      try {
        final url = c.pages[i];
        if (url.startsWith('/')) return File(url);
        final bytes = await Sources.bytes(
          url,
          referer: Sources.refererFor(b.source),
        );
        final tmp = File('${file.path}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
        return file;
      } finally {
        _pending.remove(file.path);
      }
    });
  }

  final Map<String, Future<String>> _analysisPending = {};
  final Map<String, String> _analysisMemory = {};
  bool get analysisBusy => _analysisPending.isNotEmpty;
  Future<Json> recognize(File image, {bool background = false}) async {
    final stat = await image.stat();
    final key =
        '${image.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
    final cached = _analysisMemory.remove(key);
    if (cached != null) {
      _analysisMemory[key] = cached;
      return jsonDecode(cached) as Json;
    }
    final encoded = await _analysisPending.putIfAbsent(key, () async {
      try {
        final value = jsonEncode(await _recognize(image, background));
        _analysisMemory[key] = value;
        while (_analysisMemory.length > 8) {
          _analysisMemory.remove(_analysisMemory.keys.first);
        }
        return value;
      } finally {
        _analysisPending.remove(key);
      }
    });
    // Reader layouts are mutable: every consumer owns its own copy.
    return jsonDecode(encoded) as Json;
  }

  static bool ambiguousGaps(Json layout) {
    final panels = layout['panels'] as List? ?? [];
    if (panels.any(
      (p) => (p['source'] ?? '').toString().contains('detector-container'),
    )) {
      return true;
    }
    bool inside(List points, double x, double y) {
      bool hit = false;
      for (int i = 0, j = points.length - 1; i < points.length; j = i++) {
        final a = points[i], b = points[j];
        if (((a[1] as num) > y) != ((b[1] as num) > y) &&
            x <
                ((b[0] as num) - (a[0] as num)) *
                        (y - (a[1] as num)) /
                        ((b[1] as num) - (a[1] as num)) +
                    (a[0] as num)) {
          hit = !hit;
        }
      }
      return hit;
    }

    for (int i = 0; i < panels.length; i++) {
      final a = panels[i]['polygon'] as List?;
      if (a == null || a.isEmpty) continue;
      final xs = a.map((p) => (p[0] as num).toDouble()).toList()..sort();
      final ys = a.map((p) => (p[1] as num).toDouble()).toList()..sort();
      for (int j = i + 1; j < panels.length; j++) {
        final b = panels[j]['polygon'] as List?;
        if (b == null) continue;
        int sampled = 0, overlap = 0;
        for (int y = 0; y < 24; y++) {
          for (int x = 0; x < 24; x++) {
            final px = xs.first + (xs.last - xs.first) * (x + .5) / 24,
                py = ys.first + (ys.last - ys.first) * (y + .5) / 24;
            if (inside(a, px, py)) {
              sampled++;
              if (inside(b, px, py)) overlap++;
            }
          }
        }
        if (sampled > 0 && overlap > sampled * .025) return true;
      }
    }
    return false;
  }

  static void groupArtwork(Json result) {
    final width = (result['width'] as num?)?.toDouble() ?? 0;
    final height = (result['height'] as num?)?.toDouble() ?? 0;
    final panels = result['panels'] as List? ?? [];
    if (width <= 0 || height <= 0) return;
    result['uncertainGaps'] = ambiguousGaps(result);
    result['wideSpread'] = width / height >= 1.1;
    result['wholePage'] =
        panels.isEmpty ||
        result['uncertainGaps'] == true ||
        result['wideSpread'] == true;
    // Narrow, aligned strips can be genuine consecutive panels. Geometry alone
    // must never merge them; scene reconciliation belongs to the native detector.
    final linked = <int, List<int>>{};
    for (int i = 0; i < panels.length; i++) {
      final id = panels[i]['artworkGroup'];
      if (id is int && id >= 0) linked.putIfAbsent(id, () => []).add(i);
    }
    final intervals = linked.values.where((g) => g.length > 1).toList()
      ..sort((a, b) => a.first.compareTo(b.first));
    final groups = <List<int>>[];
    for (final g in intervals) {
      if (groups.isNotEmpty && g.first <= groups.last.last) {
        final start = groups.last.first;
        final end = g.last > groups.last.last ? g.last : groups.last.last;
        groups[groups.length - 1] = [for (int i = start; i <= end; i++) i];
      } else {
        groups.add([for (int i = g.first; i <= g.last; i++) i]);
      }
    }
    result['revealGroups'] = groups;
    result['compositionVersion'] = 5;
  }

  // Measure the page's actual artwork against its own paper/stock colour.
  // Downsampled RGB averages suppress screentone dots without changing source pixels.
  static List<double> contentExtent(Uint8List rgba, int width, int height) {
    final stride = width + 1;
    final sums = List.generate(3, (_) => Int32List((width + 1) * (height + 1)));
    for (int y = 0; y < height; y++) {
      final row = [0, 0, 0];
      for (int x = 0; x < width; x++) {
        final source = (y * width + x) * 4, target = (y + 1) * stride + x + 1;
        for (int c = 0; c < 3; c++) {
          row[c] += rgba[source + c];
          sums[c][target] = sums[c][target - stride] + row[c];
        }
      }
    }
    List<double> sample(int x, int y) {
      final x0 = (x - 1).clamp(0, width), x1 = (x + 2).clamp(0, width);
      final y0 = (y - 1).clamp(0, height), y1 = (y + 2).clamp(0, height);
      return List.generate(
        3,
        (c) =>
            (sums[c][y1 * stride + x1] -
                sums[c][y0 * stride + x1] -
                sums[c][y1 * stride + x0] +
                sums[c][y0 * stride + x0]) /
            ((x1 - x0) * (y1 - y0)),
      );
    }

    List<double> stock(int side) {
      final bins = <int, List<double>>{};
      for (int y = 0; y < height; y++) {
        final value = sample(side, y);
        final key =
            ((value[0].toInt() >> 4) << 8) |
            ((value[1].toInt() >> 4) << 4) |
            (value[2].toInt() >> 4);
        final bin = bins.putIfAbsent(key, () => [0, 0, 0, 0]);
        bin[0]++;
        for (int c = 0; c < 3; c++) {
          bin[c + 1] += value[c];
        }
      }
      final best = bins.values.reduce((a, b) => a[0] > b[0] ? a : b);
      return [for (int c = 1; c < 4; c++) best[c] / best[0]];
    }

    final leftStock = stock(0), rightStock = stock(width - 1);
    final threshold = (height * .004).ceil().clamp(2, 100);
    bool paper(int x, List<double> background) {
      int contrast = 0;
      for (int y = 0; y < height; y++) {
        final p = sample(x, y);
        if (List.generate(
              3,
              (c) => (p[c] - background[c]).abs(),
            ).reduce((a, b) => a > b ? a : b) >
            30) {
          contrast++;
        }
        if (contrast >= threshold) return false;
      }
      return true;
    }

    int left = 0, right = width - 1;
    while (left < right && paper(left, leftStock)) {
      left++;
    }
    while (right > left && paper(right, rightStock)) {
      right--;
    }
    if (right - left < width * .15) {
      return [0, 0, width.toDouble(), height.toDouble()];
    }
    left = (left - 2).clamp(0, width - 1);
    right = (right + 2).clamp(left, width - 1);
    return [
      left.toDouble(),
      0,
      (right - left + 1).toDouble(),
      height.toDouble(),
    ];
  }

  final Map<String, Future<Json>> _displayGeometry = {};

  Future<Json> prepareDisplay(File image, int width, int height) async {
    final stat = await image.stat();
    final key =
        '${image.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:$width:$height';
    final geometry = await _displayGeometry.putIfAbsent(key, () async {
      final codec = await ui.instantiateImageCodec(
        await image.readAsBytes(),
        targetWidth: 480,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      final preview = frame.image;
      try {
        final pixels = await preview.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (pixels == null) throw StateError('无法读取图片内容边界');
        final bytes = pixels.buffer.asUint8List();
        final extent = contentExtent(bytes, preview.width, preview.height);
        final sx = width / preview.width;
        int darkSides = 0;
        for (int side = 0; side < 4; side++) {
          int dark = 0;
          final length = side < 2 ? preview.height : preview.width;
          for (int n = 0; n < length; n++) {
            final x = side == 0
                ? 0
                : side == 1
                ? preview.width - 1
                : n;
            final y = side == 2
                ? 0
                : side == 3
                ? preview.height - 1
                : n;
            final i = (y * preview.width + x) * 4;
            if (bytes[i] < 45 && bytes[i + 1] < 45 && bytes[i + 2] < 45) dark++;
          }
          if (dark > length * .85) darkSides++;
        }
        return <String, dynamic>{
          'width': width,
          'height': height,
          'contentBounds': [extent[0] * sx, 0, extent[2] * sx, height],
          'contentBoundsVersion': 2,
          'background': darkSides >= 2 ? '#000000' : '#ffffff',
        };
      } finally {
        preview.dispose();
      }
    });
    return Map<String, dynamic>.from(geometry);
  }

  Future<void> _centerBounds(File image, Json result) async {
    groupArtwork(result);
    final geometry = await prepareDisplay(
      image,
      (result['width'] as num).toInt(),
      (result['height'] as num).toInt(),
    );
    result.addAll(geometry);
  }

  Future<Json> _recognize(File image, bool background) async {
    final hash = sha256.convert(await image.readAsBytes()).toString();
    final d = Directory('${root.path}/analysis');
    await d.create(recursive: true);
    final f = File('${d.path}/et15-geometry26-$hash.json');
    if (await f.exists()) {
      try {
        final result = jsonDecode(await f.readAsString()) as Json;
        if (!result.containsKey('contentBounds') ||
            result['compositionVersion'] != 5 ||
            result['contentBoundsVersion'] != 2) {
          await _centerBounds(image, result);
          await f.writeAsString(jsonEncode(result), flush: true);
        }
        return result;
      } catch (_) {}
    }
    final raw = await native.invokeMethod<String>('recognize', {
      'path': image.path,
      'background': background,
    });
    final result = jsonDecode(raw!) as Json;
    result['sourcePath'] = image.path;
    await _centerBounds(image, result);
    final tmp = File('${f.path}.part');
    await tmp.writeAsString(jsonEncode(result), flush: true);
    await tmp.rename(f.path);
    return result;
  }

  Future<bool> chapterReady(Book b, Chapter ch) async {
    if (ch.pages.isEmpty) return false;
    for (int i = 0; i < ch.pages.length; i++) {
      final file = ch.pages[i].startsWith('/')
          ? File(ch.pages[i])
          : File('${chapterDir(b, ch).path}/$i.img');
      if (!await file.exists()) return false;
      final hash = sha256.convert(await file.readAsBytes()).toString();
      final cached = File('${root.path}/analysis/et15-geometry26-$hash.json');
      if (!await cached.exists()) return false;
      try {
        final data = jsonDecode(await cached.readAsString());
        if (data['panels'] is! List || data['width'] is! num) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  Future<int> bytesUsed(Directory d) async {
    if (!await d.exists()) return 0;
    int total = 0;
    await for (final f in d.list(recursive: true, followLinks: false)) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  Future<void> deleteChapter(Book b, Chapter c) async {
    if (_pending.keys.any((p) => p.startsWith(chapterDir(b, c).path))) {
      throw StateError('该章节仍在下载，请等待下载完成');
    }
    final d = chapterDir(b, c);
    _analysisMemory.clear();
    if (await d.exists()) await d.delete(recursive: true);
    notifyListeners();
  }

  Future<void> clearAnalysis() async {
    if (_analysisPending.isNotEmpty) throw StateError('正在识别，请退出阅读并等待当前任务完成后清理');
    final d = Directory('${root.path}/analysis');
    _analysisMemory.clear();
    if (await d.exists()) await d.delete(recursive: true);
    notifyListeners();
  }

  Future<void> deleteCacheEntry(FileSystemEntity entry) =>
      deleteCacheEntries([entry]);

  Future<void> deleteCacheEntries(
    List<FileSystemEntity> entries, {
    void Function(FileSystemEntity)? onDeleted,
  }) async {
    if (_analysisPending.isNotEmpty || _pending.isNotEmpty || startupBusy) {
      throw StateError('仍有下载或识别任务，请稍后再清理');
    }
    final base = await root.resolveSymbolicLinks();
    final valid = <FileSystemEntity>[];
    final originals = <String, FileSystemEntity>{};
    // Resolve and validate every target before the first deletion.
    for (final entry in entries) {
      if (entry is Link) throw StateError('不删除链接文件');
      if (!await entry.exists()) continue;
      final path = await entry.resolveSymbolicLinks();
      if (!['analysis', 'covers', 'pages', 'imports'].any(
        (folder) => path.startsWith(
          '$base${Platform.pathSeparator}$folder${Platform.pathSeparator}',
        ),
      )) {
        throw StateError('只能删除缓存目录内的项目');
      }
      valid.add(entry is Directory ? Directory(path) : File(path));
      originals[path] = entry;
    }
    _analysisMemory.clear();
    bool stateChanged = false;
    try {
      // Bounded concurrent deletes; no repeated full-directory size scans.
      for (int offset = 0; offset < valid.length; offset += 4) {
        await Future.wait(
          valid.skip(offset).take(4).map((entry) async {
            await entry.delete(recursive: entry is Directory);
            _validCovers.remove(entry.path);
            if (entry.path.startsWith(
              '$base${Platform.pathSeparator}imports${Platform.pathSeparator}',
            )) {
              state['books'] = books
                  .where(
                    (b) =>
                        '$base${Platform.pathSeparator}imports${Platform.pathSeparator}${b.id}' !=
                        entry.path,
                  )
                  .map((b) => b.toJson())
                  .toList();
              stateChanged = true;
            }
            onDeleted?.call(originals[entry.path]!);
          }),
        );
      }
    } finally {
      if (stateChanged) await save();
      notifyListeners();
    }
  }

  Future<File> cover(Book b) async {
    final dir = Directory('${root.path}/covers');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${keyFor(b.key)}.img');
    if (_validCovers.contains(file.path) && await file.exists()) return file;
    return _pending.putIfAbsent(file.path, () async {
      try {
        if (await file.exists() && await validImage(await file.readAsBytes())) {
          _validCovers.add(file.path);
          return file;
        }
        final bytes = await Sources.bytes(
          b.cover,
          referer: Sources.refererFor(b.source),
        );
        if (!await validImage(bytes)) throw StateError('封面来源没有返回有效图片，请重试');
        final temporary = File('${file.path}.part');
        await temporary.writeAsBytes(bytes, flush: true);
        await temporary.rename(file.path);
        _validCovers.add(file.path);
        return file;
      } finally {
        _pending.remove(file.path);
      }
    });
  }

  static Future<bool> validImage(List<int> bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> clearCovers() async {
    if (_pending.keys.any((p) => p.contains('/covers/'))) {
      throw StateError('封面仍在加载，请稍后重试');
    }
    final d = Directory('${root.path}/covers');
    if (await d.exists()) await d.delete(recursive: true);
    _validCovers.clear();
    notifyListeners();
  }

  Future<void> removeImport(Book b) async {
    if (b.source != 'local') return;
    final d = Directory('${root.path}/imports/${b.id}');
    if (await d.exists()) await d.delete(recursive: true);
    state['books'] = books
        .where((x) => x.key != b.key)
        .map((x) => x.toJson())
        .toList();
    await save();
  }

  List<Json> bookmarks(Book b) => (state['bookmarks']?[b.key] as List? ?? [])
      .map((x) => Map<String, dynamic>.from(x))
      .toList();
  Future<void> toggleBookmark(Book b, Chapter ch, int page, int step) async {
    final entries = bookmarks(b);
    final index = entries.indexWhere(
      (x) => x['chapter'] == ch.id && x['page'] == page,
    );
    if (index >= 0) {
      entries.removeAt(index);
    } else {
      entries.add({
        'chapter': ch.id,
        'title': ch.title,
        'page': page,
        'step': step,
      });
    }
    final all = Map<String, dynamic>.from(state['bookmarks'] ?? {});
    all[b.key] = entries;
    state['bookmarks'] = all;
    await save();
  }

  Future<Book?> importFile() async {
    final raw = await native.invokeMethod<Map>('pick');
    if (raw == null) return null;
    final path = raw['path'] as String, name = raw['name'] as String;
    final input = File(path);
    final hash = sha256.convert(await input.readAsBytes()).toString();
    final d = Directory('${root.path}/imports/$hash');
    await d.create(recursive: true);
    final pages = <String>[];
    if (RegExp(r'\.(cbz|zip|epub)$', caseSensitive: false).hasMatch(name)) {
      final archive = ZipDecoder().decodeBytes(await input.readAsBytes());
      var images =
          archive.files
              .where(
                (f) =>
                    f.isFile &&
                    RegExp(
                      r'\.(jpe?g|png|webp)$',
                      caseSensitive: false,
                    ).hasMatch(f.name),
              )
              .toList()
            ..sort((a, b) => naturalCompare(a.name, b.name));
      if (name.toLowerCase().endsWith('.epub')) images = epubImages(archive);
      if (images.isEmpty) throw StateError('压缩包内没有漫画图片');
      int size = 0;
      for (var i = 0; i < images.length; i++) {
        size += images[i].size;
        if (size > 1024 * 1024 * 1024) throw StateError('解压图片超过 1 GB，请拆分卷册');
        final f = File('${d.path}/$i.img');
        await f.writeAsBytes(images[i].content as List<int>);
        pages.add(f.path);
      }
    } else {
      final f = await input.copy('${d.path}/0.img');
      pages.add(f.path);
    }
    final b = Book(
      hash,
      'local',
      name,
      '',
      chapters: [Chapter(hash, '本地卷册', pages: pages)],
    );
    await remember(b);
    await input.delete();
    return b;
  }
}

List<ArchiveFile> epubImages(Archive archive) {
  String text(String path) {
    final f = archive.findFile(path);
    if (f == null) throw StateError('EPUB 缺少 $path');
    return utf8.decode(f.content as List<int>);
  }

  final container = XmlDocument.parse(text('META-INF/container.xml'));
  final opfPath = container.descendants
      .whereType<XmlElement>()
      .firstWhere((e) => e.name.local == 'rootfile')
      .getAttribute('full-path')!;
  final opf = XmlDocument.parse(text(opfPath));
  final manifest = <String, String>{};
  for (final e in opf.descendants.whereType<XmlElement>().where(
    (e) => e.name.local == 'item',
  )) {
    final id = e.getAttribute('id'), href = e.getAttribute('href');
    if (id != null && href != null) {
      manifest[id] = Uri.decodeComponent(Uri(path: opfPath).resolve(href).path);
    }
  }
  final ordered = <ArchiveFile>[];
  final seen = <String>{};
  for (final item in opf.descendants.whereType<XmlElement>().where(
    (e) => e.name.local == 'itemref',
  )) {
    final path = manifest[item.getAttribute('idref')];
    if (path == null) continue;
    if (RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(path)) {
      final f = archive.findFile(path);
      if (f != null && seen.add(path)) ordered.add(f);
      continue;
    }
    final page = XmlDocument.parse(text(path));
    for (final image in page.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'img' || e.name.local == 'image',
    )) {
      final href =
          image.getAttribute('src') ??
          image.getAttribute('href') ??
          image.attributes
              .where((a) => a.name.local == 'href')
              .firstOrNull
              ?.value;
      if (href == null) continue;
      final resolved = Uri.decodeComponent(Uri(path: path).resolve(href).path);
      final f = archive.findFile(resolved);
      if (f != null && seen.add(resolved)) ordered.add(f);
    }
  }
  if (ordered.isEmpty) throw StateError('EPUB 的阅读顺序中没有漫画图片');
  return ordered;
}

int naturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final aa = re.allMatches(a).map((m) => m[0]!).toList(),
      bb = re.allMatches(b).map((m) => m[0]!).toList();
  for (int i = 0; i < aa.length && i < bb.length; i++) {
    final x = int.tryParse(aa[i]), y = int.tryParse(bb[i]);
    final c = x != null && y != null ? x.compareTo(y) : aa[i].compareTo(bb[i]);
    if (c != 0) return c;
  }
  return aa.length.compareTo(bb.length);
}

class Sources {
  static const names = <String, String>{'md': 'MangaDex', 'copy': '拷贝漫画'};
  static String refererFor(String source) =>
      source == 'md' ? 'https://mangadex.org/' : WebSources.roots[source] ?? '';

  static bool isMangaDexHost(String host) =>
      host == 'mangadex.org' ||
      host.endsWith('.mangadex.org') ||
      host.endsWith('.mangadex.network');
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static final Map<String, Json> verifiedResponses = {};
  static String mdCookie = '';
  static Future<void> verify(String url) async {
    final raw = await native.invokeMethod<String>('mdJson', {'url': url});
    if (raw == null) throw StateError('验证没有返回数据，请重试');
    verifiedResponses[url] = Map<String, dynamic>.from(jsonDecode(raw));
    mdCookie = await native.invokeMethod<String>('mdCookies') ?? '';
  }

  static final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 25);
  static Future<Uint8List> bytes(String url, {String? referer}) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https') {
      throw StateError('书源返回了不支持的地址');
    }
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 30));
    req.headers.set(
      'User-Agent',
      isMangaDexHost(uri.host)
          ? 'Gejian/0.7.1 (Android comic reader)'
          : userAgent,
    );
    if (uri.host == 'api.mangadex.org') {
      req.headers.set('Accept', 'application/json');
    } else if (isMangaDexHost(uri.host)) {
      req.headers.set(
        'Accept',
        'image/jpeg,image/png,image/webp,image/*;q=0.8,*/*;q=0.5',
      );
    }
    if (uri.host == 'api.mangadex.org' && mdCookie.isNotEmpty) {
      req.headers.set('Cookie', mdCookie);
    }

    if (referer != null) req.headers.set('Referer', referer);
    final res = await req.close().timeout(const Duration(seconds: 45));
    if (uri.host == 'api.mangadex.org' &&
        (res.statusCode == 403 || res.statusCode == 503) &&
        res.headers.contentType?.mimeType == 'text/html') {
      await res.drain();
      throw SourceVerificationRequired(url);
    }
    if (res.statusCode != 200) {
      await res.drain();
      throw HttpException('书源返回 ${res.statusCode}', uri: uri);
    }
    return consolidateHttpClientResponseBytes(res)
        .timeout(const Duration(seconds: 60));
  }

  static Future<Json> json(String url) async {
    final verified = verifiedResponses.remove(url);
    if (verified != null) return verified;
    final body = utf8.decode(await bytes(url));
    if (body.trimLeft().startsWith('{')) return jsonDecode(body);
    if (Uri.parse(url).host == 'api.mangadex.org') {
      throw SourceVerificationRequired(url);
    }
    throw StateError('书源返回了验证页面，请稍后重试或切换网络');
  }

  static String title(Json a) =>
      ((a['title'] as Map?)?['zh'] ??
              (a['title'] as Map?)?['zh-hk'] ??
              (a['title'] as Map?)?['en'] ??
              (a['title'] as Map?)?.values.firstOrNull ??
              '未命名')
          .toString();
  static Book md(Json d) {
    final a = Map<String, dynamic>.from(d['attributes']);
    String cover = '';
    for (final r in d['relationships'] ?? []) {
      if (r['type'] == 'cover_art' && r['attributes']?['fileName'] != null) {
        cover =
            'https://uploads.mangadex.org/covers/${d['id']}/${r['attributes']['fileName']}.512.jpg';
      }
    }
    return Book(
      d['id'],
      'md',
      title(a),
      cover,
      description: (a['description']?['zh'] ?? a['description']?['en'] ?? '')
          .toString(),
    );
  }

  static Future<List<Book>> ranking() async {
    final d = await json(
      'https://api.mangadex.org/manga?limit=20&includes[]=cover_art&order[followedCount]=desc&contentRating[]=safe&contentRating[]=suggestive',
    );
    return (d['data'] as List)
        .map((b) => md(Map<String, dynamic>.from(b)))
        .toList();
  }

  static Future<List<Book>> daily() async {
    final d = await json(
      'https://api.mangadex.org/manga?limit=60&includes[]=cover_art&order[latestUploadedChapter]=desc&contentRating[]=safe&contentRating[]=suggestive&hasAvailableChapters=true',
    );
    final pool =
        (d['data'] as List)
            .map((b) => md(Map<String, dynamic>.from(b)))
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    if (pool.isEmpty) return pool;
    final now = DateTime.now();
    final offset =
        DateTime.utc(now.year, now.month, now.day).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay %
        pool.length;
    return List.generate(
      pool.length < 12 ? pool.length : 12,
      (i) => pool[(offset + i) % pool.length],
    );
  }

  static Future<List<Book>> search(
    String source,
    String query, {
    int offset = 0,
    int limit = 100,
  }) async {
    if (source == 'md') {
      final d = await json(
        'https://api.mangadex.org/manga?limit=$limit&offset=$offset&includes[]=cover_art${query.isEmpty ? '' : '&title=${Uri.encodeComponent(query)}'}',
      );
      return (d['data'] as List)
          .map((b) => md(Map<String, dynamic>.from(b)))
          .toList();
    }
    return WebSources.search(source, query, offset: offset, limit: limit);
  }

  static Future<void> moreChapters(Book b, {bool reset = false}) async {
    final offset = reset ? 0 : b.chapterOffset;
    final d = await json(
      'https://api.mangadex.org/manga/${b.id}/feed?limit=100&offset=$offset&order[chapter]=asc&includeExternalUrl=0',
    ).timeout(const Duration(seconds: 25));
    final batch = d['data'] as List;
    final list = reset ? <Chapter>[] : List<Chapter>.of(b.chapters);
    final seen = list.map((c) => c.id).toSet();
    for (final c in batch) {
      if (!seen.add(c['id'])) continue;
      final a = c['attributes'];
      list.add(
        Chapter(
          c['id'],
          "${a['chapter'] ?? '番外'} · ${a['translatedLanguage']} ${a['title'] ?? ''}",
        ),
      );
    }
    b.chapters = list;
    b.chapterOffset = offset + batch.length;
    b.chapterTotal = d['total'] as int;
    if (batch.isEmpty) b.chapterTotal = b.chapterOffset;
  }

  static Future<void> chapters(Book b, {bool refresh = false}) async {
    if (b.source == 'local' || (!refresh && b.chapters.isNotEmpty)) return;
    if (b.source == 'md') {
      await moreChapters(b, reset: true);
    } else {
      await WebSources.chapters(b);
    }
    if (b.chapters.isEmpty) throw StateError('这部漫画暂时没有可读章节');
  }

  static Future<void> pages(Book b, Chapter c) async {
    if (c.pages.isNotEmpty) return;
    if (b.source == 'md') {
      final d = await json('https://api.mangadex.org/at-home/server/${c.id}');
      c.pages = (d['chapter']['data'] as List)
          .map((f) => '${d['baseUrl']}/data/${d['chapter']['hash']}/$f')
          .toList();
    } else if (b.source != 'local') {
      c.pages = await WebSources.pages(b, c);
    }
    if (c.pages.isEmpty) throw StateError('章节没有图片');
  }
}
