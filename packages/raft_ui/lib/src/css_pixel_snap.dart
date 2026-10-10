import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// Paints [child] at a device-pixel-aligned position.
///
/// Blink keeps fractional layout (a `leading-[16.5px]` line, `items-center`
/// half pixels) but snaps every box edge to a physical pixel when it paints;
/// Flutter paints the fraction, anti-aliasing borders into two grey rows.
/// This wrapper reproduces the snap for a block: the paint origin moves to
/// `round(global * dpr) / dpr` (round half up), the layout is untouched.
class RaftCssPixelSnap extends SingleChildRenderObjectWidget {
  const RaftCssPixelSnap({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCssPixelSnap(MediaQuery.devicePixelRatioOf(context));

  @override
  void updateRenderObject(BuildContext context, _RenderCssPixelSnap object) {
    object.devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

class _RenderCssPixelSnap extends RenderProxyBox {
  _RenderCssPixelSnap(this._dpr);
  double _dpr;
  set devicePixelRatio(double value) {
    if (_dpr == value) return;
    _dpr = value;
    markNeedsPaint();
  }

  double _snap(double v) => ((v * _dpr + .5).floorToDouble()) / _dpr;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final global = localToGlobal(Offset.zero);
    final shift = Offset(
      _snap(global.dx) - global.dx,
      _snap(global.dy) - global.dy,
    );
    context.paintChild(child, offset + shift);
  }
}
