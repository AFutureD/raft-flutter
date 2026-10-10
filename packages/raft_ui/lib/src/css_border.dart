import 'dart:math' as math;

/// Chromium resolves a CSS border width to whole device pixels: widths below
/// one device pixel paint as one full-colour pixel, larger ones are floored
/// (`border-[0.5px]` is a 1px line at 1x and 2x, `1.5` device px floor to 1 at
/// 3x). Flutter draws a fractional logical width anti-aliased, i.e. a half
/// strength line, so snap the width the way Blink does.
///
/// Returns the logical width that covers exactly that many device pixels.
double raftCssBorderWidth(double cssWidth, double devicePixelRatio) {
  if (cssWidth <= 0) return 0;
  final device = math.max(1.0, (cssWidth * devicePixelRatio).floorToDouble());
  return device / devicePixelRatio;
}
