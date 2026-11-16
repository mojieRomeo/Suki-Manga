import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'screens.dart';
import 'startup.dart';

class MuseSplash extends StatefulWidget {
  final LibraryStore store;
  const MuseSplash({super.key, required this.store});
  @override
  State<MuseSplash> createState() => _MuseSplashState();
}

class _MuseSplashState extends State<MuseSplash> with TickerProviderStateMixin {
  late final AnimationController motion, intro, fade;
  Timer? introTimer, exitTimer;
  ui.Image? wall;
  bool finished = false;
  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
    );
    motion = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
    fade =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 600),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            SystemChrome.setSystemUIOverlayStyle(
              SystemUiOverlayStyle.dark.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
              ),
            );
            setState(() => finished = true);
          }
        });
    unawaited(StartupData.prepare(widget.store).catchError((_) => <File>[]));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(loadWall());
      introTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        intro.forward();
        if (!MediaQuery.disableAnimationsOf(context)) motion.forward();
      });
      exitTimer = Timer(const Duration(milliseconds: 4900), enter);
    });
  }

  Future<void> loadWall() async {
    final bytes = await rootBundle.load('assets/branding/startup_fallback.jpg');
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    if (!mounted) {
      image.dispose();
      return;
    }
    // Decode once behind the title, never replace a visible wall.
    setState(() => wall = image);
  }

  void enter() {
    if (!mounted || finished || fade.isAnimating) return;
    introTimer?.cancel();
    exitTimer?.cancel();
    fade.forward();
  }

  @override
  void dispose() {
    introTimer?.cancel();
    exitTimer?.cancel();
    motion.dispose();
    intro.dispose();
    fade.dispose();
    wall?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      LibraryHome(store: widget.store),
      if (!finished)
        FadeTransition(
          opacity: ReverseAnimation(
            CurvedAnimation(parent: fade, curve: Curves.easeInOut),
          ),
          child: GestureDetector(
            onTap: enter,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xff242127)),
                AnimatedBuilder(
                  animation: motion,
                  builder: (context, _) => wall == null
                      ? Image.asset(
                          'assets/branding/startup_fallback.jpg',
                          fit: BoxFit.cover,
                        )
                      : CustomPaint(painter: _WallPainter(wall!, motion.value)),
                ),
                FadeTransition(
                  opacity: ReverseAnimation(
                    CurvedAnimation(parent: intro, curve: Curves.easeInOut),
                  ),
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: SizedBox(
                        width: MediaQuery.sizeOf(context).width * .52,
                        child: const FittedBox(
                          child: Text(
                            'Suki Manga',
                            style: TextStyle(
                              fontFamily: 'SukiDisplay',
                              fontSize: 48,
                              fontWeight: FontWeight.w400,
                              color: Colors.white,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

class _WallPainter extends CustomPainter {
  final ui.Image image;
  final double progress;
  _WallPainter(this.image, this.progress);
  @override
  void paint(Canvas canvas, Size size) {
    final height = size.width * image.height / image.width;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, -progress * size.height * .22, size.width, height),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WallPainter old) =>
      old.image != image || old.progress != progress;
}
