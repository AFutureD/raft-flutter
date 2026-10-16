import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'display_spec.dart';
import 'enter.dart';
import 'entity_model.dart';

/// Shared pieces of the entity cards and the organization blocks. Sizes here
/// are the arm's-length scale of the phone cards (attention_card.dart): the
/// compact headline is never under [entityHeadlineCompact] and no text is
/// smaller than [entityMinText].
const entityHeadlineCompact = 26.0;
const entityHeadlineDetail = 20.0;
const entityMetaCompact = 18.0;
const entityMinText = 16.0;

/// The fill a priority colour has in the active theme.
Color agentPriorityFill(RaftAgentTheme t, AgentPriority p) =>
    t.cardFills?[p] ?? t.priority(p);

/// The fill a tone is drawn in; neutral has none.
Color? agentToneFill(RaftAgentTheme t, AgentTone tone) => switch (tone) {
  AgentTone.good => agentPriorityFill(t, AgentPriority.progress),
  AgentTone.warn => agentPriorityFill(t, AgentPriority.blocked),
  AgentTone.neutral => null,
};

/// ① to ⑳ for 1 to 20, else the handle as written.
String agentHandleGlyph(String handle) {
  const circled = '①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳';
  final n = int.tryParse(handle);
  if (n != null && n >= 1 && n <= 20) return circled[n - 1];
  return handle;
}

/// The reference handle of a card ("①"): what the person says to point at it.
class AgentHandleBadge extends StatelessWidget {
  const AgentHandleBadge(this.handle, {super.key});
  final String handle;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final glyph = agentHandleGlyph(handle);
    return AgentPop(
      at: .3,
      child: Semantics(
        label: '编号 $glyph',
        excludeSemantics: true,
        child: DecoratedBox(
          key: const ValueKey('entity-handle'),
          decoration: BoxDecoration(
            color: t.markHighlight,
            borderRadius: BorderRadius.circular(t.cardRadius == 0 ? 0 : 8),
            border: Border.all(color: t.line, width: 2.5),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: Text(
                  glyph,
                  style: t
                      .heading(22, weight: FontWeight.w900)
                      .copyWith(height: 1.1, color: t.orbForeground),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A coloured status word ("进行中", "在忙", "未读 3").
class AgentEntityPill extends StatelessWidget {
  const AgentEntityPill(
    this.text, {
    super.key,
    required this.fill,
    this.order,
    this.size = entityMinText,
  });
  final String text;
  final Color fill;
  final int? order;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final square = t.cardRadius == 0;
    return AgentPop(
      order: order ?? 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(square ? 0 : 999),
          border: Border.all(color: t.line, width: t.stickerLabels ? 2.5 : 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Text(
            text,
            style: t.body(
              size,
              weight: FontWeight.w800,
              color: t.stickerLabels ? t.line : t.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// A round status dot.
class AgentStatusDot extends StatelessWidget {
  const AgentStatusDot(this.color, {super.key, this.size = 14});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: t.line, width: 2),
      ),
    );
  }
}

/// The card shell of an entity or block: paper, ink border, hard shadow.
/// [tone] puts a coloured strip on the left; [emphasis] high draws a thicker
/// border and a deeper shadow.
class AgentEntityFrame extends StatelessWidget {
  const AgentEntityFrame({
    super.key,
    required this.child,
    this.tone = AgentTone.neutral,
    this.emphasis = AgentEmphasis.normal,
    this.padding = const EdgeInsets.fromLTRB(14, 11, 14, 12),
    this.dashed = false,
  });
  final Widget child;
  final AgentTone tone;
  final AgentEmphasis emphasis;
  final EdgeInsets padding;

  /// A quiet frame for a stub (no shadow, chip paper).
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final high = emphasis == AgentEmphasis.high;
    final strip =
        agentToneFill(t, tone) ?? (high && !dashed ? t.markHighlight : null);
    final border = t.cardBorderWidth + (high ? 1.5 : 0);
    final shadow = dashed
        ? const <BoxShadow>[]
        : high && t.cardShadow.isNotEmpty
        ? [BoxShadow(color: t.line, offset: const Offset(7, 7))]
        : t.cardShadow;
    final radius = BorderRadius.circular(t.cardRadius);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: dashed ? t.chip : t.card,
          borderRadius: radius,
          border: Border.all(color: t.line, width: dashed ? 2 : border),
          boxShadow: shadow,
        ),
        // The child is clipped inside the border, so a header band or a strip
        // cannot paint over it.
        child: Padding(
          padding: EdgeInsets.all(dashed ? 2 : border),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              (t.cardRadius - border).clamp(0, 99),
            ),
            // Without a strip nothing needs the intrinsic height, and a block
            // that measures its own width (a table) must not be asked for it.
            // A property change that makes the card taller or shorter
            // (an element shown or hidden, another level) grows or shrinks
            // it instead of jumping.
            child: AnimatedSize(
              duration: agentResizeDuration,
              curve: agentResizeCurve,
              alignment: Alignment.topCenter,
              child: strip == null
                  ? Padding(padding: padding, child: child)
                  : IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            key: const ValueKey('entity-strip'),
                            width: 10,
                            decoration: BoxDecoration(
                              color: strip,
                              border: Border(
                                right: BorderSide(color: t.line, width: border),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Padding(padding: padding, child: child),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A square avatar: the app's own when given, else the first letter.
class AgentEntityAvatar extends StatelessWidget {
  const AgentEntityAvatar({
    super.key,
    required this.name,
    required this.size,
    this.builder,
  });
  final String name;
  final double size;
  final AgentAvatarBuilder? builder;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final radius = BorderRadius.circular(t.cardRadius == 0 ? 0 : 10);
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(color: t.line, width: 2.5),
        color: t.chip,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox.square(
          dimension: size,
          child: builder != null
              ? builder!(context, size)
              : Center(
                  child: Text(
                    initial,
                    style: t.heading(size * .5, weight: FontWeight.w900),
                  ),
                ),
        ),
      ),
    );
  }
}

/// A big button: a thumb-sized sticker with a hard shadow.
class AgentActionButton extends StatelessWidget {
  const AgentActionButton({
    super.key,
    required this.label,
    required this.onTap,
    this.fill,
    this.size = 20,
  });
  final String label;
  final VoidCallback? onTap;

  /// Null draws plain paper.
  final Color? fill;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : .45,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52, minWidth: 96),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill ?? t.layer,
              borderRadius: BorderRadius.circular(t.cardRadius == 0 ? 0 : 12),
              border: Border.all(
                color: t.line,
                width: t.stickerLabels ? 3 : t.cardBorderWidth,
              ),
              boxShadow: enabled && t.cardShadow.isNotEmpty
                  ? [BoxShadow(color: t.line, offset: const Offset(3, 3))]
                  : const [],
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: t.body(
                size,
                weight: FontWeight.w900,
                color: t.stickerLabels ? t.line : t.foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
