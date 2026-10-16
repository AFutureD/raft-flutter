import 'package:flutter/material.dart';

import '../spotlight.dart';
import 'hf_scope.dart';
import 'hf_tokens.dart';

enum HfActionKind {
  /// Yellow: the one thing to do.
  primary,

  /// White: another way.
  secondary,

  /// Dashed outline, no fill: leave it for later.
  text,
}

/// A big button, at least 56 s high. On a TV (nothing can be pressed) the
/// same pill is drawn as a voice hint, "说「通过」", and does not react.
class HfAction extends StatefulWidget {
  const HfAction(
    this.label, {
    super.key,
    this.kind = HfActionKind.secondary,
    this.icon,
    this.onPressed,
    this.focusId,
    this.voice,
  });

  final String label;
  final HfActionKind kind;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// Makes the button something the agent can point at.
  final String? focusId;

  /// What the pill says on a TV; null is `说「label」`.
  final String? voice;

  static const minHeight = 56.0;

  @override
  State<HfAction> createState() => _HfActionState();
}

class _HfActionState extends State<HfAction> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final hint = !hf.interactive;
    final voice = widget.voice ?? '说「${widget.label}」';
    final text = widget.kind == HfActionKind.text;
    final radius = BorderRadius.circular(hf.sp(14));
    final lift = hf.sp(4);
    Widget face = Container(
      constraints: BoxConstraints(minHeight: hf.sp(HfAction.minHeight)),
      padding: EdgeInsets.symmetric(horizontal: hf.sp(8), vertical: hf.sp(6)),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: switch (widget.kind) {
          HfActionKind.primary => HfColors.sticker,
          HfActionKind.secondary => HfColors.card,
          HfActionKind.text => null,
        },
        borderRadius: radius,
        border: text ? null : Border.all(color: HfColors.ink, width: hf.sp(3)),
        boxShadow: text
            ? null
            : [
                BoxShadow(
                  color: HfColors.ink,
                  offset: Offset(0, _down ? 0 : lift),
                ),
              ],
      ),
      child: hint
          ? _VoiceHint(
              voice,
              style: hf.type(
                HfType.headline,
                color: text ? HfColors.inkSoft : HfColors.ink,
              ),
              lead: hf.type(HfType.body, color: HfColors.inkSoft),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: hf.sp(24), color: HfColors.ink),
                  SizedBox(width: hf.sp(8)),
                ],
                Flexible(
                  // Never cut a label with "…": a narrow button shrinks it.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      style: hf.type(
                        HfType.headline,
                        color: text ? HfColors.inkSoft : HfColors.ink,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
    if (text) {
      face = CustomPaint(
        foregroundPainter: _DashedOutline(
          radius: hf.sp(14),
          width: hf.sp(2.5),
          dash: hf.sp(8),
          color: HfColors.inkSoft,
        ),
        child: face,
      );
    }
    // The shadow is drawn below the box; keep room for it (the dashed one
    // too, so buttons side by side stay level).
    Widget button = Padding(
      padding: EdgeInsets.only(bottom: lift),
      child: Transform.translate(
        offset: Offset(0, _down && !text ? lift : 0),
        child: face,
      ),
    );
    if (hint) {
      button = Semantics(label: voice, excludeSemantics: true, child: button);
    } else {
      button = MouseRegion(
        cursor: widget.onPressed == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onPressed,
          child: button,
        ),
      );
      button = Semantics(
        button: true,
        label: widget.label,
        enabled: widget.onPressed != null,
        excludeSemantics: true,
        child: button,
      );
    }
    final id = widget.focusId;
    return id == null ? button : AgentFocusable(id: id, child: button);
  }
}

/// "说「打开讨论」" on one line when it fits, else "说" above "「打开讨论」".
class _VoiceHint extends StatelessWidget {
  const _VoiceHint(this.voice, {required this.style, required this.lead});
  final String voice;
  final TextStyle style, lead;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final one = TextPainter(
        text: TextSpan(text: voice, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout();
      final at = voice.indexOf('「');
      final fits = one.width <= box.maxWidth || at <= 0;
      // A narrow pill shrinks the words rather than cutting them.
      return FittedBox(
        fit: BoxFit.scaleDown,
        child: fits
            ? Text(voice, maxLines: 1, style: style)
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(voice.substring(0, at), maxLines: 1, style: lead),
                  Text(voice.substring(at), maxLines: 1, style: style),
                ],
              ),
      );
    },
  );
}

class _DashedOutline extends CustomPainter {
  _DashedOutline({
    required this.radius,
    required this.width,
    required this.dash,
    required this.color,
  });
  final double radius, width, dash;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(width / 2),
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    for (final m in path.computeMetrics()) {
      var at = 0.0;
      while (at < m.length) {
        canvas.drawPath(m.extractPath(at, at + dash), paint);
        at += dash * 1.9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutline old) =>
      old.radius != radius ||
      old.width != width ||
      old.dash != dash ||
      old.color != color;
}

/// The actions of a card, laid out for the width: side by side when there is
/// room (not on a phone), else the first on its own line above the rest. On
/// a TV they are voice hints.
class HfActions extends StatelessWidget {
  const HfActions({super.key, required this.actions});
  final List<HfAction> actions;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    if (actions.isEmpty) return const SizedBox.shrink();
    final gap = hf.sp(12);
    Widget row(List<HfAction> items) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(child: items[i]),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        // Three side by side need 340 s-units; a phone stacks them for the
        // thumb: the main action on its own line.
        if (actions.length < 3 || (!hf.phone && box.maxWidth / hf.s >= 340)) {
          return row(actions);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            actions.first,
            SizedBox(height: gap * .5),
            row(actions.sublist(1)),
          ],
        );
      },
    );
  }
}

/// A question with two answers: what is about to happen, then 确认 / 取消.
/// It can also be answered aloud ("对", "取消"); on a TV the two pills are
/// the words to say.
class HfConfirm extends StatelessWidget {
  const HfConfirm({
    super.key,
    required this.message,
    this.confirmLabel = '确认',
    this.cancelLabel = '取消',
    this.confirmVoice = '说「对」确认',
    this.cancelVoice = '说「取消」',
    this.onConfirm,
    this.onCancel,
    this.focusId,
  });

  /// "将把 #12 指派给 Bo —— 确认？"
  final String message;
  final String confirmLabel, cancelLabel;

  /// What the two pills say on a TV.
  final String confirmVoice, cancelVoice;
  final VoidCallback? onConfirm, onCancel;
  final String? focusId;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final card = Container(
      padding: EdgeInsets.all(hf.sp(16)),
      decoration: BoxDecoration(
        color: HfColors.card,
        borderRadius: BorderRadius.circular(hf.sp(16)),
        border: Border.all(color: HfColors.ink, width: hf.sp(3)),
        boxShadow: [
          BoxShadow(color: HfColors.sticker, offset: Offset(0, hf.sp(6))),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: hf.sp(8),
                  vertical: hf.sp(1),
                ),
                decoration: BoxDecoration(
                  color: HfColors.ink,
                  borderRadius: BorderRadius.circular(hf.sp(6)),
                ),
                child: Text(
                  '需要确认',
                  style: hf.type(HfType.meta, color: Colors.white),
                ),
              ),
            ],
          ),
          SizedBox(height: hf.sp(10)),
          Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: hf.type(HfType.headline),
          ),
          SizedBox(height: hf.sp(14)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: HfAction(
                  confirmLabel,
                  kind: HfActionKind.primary,
                  icon: Icons.check_rounded,
                  voice: confirmVoice,
                  onPressed: onConfirm,
                ),
              ),
              SizedBox(width: hf.sp(12)),
              Expanded(
                child: HfAction(
                  cancelLabel,
                  icon: Icons.close_rounded,
                  voice: cancelVoice,
                  onPressed: onCancel,
                ),
              ),
            ],
          ),
          if (hf.interactive) ...[
            SizedBox(height: hf.sp(6)),
            Text(
              '也可以直接说“对”或“取消”',
              style: hf.type(HfType.meta, color: HfColors.inkMuted),
            ),
          ],
        ],
      ),
    );
    final id = focusId;
    return id == null ? card : AgentFocusable(id: id, child: card);
  }
}
