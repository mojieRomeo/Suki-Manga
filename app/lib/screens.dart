import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'reader.dart';
import 'startup.dart';

String megabytes(int bytes) => '${(bytes / 1048576).toStringAsFixed(2)} MB';

// Walk files away from the UI isolate; each file is statted once per refresh.
Future<List<Json>> scanCacheFolder(String path, bool analysis) =>
    Isolate.run(() {
      final folder = Directory(path);
      if (!folder.existsSync()) return <Json>[];
      final rows = <Json>[];
      for (final entry in folder.listSync(followLinks: false)) {
        if (entry is Link) continue;
        int bytes = 0;
        try {
          if (entry is File) {
            bytes = entry.lengthSync();
          } else if (entry is Directory) {
            for (final file in entry.listSync(
              recursive: true,
              followLinks: false,
            )) {
              if (file is File) bytes += file.lengthSync();
            }
          }
          String? source;
          if (analysis && entry is File) {
            try {
              source =
                  (jsonDecode(entry.readAsStringSync()) as Map)['sourcePath']
                      as String?;
            } catch (_) {}
          }
          rows.add({
            'path': entry.path,
            'directory': entry is Directory,
            'bytes': bytes,
            'source': source,
          });
        } on FileSystemException {
          /* A download may replace a file during a scan. */
        }
      }
      rows.sort((a, b) => (b['bytes'] as int).compareTo(a['bytes'] as int));
      return rows;
    });

class CacheBrowser extends StatefulWidget {
  final LibraryStore store;
  const CacheBrowser(this.store, {super.key});
  @override
  State<CacheBrowser> createState() => _CacheBrowserState();
}

class _CacheBrowserState extends State<CacheBrowser> {
  int category = 0, page = 0;
  static const pageSize = 20;
  bool deleting = false;
  late Future<List<Json>> entries;
  final folders = ['analysis', 'covers', 'pages', 'imports', 'startup'];
  @override
  void initState() {
    super.initState();
    entries = scan();
  }

  Future<List<Json>> scan() async {
    final selected = category;
    final titles = <String, String>{}, chapters = <String, String>{};
    for (final book in widget.store.books) {
      titles['${keyFor(book.key)}.img'] = book.title;
      titles[book.id] = book.title;
      for (final chapter in book.chapters) {
        final path = widget.store
            .chapterDir(book, chapter)
            .path
            .replaceAll('\\', '/');
        chapters[path] = '${book.title} · ${chapter.title}';
        titles[path.split('/').last] = chapters[path]!;
      }
    }
    final rows = await scanCacheFolder(
      '${widget.store.root.path}/${folders[selected]}',
      selected == 0,
    );
    for (final row in rows) {
      final path = row['path'] as String;
      final name = path.replaceAll('\\', '/').split('/').last;
      row['entry'] = row['directory'] == true ? Directory(path) : File(path);
      row['title'] = titles[name] ?? name;
      final source = row['source'];
      if (source is String && source.replaceAll('\\', '/').contains('/')) {
        final normalized = source.replaceAll('\\', '/');
        final parent = normalized.substring(0, normalized.lastIndexOf('/'));
        if (chapters.containsKey(parent)) {
          final index =
              int.tryParse(normalized.split('/').last.split('.').first) ?? 0;
          row['title'] = '${chapters[parent]} · 第 ${index + 1} 页识别';
        }
      }
    }
    return rows;
  }

  Future<void> removeRows(List<Json> rows) async {
    final total = rows.fold<int>(0, (sum, r) => sum + (r['bytes'] as int));
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这些缓存？'),
        content: Text(
          '${rows.length} 项 · ${megabytes(total)}\n${widget.store.root.path}/${folders[category]}/\n删除所选文件；进度、心愿单和原始导入文件保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => deleting = true);
    int removed = 0;
    final rowsByPath = {
      for (final row in rows) (row['entry'] as FileSystemEntity).path: row,
    };
    try {
      await widget.store.deleteCacheEntries(
        rows.map((row) => row['entry'] as FileSystemEntity).toList(),
        onDeleted: (entry) {
          final row = rowsByPath[entry.path];
          if (row != null) removed += row['bytes'] as int;
        },
      );
      if (category == 4) {
        StartupData.feeds.clear();
        PaintingBinding.instance.imageCache.clear();
      }
      if (mounted) message(context, '已删除 ${megabytes(removed)} 存储文件');
    } catch (e) {
      if (mounted) {
        message(context, '已删除 ${megabytes(removed)}；${friendlyError(e)}');
      }
    }
    if (mounted) {
      setState(() {
        deleting = false;
        entries = scan();
      });
    }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('所有缓存')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < 5; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(['识别结果', '封面', '章节图片', '导入副本', '每日开屏'][i]),
                      selected: category == i,
                      onSelected: deleting
                          ? null
                          : (_) => setState(() {
                              category = i;
                              page = 0;
                              entries = scan();
                            }),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Json>>(
            future: entries,
            builder: (c, s) {
              if (s.hasError) {
                return Center(child: Text(friendlyError(s.error!)));
              }
              if (!s.hasData) return const Busy();
              final rows = s.data!,
                  total = rows.fold<int>(
                    0,
                    (sum, r) => sum + (r['bytes'] as int),
                  );
              final pages = (rows.length / pageSize).ceil().clamp(1, 1 << 30);
              final current = page.clamp(0, pages - 1);
              final start = current * pageSize;
              final end = (start + pageSize).clamp(0, rows.length);
              return Column(
                children: [
                  ListTile(
                    title: Text('${rows.length} 项 · ${megabytes(total)}'),
                    subtitle: SelectableText(
                      '${widget.store.root.path}/${folders[category]}/',
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: TextButton(
                      onPressed: deleting || rows.isEmpty
                          ? null
                          : () => removeRows(rows),
                      child: const Text('清空此类'),
                    ),
                  ),
                  if (deleting) const LinearProgressIndicator(),
                  Expanded(
                    child: rows.isEmpty
                        ? const Center(child: Text('暂无缓存'))
                        : ListView.builder(
                            itemCount: end - start,
                            itemBuilder: (c, i) {
                              final row = rows[start + i];
                              return ListTile(
                                title: Text(
                                  row['title'],
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${megabytes(row['bytes'])}\n${(row['entry'] as FileSystemEntity).path}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: IconButton(
                                  tooltip: '删除所选缓存',
                                  onPressed: deleting
                                      ? null
                                      : () => removeRows([row]),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              );
                            },
                          ),
                  ),
                  if (rows.length > pageSize)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '上一页',
                          onPressed: deleting || current == 0
                              ? null
                              : () => setState(() => page = current - 1),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Text('${current + 1} / $pages 页 · ${start + 1}–$end 项'),
                        IconButton(
                          tooltip: '下一页',
                          onPressed: deleting || current + 1 >= pages
                              ? null
                              : () => setState(() => page = current + 1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

void message(BuildContext c, Object error) {
  ScaffoldMessenger.of(c)
      .showSnackBar(SnackBar(content: Text(friendlyError(error))));
}

String friendlyError(Object e) {
  if (e is PlatformException) return e.message ?? '书源操作未完成，请重试。';
  if (e is SocketException) {
    return '连接书源失败（${e.osError?.errorCode ?? '网络'}）。请确认此网络能打开所选站点，然后重试。';
  }
  if (e is TimeoutException) return '书源响应超时，请稍后重试。';
  if (e is HttpException) return e.message;
  return e.toString().replaceFirst('Bad state: ', '');
}

class Busy extends StatelessWidget {
  const Busy({super.key});
  @override
  Widget build(BuildContext c) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: CircularProgressIndicator(strokeWidth: 2.5),
    ),
  );
}

class Failure extends StatelessWidget {
  final Object error;
  final VoidCallback retry;
  const Failure(this.error, this.retry, {super.key});
  @override
  Widget build(BuildContext c) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_outlined, size: 36),
          const SizedBox(height: 12),
          Text(friendlyError(error), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: retry, child: const Text('重试')),
          if (error is SourceVerificationRequired)
            TextButton.icon(
              icon: const Icon(Icons.open_in_browser),
              label: const Text('验证书源'),
              onPressed: () async {
                try {
                  await Sources.verify(
                    (error as SourceVerificationRequired).url,
                  );
                  if (c.mounted) retry();
                } catch (e) {
                  if (c.mounted) message(c, e);
                }
              },
            ),
        ],
      ),
    ),
  );
}

class Cover extends StatefulWidget {
  final Book book;
  final LibraryStore store;
  final BoxFit fit;
  const Cover(
    this.book, {
    super.key,
    required this.store,
    this.fit = BoxFit.cover,
  });
  @override
  State<Cover> createState() => _CoverState();
}

class _CoverState extends State<Cover> {
  Book get book => widget.book;
  LibraryStore get store => widget.store;
  BoxFit get fit => widget.fit;
  Future<File>? _future;
  void prepare() {
    if (book.source != 'local' && book.cover.isNotEmpty) {
      _future = store.cover(book);
    }
  }

  @override
  void initState() {
    super.initState();
    prepare();
  }

  @override
  void didUpdateWidget(Cover old) {
    super.didUpdateWidget(old);
    if (old.book.key != book.key || old.book.cover != book.cover) {
      _future = null;
      prepare();
    }
  }

  Widget failed() => ColoredBox(
    color: const Color(0xffe9e5f2),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.image_not_supported_outlined),
          IconButton(
            tooltip: '重试封面',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(prepare),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext c) {
    final fallback = ColoredBox(
      color: const Color(0xffe9e5f2),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            book.title,
            textAlign: TextAlign.center,
            style: Theme.of(c).textTheme.titleMedium,
          ),
        ),
      ),
    );
    if (book.source == 'local' &&
        book.chapters.isNotEmpty &&
        book.chapters.first.pages.isNotEmpty) {
      return Image.file(
        File(book.chapters.first.pages.first),
        fit: fit,
        errorBuilder: (_, e, s) => fallback,
      );
    }
    if (book.cover.isEmpty) return fallback;
    return FutureBuilder<File>(
      future: _future,
      builder: (c, s) {
        if (s.hasError) return failed();
        if (!s.hasData) return const Busy();
        return Image.file(
          s.data!,
          fit: fit,
          errorBuilder: (_, e, s) => failed(),
        );
      },
    );
  }
}

class LibraryHome extends StatefulWidget {
  final LibraryStore store;
  const LibraryHome({super.key, required this.store});
  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  int tab = 0;
  final tabHistory = <int>[];
  String sort = '最近阅读';
  bool importing = false;
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.store.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.removeListener(changed);
    search.dispose();
    super.dispose();
  }

  void detail(Book b) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => BookDetail(store: widget.store, book: b),
    ),
  );
  Future<void> importBook() async {
    setState(() => importing = true);
    try {
      final b = await widget.store.importFile();
      if (b != null && mounted) detail(b);
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final store = widget.store;
    var books = store.books;
    if (tab == 2) {
      books = books.where((b) => store.favorites.contains(b.key)).toList();
    }
    if (tab == 0) {
      books = books.where((b) => store.progress(b).isNotEmpty).toList();
    }
    books.sort(
      (a, b) => sort == '书名'
          ? a.title.compareTo(b.title)
          : ((store.progress(b)['time'] ?? 0) as int).compareTo(
              (store.progress(a)['time'] ?? 0) as int,
            ),
    );
    return PopScope(
      canPop: tabHistory.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && tabHistory.isNotEmpty) {
          setState(() => tab = tabHistory.removeLast());
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                children: [
                  if (tab != 3)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                      child: SearchBar(
                        elevation: const WidgetStatePropertyAll(0),
                        controller: search,
                        hintText: '在 Suki Manga 中搜索漫画',
                        leading: const Icon(Icons.search),
                        trailing: [
                          IconButton(
                            tooltip: '设置与缓存',
                            onPressed: () => Navigator.push(
                              c,
                              MaterialPageRoute(
                                builder: (_) => SettingsPage(store),
                              ),
                            ),
                            icon: const CircleAvatar(
                              radius: 18,
                              child: Icon(Icons.person_outline, size: 22),
                            ),
                          ),
                        ],
                        onSubmitted: (q) => Navigator.push(
                          c,
                          MaterialPageRoute(
                            builder: (_) =>
                                DiscoverPage(store: store, query: q),
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: tab == 3
                          ? 2
                          : tab == 0
                          ? 0
                          : 1,
                      children: [
                        HomeFeed(store: store, onTap: detail),
                        Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    tab == 2 ? '心愿单' : '我的书库',
                                    style: Theme.of(c).textTheme.titleLarge,
                                  ),
                                  const Spacer(),
                                  PopupMenuButton<String>(
                                    tooltip: '排序',
                                    initialValue: sort,
                                    onSelected: (s) => setState(() => sort = s),
                                    itemBuilder: (_) => ['最近阅读', '书名']
                                        .map(
                                          (s) => PopupMenuItem(
                                            value: s,
                                            child: Text(s),
                                          ),
                                        )
                                        .toList(),
                                    icon: const Icon(Icons.sort),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: importing
                                  ? const Busy()
                                  : books.isEmpty
                                  ? Center(
                                      child: Icon(
                                        tab == 2
                                            ? Icons.bookmark_border
                                            : tab == 1
                                            ? Icons.library_books_outlined
                                            : Icons.auto_stories_outlined,
                                        size: 40,
                                        color: Theme.of(c).colorScheme.primary,
                                      ),
                                    )
                                  : tab == 1
                                  ? LibraryRows(
                                      store: store,
                                      books: books,
                                      onTap: detail,
                                    )
                                  : BookGrid(
                                      books: books,
                                      store: store,
                                      onTap: detail,
                                    ),
                            ),
                          ],
                        ),
                        DiscoverPage(store: store, embedded: true),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        floatingActionButton: tab == 1
            ? FloatingActionButton.extended(
                onPressed: importing ? null : importBook,
                icon: const Icon(Icons.add),
                label: const Text('导入漫画'),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) {
            if (i != tab) {
              setState(() {
                tabHistory.add(tab);
                tab = i;
              });
            }
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: '首页',
            ),
            NavigationDestination(
              icon: Icon(Icons.library_books_outlined),
              selectedIcon: Icon(Icons.library_books),
              label: '书库',
            ),
            NavigationDestination(
              icon: Icon(Icons.bookmark_border),
              selectedIcon: Icon(Icons.bookmark),
              label: '心愿单',
            ),
            NavigationDestination(
              icon: Icon(Icons.explore_outlined),
              selectedIcon: Icon(Icons.explore),
              label: '发现',
            ),
          ],
        ),
      ),
    );
  }
}

class BookGrid extends StatelessWidget {
  final List<Book> books;
  final LibraryStore store;
  final void Function(Book) onTap;
  const BookGrid({
    super.key,
    required this.books,
    required this.store,
    required this.onTap,
  });
  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (c, box) {
      final columns = box.maxWidth > 720 ? 4 : 2;
      final width = (box.maxWidth - 44 - (columns - 1) * 18) / columns;
      return GridView.builder(
        key: const PageStorageKey('book-grid'),
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 90),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: width * 1.42 + 64,
          crossAxisSpacing: 18,
          mainAxisSpacing: 20,
        ),
        itemCount: books.length,
        itemBuilder: (c, i) => InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onTap(books[i]),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: width * 1.42,
                width: double.infinity,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Cover(books[i], store: store),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                books[i].title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                readingLabel(store, books[i]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(c).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String readingLabel(LibraryStore store, Book b) {
  final p = store.progress(b);
  final saved = store.books.where((item) => item.key == b.key).firstOrNull;
  final chapter = (saved ?? b).chapters
      .where((c) => c.id == p['chapter'])
      .firstOrNull;
  final total = p['total'] as int? ?? 0;
  final percent = total > 0
      ? (((p['page'] as int? ?? 0) + 1) / total * 100).round().clamp(0, 100)
      : 0;
  return '${chapter?.title ?? '未开始'} · 已读 $percent%';
}

class LibraryRows extends StatelessWidget {
  final LibraryStore store;
  final List<Book> books;
  final void Function(Book) onTap;
  const LibraryRows({
    super.key,
    required this.store,
    required this.books,
    required this.onTap,
  });
  @override
  Widget build(BuildContext c) => ListView.separated(
    key: const PageStorageKey('library-list'),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
    itemCount: books.length,
    separatorBuilder: (_, i) => const Divider(height: 28),
    itemBuilder: (c, i) {
      final b = books[i], time = store.progress(b)['time'] as int?;
      final date = time == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(time);
      return InkWell(
        onTap: () => onTap(b),
        child: Row(
          children: [
            SizedBox(
              width: 80,
              height: 110,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Cover(b, store: store),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    readingLabel(store, b),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    date == null
                        ? '尚未阅读'
                        : '最后阅读：${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(c).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_forward,
              size: 20,
              color: Theme.of(c).colorScheme.primary,
            ),
          ],
        ),
      );
    },
  );
}

class HomeFeed extends StatefulWidget {
  final LibraryStore store;
  final void Function(Book) onTap;
  const HomeFeed({super.key, required this.store, required this.onTap});
  @override
  State<HomeFeed> createState() => _HomeFeedState();
}

class _HomeFeedState extends State<HomeFeed> {
  late Future<List<List<Book>>> feed;
  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() {
    feed = StartupData.home(widget.store);
  }

  @override
  Widget build(BuildContext c) => FutureBuilder<List<List<Book>>>(
    future: feed,
    builder: (c, s) {
      final available = MediaQuery.sizeOf(c).width.clamp(0.0, 1000.0);
      final columns = available > 720 ? 4 : 2;
      final coverWidth = (available - 44 - (columns - 1) * 18) / columns;
      if (s.hasError) return Failure(s.error!, () => setState(reload));
      if (!s.hasData) return const Busy();
      return RefreshIndicator(
        onRefresh: () async {
          setState(() => feed = StartupData.home(widget.store, refresh: true));
          await feed;
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            for (int section = 0; section < 2; section++) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 4),
                child: Text(
                  section == 0 ? 'MangaDex 排行榜' : '每日推荐',
                  style: Theme.of(c).textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Text(
                  section == 0 ? '按收藏人数排序' : '从近期更新中每日精选',
                  style: Theme.of(c).textTheme.bodySmall,
                ),
              ),
              SizedBox(
                height: coverWidth * 1.42 + 88,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(22, 12, 22, 12),
                  itemCount: s.data![section].length,
                  separatorBuilder: (_, i) => const SizedBox(width: 18),
                  itemBuilder: (c, i) {
                    final b = s.data![section][i];
                    return SizedBox(
                      width: coverWidth,
                      child: InkWell(
                        onTap: () => widget.onTap(b),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: coverWidth * 1.42,
                              width: coverWidth,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Cover(b, store: widget.store),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              b.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              section == 0
                                  ? '收藏榜第 ${i + 1} 名'
                                  : readingLabel(widget.store, b),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class DiscoverPage extends StatefulWidget {
  final LibraryStore store;
  final String query;
  final bool embedded;
  const DiscoverPage({
    super.key,
    required this.store,
    this.query = '',
    this.embedded = false,
  });
  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  String source = 'md', query = '';
  late Future<List<Book>> results;
  final input = TextEditingController();
  List<Book> items = [];
  bool more = false, hasMore = true;
  String? moreError;
  int ticket = 0;
  int resultPage = 0;
  bool changingPage = false;
  final resultPages = <int, List<Book>>{};
  @override
  void initState() {
    super.initState();
    query = widget.query;
    input.text = query;
    reload();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void reload() {
    resultPage = 0;
    resultPages.clear();
    ticket++;
    items = [];
    hasMore = true;
    more = false;
    moreError = null;
    results = query.trim().isEmpty
        ? Future.value([])
        : Sources.search(source, query.trim(), limit: 30);
  }

  Future<void> changePage(int target) async {
    if (target < 0 || changingPage) return;
    final t = ticket;
    setState(() => changingPage = true);
    try {
      final next =
          resultPages[target] ??
          await Sources.search(source, query, offset: target * 30, limit: 30);
      if (mounted && t == ticket) {
        setState(() {
          if (next.isEmpty && target > 0) {
            hasMore = false;
            return;
          }
          resultPages[target] = next;
          items = next;
          resultPage = target;
          hasMore = next.length == 30;
          moreError = null;
        });
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => changingPage = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final content = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: SearchBar(
            elevation: const WidgetStatePropertyAll(0),
            controller: input,
            hintText: '在 ${source == 'md' ? 'MangaDex' : '拷贝漫画'} 中搜索漫画',
            leading: const Icon(Icons.search),
            onSubmitted: (value) => setState(() {
              query = value;
              reload();
            }),
            trailing: [
              IconButton(
                tooltip: '搜索',
                icon: const Icon(Icons.arrow_forward),
                onPressed: () => setState(() {
                  query = input.text;
                  reload();
                }),
              ),
              PopupMenuButton<String>(
                tooltip: '切换书源',
                initialValue: source,
                onSelected: (value) => setState(() {
                  source = value;
                  reload();
                }),
                icon: CircleAvatar(
                  radius: 18,
                  child: Text(
                    source == 'md' ? 'M' : '拷',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                itemBuilder: (_) => [
                  const PopupMenuItem<String>(
                    enabled: false,
                    child: Text('书源'),
                  ),
                  CheckedPopupMenuItem<String>(
                    value: 'md',
                    checked: source == 'md',
                    child: const Text('MangaDex'),
                  ),
                  CheckedPopupMenuItem<String>(
                    value: 'copy',
                    checked: source == 'copy',
                    child: const Text('拷贝漫画'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Book>>(
            future: results,
            builder: (c, s) {
              if (s.connectionState != ConnectionState.done) {
                return const Busy();
              }
              if (s.hasError) return Failure(s.error!, () => setState(reload));
              if (!resultPages.containsKey(0)) {
                items = List.of(s.data!);
                resultPages[0] = items;
                hasMore = items.length == 30;
              }
              if (items.isEmpty) {
                return Center(
                  child: Text(
                    query.trim().isEmpty ? '输入漫画名称开始搜索' : '没有找到漫画，换个关键词试试',
                  ),
                );
              }
              return Column(
                children: [
                  Expanded(
                    child: changingPage
                        ? const Busy()
                        : BookGrid(
                            key: ValueKey('$source:$query:$resultPage'),
                            books: items,
                            store: widget.store,
                            onTap: (b) => Navigator.push(
                              c,
                              MaterialPageRoute(
                                builder: (_) =>
                                    BookDetail(store: widget.store, book: b),
                              ),
                            ),
                          ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '上一页搜索结果',
                        onPressed: resultPage > 0 && !changingPage
                            ? () => changePage(resultPage - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('第 ${resultPage + 1} 页 · 每页 30 本'),
                      IconButton(
                        tooltip: '下一页搜索结果',
                        onPressed: hasMore && !changingPage
                            ? () => changePage(resultPage + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
    return widget.embedded
        ? content
        : Scaffold(
            appBar: AppBar(title: const Text('发现漫画')),
            body: content,
          );
  }
}

class BookDetail extends StatefulWidget {
  final LibraryStore store;
  final Book book;
  const BookDetail({super.key, required this.store, required this.book});
  @override
  State<BookDetail> createState() => _BookDetailState();
}

class _BookDetailState extends State<BookDetail> {
  late Future<void> loading;
  bool opening = false,
      downloading = false,
      descending = false,
      moreLoading = false;
  String filter = '';
  int downloaded = 0;
  @override
  void initState() {
    super.initState();
    final saved = widget.store.books
        .where((b) => b.key == widget.book.key)
        .firstOrNull;
    if (saved != null && widget.book.chapters.isEmpty) {
      widget.book.chapters = saved.chapters;
      widget.book.chapterOffset = saved.chapterOffset;
      widget.book.chapterTotal = saved.chapterTotal;
    }
    unawaited(native.invokeMethod('warmup').catchError((Object e) => null));
    load();
  }

  Object? chapterError;
  bool disposed = false;
  final readyChapters = <String>{};
  Timer? readinessTimer;
  Future<void> refreshReady() async {
    if (widget.store.analysisBusy && readinessTimer == null) {
      readinessTimer = Timer.periodic(const Duration(milliseconds: 500), (
        timer,
      ) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (!widget.store.analysisBusy) {
          timer.cancel();
          readinessTimer = null;
          unawaited(refreshReady());
        }
      });
    }
    for (final ch in widget.book.chapters.where((ch) => ch.pages.isNotEmpty)) {
      final ready = await widget.store.chapterReady(widget.book, ch);
      if (!mounted) return;
      setState(() {
        if (ready) {
          readyChapters.add(ch.id);
        } else {
          readyChapters.remove(ch.id);
        }
      });
    }
  }

  @override
  void dispose() {
    disposed = true;
    readinessTimer?.cancel();
    super.dispose();
  }

  void load() {
    chapterError = null;
    loading = Sources.chapters(widget.book).then((_) async {
      await widget.store.remember(widget.book);
      unawaited(refreshReady());
      if (mounted) {
        setState(() {});
        unawaited(continueChapters());
      }
    });
  }

  Future<void> continueChapters() async {
    if (moreLoading || widget.book.source != 'md') return;
    setState(() => moreLoading = true);
    try {
      while (!disposed &&
          widget.book.chapterOffset < widget.book.chapterTotal) {
        await Sources.moreChapters(widget.book);
        if (disposed) return;
        if (widget.book.chapterOffset % 500 == 0 ||
            widget.book.chapterOffset >= widget.book.chapterTotal) {
          await widget.store.remember(widget.book);
        }
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) setState(() => chapterError = e);
    } finally {
      if (mounted) setState(() => moreLoading = false);
    }
  }

  Future<void> read(Chapter ch) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await Sources.pages(widget.book, ch);
      await widget.store.remember(widget.book);
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) =>
                ReaderPage(store: widget.store, book: widget.book, chapter: ch),
          ),
        );
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) {
        setState(() => opening = false);
        unawaited(refreshReady());
      }
    }
  }

  Future<void> download(Chapter ch) async {
    if (downloading) return;
    setState(() {
      downloading = true;
      downloaded = 0;
    });
    try {
      await Sources.pages(widget.book, ch);
      await widget.store.remember(widget.book);
      for (int i = 0; i < ch.pages.length; i++) {
        final file = await widget.store.page(widget.book, ch, i);
        await widget.store.recognize(file, background: true);
        if (mounted) setState(() => downloaded = i + 1);
      }
      if (mounted) {
        setState(() => readyChapters.add(ch.id));
        message(context, '本章 ${ch.pages.length} 页已下载并识别完成');
      }
    } catch (e) {
      if (mounted) message(context, e);
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final b = widget.book, store = widget.store, p = store.progress(b);
    final favorite = store.favorites.contains(b.key);
    return Scaffold(
      appBar: AppBar(
        title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: favorite ? '移出心愿单' : '加入心愿单',
            onPressed: () async {
              await store.favorite(b);
              if (mounted) setState(() {});
            },
            icon: Icon(favorite ? Icons.bookmark : Icons.bookmark_border),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: FutureBuilder<void>(
            future: loading,
            builder: (c, s) {
              if (s.hasError && b.chapters.isEmpty) {
                return Failure(s.error!, () => setState(load));
              }
              var chapters = b.chapters
                  .where(
                    (ch) =>
                        ch.title.toLowerCase().contains(filter.toLowerCase()),
                  )
                  .toList();
              if (descending) chapters = chapters.reversed.toList();
              final resume =
                  b.chapters.where((ch) => ch.id == p['chapter']).firstOrNull ??
                  b.chapters.firstOrNull;
              return CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 115,
                                height: 164,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Cover(b, store: store),
                                ),
                              ),
                              const SizedBox(width: 20),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      b.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(c).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      '${b.source == 'md'
                                          ? 'MangaDex'
                                          : b.source == 'copy'
                                          ? '拷贝漫画'
                                          : '本地漫画'} · ${b.chapters.length} 章',
                                    ),
                                    const SizedBox(height: 18),
                                    opening
                                        ? const CircularProgressIndicator()
                                        : FilledButton.icon(
                                            onPressed: resume == null
                                                ? null
                                                : () => read(resume),
                                            icon: const Icon(
                                              Icons.auto_stories_outlined,
                                            ),
                                            label: Text(
                                              p.isEmpty ? '开始阅读' : '继续阅读',
                                            ),
                                          ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          if (b.description.isNotEmpty)
                            Text(
                              b.description,
                              maxLines: 8,
                              overflow: TextOverflow.ellipsis,
                            ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  onChanged: (v) => setState(() => filter = v),
                                  decoration: const InputDecoration(
                                    hintText: '筛选章节 / 语言',
                                    prefixIcon: Icon(Icons.search),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: '章节排序',
                                onPressed: () =>
                                    setState(() => descending = !descending),
                                icon: Icon(
                                  descending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                ),
                              ),
                            ],
                          ),
                          if (chapterError != null)
                            TextButton(
                              onPressed: () => continueChapters(),
                              child: const Text('章节加载失败，点击重试'),
                            ),
                          if ((s.connectionState != ConnectionState.done ||
                                  moreLoading) &&
                              chapters.isEmpty)
                            const Busy(),
                          if (filter.isNotEmpty &&
                              chapters.isEmpty &&
                              !moreLoading &&
                              s.connectionState == ConnectionState.done &&
                              chapterError == null)
                            const Text('没有匹配的章节'),
                          if (downloading)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Row(
                                children: [
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text('正在保存 · $downloaded 页'),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: chapters.length,
                    itemBuilder: (c, i) {
                      final ch = chapters[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                        ),
                        title: Text(ch.title),
                        leading: Icon(
                          ch.id == p['chapter']
                              ? Icons.play_circle_outline
                              : Icons.auto_stories_outlined,
                        ),
                        onTap: opening ? null : () => read(ch),
                        trailing: IconButton(
                          tooltip: readyChapters.contains(ch.id)
                              ? '已下载并识别完成'
                              : '下载并识别本章',
                          onPressed: downloading ? null : () => download(ch),
                          icon: Icon(
                            readyChapters.contains(ch.id)
                                ? Icons.download_done_rounded
                                : Icons.download_outlined,
                          ),
                        ),
                      );
                    },
                  ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 36)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final LibraryStore store;
  const SettingsPage(this.store, {super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool busy = false;
  @override
  Widget build(BuildContext c) {
    final store = widget.store;
    return Scaffold(
      appBar: AppBar(title: const Text('设置与缓存')),
      body: busy
          ? const Busy()
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                SwitchListTile(
                  title: const Text('默认逐格累积揭晓'),
                  subtitle: const Text('间隙不明确时显示整页；点空白处揭晓，滑动翻页'),
                  value: store.state['readerMode'] != 'page',
                  onChanged: (v) async {
                    await store.setSetting('readerMode', v ? 'panel' : 'page');
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('气泡浮层'),
                  subtitle: const Text('点击气泡才放大，再次点击收起'),
                  value: store.setting('bubbles', true),
                  onChanged: (v) async {
                    await store.setSetting('bubbles', v);
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('从右向左阅读'),
                  value: store.setting('rtl', true),
                  onChanged: (v) async {
                    await store.setSetting('rtl', v);
                    setState(() {});
                  },
                ),
                SwitchListTile(
                  title: const Text('阅读时保持屏幕常亮'),
                  value: store.setting('awake', true),
                  onChanged: (v) async {
                    await store.setSetting('awake', v);
                    setState(() {});
                  },
                ),
                const Divider(),
                const ListTile(
                  title: Text('我的缓存'),
                  subtitle: Text('仅主动删除，不自动清空。下面操作删除存储文件，不是释放运行内存。'),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('查看所有缓存'),
                  subtitle: const Text('按类型查看文件、位置、大小并选择删除'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    c,
                    MaterialPageRoute(builder: (_) => CacheBrowser(store)),
                  ),
                ),
                const Divider(),
                const ListTile(
                  title: Text('Suki Manga 0.8.7'),
                  subtitle: Text(
                    'Flutter · ExecuTorch · OpenCV\n识别在手机本地完成，在线书源需要网络。',
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
