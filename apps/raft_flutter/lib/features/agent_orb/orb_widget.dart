import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'orb_state.dart';

/// A floating chip surface: the theme's card with its frame and shadow.
BoxDecoration orbSurface(RaftTokens t, {Color? fill, double radius = 999}) =>
    BoxDecoration(
      color: fill ?? t.card,
      border: Border.all(
        color: t.brutal ? t.product.brutalBlack : t.line,
        width: t.border,
      ),
      borderRadius: t.brutal
          ? BorderRadius.zero
          : BorderRadius.circular(radius),
      boxShadow: t.brutal
          ? RaftProductShadows.shadowBrutalSm.paintOrder
          : t.themeShadows.md.paintOrder,
    );

/// The orb's diameter and the status chip's height (design frames).
const orbSize = 56.0, orbChipHeight = 28.0;

/// One loop of the listening pulse / thinking spinner.
const _orbLoop = Duration(milliseconds: 1400);

/// The status chip next to the orb ("正在说", "正在操作", "在想…").
class OrbChip extends StatelessWidget {
  const OrbChip({super.key, required this.label, this.fill, this.leading});
  final String label;
  final Widget? leading;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: orbChipHeight),
      padding: const EdgeInsets.symmetric(
        horizontal: RaftSpace.x3,
        vertical: RaftSpace.x1,
      ),
      decoration: orbSurface(t, fill: fill),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: RaftSpace.x1_5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RaftTypography.body(
                t,
                size: 12,
                line: 16,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The little sound bars of "正在说" and the transcript pill.
class OrbWaveBars extends StatelessWidget {
  const OrbWaveBars({super.key, required this.color, this.height = 14});
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    const heights = [.4, .75, 1.0, .6, .85, .45];
    return SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final (i, h) in heights.indexed) ...[
            Container(
              width: RaftSpace.x1,
              height: height * h,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(RaftSpace.half),
              ),
            ),
            if (i != heights.length - 1) const SizedBox(width: RaftSpace.half),
          ],
        ],
      ),
    );
  }
}

/// The chip for [state], or null when it needs none. [connecting] is a call
/// that is still being set up.
Widget? orbStatusChip(
  BuildContext context,
  OrbState state, {
  bool connecting = false,
}) {
  final t = RaftTokens.of(context);
  switch (state) {
    case OrbState.speaking:
      return OrbChip(
        label: '正在说',
        fill: t.brutal ? t.product.brutalLime : null,
        leading: OrbWaveBars(
          color: t.brutal ? t.product.brutalBlack : t.accent,
        ),
      );
    case OrbState.operating:
      return OrbChip(
        label: '正在操作',
        fill: t.brutal ? t.product.brutalCyan : null,
        leading: RaftIcon(RaftGlyph.activity, size: 14, color: t.strong),
      );
    case OrbState.thinking:
      return OrbChip(label: connecting ? '连接中…' : '在想…');
    case OrbState.idle:
    case OrbState.listening:
      return null;
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.state, this.color, this.brutal, this.scale, this.phase);
  final OrbState state;
  final Color color;
  final bool brutal;
  final double scale;

  /// 0..1, one loop of the animation.
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final p = Paint()..style = PaintingStyle.stroke;
    if (state == OrbState.listening) {
      final pulse = (math.sin(phase * 2 * math.pi) + 1) / 2 * 3;
      for (final (gap, alpha, w) in [
        (6.0, .9, 3.0),
        (13.0, .45, 3.0),
        (19.0, .2, 2.0),
      ]) {
        p
          ..color = color.withValues(alpha: alpha)
          ..strokeWidth = w * scale;
        canvas.drawCircle(c, r + (gap + pulse) * scale, p);
      }
    } else if (state == OrbState.thinking) {
      p
        ..color = color
        ..strokeWidth = 4 * scale
        ..strokeCap = brutal ? StrokeCap.butt : StrokeCap.round;
      final rect = Rect.fromCircle(center: c, radius: r + 8 * scale);
      const sweep = 1.25;
      final turn = phase * 2 * math.pi;
      for (var i = 0; i < 3; i++) {
        canvas.drawArc(
          rect,
          -1.2 + i * 2.0944 + turn,
          sweep,
          false,
          p..color = color.withValues(alpha: 1 - i * .3),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.state != state || old.phase != phase || old.color != color;
}

/// The orb itself: a face in a circle, with pulsing rings while it listens and
/// a turning ring while it thinks. Tap, long-press and drag are the caller's
/// ([OrbBall] adds them).
class AgentOrb extends StatefulWidget {
  const AgentOrb({super.key, this.state = OrbState.idle, this.size = orbSize});
  final OrbState state;
  final double size;

  @override
  State<AgentOrb> createState() => _AgentOrbState();
}

class _AgentOrbState extends State<AgentOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController loop = AnimationController(
    vsync: this,
    duration: _orbLoop,
  );

  bool get _animates =>
      widget.state == OrbState.listening || widget.state == OrbState.thinking;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AgentOrb old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_animates && !reduce) {
      // ignore: raft_lints/avoid_unreviewed_idle_work -- Runs only while the orb listens or thinks (a call is on); it stops with the state and under reduced motion.
      if (!loop.isAnimating) loop.repeat();
    } else if (loop.isAnimating) {
      loop.stop();
    }
  }

  @override
  void dispose() {
    loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final size = widget.size;
    final scale = size / orbSize;
    final state = widget.state;
    final active = state != OrbState.idle;
    final ringColor = switch (state) {
      OrbState.listening => t.brutal ? t.product.brutalPink : t.accent,
      OrbState.thinking => t.brutal ? t.product.brutalCyan : t.accent,
      _ => t.accent,
    };
    final fill = t.brutal
        ? (active ? t.product.brutalYellow : t.product.brutalCream)
        : t.card;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: loop,
              builder: (context, _) => CustomPaint(
                painter: _RingPainter(
                  state,
                  ringColor,
                  t.brutal,
                  scale,
                  loop.value,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Container(
              key: const ValueKey('agent-orb'),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: Border.all(
                  color: t.brutal
                      ? t.product.brutalBlack
                      : (active ? t.accent : t.line),
                  // ds-allow: the orb's rim is drawn at the design's 3 / 1.5 dp and scales with the orb
                  width: (t.brutal ? 3 : 1.5) * scale,
                ),
                boxShadow: t.brutal
                    ? RaftProductShadows.shadowBrutal.paintOrder
                    : t.themeShadows.lg.paintOrder,
              ),
              child: Text(
                state == OrbState.thinking ? '🤔' : '🙂',
                textScaler: TextScaler.noScaling,
                style: RaftTypography.body(
                  t,
                  size: size * .5,
                  line: size * .5 * 1.15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The orb with its gestures: tap, long-press and, for the floating one, drag.
class OrbBall extends StatelessWidget {
  const OrbBall({
    super.key,
    required this.state,
    required this.onTap,
    required this.onLongPress,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
  });
  final OrbState state;
  final VoidCallback onTap, onLongPress;
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Agent',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      onPanStart: onPanStart,
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      child: AgentOrb(state: state),
    ),
  );
}
