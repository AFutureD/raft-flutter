import 'package:flutter/material.dart';

import '../display_spec.dart';
import '../enter.dart';
import '../entity_blocks.dart';
import '../entity_model.dart';
import '../spotlight.dart';
import 'hf_blocks.dart';
import 'hf_describe.dart';
import 'hf_entity.dart';
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
      final width = one.width;
      one.dispose();
      final at = voice.indexOf('「');
      final fits = width <= box.maxWidth || at <= 0;
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
/// a TV they are voice hints. [oneRow] keeps them side by side on a phone too
/// (a stage under a row, which has little height to spare).
class HfActions extends StatelessWidget implements HfDescribed {
  const HfActions({super.key, required this.actions, this.oneRow = false});
  final List<HfAction> actions;
  final bool oneRow;

  @override
  HfDescription describe(HfDescribeEnv env) =>
      HfDescription(const [], actions: [for (final a in actions) a.label]);

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
        if (oneRow ||
            actions.length < 3 ||
            (!hf.phone && box.maxWidth / hf.s >= 340)) {
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

/// What is about to happen, and a yes / no: the question (or a title), the
/// changes as "field: from → to" lines, the thing it is about, then 确认 /
/// 取消. It can also be answered aloud ("对", "取消"); on a TV the two pills
/// are the words to say.
///
/// Once the operation ran (or runs, or failed) the pills give way to the
/// [outcome]; once it was decided, to [result]. The card locks itself after
/// the first press so a double tap cannot decide twice. [display]: the
/// `label` and the `field_names`; the changes, the outcome and the pills are
/// never left out, a confirmation is only worth anything if the person sees
/// what they confirm.
class HfConfirm extends StatefulWidget implements HfDescribed {
  const HfConfirm({
    super.key,
    required this.message,
    this.changes = const [],
    this.risk = AgentConfirmRisk.change,
    this.label = '将要修改',
    this.attachment,
    this.things = const [],
    this.outcome,
    this.result,
    this.display,
    this.confirmLabel,
    this.cancelLabel = '取消',
    this.confirmVoice = '说「对」确认',
    this.cancelVoice = '说「取消」',
    this.onConfirm,
    this.onCancel,
    this.focusId,
  });

  /// "将把 #12 指派给 Bo —— 确认？"
  final String message;

  /// "field: from → to" lines.
  final List<String> changes;
  final AgentConfirmRisk risk;

  /// The tag above the message of a plain confirmation.
  final String label;

  /// Under the changes: the things the operation is about, and after it ran,
  /// the thing it made (an entity card).
  final Widget? attachment;

  /// The things the operation is about, drawn as cards from the app's data
  /// (after [attachment]).
  final List<AgentEntityRef> things;
  final AgentActionOutcome? outcome;

  /// Set by the owner once the decision was carried out (or refused).
  final AgentConfirmResult? result;
  final DisplaySpec? display;

  /// The confirm pill; null is 确认 (确认执行 for a sensitive operation).
  final String? confirmLabel;
  final String cancelLabel;

  /// What the two pills say on a TV.
  final String confirmVoice, cancelVoice;
  final VoidCallback? onConfirm, onCancel;
  final String? focusId;

  /// The words of the tag above the message.
  String get tag => switch (outcome?.kind) {
    AgentOutcomeKind.running => '执行中',
    AgentOutcomeKind.done => '已完成',
    AgentOutcomeKind.failed => '没成功',
    null => risk == AgentConfirmRisk.sensitive ? '敏感操作' : label,
  };

  /// The voice hint under the pills of a card that waits.
  static const answerHint = '也可以直接说“对”或“取消”';

  /// A change as it is drawn: the field, then "from → to" or the value.
  static String changeLine(AgentChange c, {required bool showField}) {
    final from = c.from, to = c.to;
    final value = from != null && to != null
        ? '${from.isEmpty ? '（空）' : from} → ${to.isEmpty ? '（空）' : to}'
        : to;
    final field = showField || (from == null && to == null) ? c.field : null;
    return hfKept([field, value]).join('：');
  }

  @override
  HfDescription describe(HfDescribeEnv env) {
    final x = (display ?? DisplaySpec.none).resolve('ConfirmCard');
    final sensitive = risk == AgentConfirmRisk.sensitive;
    final o = outcome;
    final lines = <String>[
      if (x.has('label') || sensitive || o != null) tag,
      message,
      for (final line in changes.take(AgentBlockLimits.confirmChanges))
        changeLine(AgentChange.parse(line), showField: x.has('field_names')),
      for (final t in things)
        ...HfEntityCard(entity: t).describe(env.at(null)).lines,
    ];
    final actions = <String>[];
    if (o != null) {
      lines.add('${o.text}${_OutcomeRow.mark(o.kind)}');
      actions.addAll(_OutcomeRow.labels(o));
    } else if (result == null) {
      actions.addAll([
        confirmLabel ?? (sensitive ? '确认执行' : '确认'),
        cancelLabel,
      ]);
      lines.add(answerHint);
    } else {
      lines.add(result == AgentConfirmResult.confirmed ? '已确认' : '已取消');
    }
    return HfDescription(lines, actions: actions, block: true);
  }

  @override
  State<HfConfirm> createState() => _HfConfirmState();
}

class _HfConfirmState extends State<HfConfirm> {
  AgentConfirmResult? _decided;

  AgentConfirmResult? get _result => widget.result ?? _decided;

  void _decide(AgentConfirmResult r, VoidCallback? cb) {
    if (_result != null) return;
    setState(() => _decided = r);
    cb?.call();
  }

  /// The things the operation is about, as cards the app draws from its data.
  Widget _things(HfData hf) => Padding(
    padding: EdgeInsets.only(top: hf.rowGap * .5),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in widget.things)
          Padding(
            padding: EdgeInsets.only(bottom: hf.rowGap),
            child: HfEntityCard(entity: e),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (widget.display ?? DisplaySpec.none).resolve('ConfirmCard');
    final sensitive = widget.risk == AgentConfirmRisk.sensitive;
    final outcome = widget.outcome;
    final result = _result;
    final tag = widget.tag;
    final tagFill = switch (outcome?.kind) {
      AgentOutcomeKind.done => HfColors.progress,
      AgentOutcomeKind.failed => HfColors.decision,
      _ => sensitive ? HfColors.blocked : HfColors.ink,
    };
    final tagInk = tagFill == HfColors.ink ? Colors.white : HfColors.ink;
    final card = Semantics(
      container: true,
      label: '${sensitive ? '敏感操作，' : ''}${widget.message}',
      child: KeyedSubtree(
        key: ValueKey('confirm-card-${widget.risk.name}'),
        child: HfCard(
          tone: sensitive ? HfTone.decision : HfTone.sticker,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // A sensitive operation, and one that already ran, always say so.
              if (x.has('label') || sensitive || outcome != null)
                Padding(
                  padding: EdgeInsets.only(bottom: hf.sp(10)),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: hf.sp(8),
                          vertical: hf.sp(1),
                        ),
                        decoration: BoxDecoration(
                          color: tagFill,
                          borderRadius: BorderRadius.circular(hf.sp(6)),
                          border: tagFill == HfColors.ink
                              ? null
                              : Border.all(
                                  color: HfColors.ink,
                                  width: hf.sp(2),
                                ),
                        ),
                        child: Text(
                          tag,
                          style: hf.type(HfType.meta, color: tagInk),
                        ),
                      ),
                    ],
                  ),
                ),
              AgentTypeText(
                widget.message,
                maxLines: x.lines,
                style: hf.type(HfType.headline),
              ),
              if (widget.changes.isNotEmpty) SizedBox(height: hf.sp(10)),
              for (final line in widget.changes.take(
                AgentBlockLimits.confirmChanges,
              ))
                _ChangeRow(
                  change: AgentChange.parse(line),
                  showField: x.has('field_names'),
                ),
              if (widget.attachment != null) widget.attachment!,
              if (widget.things.isNotEmpty) _things(hf),
              SizedBox(height: hf.sp(14)),
              if (outcome != null)
                _OutcomeRow(outcome: outcome)
              else if (result == null) ...[
                Row(
                  key: const ValueKey('confirm-card-actions'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: AgentPop(
                        child: HfAction(
                          widget.confirmLabel ?? (sensitive ? '确认执行' : '确认'),
                          kind: HfActionKind.primary,
                          icon: Icons.check_rounded,
                          voice: widget.confirmVoice,
                          onPressed: () => _decide(
                            AgentConfirmResult.confirmed,
                            widget.onConfirm,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: hf.sp(12)),
                    Expanded(
                      flex: 2,
                      child: AgentPop(
                        order: 1,
                        child: HfAction(
                          widget.cancelLabel,
                          icon: Icons.close_rounded,
                          voice: widget.cancelVoice,
                          onPressed: () => _decide(
                            AgentConfirmResult.cancelled,
                            widget.onCancel,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (hf.interactive) ...[
                  SizedBox(height: hf.sp(6)),
                  Text(
                    HfConfirm.answerHint,
                    style: hf.type(HfType.meta, color: HfColors.inkMuted),
                  ),
                ],
              ] else
                Text(
                  result == AgentConfirmResult.confirmed ? '已确认' : '已取消',
                  key: ValueKey('confirm-card-${result.name}'),
                  style: hf.type(HfType.count),
                ),
            ],
          ),
        ),
      ),
    );
    final id = widget.focusId;
    return id == null ? card : AgentFocusable(id: id, child: card);
  }
}

class _OutcomeRow extends StatelessWidget {
  const _OutcomeRow({required this.outcome});
  final AgentActionOutcome outcome;

  static String mark(AgentOutcomeKind kind) => switch (kind) {
    AgentOutcomeKind.done => ' ✅',
    AgentOutcomeKind.failed => ' ⚠️',
    AgentOutcomeKind.running => '…',
  };

  /// The pills of a result card, in the order they are drawn.
  static List<String> labels(AgentActionOutcome o) => [
    if (o.onRetry != null) '重试',
    if (o.onUndo != null && o.undoLabel != null) '撤销（${o.undoLabel}）',
    if (o.onDismiss != null) '知道了',
  ];

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final o = outcome;
    final mark = _OutcomeRow.mark(o.kind);
    final buttons = [
      if (o.onRetry != null)
        HfAction(
          '重试',
          key: const ValueKey('confirm-card-retry'),
          kind: HfActionKind.primary,
          onPressed: o.onRetry,
        ),
      if (o.onUndo != null && o.undoLabel != null)
        HfAction(
          '撤销（${o.undoLabel}）',
          key: const ValueKey('confirm-card-undo'),
          voice: '说「撤销」',
          onPressed: o.onUndo,
        ),
      if (o.onDismiss != null)
        HfAction(
          '知道了',
          key: const ValueKey('confirm-card-dismiss'),
          kind: HfActionKind.text,
          onPressed: o.onDismiss,
        ),
    ];
    return Column(
      key: ValueKey('confirm-card-outcome-${o.kind.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${o.text}$mark', style: hf.type(HfType.count)),
        if (buttons.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: hf.sp(10)),
            child: HfActions(actions: buttons),
          ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change, this.showField = true});
  final AgentChange change;
  final bool showField;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final from = change.from, to = change.to;
    return Padding(
      padding: EdgeInsets.only(bottom: hf.sp(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showField || (from == null && to == null))
            Text(
              change.field,
              style: hf.type(HfType.meta, color: HfColors.inkSoft),
            ),
          if (from != null && to != null)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: hf.sp(8),
              children: [
                Text(
                  from.isEmpty ? '（空）' : from,
                  style: hf
                      .type(HfType.body, color: HfColors.inkMuted)
                      .copyWith(decoration: TextDecoration.lineThrough),
                ),
                Icon(Icons.arrow_forward, size: hf.sp(20), color: HfColors.ink),
                Text(to.isEmpty ? '（空）' : to, style: hf.type(HfType.headline)),
              ],
            )
          else if (to != null)
            Text(to, style: hf.type(HfType.headline)),
        ],
      ),
    );
  }
}
