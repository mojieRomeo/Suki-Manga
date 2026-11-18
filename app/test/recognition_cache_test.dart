import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gejian/data.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LibraryStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('recognition-cache-');
    store = LibraryStore(root, {});
  });
  tearDown(() => root.delete(recursive: true));
  Future<File> layout(File image, int value) async {
    final hash = sha256.convert(await image.readAsBytes());
    final file = File('${root.path}/analysis/et15-geometry26-$hash.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'width': 100,
        'height': 200,
        'compositionVersion': 5,
        'contentBoundsVersion': 2,
        'contentBounds': [0, 0, 100, 200],
        'panels': [
          {'value': value},
        ],
      }),
    );
    return file;
  }

  test('concurrent and memory results are independent snapshots', () async {
    final image = await File('${root.path}/page.img').writeAsBytes([1, 2, 3]);
    final disk = await layout(image, 1);
    final results = await Future.wait(
      List.generate(3, (_) => store.recognize(image)),
    );
    results.first['panels'][0]['value'] = 99;
    expect(results.last['panels'][0]['value'], 1);
    await disk.delete();
    expect((await store.recognize(image))['panels'][0]['value'], 1);
  });
  test('clearing analysis invalidates memory', () async {
    final image = await File('${root.path}/page.img').writeAsBytes([1]);
    await layout(image, 1);
    await store.recognize(image);
    await store.clearAnalysis();
    await layout(image, 2);
    expect((await store.recognize(image))['panels'][0]['value'], 2);
  });
  test('changed image cannot reuse stale recognition', () async {
    final image = await File('${root.path}/page.img').writeAsBytes([1]);
    await layout(image, 1);
    await store.recognize(image);
    await image.writeAsBytes([2, 3]);
    await layout(image, 2);
    expect((await store.recognize(image))['panels'][0]['value'], 2);
  });
}
