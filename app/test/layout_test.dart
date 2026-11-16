import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/screens.dart';

void main() {
  testWidgets(
    'covers keep equal heights with long titles and whole cards open',
    (t) async {
      final books = [
        Book('a', 'local', 'Long title ' * 20, ''),
        Book('b', 'local', 'Short', ''),
      ];
      final store = LibraryStore(Directory.systemTemp, {});
      Book? opened;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookGrid(
              books: books,
              store: store,
              onTap: (b) => opened = b,
            ),
          ),
        ),
      );
      final a = t.getRect(find.byType(Cover).at(0)),
          b = t.getRect(find.byType(Cover).at(1));
      expect(a.height, b.height);
      expect(a.top, b.top);
      expect(find.text('查看系列漫画'), findsNothing);
      final title = t.widget<Text>(find.text(books[0].title).last);
      expect(title.maxLines, 1);
      await t.tap(find.text('Short').last);
      expect(opened, books[1]);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('library shows last read date and a tappable row', (t) async {
    final book = Book(
      'a',
      'local',
      'Title',
      '',
      chapters: [Chapter('c', '第 2 章')],
    );
    final store = LibraryStore(Directory.systemTemp, {
      'progress': {
        book.key: {
          'chapter': 'c',
          'page': 17,
          'total': 100,
          'time': DateTime(2026, 11, 13).millisecondsSinceEpoch,
        },
      },
    });
    bool opened = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryRows(
            store: store,
            books: [book],
            onTap: (_) => opened = true,
          ),
        ),
      ),
    );
    expect(find.text('第 2 章 · 已读 18%'), findsOneWidget);
    expect(find.text('最后阅读：2026-11-13'), findsOneWidget);
    await t.tap(find.text('最后阅读：2026-11-13'));
    expect(opened, true);
  });
}
