import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:gejian/data.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final sample in [('copy', 'one')]) {
    testWidgets('live ${sample.$1} search, chapters, pages', (tester) async {
      final result = await tester.runAsync(() async {
        final books = await Sources.search(sample.$1, sample.$2, limit: 30);
        expect(books, isNotEmpty);
        final book = books.first;
        await Sources.chapters(book);
        expect(book.chapters, isNotEmpty);
        await Sources.pages(book, book.chapters.first);
        expect(book.chapters.first.pages, isNotEmpty);
        final bytes = await Sources.bytes(
          book.chapters.first.pages.first,
          referer: Sources.refererFor(book.source),
        );
        expect(bytes.length, greaterThan(1000));
        return {
          'source': book.source,
          'title': book.title,
          'chapters': book.chapters.length,
          'pages': book.chapters.first.pages.length,
          'firstImageBytes': bytes.length,
        };
      });
      // ignore: avoid_print
      print('LIVE_SOURCE ${jsonEncode(result)}');
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
