import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'orb_controller.dart';
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

/// The orb's diameter and the call pill's height (design frames).
const orbSize = 56.0, orbPillHeight = 32.0;

/// One loop of the rings' pulse / the dashed ring's turn.
const _orbLoop = Duration(milliseconds: 1400);

/// The red dot of a call that listens, the green one of a call that speaks
/// or operates (design frame 09).
// ds-allow: the call dots are fixed signal colours in every theme (red listening, green speaking; design frame 09)
const orbLiveRed = Color(0xFFFF3B30);
// ds-allow: the call dots are fixed signal colours in every theme (red listening, green speaking; design frame 09)
const orbLiveGreen = Color(0xFF22C55E);

/// The little sound bars of the call pill and the subtitle.
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

/// What colour the rings of [state] are, or null when it has none.
Color? orbRingColor(RaftTokens t, OrbState state) => switch (state) {
  OrbState.idle => null,
  OrbState.listening => t.brutal ? t.product.brutalPink : t.accent,
  OrbState.speaking => orbLiveGreen,
  OrbState.operating ||
  OrbState.connecting ||
  OrbState.thinking => t.brutal ? t.product.brutalCyan : t.accent,
};

/// Whether the orb is part of a live call: the yellow orb with a dot.
bool orbIsLive(OrbState state) =>
    state == OrbState.listening ||
    state == OrbState.speaking ||
    state == OrbState.operating;

class _RingPainter extends CustomPainter {
  _RingPainter(this.state, this.color, this.scale, this.phase, this.level);
  final OrbState state;
  final Color color;
  final double scale;

  /// 0..1, one loop of the animation.
  final double phase;

  /// 0..1, how loud the person is (listening); 0 when unknown.
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final p = Paint()..style = PaintingStyle.stroke;
    if (state == OrbState.connecting || state == OrbState.thinking) {
      // A dashed ring that turns: the dashes fade along the trail.
      final rect = Rect.fromCircle(center: c, radius: r + 11 * scale);
      const n = 14;
      const arc = 2 * math.pi / n;
      final turn = phase * 2 * math.pi;
      for (var i = 0; i < n; i++) {
        p
          ..strokeWidth = (i == 0 ? 6.5 : 4.5) * scale
          ..strokeCap = StrokeCap.butt
          ..color = color.withValues(alpha: (1 - i / n * .85).clamp(.15, 1.0));
        canvas.drawArc(rect, turn - i * arc, arc * .58, false, p);
      }
      return;
    }
    // Rings that breathe; the person's voice pushes them out.
    final pulse =
        (math.sin(phase * 2 * math.pi) + 1) / 2 * 2 +
        (state == OrbState.listening ? level * 9 : 0);
    final rings = state == OrbState.speaking
        ? const [(7.0, .95, 3.5), (16.0, .5, 3.0), (26.0, .22, 2.5)]
        : const [(6.0, .95, 3.5), (13.0, .5, 3.0), (20.0, .22, 2.5)];
    for (final (gap, alpha, w) in rings) {
      p
        ..color = color.withValues(alpha: alpha)
        ..strokeWidth = w * scale;
      canvas.drawCircle(c, r + (gap + pulse) * scale, p);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}

/// The orb itself: a face in a circle. Idle it is cream with no ring; a call
/// being set up has a turning dashed ring; a live call has a yellow orb, rings
/// (pink while it listens, following [level]; green while the agent speaks;
/// cyan while it operates the app) and a dot. Tap, long-press and drag are the
/// caller's ([OrbBall] adds them).
class AgentOrb extends StatefulWidget {
  const AgentOrb({
    super.key,
    this.state = OrbState.idle,
    this.size = orbSize,
    this.level,
  });
  final OrbState state;
  final double size;

  /// How loud the person is, 0..1; null when there is no microphone to ask.
  final ValueListenable<double>? level;

  @override
  State<AgentOrb> createState() => _AgentOrbState();
}

class _AgentOrbState extends State<AgentOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController loop = AnimationController(
    vsync: this,
    duration: _orbLoop,
  );

  bool get _animates => widget.state != OrbState.idle;

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
      // ignore: raft_lints/avoid_unreviewed_idle_work -- Runs only while a call or a turn is on (the orb is not idle); it stops with the state and under reduced motion.
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
    final live = orbIsLive(state);
    final ringColor = orbRingColor(t, state);
    final fill = t.brutal
        ? (live ? t.product.brutalYellow : t.product.brutalCream)
        : t.card;
    final level = widget.level;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (ringColor != null)
            Positioned.fill(
              child: AnimatedBuilder(
                key: ValueKey('orb-rings-${state.name}'),
                animation: Listenable.merge([loop, ?level]),
                builder: (context, _) => CustomPaint(
                  painter: _RingPainter(
                    state,
                    ringColor,
                    scale,
                    loop.value,
                    level?.value ?? 0,
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
                      : (live ? t.accent : t.line),
                  // ds-allow: the orb's rim is drawn at the design's 3 / 1.5 dp and scales with the orb
                  // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                  width: (t.brutal || live ? 3 : 1.5) * scale,
                ),
                boxShadow: t.brutal
                    ? RaftProductShadows.shadowBrutal.paintOrder
                    : t.themeShadows.lg.paintOrder,
              ),
              child: Text(
                switch (state) {
                  OrbState.thinking => '🤔',
                  OrbState.speaking => '😄',
                  _ => '🙂',
                },
                textScaler: TextScaler.noScaling,
                style: RaftTypography.body(
                  t,
                  size: size * .5,
                  line: size * .5 * 1.15,
                ),
              ),
            ),
          ),
          if (live)
            Positioned(
              right: -4 * scale,
              top: -4 * scale,
              child: DecoratedBox(
                key: const ValueKey('orb-dot'),
                decoration: BoxDecoration(
                  color: state == OrbState.listening
                      ? orbLiveRed
                      : orbLiveGreen,
                  shape: BoxShape.circle,
                  border: Border.all(
                    // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
                    color: t.brutal ? t.product.brutalBlack : Colors.white,
                    // ds-allow: the dot's rim is drawn at the design's 2.5 dp and scales with the orb
                    // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                    width: 2.5 * scale,
                  ),
                ),
                // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
                child: SizedBox.square(dimension: 18 * scale),
              ),
            ),
        ],
      ),
    );
  }
}

/// The orb with its gestures: tap, long-press and, for the floating one, drag.
/// It shows [controller]'s state and follows the person's voice.
class OrbBall extends StatelessWidget {
  const OrbBall({
    super.key,
    required this.controller,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
  });
  final OrbController controller;
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Agent',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: controller.tapOrb,
      onLongPress: controller.longPressOrb,
      onPanStart: onPanStart,
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) =>
            AgentOrb(state: controller.state, level: controller.voice.micLevel),
      ),
    ),
  );
}
