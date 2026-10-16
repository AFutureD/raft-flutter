import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'attention_card.dart' show AgentCountBadge;
import 'display_spec.dart';
import 'enter.dart';
import 'layer_frame.dart';
import 'marks.dart';

/// What an agent is doing right now, as the person reads it.
enum AgentWorkState { busy, idle, blocked, offline }

/// Labels for [AgentWorkState]; apps may pass localized ones.
const agentWorkStateLabels = {
  AgentWorkState.busy: '在忙',
  AgentWorkState.idle: '空闲',
  AgentWorkState.blocked: '卡住了',
  AgentWorkState.offline: '离线',
};

/// Labels for task statuses.
const agentTaskStatusLabels = {
  'todo': '待办',
  'in_progress': '进行中',
  'in_review': '等验收',
  'done': '已完成',
  'closed': '已关闭',
};

AgentPriority _priorityOf(AgentWorkState s) => switch (s) {
  AgentWorkState.busy => AgentPriority.progress,
  AgentWorkState.blocked => AgentPriority.blocked,
  AgentWorkState.idle => AgentPriority.mention,
  AgentWorkState.offline => AgentPriority.progress,
};

/// The colour a state is drawn in: busy green, blocked orange; idle and
/// offline stay on paper tones so the busy ones stand out.
Color agentWorkStateColor(RaftAgentTheme t, AgentWorkState s) => switch (s) {
  AgentWorkState.busy =>
    t.cardFills?[AgentPriority.progress] ?? t.priority(AgentPriority.progress),
  AgentWorkState.blocked =>
    t.cardFills?[AgentPriority.blocked] ?? t.priority(AgentPriority.blocked),
  AgentWorkState.idle => t.chip,
  AgentWorkState.offline => t.hint.withValues(alpha: .35),
};

Color _statusColor(RaftAgentTheme t, String status) => switch (status) {
  'in_review' =>
    t.cardFills?[AgentPriority.decision] ?? t.priority(AgentPriority.decision),
  'in_progress' =>
    t.cardFills?[AgentPriority.progress] ?? t.priority(AgentPriority.progress),
  'done' =>
    t.cardFills?[AgentPriority.progress] ?? t.priority(AgentPriority.progress),
  'todo' => t.chip,
  _ => t.hint.withValues(alpha: .35),
};

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(t.cardRadius),
          border: Border.all(color: t.line, width: t.cardBorderWidth),
          boxShadow: t.cardShadow,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
          // An element shown or hidden grows or shrinks the card smoothly.
          child: AnimatedSize(
            duration: agentResizeDuration,
            curve: agentResizeCurve,
            alignment: Alignment.topCenter,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _Sticker extends StatelessWidget {
  const _Sticker(this.text, {required this.fill, this.size = 12});
  final String text;
  final Color fill;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final square = t.cardRadius == 0;
    return AgentPop(
      child: Transform.rotate(
        angle: t.stickerLabels ? -.04 : 0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(square ? 0 : 999),
            border: Border.all(color: t.line, width: t.stickerLabels ? 2.5 : 1),
            boxShadow: t.stickerLabels
                ? [BoxShadow(color: t.line, offset: const Offset(2, 2))]
                : const [],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1.5),
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
      ),
    );
  }
}

/// One agent and what it is doing: name, state sticker, the current
/// activity, how long and where.
///
/// [display] says which of those are drawn (`name`, `state`, `activity`,
/// `since`, `channel`); without it all of them are.
class AgentStatusCardView extends StatelessWidget {
  const AgentStatusCardView({
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

  /// What it is doing, one phrase.
  final String? activity;

  /// How long that has been so ("12 分钟").
  final String? since;
  final String? channel;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('AgentStatusCard');
    final f = x.factor(surface: true);
    final tags = [
      if (x.has('since') && since != null && since!.isNotEmpty) since!,
      if (x.has('channel') && channel != null && channel!.isNotEmpty)
        '#$channel',
    ];
    final showActivity = x.has('activity') && (activity ?? '').isNotEmpty;
    final showState = x.has('state');
    // Every element off still leaves the name.
    final showName =
        x.has('name') || (!showState && !showActivity && tags.isEmpty);
    return Semantics(
      container: true,
      label: '$name，${agentWorkStateLabels[state]}',
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showName || showState)
              Row(
                children: [
                  Expanded(
                    child: showName
                        ? AgentMarkText(
                            name,
                            maxLines: 1,
                            style: t.heading(17 * f, weight: FontWeight.w800),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (showState) ...[
                    const SizedBox(width: 8),
                    _Sticker(
                      agentWorkStateLabels[state] ?? '',
                      fill: agentWorkStateColor(t, state),
                      size: 12 * f,
                    ),
                  ],
                ],
              ),
            if (showActivity) ...[
              if (showName || showState) const SizedBox(height: 4),
              AgentMarkText(
                activity!,
                maxLines: x.lines,
                style: t.body(14 * f, color: t.foreground),
              ),
            ],
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (i, tag) in tags.indexed)
                    AgentPop(
                      order: i + 1,
                      child: AgentChip(tag, size: 11 * f),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A titled group of cards, coloured by what they have in common. [display]
/// says whether the title and the count badge are drawn.
class AgentStatusGroupView extends StatelessWidget {
  const AgentStatusGroupView({
    super.key,
    required this.title,
    required this.children,
    this.state,
    this.count,
    this.display,
  });

  final String title;
  final AgentWorkState? state;

  /// Defaults to the number of [children].
  final int? count;
  final List<Widget> children;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('AgentStatusGroup');
    final f = x.factor(surface: true);
    final n = count ?? children.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: agentResizeDuration,
          curve: agentResizeCurve,
          alignment: Alignment.topCenter,
          child: x.has('title') || x.has('count')
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                  child: Row(
                    children: [
                      if (x.has('title'))
                        Flexible(
                          child: AgentTypeText(
                            title,
                            at: .2,
                            style: t.heading(15 * f, weight: FontWeight.w900),
                          ),
                        ),
                      if (x.has('title') && x.has('count'))
                        const SizedBox(width: 8),
                      if (x.has('count'))
                        AgentPop(
                          at: .5,
                          child: AgentCountBadge(
                            '$n',
                            size: 15 * f,
                            priority: _priorityOf(state ?? AgentWorkState.busy),
                          ),
                        ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        ...children,
      ],
    );
  }
}

/// One task as a sentence, its status and who has it, the last thing said
/// about it and what is asked of the person.
///
/// [display] says which parts are drawn: `number`, `status`, `title`,
/// `assignee`, `channel`, `latest_progress` and `ask`.
class AgentTaskCardView extends StatelessWidget {
  const AgentTaskCardView({
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

  final String title;

  /// `todo`, `in_progress`, `in_review`, `done` or `closed`.
  final String status;
  final int? number;
  final String? assignee, channel;

  /// The latest progress line, already formatted ("Cindy · 10:32  文字").
  final String? quote;
  final String? ask;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('TaskCard');
    final f = x.factor(surface: true);
    final meta = [
      if (x.has('assignee') && assignee != null && assignee!.isNotEmpty)
        '负责人 $assignee',
      if (x.has('channel') && channel != null && channel!.isNotEmpty)
        '#$channel',
    ];
    final showNumber = x.has('number') && number != null;
    final showStatus = x.has('status');
    final showQuote = x.has('latest_progress') && (quote ?? '').isNotEmpty;
    final showAsk = x.has('ask') && (ask ?? '').isNotEmpty;
    // Every element off still leaves the title.
    final showTitle =
        x.has('title') ||
        (!showNumber && !showStatus && meta.isEmpty && !showQuote && !showAsk);
    return Semantics(
      container: true,
      label:
          '任务${number == null ? '' : ' $number'}，${agentTaskStatusLabels[status] ?? status}',
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showNumber || showStatus)
              Row(
                children: [
                  if (showNumber)
                    Text(
                      '#$number',
                      style: t.heading(14 * f, weight: FontWeight.w900),
                    ),
                  const Spacer(),
                  if (showStatus)
                    _Sticker(
                      agentTaskStatusLabels[status] ?? status,
                      fill: _statusColor(t, status),
                      size: 12 * f,
                    ),
                ],
              ),
            if (showTitle) ...[
              if (showNumber || showStatus) const SizedBox(height: 6),
              AgentMarkText(
                title,
                maxLines: x.lines,
                style: t.heading(18 * f, weight: FontWeight.w800),
              ),
            ],
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final (i, m) in meta.indexed)
                    AgentPop(
                      order: i + 1,
                      child: AgentChip(m, size: 11 * f),
                    ),
                ],
              ),
            ],
            if (showQuote) ...[
              const SizedBox(height: 10),
              _QuoteBar(
                child: AgentMarkText(
                  quote!,
                  maxLines: 4,
                  style: t.body(13 * f, color: t.muted),
                ),
              ),
            ],
            if (showAsk) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AgentPop(
                    order: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.stickerLabels ? t.line : t.foreground,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 1,
                        ),
                        child: Text(
                          '要你做',
                          style: t.body(
                            11.5 * f,
                            weight: FontWeight.w800,
                            color: t.stickerLabels ? t.layer : t.canvas,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AgentMarkText(
                      ask!,
                      maxLines: 2,
                      style: t.body(14 * f, weight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuoteBar extends StatelessWidget {
  const _QuoteBar({required this.child, this.bar = true});
  final Widget child;
  final bool bar;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: bar
            ? Border(
                left: BorderSide(
                  color: t.line.withValues(alpha: .25),
                  width: 4,
                ),
              )
            : null,
      ),
      child: child,
    );
  }
}

/// A line somebody wrote, quoted as it was said. [display] says which parts
/// are drawn: `author`, `time`, `channel`, `text` and the `bar` at the left.
class AgentMessageQuoteView extends StatelessWidget {
  const AgentMessageQuoteView({
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
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('MessageQuote');
    final f = x.factor(surface: true);
    final head = [
      if (x.has('author')) author,
      if (x.has('time') && time != null && time!.isNotEmpty) time!,
      if (x.has('channel') && channel != null && channel!.isNotEmpty)
        '#$channel',
    ].join(' · ');
    // Every element off still leaves the words.
    final showText = x.has('text') || head.isEmpty;
    return Semantics(
      container: true,
      label: '$author 说：$text',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: AnimatedSize(
          duration: agentResizeDuration,
          curve: agentResizeCurve,
          alignment: Alignment.topCenter,
          child: _QuoteBar(
            bar: x.has('bar'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (head.isNotEmpty)
                  Text(
                    head,
                    style: t.body(
                      12.5 * f,
                      color: t.muted,
                      weight: FontWeight.w800,
                    ),
                  ),
                if (head.isNotEmpty && showText) const SizedBox(height: 2),
                if (showText)
                  AgentMarkText(
                    text,
                    maxLines: x.lines,
                    style: t.body(14.5 * f, color: t.foreground),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One label and its value.
class AgentStatData {
  const AgentStatData(this.label, this.value);
  final String label, value;
}

/// Label/value pairs as big numbers in a row (wraps on a narrow screen).
/// [display] says whether the `label` under each number is drawn.
class AgentStatRowView extends StatelessWidget {
  const AgentStatRowView({super.key, required this.stats, this.display});
  final List<AgentStatData> stats;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('StatRow');
    final f = x.factor(surface: true);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: AnimatedSize(
        duration: agentResizeDuration,
        curve: agentResizeCurve,
        alignment: Alignment.topCenter,
        child: Wrap(
          spacing: 22,
          runSpacing: 10,
          children: [
            for (final s in stats)
              Semantics(
                container: true,
                label: '${s.label} ${s.value}',
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AgentCountUp(
                      s.value,
                      style: t
                          .heading(
                            (t.stickerLabels ? 30 : 24) * f,
                            weight: FontWeight.w900,
                          )
                          .copyWith(height: 1.1),
                    ),
                    if (x.has('label'))
                      Text(s.label, style: t.body(11.5 * f, color: t.hint)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A labelled run of children. [display] says whether the `title` and the
/// `count` badge are drawn.
class AgentSurfaceSectionView extends StatelessWidget {
  const AgentSurfaceSectionView({
    super.key,
    required this.title,
    required this.children,
    this.display,
  });
  final String title;
  final List<Widget> children;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final x = (display ?? DisplaySpec.none).resolve('Section');
    final f = x.factor(surface: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: agentResizeDuration,
          curve: agentResizeCurve,
          alignment: Alignment.topCenter,
          child: x.has('title') || x.has('count')
              ? Row(
                  children: [
                    if (x.has('title'))
                      Flexible(child: AgentSectionLabel(title, scale: f)),
                    if (x.has('count'))
                      Padding(
                        padding: EdgeInsets.only(
                          left: x.has('title') ? 0 : 18,
                          top: 14,
                        ),
                        child: AgentCountBadge(
                          '${children.length}',
                          size: 12 * f,
                          priority: AgentPriority.progress,
                        ),
                      ),
                  ],
                )
              : const SizedBox(width: double.infinity),
        ),
        ...children,
      ],
    );
  }
}

/// A group or section folded to one entry: "在忙 1：Cindy 在做 #119". Tapping
/// it asks for the full cards.
class AgentSummaryRow extends StatelessWidget {
  const AgentSummaryRow({
    super.key,
    required this.title,
    required this.count,
    required this.text,
    this.state,
    this.onTap,
    this.display,
    this.displayKind = 'AgentStatusGroup',
  });

  final String title;
  final int count;

  /// What of the row is drawn: `title`, `count` and the `collapse` arrow, as
  /// for [displayKind], the group (`AgentStatusGroup`) or `Section` it
  /// stands for. The members' [text] is always there.
  final DisplaySpec? display;
  final String displayKind;

  /// The members in one run: "Cindy 在做 #119、Bo 在做 #7".
  final String text;

  /// Colours the strip on the left; null uses the progress tone.
  final AgentWorkState? state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final strip = state == null
        ? (t.cardFills?[AgentPriority.progress] ??
              t.priority(AgentPriority.progress))
        : agentWorkStateColor(t, state!);
    final x = (display ?? DisplaySpec.none).resolve(displayKind);
    final f = x.factor(surface: true);
    final head = [
      if (x.has('title')) title,
      if (x.has('count')) '$count',
    ].join(' ');
    final line = '$title $count${text.isEmpty ? '' : '：$text'}';
    return Semantics(
      button: onTap != null,
      container: true,
      label: line,
      excludeSemantics: true,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(t.cardRadius),
            border: Border.all(color: t.line, width: t.cardBorderWidth),
            boxShadow: t.cardShadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              (t.cardRadius - t.cardBorderWidth).clamp(0, 99),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 10,
                        decoration: BoxDecoration(
                          color: strip,
                          border: Border(
                            right: BorderSide(
                              color: t.line,
                              width: t.cardBorderWidth,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                if (head.isNotEmpty)
                                  TextSpan(
                                    text: head,
                                    style: t.heading(
                                      15 * f,
                                      weight: FontWeight.w900,
                                    ),
                                  ),
                                if (text.isNotEmpty)
                                  TextSpan(
                                    text: head.isEmpty ? text : '：$text',
                                    style: t.body(14 * f, color: t.foreground),
                                  ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (onTap != null && x.has('collapse'))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            Icons.expand_more,
                            size: 20 * f,
                            color: t.hint,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
