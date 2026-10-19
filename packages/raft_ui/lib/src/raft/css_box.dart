// A CSS-like box for the raft-ui 0.7.1 controls: fill, border, an inset ring, and outer rings (`ring-*`, the
// focus ring) that are painted outside the border box only. Flutter's BoxShadow paints under the whole box, so a
// translucent ring or a ring around a transparent button would tint the inside; this clips the rings out.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Whether captures come from a browser with an emulated device scale factor (the parity reference, Playwright
/// `deviceScaleFactor: 3`): Blink then does not zoom layout by the DPR, so a CSS border width floors to whole CSS
/// pixels (`border-[1.5px]` paints 1px). Only the parity harness sets it.
abstract final class RaftBorderSnap {
  static bool emulatedDeviceScaleFactor = false;
}

/// A CSS border width as Blink paints it: floored to whole device pixels (a real browser at 3x draws 1.5px as
/// 4 device px), or to whole CSS pixels under [RaftBorderSnap.emulatedDeviceScaleFactor]. Never below one device pixel.
double raftControlBorderPx(BuildContext context, double css) {
  final dpr = MediaQuery.devicePixelRatioOf(context);
  if (RaftBorderSnap.emulatedDeviceScaleFactor) {
    return css >= 1 ? css.floorToDouble() : 1 / dpr;
  }
  return math.max(1.0, (css * dpr).floorToDouble()) / dpr;
}

/// One outer ring, `0 0 0 <spread>px <color>`.
@immutable
class RaftRing {
  const RaftRing(this.spread, this.color);
  final double spread;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is RaftRing && other.spread == spread && other.color == color;

  @override
  int get hashCode => Object.hash(spread, color);
}

/// Rings in CSS box-shadow order (first = on top), as `ring-*` and `shadow-focus` compose them.
class RaftCssBox extends StatelessWidget {
  const RaftCssBox({
    super.key,
    this.radius = 0,
    this.fill,
    this.borderWidth = 0,
    this.borderColor,
    this.insetRingWidth = 0,
    this.insetRingColor,
    this.rings = const [],
    this.width,
    this.height,
    this.padding,
    this.alignment,
    this.child,
  });

  /// `rounded-*` of the border box.
  final double radius;
  final Color? fill;

  /// CSS `border` (layout: reduces the content box). Zero for none.
  final double borderWidth;
  final Color? borderColor;

  /// `inset-ring-*` / an inset box-shadow: painted inside the padding edge, no layout.
  final double insetRingWidth;
  final Color? insetRingColor;
  final List<RaftRing> rings;
  final double? width, height;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: borderRadius,
        border: borderWidth > 0 && borderColor != null
            ? Border.all(color: borderColor!, width: borderWidth)
            : null,
      ),
      position: DecorationPosition.background,
      child: _InsetRing(
        radius: radius - borderWidth,
        inset: borderWidth,
        width: insetRingWidth,
        color: insetRingColor,
        child: Padding(
          padding: EdgeInsets.all(borderWidth),
          child: child == null
              ? null
              : Padding(
                  padding: padding ?? EdgeInsets.zero,
                  child: Align(
                    alignment: alignment ?? Alignment.topLeft,
                    widthFactor: 1,
                    heightFactor: 1,
                    child: child,
                  ),
                ),
        ),
      ),
    );
    if (width != null || height != null) {
      box = SizedBox(width: width, height: height, child: box);
    }
    if (rings.isEmpty) return box;
    return CustomPaint(painter: _RingsPainter(radius, rings), child: box);
  }
}

class _InsetRing extends StatelessWidget {
  const _InsetRing({
    required this.radius,
    required this.inset,
    required this.width,
    required this.color,
    required this.child,
  });
  final double radius, inset, width;
  final Color? color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (width <= 0 || color == null) return child;
    return CustomPaint(
      foregroundPainter: _InsetRingPainter(
        radius: math.max(0, radius),
        width: width,
        color: color!,
      ),
      child: child,
    );
  }
}

class _InsetRingPainter extends CustomPainter {
  _InsetRingPainter({
    required this.radius,
    required this.width,
    required this.color,
  });
  final double radius, width;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final inner = outer.deflate(width);
    canvas.drawDRRect(outer, inner, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_InsetRingPainter old) =>
      old.radius != radius || old.width != width || old.color != color;
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.radius, this.rings);
  final double radius;
  final List<RaftRing> rings;

  @override
  void paint(Canvas canvas, Size size) {
    final box = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    // CSS paints the first shadow on top: draw the last (largest) ring first.
    for (final ring in rings.reversed) {
      canvas.drawDRRect(
        box.inflate(ring.spread),
        box,
        Paint()..color = ring.color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) =>
      old.radius != radius || !_same(old.rings, rings);

  static bool _same(List<RaftRing> a, List<RaftRing> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
