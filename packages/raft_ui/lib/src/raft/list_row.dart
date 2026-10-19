// raft-ui 0.7.1 `ListRow`: one row of a list. Children are the leading block (an avatar, `RaftListRowIcon`), a
// `RaftListRowBody` (title / description, or a top and a bottom line) and whatever trails (a value, a badge, a
// switch, `RaftListRowChevron`). Rows are `gap-3 px-4 py-3`; the `default` variant is at least 64px and rules off
// at 63px, `plain` rules off at 16px, `entry` has no rule. `selected` fills `info-soft`; `tone` sets the ink.
import 'package:flutter/material.dart';

import '../design_primitives.dart';
import '../icons.dart';
import '../localization.dart';
import '../theme.dart';
import '../tokens/tokens.dart';
import 'css_box.dart';
import 'ui_tokens.dart';

/// `variant` axis of `listRow`.
enum RaftListRowVariant { standard, plain, entry }

/// `tone` axis: `unread` bolds the title and inks the description, `muted` and `away` fade the row.
enum RaftListRowTone { normal, unread, muted, away }

/// The three inks a row hands to its parts (`--list-row-ink`, `-ink-2`, `-ink-3`).
@immutable
class RaftListRowInk {
  const RaftListRowInk(this.ink, this.ink2, this.ink3);
  final Color ink, ink2, ink3;

  static RaftListRowInk resolve(
    RaftUiColors ui, {
    RaftListRowTone tone = RaftListRowTone.normal,
    bool disabled = false,
  }) {
    if (disabled) {
      return RaftListRowInk(
        ui.foregroundDisabled,
        ui.foregroundDisabled,
        ui.foregroundDisabled,
      );
    }
    return switch (tone) {
      RaftListRowTone.normal => RaftListRowInk(
        ui.foreground,
        ui.foregroundMuted,
        ui.foregroundHint,
      ),
      RaftListRowTone.unread => RaftListRowInk(
        ui.foreground,
        ui.foreground,
        ui.foregroundHint,
      ),
      RaftListRowTone.muted => RaftListRowInk(
        ui.foregroundMuted,
        ui.foregroundMuted,
        ui.foregroundHint,
      ),
      RaftListRowTone.away => RaftListRowInk(
        ui.foregroundHint,
        ui.foregroundHint,
        ui.foregroundHint,
      ),
    };
  }
}

class _ListRowScope extends InheritedWidget {
  const _ListRowScope({
    required this.ink,
    required this.tone,
    required this.contentWidth,
    required super.child,
  });
  final RaftListRowInk ink;
  final RaftListRowTone tone;

  /// Width of the row's content box (for `max-w-[45%]`).
  final double contentWidth;

  static _ListRowScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ListRowScope>();

  @override
  bool updateShouldNotify(_ListRowScope old) =>
      ink != old.ink || tone != old.tone || contentWidth != old.contentWidth;
}

RaftListRowInk _inkOf(BuildContext context) =>
    _ListRowScope.maybeOf(context)?.ink ??
    RaftListRowInk.resolve(RaftTokens.of(context).ui);

/// `ListRow`. Without [onPressed] the row still looks like a button (it is one in the web kit); [interactive]
/// false is the `div` row that hosts its own control (a switch).
class RaftListRow extends StatelessWidget {
  const RaftListRow({
    super.key,
    required this.children,
    this.variant = RaftListRowVariant.standard,
    this.tone = RaftListRowTone.normal,
    this.selected = false,
    this.interactive = true,
    this.disabled = false,
    this.onPressed,
    this.topRule = false,
    this.focusNode,
    this.semanticLabel,
  });

  final List<Widget> children;
  final RaftListRowVariant variant;
  final RaftListRowTone tone;
  final bool selected;

  /// `interactive={false}`: no hover wash, no button.
  final bool interactive;
  final bool disabled;
  final VoidCallback? onPressed;

  /// The hairline above the row (`[data-slot=list-row]+&` / `li+li>&`): drawn from the rule start to the right
  /// edge. [RaftListRowGroup] and [RaftListRowList] set it on every row after the first.
  final bool topRule;
  final FocusNode? focusNode;
  final String? semanticLabel;

  RaftListRow copyWith({bool? topRule}) => RaftListRow(
    key: key,
    variant: variant,
    tone: tone,
    selected: selected,
    interactive: interactive,
    disabled: disabled,
    onPressed: onPressed,
    topRule: topRule ?? this.topRule,
    focusNode: focusNode,
    semanticLabel: semanticLabel,
    children: children,
  );

  /// `--list-row-rule-start`.
  double get ruleStart => variant == RaftListRowVariant.standard ? 63 : 16;

  @override
  Widget build(BuildContext context) {
    final ui = RaftTokens.of(context).ui;
    final ink = RaftListRowInk.resolve(ui, tone: tone, disabled: disabled);
    final pressable = interactive && !disabled && onPressed != null;
    Widget body(RaftInteractionState st) {
      final wash = pressable && !selected && (st.hovered || st.pressed);
      final fill = selected
          ? ui['info-soft']
          : wash
          ? ui.fillPressed
          : const Color(0x00000000);
      Widget row = LayoutBuilder(
        builder: (context, box) {
          final contentWidth = box.maxWidth.isFinite ? box.maxWidth - 32 : 0.0;
          return _ListRowScope(
            ink: ink,
            tone: tone,
            contentWidth: contentWidth,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  children[i] is RaftListRowBody
                      ? Expanded(child: children[i])
                      : children[i],
                ],
              ],
            ),
          );
        },
      );
      row = ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: variant == RaftListRowVariant.standard ? 64 : 0,
        ),
        child: RaftCssBox(
          fill: fill,
          insetRingWidth: st.focusVisible ? 2 : 0,
          insetRingColor: ui.foreground,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          alignment: Alignment.center,
          child: row,
        ),
      );
      // `entry` rows have no `before:` rule at all.
      if (!topRule || variant == RaftListRowVariant.entry) return row;
      return Stack(
        children: [
          row,
          Positioned(
            top: 0,
            left: ruleStart,
            right: 0,
            height: 1,
            child: IgnorePointer(child: ColoredBox(color: ui.lineHairline)),
          ),
        ],
      );
    }

    if (!interactive) {
      return Semantics(
        container: true,
        selected: selected,
        label: semanticLabel,
        child: body(const RaftInteractionState()),
      );
    }
    return RaftInteractive(
      onPressed: disabled ? null : onPressed,
      focusNode: focusNode,
      selected: selected,
      semanticLabel: semanticLabel,
      builder: (context, st) => body(st),
    );
  }
}

/// `ListRowBody`: the text column (`flex-1 min-w-0 flex-col gap-0.5`). A direct child of [RaftListRow].
class RaftListRowBody extends StatelessWidget {
  const RaftListRowBody({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const SizedBox(height: 2),
        children[i],
      ],
    ],
  );
}

Widget _line(List<Widget> children) => Row(
  crossAxisAlignment: CrossAxisAlignment.center,
  children: [
    for (var i = 0; i < children.length; i++) ...[
      if (i > 0) const SizedBox(width: 8),
      children[i] is RaftListRowTitle || children[i] is RaftListRowDescription
          ? Expanded(child: children[i])
          : children[i],
    ],
  ],
);

/// `ListRowTop`: the title, then the time.
class RaftListRowTop extends StatelessWidget {
  const RaftListRowTop({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => _line(children);
}

/// `ListRowBottom`: the preview, then at most one badge.
class RaftListRowBottom extends StatelessWidget {
  const RaftListRowBottom({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => _line(children);
}

/// `ListRowTitle`: 16/24 semibold on one line (bold on an unread row).
class RaftListRowTitle extends StatelessWidget {
  const RaftListRowTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final scope = _ListRowScope.maybeOf(context);
    final unread = scope?.tone == RaftListRowTone.unread;
    // Chromium seats a 16/24 Space Grotesk line box about 0.75px higher than Flutter's half-leading does.
    return Transform.translate(
      offset: const Offset(0, -0.75),
      child: Text(
        raftText(context, text),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: t.scale(
          RaftTypeScale.body,
          weight: unread ? FontWeight.w700 : FontWeight.w600,
          color: _inkOf(context).ink,
        ),
      ),
    );
  }
}

/// `ListRowDescription`: 14/20 in ink-2; [wrap] lets it take several lines.
class RaftListRowDescription extends StatelessWidget {
  const RaftListRowDescription(this.text, {super.key, this.wrap = false});
  final String text;
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Text(
      raftText(context, text),
      maxLines: wrap ? null : 1,
      softWrap: wrap,
      overflow: wrap ? TextOverflow.clip : TextOverflow.ellipsis,
      style: t.scale(
        RaftTypeScale.callout,
        weight: FontWeight.w400,
        color: _inkOf(context).ink2,
      ),
    );
  }
}

/// `ListRowMeta`: machine-written facts in Space Mono 12, ink-3 (the time, a gray count).
class RaftListRowMeta extends StatelessWidget {
  const RaftListRowMeta(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    // Chromium rounds Space Mono's ascent and descent at 12px, which seats the line box 1px higher.
    return Transform.translate(
      offset: const Offset(0, -1),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: t
            .scale(
              RaftTypeScale.monoMeta,
              mono: true,
              weight: FontWeight.w400,
              color: _inkOf(context).ink3,
            )
            .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// `ListRowValue`: a setting's current value, 15/20 in ink-3, at most 45% of the row.
class RaftListRowValue extends StatelessWidget {
  const RaftListRowValue(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final scope = _ListRowScope.maybeOf(context);
    final width = scope?.contentWidth ?? 0;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width > 0 ? width * .45 : double.infinity,
      ),
      child: Text(
        raftText(context, text),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: t.scale(
          RaftTypeScale.subhead,
          weight: FontWeight.w400,
          color: _inkOf(context).ink3,
        ),
      ),
    );
  }
}

/// `ListRowIcon`: a 20px leading icon in ink-3.
class RaftListRowIcon extends StatelessWidget {
  const RaftListRowIcon(this.glyph, {super.key});
  final RaftGlyph glyph;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: 20,
      child: RaftIcon(glyph, size: 20, color: _inkOf(context).ink3),
    ),
  );
}

/// `ListRowChevron`: the ink-3 arrow of a row that opens another page.
class RaftListRowChevron extends StatelessWidget {
  const RaftListRowChevron({super.key});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: 20,
      child: RaftIcon(
        RaftGlyph.chevronRight,
        size: 20,
        color: _inkOf(context).ink3,
      ),
    ),
  );
}

List<Widget> _withRules(List<Widget> children) => [
  for (var i = 0; i < children.length; i++)
    children[i] is RaftListRow && i > 0 && children[i - 1] is RaftListRow
        ? (children[i] as RaftListRow).copyWith(topRule: true)
        : children[i],
];

/// A plain stack of rows (a `div` of `ListRow`s): the rule above every row after the first.
class RaftListRowList extends StatelessWidget {
  const RaftListRowList({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: _withRules(children),
  );
}

/// `ListRowGroup`: rows wrapped in a card (`layer-card`, 1px `line-hairline`, `rounded-container`).
class RaftListRowGroup extends StatelessWidget {
  const RaftListRowGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ui = RaftTokens.of(context).ui;
    final border = raftControlBorderPx(context, 1);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ui.layerCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ui.lineHairline, width: border),
      ),
      child: Padding(
        padding: EdgeInsets.all(border),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10 - border),
          child: RaftListRowList(children: children),
        ),
      ),
    );
  }
}
