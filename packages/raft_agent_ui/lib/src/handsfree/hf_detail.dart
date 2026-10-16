import 'package:flutter/material.dart';

import '../marks.dart';
import '../scroll_fade.dart';
import '../spotlight.dart';
import 'hf_action.dart';
import 'hf_basics.dart';
import 'hf_scope.dart';
import 'hf_tokens.dart';

/// One fact of a detail: who, where, how long.
@immutable
class HfFact {
  const HfFact(this.label, this.value, {this.lines = 2});
  final String label, value;

  /// Lines the value may take.
  final int lines;
}

/// One line of recent progress.
@immutable
class HfProgressLine {
  const HfProgressLine(this.time, this.who, this.text);
  final String time, who, text;
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
class HfDetail extends StatelessWidget {
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
    this.titleLines = 2,
    this.progressLines = 2,
    this.trailing,
    this.focusId,
    this.oneRowActions = false,
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

  /// Lines the heading may take, and each line of progress.
  final int titleLines, progressLines;

  /// Something small at the right of the heading (an avatar).
  final Widget? trailing;

  /// Keep the actions in one row on a phone too (a sheet).
  final bool oneRowActions;
  final String? focusId;

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
            SizedBox(
              width: hf.sp(48),
              child: Text(
                p.time,
                maxLines: 1,
                style: hf.type(HfType.meta, color: HfColors.inkMuted),
              ),
            ),
          Expanded(
            child: AgentMarkText(
              p.who.isEmpty ? p.text : '${p.who} · ${p.text}',
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
    Widget progress_() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HfSectionLabel('最近进展', tone: tone),
        SizedBox(height: hf.sp(8)),
        for (final p in progress) progressLine(p),
      ],
    );
    // [scroll]: the card is given a height that may be too little for it; its
    // content then scrolls inside the frame and fades where it is cut.
    Widget cardOf({required bool scroll}) => LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth / hf.s >= 560;
        Widget content;
        if (wide) {
          content = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: facts_()),
              SizedBox(width: hf.sp(24)),
              if (progress.isNotEmpty) Expanded(flex: 6, child: progress_()),
            ],
          );
        } else {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (facts.isNotEmpty) facts_(),
              if (facts.isNotEmpty && progress.isNotEmpty)
                SizedBox(height: hf.sp(4)),
              if (progress.isNotEmpty) progress_(),
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
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
              if (facts.isNotEmpty || progress.isNotEmpty)
                SizedBox(height: hf.sp(10)),
            ],
            if (facts.isNotEmpty || progress.isNotEmpty) content,
          ],
        );
        return Container(
          padding: scroll
              ? EdgeInsets.symmetric(horizontal: hf.sp(16))
              : EdgeInsets.fromLTRB(hf.sp(16), top, hf.sp(16), bottom),
          decoration: BoxDecoration(
            color: HfColors.card,
            borderRadius: BorderRadius.circular(hf.sp(16)),
            border: Border.all(color: HfColors.ink, width: hf.sp(3)),
            boxShadow: [BoxShadow(color: color, offset: Offset(0, hf.sp(6)))],
          ),
          child: scroll
              ? AgentScrollFade(
                  key: const ValueKey('hf-detail-fade'),
                  shrinkWrap: true,
                  scrollbar: hf.interactive,
                  fadeColor: HfColors.card,
                  builder: (context, controller) => SingleChildScrollView(
                    key: const ValueKey('hf-detail-scroll'),
                    controller: controller,
                    physics: hf.interactive
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.only(top: top, bottom: bottom),
                    child: inner,
                  ),
                )
              : inner,
        );
      },
    );
    final card = cardOf(scroll: false);
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
    // In a room of its own height (beside a list) the card scrolls inside it
    // and the actions stay in view under it; else it is as tall as it is.
    final body = LayoutBuilder(
      builder: (context, box) {
        if (!box.hasBoundedHeight || actions.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...head,
              card,
              if (actions.isNotEmpty) ...[
                actionGap,
                HfActions(actions: actions, oneRow: oneRowActions),
              ],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ...head,
            Flexible(child: cardOf(scroll: true)),
            actionGap,
            HfActions(actions: actions, oneRow: oneRowActions),
          ],
        );
      },
    );
    final id = focusId;
    return id == null ? body : AgentFocusable(id: id, child: body);
  }
}
