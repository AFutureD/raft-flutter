import 'package:flutter/material.dart';

import '../display_spec.dart';
import '../enter.dart';
import '../entity_model.dart';
import 'hf_basics.dart';
import 'hf_detail.dart';
import 'hf_entity.dart';
import 'hf_row.dart';
import 'hf_scope.dart';
import 'hf_tokens.dart';

/// The number a card wears: its place on the numbered screen, unless the
/// `handle` element is off. The card can be pointed at either way.
int? _indexOf(BuildContext context, AgentDisplay x) =>
    x.has('handle') ? HfItemScope.maybeOf(context)?.index : null;

/// An element shown or hidden grows or shrinks the card smoothly.
Widget _smooth(Widget child) => AnimatedSize(
  duration: agentResizeDuration,
  curve: agentResizeCurve,
  alignment: Alignment.topCenter,
  child: child,
);

String? _joined(Iterable<String?> parts, [String sep = ' · ']) {
  final kept = [
    for (final p in parts)
      if (p != null && p.trim().isNotEmpty) p.trim(),
  ];
  return kept.isEmpty ? null : kept.join(sep);
}

/// One agent and what it is doing: the state in words and how long as the
/// meta, the name as the title, what it is doing and where as the detail.
///
/// [display] says which of those are drawn (`name`, `state`, `activity`,
/// `since`, `channel`); without it all of them are.
class HfStatusCard extends StatelessWidget {
  const HfStatusCard({
    super.key,
    required this.name,
    required this.state,
    this.activity,
    this.since,
    this.channel,
    this.display,
  });
  final String name;
  final AgentWorkState state;
  final String? activity, since, channel;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final x = (display ?? DisplaySpec.none).resolve('AgentStatusCard');
    final showName = x.has('name');
    final act = x.has('activity') ? activity : null;
    return _smooth(
      HfRow(
        key: ValueKey('agent-status-$name'),
        index: _indexOf(context, x),
        tone: hfWorkTone(state),
        meta: _joined([
          if (x.has('state')) agentWorkStateLabels[state],
          if (x.has('since')) since,
        ]),
        // Every element off still leaves who it is.
        title: showName ? name : (act ?? name),
        titleLines: x.lines,
        detail: _joined([
          if (showName) act,
          if (x.has('channel') && channel != null) '#$channel',
        ]),
      ),
    );
  }
}

/// One task: its status as the colour and the first word of the meta, the
/// title, and the latest progress or what is asked of the person. A card whose
/// `display.level` is `detail` is an [HfDetail] with a row per fact.
class HfTaskCard extends StatelessWidget {
  const HfTaskCard({
    super.key,
    required this.title,
    required this.status,
    this.number,
    this.assignee,
    this.channel,
    this.quote,
    this.ask,
    this.display,
  });
  final String title, status;
  final int? number;
  final String? assignee, channel, quote, ask;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final x = (display ?? DisplaySpec.none).resolve('TaskCard');
    final word = agentTaskStatusLabels[status] ?? status;
    final meta = _joined([
      if (x.has('status')) word,
      if (x.has('number') && number != null) '#$number',
      if (x.has('assignee') && assignee != null) assignee,
      if (x.has('channel') && channel != null) '#$channel',
    ]);
    final said = x.has('latest_progress') ? quote : null;
    final asked = x.has('ask') && ask != null ? ask : null;
    final tone = hfTaskTone(status);
    final index = _indexOf(context, x);
    if (display?.level == AgentLevel.detail) {
      return _smooth(
        HfDetail(
          key: const ValueKey('agent-task-detail'),
          titleMode: HfDetailTitle.heading,
          index: index,
          title: x.has('title') ? title : (asked ?? title),
          titleLines: x.lines,
          status: meta,
          tone: tone,
          facts: [
            if (asked != null) HfFact('要你做', asked),
            if (x.has('assignee') && assignee != null) HfFact('负责人', assignee!),
            if (x.has('channel') && channel != null) HfFact('频道', '#$channel'),
          ],
          progress: [if (said != null) HfProgressLine('', '', said)],
        ),
      );
    }
    return _smooth(
      HfRow(
        key: const ValueKey('agent-task-row'),
        index: index,
        tone: tone,
        meta: meta,
        title: x.has('title') ? title : (asked ?? title),
        titleLines: x.lines,
        detail: _joined([if (asked != null) '要你做：$asked', ?said]),
        detailLines: x.lines > 1 ? 2 : 1,
      ),
    );
  }
}

/// A quoted line: who said it and when as the meta, the words as the title.
/// [display]: `author`, `time`, `channel`, `text`; `lines` clamps the words.
class HfMessageQuote extends StatelessWidget {
  const HfMessageQuote({
    super.key,
    required this.author,
    required this.text,
    this.time,
    this.channel,
    this.display,
  });
  final String author, text;
  final String? time, channel;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final x = (display ?? DisplaySpec.none).resolve('MessageQuote');
    return _smooth(
      HfRow(
        key: const ValueKey('agent-quote'),
        bar: x.has('bar'),
        index: _indexOf(context, x),
        tone: HfTone.info,
        meta: _joined([
          if (x.has('author')) author,
          if (x.has('time')) time,
          if (x.has('channel') && channel != null) '#$channel',
        ]),
        title: x.has('text') ? text : author,
        titleLines: x.lines,
      ),
    );
  }
}

/// One label and its value.
class HfStat {
  const HfStat(this.label, this.value);
  final String label, value;
}

/// A few numbers in one numbered strip: a big value and, when `label` is on,
/// the word under it.
class HfStatStrip extends StatelessWidget {
  const HfStatStrip({super.key, required this.stats, this.display});
  final List<HfStat> stats;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (display ?? DisplaySpec.none).resolve('StatRow');
    final radius = BorderRadius.circular(hf.sp(16));
    final index = _indexOf(context, x);
    return _smooth(
      DecoratedBox(
        decoration: BoxDecoration(
          color: HfColors.cream,
          borderRadius: radius,
          boxShadow: [
            BoxShadow(color: HfColors.progress, offset: Offset(0, hf.sp(6))),
          ],
        ),
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
                  Container(
                    width: hf.sp(56),
                    color: HfColors.progress,
                    alignment: Alignment.center,
                    child: Text(
                      index == null ? '' : '$index',
                      style: hf.type(HfType.rank).copyWith(height: 1),
                    ),
                  ),
                  for (final (i, s) in stats.indexed)
                    Expanded(
                      child: Semantics(
                        container: true,
                        label: '${s.label} ${s.value}',
                        excludeSemantics: true,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            vertical: hf.sp(6),
                            horizontal: hf.sp(4),
                          ),
                          decoration: BoxDecoration(
                            border: i == 0
                                ? null
                                : Border(
                                    left: BorderSide(
                                      color: HfColors.ink,
                                      width: hf.sp(2),
                                    ),
                                  ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AgentCountUp(
                                s.value,
                                style: hf
                                    .type(HfType.stat)
                                    .copyWith(height: 1.1),
                              ),
                              if (x.has('label'))
                                Text(
                                  s.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: hf.type(
                                    HfType.meta,
                                    color: HfColors.inkSoft,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled run of children: the group's name with its count and a rule,
/// then the children. [displayKind] is `Section` or `AgentStatusGroup`;
/// `title` and `count` say which of the two are drawn.
class HfGroup extends StatelessWidget {
  const HfGroup({
    super.key,
    required this.title,
    required this.children,
    this.tone = HfTone.info,
    this.display,
    this.displayKind = 'Section',
  });
  final String title;
  final List<Widget> children;
  final HfTone tone;
  final DisplaySpec? display;
  final String displayKind;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (display ?? DisplaySpec.none).resolve(displayKind);
    final head = x.has('title') || x.has('count');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _smooth(
          head
              ? Padding(
                  padding: EdgeInsets.only(bottom: hf.sp(8), top: hf.sp(2)),
                  child: HfSectionLabel(
                    x.has('title') ? title : '',
                    count: x.has('count') ? children.length : null,
                    tone: tone,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        ...children,
      ],
    );
  }
}

/// A group folded to one numbered row: "在忙 1" with its members in a line
/// under it. A press asks for the full cards.
class HfSummaryRow extends StatelessWidget {
  const HfSummaryRow({
    super.key,
    required this.title,
    required this.count,
    required this.text,
    this.tone = HfTone.progress,
    this.onTap,
    this.display,
    this.displayKind = 'AgentStatusGroup',
  });
  final String title;
  final int count;

  /// The members in one run: "Cindy 在做 #119、Bo 在做 #7".
  final String text;
  final HfTone tone;
  final VoidCallback? onTap;

  /// What of the row is drawn: `title`, `count` and the `collapse` arrow, as
  /// for [displayKind], the group or `Section` it stands for. The members'
  /// [text] is always there.
  final DisplaySpec? display;
  final String displayKind;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (display ?? DisplaySpec.none).resolve(displayKind);
    final head = _joined([
      if (x.has('title')) title,
      if (x.has('count')) '$count',
    ], ' ');
    return HfRow(
      index: HfItemScope.maybeOf(context)?.index,
      tone: tone,
      title: head ?? text,
      titleLines: 1,
      detail: head == null || text.isEmpty ? null : text,
      detailLines: 2,
      trailing: onTap != null && x.has('collapse')
          ? Icon(Icons.expand_more, size: hf.sp(26), color: HfColors.inkSoft)
          : null,
      onTap: onTap,
    );
  }
}
