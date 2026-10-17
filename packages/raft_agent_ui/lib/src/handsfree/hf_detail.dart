import 'package:flutter/material.dart';

import '../marks.dart';
import '../spotlight.dart';
import 'hf_action.dart';
import 'hf_basics.dart';
import 'hf_describe.dart';
import 'hf_scope.dart';
import 'hf_tokens.dart';

/// One fact of a detail: who, where, how long.
@immutable
class HfFact {
  const HfFact(this.label, this.value, {this.lines});
  final String label, value;

  /// Lines the value may take; null takes as many as it needs (a detail is
  /// part of a page that scrolls, so nothing in it is cut short).
  final int? lines;
}

/// One line of recent progress.
@immutable
class HfProgressLine {
  const HfProgressLine(this.time, this.who, this.text);
  final String time, who, text;

  /// The words after the time: "who · text".
  String get said => who.isEmpty ? text : '$who · $text';
}

/// Where the title of an [HfDetail] goes.
enum HfDetailTitle {
  /// A title sticker above the card (a screen of its own).
  sticker,

  /// A heading inside the card (beside a list in a wide window).
  heading,

  /// None: the screen's header already says it.
  none,
}

/// The detail of one thing: its title (a sticker, or a heading when it sits
/// beside a list), fact rows, recent progress and the actions. Wide room puts
/// the facts and the progress side by side.
class HfDetail extends StatelessWidget implements HfDescribed {
  const HfDetail({
    super.key,
    required this.title,
    this.status,
    this.tone = HfTone.info,
    this.facts = const [],
    this.progress = const [],
    this.actions = const [],
    this.titleMode = HfDetailTitle.sticker,
    this.index,
    this.titleLines,
    this.progressLines,
    this.trailing,
    this.focusId,
    this.oneRowActions = false,
    this.gridActions = false,
    this.actionsBeforeProgress = false,
    this.progressLabel = progressHeading,
  });

  final String title;

  /// The state in words, above the title.
  final String? status;
  final HfTone tone;
  final List<HfFact> facts;
  final List<HfProgressLine> progress;
  final List<HfAction> actions;

  final HfDetailTitle titleMode;

  /// The number the thing has on the screen (a card of a numbered list).
  final int? index;

  /// Lines the heading may take, and each line of progress. Null takes as
  /// many as the words need: the page scrolls, nothing is cut short.
  final int? titleLines, progressLines;

  /// Something small at the right of the heading (an avatar).
  final Widget? trailing;

  /// Keep the actions in one row on a phone too (a stage with tools).
  final bool oneRowActions;

  /// Lay many actions out as a grid of equal buttons.
  final bool gridActions;

  /// Put the actions right under the card of the heading and facts, and the
  /// [progress] under them in a card of its own: nothing is cut, and the
  /// actions do not move with the length of the words.
  final bool actionsBeforeProgress;
  final String? focusId;

  /// The heading of the progress rows, unless [progressLabel] says another.
  static const progressHeading = '最近进展';

  /// The heading over the [progress] rows (the lines of a message are not
  /// "progress").
  final String progressLabel;

  @override
  HfDescription describe(HfDescribeEnv env) => HfDescription(
    [
      ...hfKept([status, title]),
      for (final f in facts) '${f.label}：${f.value}',
      if (progress.isNotEmpty) progressLabel,
      for (final p in progress) hfKept([p.time, p.said]).join(' '),
    ],
    actions: [for (final a in actions) a.label],
    index: index,
    block: true,
  );

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final color = HfColors.of(tone);
    final gap = hf.sp(12);
    final beside = titleMode == HfDetailTitle.heading;
    Widget factRow(HfFact f) => Padding(
      padding: EdgeInsets.only(bottom: hf.sp(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            constraints: BoxConstraints(minWidth: hf.sp(64)),
            padding: EdgeInsets.symmetric(
              vertical: hf.sp(3),
              horizontal: hf.sp(6),
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: HfColors.cream,
              borderRadius: BorderRadius.circular(hf.sp(8)),
            ),
            child: Text(
              f.label,
              maxLines: 1,
              style: hf.type(HfType.body, color: HfColors.inkSoft),
            ),
          ),
          SizedBox(width: hf.sp(12)),
          Expanded(
            child: AgentMarkText(
              f.value,
              maxLines: f.lines,
              style: hf.type(HfType.headline),
            ),
          ),
        ],
      ),
    );
    Widget progressLine(HfProgressLine p) => Padding(
      padding: EdgeInsets.only(bottom: hf.sp(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.time.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(right: hf.sp(6)),
              child: ConstrainedBox(
                // Times line up when they are alike; a long one is whole.
                constraints: BoxConstraints(minWidth: hf.sp(48)),
                child: Text(
                  p.time,
                  style: hf.type(HfType.meta, color: HfColors.inkMuted),
                ),
              ),
            ),
          Expanded(
            child: AgentMarkText(
              p.said,
              maxLines: progressLines,
              style: hf.type(HfType.body),
            ),
          ),
        ],
      ),
    );
    Widget facts_() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [for (final f in facts) factRow(f)],
    );
    // The words of the progress go under the actions when asked (a phone's
    // detail: the actions stay in view whatever the words' length).
    final cardProgress = actionsBeforeProgress
        ? const <HfProgressLine>[]
        : progress;
    Widget progress_() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HfSectionLabel(progressLabel, tone: tone),
        SizedBox(height: hf.sp(8)),
        for (final p in progress) progressLine(p),
      ],
    );
    Widget cardOf() => LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth / hf.s >= 560;
        Widget content;
        if (wide) {
          content = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: facts_()),
              SizedBox(width: hf.sp(24)),
              if (cardProgress.isNotEmpty)
                Expanded(flex: 6, child: progress_()),
            ],
          );
        } else {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (facts.isNotEmpty) facts_(),
              if (facts.isNotEmpty && cardProgress.isNotEmpty)
                SizedBox(height: hf.sp(4)),
              if (cardProgress.isNotEmpty) progress_(),
            ],
          );
        }
        final top = hf.sp(beside ? 14 : 16), bottom = hf.sp(beside ? 6 : 8);
        final inner = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (beside) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (status != null || index != null)
                          Row(
                            children: [
                              if (index != null) ...[
                                Container(
                                  key: const ValueKey('hf-detail-index'),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: hf.sp(8),
                                    vertical: hf.sp(1),
                                  ),
                                  decoration: BoxDecoration(
                                    color: color,
                                    borderRadius: BorderRadius.circular(
                                      hf.sp(7),
                                    ),
                                    border: Border.all(
                                      color: HfColors.ink,
                                      width: hf.sp(2),
                                    ),
                                  ),
                                  child: Text(
                                    '$index',
                                    style: hf.type(HfType.headline, base: 15),
                                  ),
                                ),
                                SizedBox(width: hf.sp(8)),
                              ],
                              if (status != null)
                                Flexible(
                                  child: Text(
                                    status!,
                                    style: hf.type(
                                      HfType.meta,
                                      color: HfColors.inkMuted,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        if (title.isNotEmpty)
                          AgentMarkText(
                            title,
                            maxLines: titleLines,
                            style: hf.type(HfType.headline),
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    SizedBox(width: hf.sp(10)),
                    trailing!,
                  ],
                ],
              ),
              if (facts.isNotEmpty || cardProgress.isNotEmpty)
                SizedBox(height: hf.sp(10)),
            ],
            if (facts.isNotEmpty || cardProgress.isNotEmpty) content,
          ],
        );
        return Container(
          padding: EdgeInsets.fromLTRB(hf.sp(16), top, hf.sp(16), bottom),
          decoration: BoxDecoration(
            color: HfColors.card,
            borderRadius: BorderRadius.circular(hf.sp(16)),
            border: Border.all(color: HfColors.ink, width: hf.sp(3)),
            boxShadow: [BoxShadow(color: color, offset: Offset(0, hf.sp(6)))],
          ),
          child: inner,
        );
      },
    );
    final card = cardOf();
    final head = <Widget>[
      if (titleMode == HfDetailTitle.sticker)
        Align(alignment: Alignment.centerLeft, child: HfTitleSticker(title)),
      if (!beside) ...[
        if (status != null) ...[
          if (titleMode == HfDetailTitle.sticker) SizedBox(height: hf.sp(10)),
          Row(
            children: [
              Container(
                width: hf.sp(12),
                height: hf.sp(12),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: HfColors.ink, width: hf.sp(2)),
                ),
              ),
              SizedBox(width: hf.sp(8)),
              Text(status!, style: hf.type(HfType.count)),
            ],
          ),
        ],
        SizedBox(height: gap),
      ],
    ];
    final actionGap = SizedBox(height: hf.sp(beside ? 10 : 18));
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ...head,
        card,
        if (actions.isNotEmpty) ...[
          actionGap,
          HfActions(actions: actions, oneRow: oneRowActions, grid: gridActions),
        ],
        if (actionsBeforeProgress && progress.isNotEmpty) ...[
          SizedBox(height: hf.sp(beside ? 10 : 18)),
          Container(
            padding: EdgeInsets.fromLTRB(
              hf.sp(16),
              hf.sp(12),
              hf.sp(16),
              hf.sp(6),
            ),
            decoration: BoxDecoration(
              color: HfColors.card,
              borderRadius: BorderRadius.circular(hf.sp(16)),
              border: Border.all(color: HfColors.ink, width: hf.sp(3)),
              boxShadow: [BoxShadow(color: color, offset: Offset(0, hf.sp(6)))],
            ),
            child: progress_(),
          ),
        ],
      ],
    );
    final id = focusId;
    return id == null ? body : AgentFocusable(id: id, child: body);
  }
}
