import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'attention_card.dart' show AgentCountBadge;
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
          child: child,
        ),
      ),
    );
  }
}

class _Sticker extends StatelessWidget {
  const _Sticker(this.text, {required this.fill});
  final String text;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final square = t.cardRadius == 0;
    return Transform.rotate(
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
              12,
              weight: FontWeight.w800,
              color: t.stickerLabels ? t.line : t.foreground,
            ),
          ),
        ),
      ),
    );
  }
}

/// One agent and what it is doing: name, state sticker, the current
/// activity, how long and where.
class AgentStatusCardView extends StatelessWidget {
  const AgentStatusCardView({
    super.key,
    required this.name,
    required this.state,
    this.activity,
    this.since,
    this.channel,
  });

  final String name;
  final AgentWorkState state;

  /// What it is doing, one phrase.
  final String? activity;

  /// How long that has been so ("12 分钟").
  final String? since;
  final String? channel;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final tags = [
      if (since != null && since!.isNotEmpty) since!,
      if (channel != null && channel!.isNotEmpty) '#$channel',
    ];
    return Semantics(
      container: true,
      label: '$name，${agentWorkStateLabels[state]}',
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: AgentMarkText(
                    name,
                    maxLines: 1,
                    style: t.heading(17, weight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                _Sticker(
                  agentWorkStateLabels[state] ?? '',
                  fill: agentWorkStateColor(t, state),
                ),
              ],
            ),
            if (activity != null && activity!.isNotEmpty) ...[
              const SizedBox(height: 4),
              AgentMarkText(
                activity!,
                maxLines: 2,
                style: t.body(14, color: t.foreground),
              ),
            ],
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final tag in tags) AgentChip(tag)],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A titled group of cards, coloured by what they have in common.
class AgentStatusGroupView extends StatelessWidget {
  const AgentStatusGroupView({
    super.key,
    required this.title,
    required this.children,
    this.state,
    this.count,
  });

  final String title;
  final AgentWorkState? state;

  /// Defaults to the number of [children].
  final int? count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final n = count ?? children.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  style: t.heading(15, weight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 8),
              AgentCountBadge(
                '$n',
                priority: _priorityOf(state ?? AgentWorkState.busy),
              ),
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

/// One task as a sentence, its status and who has it, the last thing said
/// about it and what is asked of the person.
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
  });

  final String title;

  /// `todo`, `in_progress`, `in_review`, `done` or `closed`.
  final String status;
  final int? number;
  final String? assignee, channel;

  /// The latest progress line, already formatted ("Cindy · 10:32  文字").
  final String? quote;
  final String? ask;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final meta = [
      if (assignee != null && assignee!.isNotEmpty) '负责人 $assignee',
      if (channel != null && channel!.isNotEmpty) '#$channel',
    ];
    return Semantics(
      container: true,
      label:
          '任务${number == null ? '' : ' $number'}，${agentTaskStatusLabels[status] ?? status}',
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (number != null)
                  Text(
                    '#$number',
                    style: t.heading(14, weight: FontWeight.w900),
                  ),
                const Spacer(),
                _Sticker(
                  agentTaskStatusLabels[status] ?? status,
                  fill: _statusColor(t, status),
                ),
              ],
            ),
            const SizedBox(height: 6),
            AgentMarkText(
              title,
              maxLines: 3,
              style: t.heading(18, weight: FontWeight.w800),
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final m in meta) AgentChip(m)],
              ),
            ],
            if (quote != null && quote!.isNotEmpty) ...[
              const SizedBox(height: 10),
              _QuoteBar(
                child: AgentMarkText(
                  quote!,
                  maxLines: 4,
                  style: t.body(13, color: t.muted),
                ),
              ),
            ],
            if (ask != null && ask!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DecoratedBox(
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
                          11.5,
                          weight: FontWeight.w800,
                          color: t.stickerLabels ? t.layer : t.canvas,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AgentMarkText(
                      ask!,
                      maxLines: 2,
                      style: t.body(14, weight: FontWeight.w700),
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
  const _QuoteBar({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: t.line.withValues(alpha: .25), width: 4),
        ),
      ),
      child: child,
    );
  }
}

/// A line somebody wrote, quoted as it was said.
class AgentMessageQuoteView extends StatelessWidget {
  const AgentMessageQuoteView({
    super.key,
    required this.author,
    required this.text,
    this.time,
    this.channel,
  });

  final String author, text;
  final String? time, channel;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final head = [
      author,
      if (time != null && time!.isNotEmpty) time!,
      if (channel != null && channel!.isNotEmpty) '#$channel',
    ].join(' · ');
    return Semantics(
      container: true,
      label: '$author 说：$text',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: _QuoteBar(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                head,
                style: t.body(12.5, color: t.muted, weight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              AgentMarkText(
                text,
                maxLines: 5,
                style: t.body(14.5, color: t.foreground),
              ),
            ],
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
class AgentStatRowView extends StatelessWidget {
  const AgentStatRowView({super.key, required this.stats});
  final List<AgentStatData> stats;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
                  Text(
                    s.value,
                    style: t
                        .heading(
                          t.stickerLabels ? 30 : 24,
                          weight: FontWeight.w900,
                        )
                        .copyWith(height: 1.1),
                  ),
                  Text(s.label, style: t.body(11.5, color: t.hint)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A labelled run of children.
class AgentSurfaceSectionView extends StatelessWidget {
  const AgentSurfaceSectionView({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [AgentSectionLabel(title), ...children],
  );
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
  });

  final String title;
  final int count;

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
                                TextSpan(
                                  text: '$title $count',
                                  style: t.heading(15, weight: FontWeight.w900),
                                ),
                                if (text.isNotEmpty)
                                  TextSpan(
                                    text: '：$text',
                                    style: t.body(14, color: t.foreground),
                                  ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (onTap != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            Icons.expand_more,
                            size: 20,
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
