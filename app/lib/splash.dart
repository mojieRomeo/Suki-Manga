import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'screens.dart';
import 'startup.dart';

class MuseSplash extends StatefulWidget {
  final LibraryStore store;
  final VoidCallback? onArtworkReady;
  const MuseSplash({super.key, required this.store, this.onArtworkReady});
  @override
  State<MuseSplash> createState() => _MuseSplashState();
}

class _MuseSplashState extends State<MuseSplash> with TickerProviderStateMixin {
  late final AnimationController timeline, skipFade;
  ui.Image? title;
  bool finished = false, skipping = false, reduceMotion = false;
  bool homeReady = false;
  Timer? homeWarmup;

  @override
  void initState() {
    super.initState();
    timeline =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 3200),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => finished = true);
          }
        });
    skipFade = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => finished = true);
        }
      });
    unawaited(StartupData.prepare(widget.store).catchError((_) {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(prepareArtwork());
    });
  }

  Future<ui.Image> decode(String asset) async {
    final bytes = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  Future<void> prepareArtwork() async {
    // Decode before starting the clock; never swap artwork during a fade.
    late final ui.Image image;
    try {
      image = await decode('assets/branding/startup_title.png');
    } catch (_) {
      // A damaged installation must still be able to reach the homepage.
      if (!mounted) return;
      widget.onArtworkReady?.call();
      if (!finished) enter();
      return;
    }
    if (!mounted || finished) {
      image.dispose();
      return;
    }
    setState(() {
      title = image;
    });
    reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) timeline.duration = const Duration(milliseconds: 1400);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    var initialProgress = 0.0;
    if (!reduceMotion) {
      try {
        final elapsed = await native.invokeMethod<int>('startupElapsed');
        // The native splash already shows the same wordmark while Dart loads.
        initialProgress = ((elapsed ?? 0) / 3200).clamp(0.0, 1800 / 3200);
      } on MissingPluginException {
        // Widget tests and other platforms start the complete Flutter timeline.
      } on PlatformException {
        // Startup remains usable if the timing hint is unavailable.
      }
    }
    if (!mounted) return;
    widget.onArtworkReady?.call();
    // Render the wordmark before paying the cost of building the homepage.
    homeWarmup = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => homeReady = true);
    });
    if (mounted && !finished && !skipping) {
      timeline.forward(from: initialProgress);
    }
  }

  void enter() {
    if (finished || skipping) return;
    skipping = true;
    // Freeze the artwork and fade it out without rushing through later stages.
    timeline.stop();
    reduceMotion = MediaQuery.disableAnimationsOf(context);
    skipFade.animateTo(
      1,
      duration: Duration(milliseconds: reduceMotion ? 150 : 500),
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void dispose() {
    timeline.dispose();
    skipFade.dispose();
    homeWarmup?.cancel();
    title?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ExcludeSemantics(
        excluding: !finished,
        child: IgnorePointer(
          ignoring: !finished,
          child: homeReady || skipping || finished
              ? RepaintBoundary(child: LibraryHome(store: widget.store))
              : const ColoredBox(color: Colors.black),
        ),
      ),
      if (!finished)
        AnimatedBuilder(
          animation: Listenable.merge([timeline, skipFade]),
          builder: (context, _) {
            final normalExit = const Interval(
              2000 / 3200,
              1,
              curve: Curves.easeInOutCubic,
            ).transform(timeline.value);
            final exit = normalExit + (1 - normalExit) * skipFade.value;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value:
                  (exit < .65
                          ? SystemUiOverlayStyle.light
                          : SystemUiOverlayStyle.dark)
                      .copyWith(
                        statusBarColor: Colors.transparent,
                        systemNavigationBarColor: Colors.transparent,
                        systemNavigationBarDividerColor: Colors.transparent,
                      ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enter,
                child: Opacity(
                  opacity: 1 - exit,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Colors.black),
                      Semantics(
                        label: 'Suki Manga',
                        image: true,
                        child: title == null
                            ? Image.asset(
                                'assets/branding/startup_title.png',
                                fit: BoxFit.fill,
                                excludeFromSemantics: true,
                              )
                            : RawImage(image: title, fit: BoxFit.fill),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
    ],
  );
}
