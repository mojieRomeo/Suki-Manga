import 'package:flutter/cupertino.dart' show CupertinoSwitch;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';
import 'package:gejian/screens.dart';

class WaitingStore extends LibraryStore {
  final pending = Completer<File>();
  final requested = <int>[];
  WaitingStore() : super(Directory.systemTemp, {});
  @override
  Future<void> setSetting(String key, dynamic value) async {
    state[key] = value;
  }

  @override
  Future<File> page(Book b, Chapter c, int i) {
    requested.add(i);
    return pending.future;
  }
}

void main() {
  testWidgets(
    'loading swipes navigate and preload before current download ends',
    (t) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, (_) async => null);
      final store = WaitingStore();
      final ch = Chapter('wait', 'wait', pages: ['a', 'b']);
      final b = Book('wait', 'local', 'wait', '', chapters: [ch]);
      await t.pumpWidget(
        MaterialApp(
          home: ReaderPage(store: store, book: b, chapter: ch),
        ),
      );
      expect(find.text('1/2'), findsOneWidget);
      expect(store.requested, containsAll([0, 1]));
      await t.tap(find.byType(CupertinoSwitch));
      await t.pump();
      expect(store.state['readerMode'], 'page');
      await t.fling(
        find.byType(CircularProgressIndicator),
        const Offset(0, -200),
        800,
      );
      await t.pump();
      expect(find.text('2/2'), findsOneWidget);
      await t.fling(
        find.byType(CircularProgressIndicator),
        const Offset(0, 200),
        800,
      );
      await t.pump();
      expect(find.text('1/2'), findsOneWidget);
      await t.fling(
        find.byType(CircularProgressIndicator),
        const Offset(200, 0),
        800,
      );
      await t.pump();
      expect(find.text('2/2'), findsOneWidget);
      await t.fling(
        find.byType(CircularProgressIndicator),
        const Offset(-200, 0),
        800,
      );
      await t.pump();
      expect(find.text('1/2'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      store.pending.complete(File('unused'));
      await t.pump();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(native, null);
    },
  );
  testWidgets(
    'cache shows bytes and paths; deleting analysis preserves covers',
    (t) async {
      final root = await t.runAsync(
        () => Directory.systemTemp.createTemp('cache076-'),
      );
      try {
        final file = File('${root!.path}/analysis/sample.json');
        final cover = File('${root.path}/covers/keep.img');
        await t.runAsync(() async {
          await file.parent.create();
          await file.writeAsString('{}');
          await cover.parent.create();
          await cover.writeAsString('keep');
        });
        await t.pumpWidget(
          MaterialApp(home: CacheBrowser(LibraryStore(root, {}))),
        );
        for (
          int i = 0;
          i < 20 && find.text('sample.json').evaluate().isEmpty;
          i++
        ) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump();
        }
        expect(find.textContaining('sample.json'), findsWidgets);
        await t.tap(find.byTooltip('删除所选缓存'));
        await t.pumpAndSettle();
        expect(find.textContaining('0.00 MB'), findsWidgets);
        await t.tap(find.widgetWithText(FilledButton, '删除'));
        await t.pump();
        for (int i = 0; i < 20; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump();
        }
        expect(await t.runAsync(file.exists), false);
        expect(await t.runAsync(cover.exists), true);
        expect(find.textContaining('已删除 0.00 MB'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      } finally {
        await t.runAsync(() => root!.delete(recursive: true));
      }
    },
  );
}
