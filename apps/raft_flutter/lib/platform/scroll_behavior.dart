import 'package:flutter/material.dart';

/// Flutter 3.47.6's Impeller stretch effect disposes its previous shader during
/// build. ImageFiltered can then compare that old, lazily converted filter to
/// the new filter and dereference the disposed shader in ImageFilter::initShader
/// (Android native crash). Use Flutter's shader-free overscroll feedback until
/// the pinned SDK fixes that lifecycle; keep platform physics and scrollbars.
class RaftScrollBehavior extends MaterialScrollBehavior {
  const RaftScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (getPlatform(context) != TargetPlatform.android) {
      return super.buildOverscrollIndicator(context, child, details);
    }
    return GlowingOverscrollIndicator(
      axisDirection: details.direction,
      // ds-allow: Platform overscroll feedback follows Flutter's native glow colour; no Raft component owns this system decoration.
      color: Theme.of(context).colorScheme.secondary,
      child: child,
    );
  }
}
