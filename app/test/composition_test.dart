import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';
import 'package:gejian/reader.dart';

void main() {
  test('wide spread remains complete on its first reveal', () {
    final layout = <String, dynamic>{
      'width': 1400,
      'height': 1000,
      'panels': [
        {
          'box': [720, 20, 660, 950],
          'bubbles': [],
        },
        {
          'box': [20, 20, 660, 950],
          'bubbles': [],
        },
      ],
    };
    LibraryStore.groupArtwork(layout);
    expect(layout['wholePage'], true);
    expect(readingBeats(layout, true).single.full, true);
  });
  test('three aligned lower strips remain independent reveals', () {
    final layout = <String, dynamic>{
      'width': 1000,
      'height': 1500,
      'panels': [
        {
          'box': [10, 10, 980, 500],
          'bubbles': [],
        },
        for (final y in [750, 960, 1170])
          {
            'box': [10, y, 980, 200],
            'bubbles': [],
          },
      ],
    };
    LibraryStore.groupArtwork(layout);
    expect(layout['revealGroups'], isEmpty);
    expect(readingBeats(layout, true).map((b) => b.count), [1, 2, 3, 4]);
  });
  test('ordinary portrait side-by-side panels stay separate', () {
    final layout = <String, dynamic>{
      'width': 1000,
      'height': 1500,
      'panels': [
        {
          'box': [520, 10, 460, 1450],
          'bubbles': [],
        },
        {
          'box': [10, 10, 460, 1450],
          'bubbles': [],
        },
      ],
    };
    LibraryStore.groupArtwork(layout);
    expect(layout['wholePage'], false);
    expect(readingBeats(layout, true).length, 2);
  });
  test('pagination metadata survives saving a book', () {
    final b = Book('x', 'md', 'Title', '')
      ..chapterOffset = 100
      ..chapterTotal = 5000;
    final restored = Book.fromJson(b.toJson());
    expect(restored.chapterOffset, 100);
    expect(restored.chapterTotal, 5000);
  });
}
