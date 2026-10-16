import 'package:flutter/material.dart';

import '../agent_theme.dart';
import '../marks.dart';
import '../spotlight.dart';
import 'hf_basics.dart';
import 'hf_scope.dart';
import 'hf_tokens.dart';

/// A numbered row: a colour bar with the number the agent and the user say
/// ("第 2 条"), three layers of text (meta, title, detail) and an optional
/// [HfStatBlock] on the right.
///
/// The title takes at most two lines, the others one. Narrow rows (a phone,
/// a half window) use a 56 s bar and a 96 s stat block; wide ones (a TV, a
/// full window) 78 s and 150 s. The three text layers stay stacked.
class HfRow extends StatelessWidget {
  const HfRow({
    super.key,
    required this.index,
    required this.tone,
    required this.title,
    this.meta,
    this.detail,
    this.badge,
    this.stat,
    this.trailing,
    this.titleLines = 2,
    this.detailLines = 1,
    this.bar = true,
    this.focusId,
    this.onTap,
    this.selected = false,
    this.verticalPad,
  });

  /// The number on the bar, from 1: what a person says to point at the row.
  /// Null for a row that is not on the numbered screen (a thing a confirm
  /// card is about): the bar stays, without a number.
  final int? index;
  final HfTone tone;
  final String title;

  /// Small label above the title: "#app-dev · 等你验收".
  final String? meta;

  /// One more fact under the title.
  final String? detail;

  /// A small black tag before the meta, such as "最急".
  final String? badge;
  final HfStatBlock? stat;

  /// Something small at the right of the text (an avatar, a picture).
  final Widget? trailing;

  /// Lines the title may take (the level of a card says how many), and the
  /// detail; the meta is always one.
  final int titleLines, detailLines;

  /// The colour bar with the number at the left. Off, the row is only its
  /// text (and carries no number).
  final bool bar;

  /// Makes the row something the agent can point at (spotlight, marks).
  final String? focusId;

  /// Null on a TV, or when the row is only shown.
  final VoidCallback? onTap;

  /// The row whose detail is open beside the list.
  final bool selected;

  /// Padding above and below the text, in s-units; null takes the screen's
  /// ([HfData.rowPad]). A screen with room to spare lets its rows grow.
  final double? verticalPad;

  /// Rows wider than this many s-units use the wide layout.
  static const wideFrom = 560.0;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    Widget row = LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth / hf.s >= wideFrom;
        return _body(context, hf, wide);
      },
    );
    row = Semantics(
      container: true,
      button: onTap != null,
      label: index == null ? title : '$index，$title',
      child: row,
    );
    if (onTap != null && hf.interactive) {
      row = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: row,
        ),
      );
    }
    final id = focusId;
    return id == null ? row : AgentFocusable(id: id, child: row);
  }

  Widget _body(BuildContext context, HfData hf, bool wide) {
    final color = HfColors.of(tone);
    final radius = BorderRadius.circular(hf.sp(16));
    final metaLine = (meta != null && meta!.isNotEmpty) || badge != null;
    final titleBlock = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (metaLine)
          Row(
            children: [
              if (badge != null) ...[
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
                    badge!,
                    maxLines: 1,
                    style: hf.type(HfType.meta, color: Colors.white),
                  ),
                ),
                SizedBox(width: hf.sp(10)),
              ],
              if (meta != null)
                Flexible(
                  child: Text(
                    meta!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: hf.type(HfType.meta, color: HfColors.inkMuted),
                  ),
                ),
            ],
          ),
        AgentMarkText(
          title,
          maxLines: titleLines,
          style: hf.type(HfType.headline),
        ),
        if (detail != null && detail!.isNotEmpty)
          AgentMarkText(
            detail!,
            maxLines: detailLines,
            style: hf.type(HfType.body, color: HfColors.inkSoft),
          ),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? const Color(0xfffff7d6) : HfColors.card,
        borderRadius: radius,
        boxShadow: [BoxShadow(color: color, offset: Offset(0, hf.sp(6)))],
      ),
      // The outline is drawn over the bar and the stat block, so it runs
      // unbroken around the row.
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: HfColors.ink, width: hf.sp(3)),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (bar)
                  Container(
                    key: const ValueKey('hf-row-bar'),
                  width: hf.sp(wide ? 78 : 56),
                  color: color,
                  alignment: Alignment.center,
                  child: Text(
                    index == null ? '' : '$index',
                    // Tight lines: the number must not set the row's height.
                    style: hf
                        .type(HfType.rank, base: wide ? 46 : null)
                        .copyWith(height: 1),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: hf.sp(wide ? 18 : 12),
                      vertical: hf.sp(verticalPad ?? hf.rowPad),
                    ),
                    child: titleBlock,
                  ),
                ),
                if (trailing != null)
                  Padding(
                    padding: EdgeInsets.only(right: hf.sp(10)),
                    child: Center(child: trailing),
                  ),
                if (stat != null)
                  SizedBox(width: hf.sp(wide ? 150 : 96), child: stat),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An [HfRow] for an Agent, task, message, channel, member, computer or file:
/// the state in words is the meta, the fact is the detail.
class HfEntityRow extends HfRow {
  HfEntityRow({
    super.key,
    required super.index,
    required String status,
    required super.title,
    super.detail,
    AgentPriority priority = AgentPriority.progress,
    HfTone? tone,
    super.badge,
    super.stat,
    super.trailing,
    super.titleLines,
    super.detailLines,
    super.bar,
    super.focusId,
    super.onTap,
    super.selected,
    super.verticalPad,
  }) : super(tone: tone ?? HfColors.toneOf(priority), meta: status);
}
