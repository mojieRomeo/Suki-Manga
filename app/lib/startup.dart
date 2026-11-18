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
      try {
        return await Future.wait([Sources.ranking(), Sources.daily()]);
      } catch (_) {
        feeds.remove(key);
        rethrow;
      }
    });
  }

  static Future<void> prepare(LibraryStore store) async {
    store.startupBusy = true;
    try {
      final feed = await home(store);
      final jobs = [...feed[0].take(4), ...feed[1].take(6)];
      for (int i = 0; i < jobs.length; i += 2) {
        await Future.wait(
          jobs.skip(i).take(2).map((b) async {
            try {
              await store.cover(b);
            } catch (_) {}
          }),
        );
      }
    } finally {
      store.startupBusy = false;
    }
  }
}
