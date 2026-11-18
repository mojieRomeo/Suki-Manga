import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/screens.dart';

List<Book> books(int count, String prefix) =>
    List.generate(count, (i) => Book('$prefix$i', 'local', '$prefix$i', ''));

void main() {
  testWidgets('every source disables next page for fewer than 30 results', (
    t,
  ) async {
    for (final source in Sources.names.keys) {
      for (final count in [2, 29, 30]) {
        await t.pumpWidget(
          MaterialApp(
            home: DiscoverPage(
              key: UniqueKey(),
              store: LibraryStore(Directory.systemTemp, {}),
            ),
          ),
        );
        await t.pumpAndSettle();
        final dynamic state = t.state(find.byType(DiscoverPage));
        state.setState(() {
          state.source = source;
          state.resultPages.clear();
          state.results = Future<List<Book>>.value(books(count, source));
        });
        await t.pumpAndSettle();
        final next = t.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.chevron_right),
        );
        expect(
          next.onPressed != null,
          count >= 30,
          reason: '$source: $count results',
        );
      }
    }
  });

  testWidgets('switching pages starts at top including cached previous pages', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: DiscoverPage(store: LibraryStore(Directory.systemTemp, {})),
      ),
    );
    await t.pumpAndSettle();
    final dynamic state = t.state(find.byType(DiscoverPage));
    state.setState(() {
      state.resultPages.clear();
      state.results = Future<List<Book>>.value(books(30, 'first-'));
      state.resultPages[1] = books(30, 'second-');
      state.resultPages[2] = books(2, 'last-');
    });
    await t.pumpAndSettle();
    ScrollPosition position() => t
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(GridView),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    position().jumpTo(position().maxScrollExtent);
    await t.pump();
    expect(position().pixels, greaterThan(0));
    await t.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
    await t.pumpAndSettle();
    expect(state.resultPage, 1);
    expect(position().pixels, 0);
    position().jumpTo(position().maxScrollExtent);
    await t.pump();
    await t.tap(find.widgetWithIcon(IconButton, Icons.chevron_left));
    await t.pumpAndSettle();
    expect(state.resultPage, 0);
    expect(position().pixels, 0);
    await t.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithIcon(IconButton, Icons.chevron_right));
    await t.pumpAndSettle();
    expect(state.resultPage, 2);
    expect(position().pixels, 0);
    expect(
      t
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.chevron_right),
          )
          .onPressed,
      isNull,
    );
    await state.changePage(3);
    expect(state.resultPage, 2);
  });
}
