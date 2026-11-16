import 'dart:convert';
import 'dart:io';

import 'data.dart';

class StartupData {
  static final feeds = <String, Future<List<List<Book>>>>{};
  static String day() => DateTime.now().toIso8601String().substring(0, 10);
  static Future<List<List<Book>>> home(
    LibraryStore store, {
    bool refresh = false,
  }) {
    final key = '${store.root.path}:${day()}';
    if (refresh) feeds.remove(key);
    return feeds.putIfAbsent(key, () async {
      final file = File('${store.root.path}/startup/${day()}/feed.json');
      if (!refresh && await file.exists()) {
        try {
          final j = jsonDecode(await file.readAsString()) as List;
          return j
              .map(
                (section) => (section as List)
                    .map((b) => Book.fromJson(Map<String, dynamic>.from(b)))
                    .toList(),
              )
              .toList();
        } catch (_) {}
      }
      try {
        final data = await Future.wait([Sources.ranking(), Sources.daily()]);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          jsonEncode(
            data.map((s) => s.map((b) => b.toJson()).toList()).toList(),
          ),
          flush: true,
        );
        return data;
      } catch (e) {
        feeds.remove(key);
        rethrow;
      }
    });
  }

  static Future<List<File>> prepare(LibraryStore store) async {
    store.startupBusy = true;
    try {
      final feed = await home(store);
      final jobs = [...feed[0].take(4), ...feed[1].take(6)];
      final images = <String, File>{};
      for (int i = 0; i < jobs.length; i += 2) {
        await Future.wait(
          jobs.skip(i).take(2).map((b) async {
            try {
              images[b.key] = await store.cover(b);
            } catch (_) {}
          }),
        );
      }
      final directory = Directory('${store.root.path}/startup/${day()}');
      await directory.create(recursive: true);
      final result = <File>[];
      for (final b in feed[1].take(6)) {
        final image = images[b.key];
        if (image == null) continue;
        final copy = File('${directory.path}/cover_${result.length}.jpg');
        await image.copy(copy.path);
        result.add(copy);
      }
      return result;
    } finally {
      store.startupBusy = false;
    }
  }
}
