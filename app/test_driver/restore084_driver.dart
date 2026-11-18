import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final f = File('../reports/fix-088/ui/$name.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes);
      return true;
    },
  );
}
