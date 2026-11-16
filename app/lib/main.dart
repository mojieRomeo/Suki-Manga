import 'package:flutter/material.dart';

import 'data.dart';
import 'splash.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final proxy = await native.invokeMethod<String>('systemProxy');
  if (proxy != null && proxy.isNotEmpty) {
    Sources.client.findProxy = (_) => 'PROXY $proxy';
  }
  runApp(GejianApp(store: await LibraryStore.open()));
}

class GejianApp extends StatelessWidget {
  final LibraryStore store;
  const GejianApp({super.key, required this.store});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Suki Manga',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff605c94),
        surface: const Color(0xfffaf8ff),
      ),
      scaffoldBackgroundColor: const Color(0xfffaf8ff),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xfffaf8ff)),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xffefedf6),
      ),
    ),
    home: MuseSplash(store: store),
  );
}
