part of 'data.dart';

class WebsiteVerificationRequired implements Exception {
  final String url, kind, message;
  WebsiteVerificationRequired(this.url, this.kind, this.message);
  Future<bool> open() async {
    await WebSources.browser(url, kind, interactive: true);
    return true;
  }

  @override
  String toString() => message;
}

// Site adapters only: page recognition and reader state remain in the reader.
class WebSources {
  static const roots = <String, String>{'copy': 'https://www.copy4000.com/'};
  static String absolute(String source, String path) =>
      Uri.parse(roots[source] ?? (throw StateError('此书源已移除，请切换书源')))
          .resolve(path)
          .toString();

  static Future<String> document(String url, {String kind = 'html'}) async {
    try {
      return utf8.decode(await Sources.bytes(url));
    } on HttpException catch (e) {
      if (!e.message.contains('403') && !e.message.contains('503')) rethrow;
      return browser(url, kind);
    }
  }

  static Future<String> browser(
    String url,
    String kind, {
    bool interactive = false,
  }) async {
    String? result;
    try {
      result = await native.invokeMethod<String>('sourcePage', {
        'url': url,
        'kind': kind,
        'interactive': interactive,
      });
    } on PlatformException catch (e) {
      if (e.code == 'SOURCE_VERIFICATION') {
        throw WebsiteVerificationRequired(
          url,
          kind,
          '此书源需要网站验证。可点击“验证书源”继续，或切换其他书源。',
        );
      }
      rethrow;
    }
    if (result == null || result.isEmpty) throw StateError('书源没有返回内容');
    return result;
  }

  static Future<List<Book>> search(
    String source,
    String query, {
    required int offset,
    required int limit,
  }) async {
    if (!roots.containsKey(source)) throw StateError('此书源已移除，请切换书源');
    if (source == 'copy') {
      final d = await Sources.json(
        '${roots[source]}api/kb/web/searchcl/comics?platform=2&offset=$offset&limit=$limit&q=${Uri.encodeComponent(query)}&q_type=',
      );
      if (d['code'] != 200) throw StateError(d['message'] ?? '拷贝漫画暂不可用');
      return (d['results']['list'] as List)
          .map(
            (b) => Book(
              b['path_word'],
              source,
              b['name'],
              b['cover'] ?? '',
              description: (b['author'] as List? ?? [])
                  .map((a) => a['name'])
                  .join(' / '),
            ),
          )
          .toList();
    }

    throw StateError('此书源已移除，请切换书源');
  }

  static Future<void> chapters(Book book) async {
    final source = book.source;
    if (source == 'copy') {
      final route = '/comic/${book.id}';
      final raw = await native.invokeMethod<String>('copy', {
        'route': route,
        'kind': 'detail',
        'html': await document(absolute(source, route)),
      });
      final seen = <String>{};
      book.chapters =
          (jsonDecode(raw!) as List)
              .where((v) => seen.add(v['id']))
              .map((v) => Chapter(v['id'], v['title']))
              .toList()
            ..sort((a, b) => naturalCompare(a.title, b.title));
      return;
    }

    throw StateError('此书源已移除，请切换书源');
  }

  static Future<List<String>> pages(Book book, Chapter chapter) async {
    final source = book.source;
    if (source == 'copy') {
      final route = '/comic/${book.id}/chapter/${chapter.id}';
      final raw = await native.invokeMethod<String>('copy', {
        'route': route,
        'kind': 'chapter',
        'html': await document(absolute(source, route)),
      });
      return List<String>.from(jsonDecode(raw!));
    }

    throw StateError('此书源已移除，请切换书源');
  }
}
