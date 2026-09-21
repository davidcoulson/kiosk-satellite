import 'package:flutter/material.dart';

import '../managers/theater/theater_manager.dart';

/// Theater mode's layer over the whole display: a black wash that takes the
/// page darker than the backlight can, and the touch gate that keeps the
/// first touch in the dark from pressing anything.
///
/// Sits under the Lockdown shield and over everything else, the drawer
/// included, so an edge swipe in the dark only wakes the panel.
///
/// Two things are deliberate about how it is drawn:
///
/// * The wash is a plain colour whose alpha is animated, never an Opacity
///   over a child. An opacity layer above a hybrid-composition platform view
///   costs a saveLayer on every frame, and a scrolling poster grid under it
///   would stutter (NF-1).
/// * The wash never takes part in hit testing -- a ColoredBox is opaque to
///   hits and would swallow every touch even while peeking. Whether a touch
///   reaches the page is the Listener's behaviour alone: opaque keeps the
///   whole gesture (down, moves and up all follow the down's hit test) away
///   from the page, translucent lets it through while still counting it.
class TheaterOverlay extends StatelessWidget {
  const TheaterOverlay({super.key, required this.theater});

  final TheaterManager theater;

  static const fade = Duration(milliseconds: 400);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TheaterView>(
      valueListenable: theater.view,
      builder: (context, view, _) {
        if (!view.active) return const SizedBox.shrink();
        return Listener(
          behavior: view.absorbTouches
              ? HitTestBehavior.opaque
              : HitTestBehavior.translucent,
          onPointerDown: (_) => theater.touch(),
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: view.opacity),
              duration: fade,
              curve: Curves.easeInOut,
              builder: (context, alpha, _) => alpha <= 0.001
                  ? const SizedBox.expand()
                  : ColoredBox(
                      color: Color.fromRGBO(0, 0, 0, alpha),
                      child: const SizedBox.expand(),
                    ),
            ),
          ),
        );
      },
    );
  }
}
