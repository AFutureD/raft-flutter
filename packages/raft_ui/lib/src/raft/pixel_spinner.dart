// raft-ui 0.7.1 `Spinner`: four square pixels in a 2x2 grid that light up clockwise (top-left, top-right,
// bottom-right, bottom-left), 1s per turn, `steps(1)`. With reduced motion only the first pixel is lit.
import 'package:flutter/material.dart';

/// `size` axis of the `spinner` recipe: pixel edge and gap in px.
enum RaftPixelSpinnerSize {
  xs(4, 1.5),
  sm(5, 2),
  md(6, 2),
  lg(8, 3);

  const RaftPixelSpinnerSize(this.pixel, this.gap);
  final double pixel, gap;

  /// Edge of the whole grid.
  double get extent => pixel * 2 + gap;
}

class RaftPixelSpinner extends StatefulWidget {
  const RaftPixelSpinner({
    super.key,
    this.size = RaftPixelSpinnerSize.sm,
    this.color,
    this.semanticLabel = 'Loading',
  });
  final RaftPixelSpinnerSize size;

  /// `text-current`; defaults to the ambient text colour.
  final Color? color;
  final String semanticLabel;

  @override
  State<RaftPixelSpinner> createState() => _RaftPixelSpinnerState();
}

class _RaftPixelSpinnerState extends State<RaftPixelSpinner>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  void _sync(bool animate) {
    if (!animate) {
      _controller?.dispose();
      _controller = null;
    } else if (_controller == null) {
      // ignore: raft_lints/avoid_unreviewed_idle_work -- Loop driven by an AnimationController whose vsync is this State, so TickerMode (hidden routes, offstage tabs, folded panels) mutes it, it is disposed with the widget, and reduced motion stops it.
      _controller = AnimationController(
        vsync: this,
        duration: const Duration(seconds: 1),
      )..repeat();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync(!MediaQuery.disableAnimationsOf(context));
    final color =
        widget.color ??
        DefaultTextStyle.of(context).style.color ??
        Colors.black;
    final extent = widget.size.extent;
    final painter = (double? phase) => _PixelPainter(widget.size, color, phase);
    return Semantics(
      label: widget.semanticLabel,
      liveRegion: true,
      child: SizedBox.square(
        dimension: extent,
        child: _controller == null
            ? CustomPaint(painter: painter(null))
            : AnimatedBuilder(
                animation: _controller!,
                builder: (context, _) =>
                    CustomPaint(painter: painter(_controller!.value)),
              ),
      ),
    );
  }
}

class _PixelPainter extends CustomPainter {
  _PixelPainter(this.size, this.color, this.phase);
  final RaftPixelSpinnerSize size;
  final Color color;

  /// 0..1 through the turn; null when motion is reduced.
  final double? phase;

  // Clockwise order of the grid cells (column, row).
  static const _cells = [(0, 0), (1, 0), (1, 1), (0, 1)];

  @override
  void paint(Canvas canvas, Size _) {
    final lit = phase == null ? 0 : (phase! * 4).floor().clamp(0, 3);
    for (var i = 0; i < 4; i++) {
      final (col, row) = _cells[i];
      final rect = Rect.fromLTWH(
        col * (size.pixel + size.gap),
        row * (size.pixel + size.gap),
        size.pixel,
        size.pixel,
      );
      final paint = Paint()
        ..color = color.withValues(alpha: color.a * (i == lit ? 1 : .2));
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PixelPainter old) =>
      old.size != size || old.color != color || old.phase != phase;
}
