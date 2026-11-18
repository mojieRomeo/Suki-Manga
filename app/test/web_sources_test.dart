import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    Sources.verifiedResponses.clear();
    messenger.setMockMethodCallHandler(native, null);
  });
  test('only supported adapters remain', () {
    expect(Sources.names.keys, unorderedEquals(['md', 'copy']));
    expect(WebSources.roots.keys, ['copy']);
  });
  test('removed adapters cannot fall back to another source', () async {
    await expectLater(
      WebSources.search('obsolete', '', offset: 0, limit: 30),
      throwsStateError,
    );
    final book = Book('1', 'obsolete', '', '');
    await expectLater(WebSources.chapters(book), throwsStateError);
    await expectLater(
      WebSources.pages(book, Chapter('1', '')),
      throwsStateError,
    );
  });
  test('Copy search preserves results and author', () async {
    const query = '异世界';
    final url =
        'https://www.copy4000.com/api/kb/web/searchcl/comics?platform=2&offset=0&limit=30&q=${Uri.encodeComponent(query)}&q_type=';
    Sources.verifiedResponses[url] = {
      'code': 200,
      'results': {
        'list': [
          {
            'path_word': 'sample',
            'name': query,
            'cover': 'https://example.com/a.jpg',
            'author': [
              {'name': '作者'},
            ],
          },
        ],
      },
    };
    final books = await WebSources.search('copy', query, offset: 0, limit: 30);
    expect(books.single.id, 'sample');
    expect(books.single.source, 'copy');
    expect(books.single.description, '作者');
  });
  test('verification requires an explicit action', () async {
    final calls = <bool>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      expect(call.method, 'sourcePage');
      calls.add(call.arguments['interactive'] == true);
      if (call.arguments['interactive'] != true) {
        throw PlatformException(code: 'SOURCE_VERIFICATION');
      }
      return '<html>verified</html>';
    });
    try {
      await WebSources.browser(WebSources.roots['copy']!, 'html');
      fail('verification must be requested');
    } on WebsiteVerificationRequired catch (e) {
      expect(calls, [false]);
      expect(await e.open(), true);
      expect(calls, [false, true]);
    }
  });
}
