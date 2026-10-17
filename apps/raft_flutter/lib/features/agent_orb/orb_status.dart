import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'orb_controller.dart';
import 'orb_state.dart';
import 'orb_widget.dart';

/// "0:42", "11:05": the length of a call.
String orbClock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// What the call pill says and how it looks (design frame 09).
enum _PillKind { connecting, thinking, live, ended }

/// The pill next to the orb: cyan "连接中…" while a call is set up, black
/// "● 通话中 0:42 · 在听" while it is live (the dot is red while it listens,
/// green while the agent speaks or operates), grey "已挂断 · 通话 0:42" for a
/// few seconds after it. Nothing while the orb is idle.
///
/// [compact] leaves out the "· 在听" part, for the layer where the orb docks
/// next to the input.
class OrbCallPill extends StatelessWidget {
  const OrbCallPill({
    super.key,
    required this.controller,
    this.compact = false,
  });
  final OrbController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, controller.callSeconds]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final c = controller;
    final t = RaftTokens.of(context);
    final state = c.state;
    final ended = c.endedCallLength;
    final clock = orbClock(c.callLength);
    final inCall = c.inCall;
    final String text;
    final _PillKind kind;
    switch (state) {
      case OrbState.connecting:
        kind = _PillKind.connecting;
        text = '连接中…';
      case OrbState.thinking:
        kind = _PillKind.thinking;
        text = '在想…';
      case OrbState.idle:
        if (ended == null) return const SizedBox.shrink();
        kind = _PillKind.ended;
        text = '已挂断 · 通话 ${orbClock(ended)}';
      case OrbState.listening:
        kind = _PillKind.live;
        text = compact ? '通话中 $clock' : '通话中 $clock · 在听';
      case OrbState.speaking:
        // A typed question answered aloud is not a call: no timer.
        kind = inCall ? _PillKind.live : _PillKind.thinking;
        text = !inCall ? '正在回答…' : (compact ? '通话中 $clock' : '通话中 $clock · 在说');
      case OrbState.operating:
        kind = _PillKind.live;
        final label = c.operating.label;
        final what = label == null ? '正在操作' : '打开了 $label';
        text = inCall ? '通话中 $clock · $what' : what;
    }
    final ink = t.brutal ? t.product.brutalBlack : t.strong;
    final body = RaftTypography.body(
      t,
      size: 13,
      line: 18,
      weight: FontWeight.w700,
      color: kind == _PillKind.live
          // ds-allow: the immersive layer is dark in every theme (design frames 05 and 10): white text on a black scrim, white dot rim and black pill ink
          ? (t.brutal ? Colors.white : t.canvas)
          : ink,
    );
    final label = Flexible(
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: body,
      ),
    );
    final Widget lead;
    Widget? tail;
    switch (kind) {
      case _PillKind.connecting:
        lead = _Spinner(color: ink);
      case _PillKind.thinking:
        lead = _Spinner(color: ink);
      case _PillKind.ended:
        // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
        lead = Icon(Icons.call_end_rounded, size: 15, color: ink);
      case _PillKind.live:
        final dot = state == OrbState.listening ? orbLiveRed : orbLiveGreen;
        lead = Container(
          // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
          width: 14,
          // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
          height: 14,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: dot.withValues(alpha: .35),
            shape: BoxShape.circle,
          ),
          child: Container(
            // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
            width: 8,
            // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
        );
        if (state == OrbState.listening) {
          tail = OrbWaveBars(
            color: t.brutal ? t.product.brutalPink : t.accent,
            height: 13,
          );
        } else if (state == OrbState.speaking) {
          tail = OrbWaveBars(color: orbLiveGreen, height: 13);
        }
    }
    final BoxDecoration decoration = switch (kind) {
      _PillKind.live => BoxDecoration(
        color: ink,
        // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
        borderRadius: BorderRadius.circular(t.brutal ? 0 : 999),
        border: t.brutal
            ? Border.all(color: t.product.brutalBlack, width: t.border)
            : null,
      ),
      _PillKind.connecting => orbSurface(
        t,
        fill: t.brutal ? t.product.brutalCyan : null,
      ),
      _PillKind.thinking => orbSurface(t),
      _PillKind.ended => orbSurface(
        t,
        fill: t.brutal ? t.product.brutalStone : null,
      ),
    };
    return Container(
      key: const ValueKey('orb-call-pill'),
      height: orbPillHeight,
      padding: const EdgeInsets.symmetric(horizontal: RaftSpace.x3),
      decoration: decoration,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          lead,
          const SizedBox(width: RaftSpace.x2),
          label,
          if (tail != null) ...[const SizedBox(width: RaftSpace.x2), tail],
        ],
      ),
    );
  }
}

/// The pill with "点球挂断" under it while a call is live (frames 03 and 04).
class OrbCallStatus extends StatelessWidget {
  const OrbCallStatus({
    super.key,
    required this.controller,
    this.alignEnd = true,
  });
  final OrbController controller;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        final live =
            controller.inCall &&
            state != OrbState.connecting &&
            state != OrbState.thinking;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: alignEnd
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            // A tap on the orb hangs up; in a call the pill opens the layer.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: live && !controller.layerOpen
                  ? () => unawaited(controller.openLayer())
                  : null,
              child: OrbCallPill(controller: controller),
            ),
            if (live)
              Padding(
                padding: const EdgeInsets.only(top: RaftSpace.x1),
                child: Text(
                  '点球挂断 · 点标签展开',
                  style: RaftTypography.body(
                    t,
                    size: 11,
                    line: 14,
                    weight: FontWeight.w600,
                    color: t.muted,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A small spinning arc, for "连接中…" and "在想…".
class _Spinner extends StatefulWidget {
  const _Spinner({required this.color});
  final Color color;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController turn = AnimationController(
    vsync: this,
    // ds-allow: layer and spinner motion timing from the approved design frames
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      turn.stop();
    } else if (!turn.isAnimating) {
      // ignore: raft_lints/avoid_unreviewed_idle_work -- Lives only inside the connecting / thinking pill; it is disposed with the pill and stops under reduced motion.
      turn.repeat();
    }
  }

  @override
  void dispose() {
    turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: turn,
    // ds-allow: orb, pill and layer geometry is set by the approved design frames (09, 05)
    child: SizedBox.square(
      dimension: 15,
      child: CustomPaint(painter: _SpinnerPainter(widget.color)),
    ),
  );
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = color.withValues(alpha: .25);
    final r = Rect.fromLTWH(1.5, 1.5, size.width - 3, size.height - 3);
    canvas.drawArc(r, 0, 2 * math.pi, false, p);
    p.color = color;
    canvas.drawArc(r, -1.0, 1.9, false, p);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.color != color;
}

/// The last [budget] "columns" of [text] (a Chinese character is two, so
/// twenty of them): a one-line subtitle shows the newest words.
String orbTail(String text, {int budget = 40}) {
  var used = 0;
  var i = text.length;
  while (i > 0) {
    final cost = text.codeUnitAt(i - 1) > 0x2e7f ? 2 : 1;
    if (used + cost > budget) break;
    used += cost;
    i--;
  }
  return i == 0 ? text : '…${text.substring(i)}';
}

/// The one-line subtitle above the orb: what the person is saying (in quotes,
/// with pink sound bars) and then the agent's current line (lime). It fades
/// out when the controller drops it, about two seconds after the last word.
class OrbSubtitleBubble extends StatelessWidget {
  const OrbSubtitleBubble({
    super.key,
    required this.controller,
    required this.maxWidth,
  });
  final OrbController controller;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final line = controller.subtitle;
      return AnimatedSwitcher(
        // ds-allow: layer and spinner motion timing from the approved design frames
        duration: const Duration(milliseconds: 200),
        child: line == null
            ? const SizedBox.shrink()
            : _Bubble(line: line, maxWidth: maxWidth),
      );
    },
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.line, required this.maxWidth});
  final OrbSubtitle line;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final text = orbTail(line.text);
    return Container(
      key: const ValueKey('orb-subtitle'),
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: RaftSpace.x3,
        vertical: RaftSpace.x2,
      ),
      decoration: orbSurface(
        t,
        radius: 16,
        fill: line.agent && t.brutal ? t.product.brutalLime : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (line.agent)
            Text(
              '🙂',
              textScaler: TextScaler.noScaling,
              style: RaftTypography.body(t, size: 16, line: 19),
            )
          else
            OrbWaveBars(
              color: t.brutal ? t.product.brutalPink : t.accent,
              height: 16,
            ),
          const SizedBox(width: RaftSpace.x2),
          Flexible(
            child: Text(
              line.agent ? text : '“$text”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RaftTypography.body(
                t,
                size: 14,
                line: 20,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
