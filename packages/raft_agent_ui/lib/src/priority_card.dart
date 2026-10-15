import 'package:flutter/material.dart';

import 'agent_theme.dart';

/// Labels for [AgentPriority]; apps may pass localized ones.
const agentPriorityLabels = {
  AgentPriority.decision: '等你决定',
  AgentPriority.blocked: '卡住了',
  AgentPriority.mention: '提到了你',
  AgentPriority.progress: '进展',
};

/// One item of the proactive attention list: what kind of attention it needs,
/// how much (0-5 bars), and why.
class AgentPriorityCard extends StatelessWidget {
  const AgentPriorityCard({
    super.key,
    required this.priority,
    required this.title,
    required this.weight,
    this.detail,
    this.chips = const [],
    this.onTap,
    this.label,
  });

  final AgentPriority priority;
  final String title;

  /// 0-5; drawn as filled bars.
  final int weight;
  final String? detail;
  final List<Widget> chips;
  final VoidCallback? onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final color = t.priority(priority);
    final square = t.cardRadius == 0;
    final fill = t.cardFills?[priority];
    final labelText = label ?? agentPriorityLabels[priority] ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill ?? t.card,
          borderRadius: BorderRadius.circular(t.cardRadius),
          border: Border.all(color: t.line, width: t.cardBorderWidth),
          boxShadow: t.cardShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(t.cardRadius),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 13, 12),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (fill == null) ...[
                      Container(
                        width: 5,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(square ? 0 : 3),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (t.stickerLabels)
                                _Sticker(text: labelText, theme: t)
                              else
                                Text(
                                  labelText,
                                  style: t.body(
                                    11.5,
                                    color: color,
                                    weight: FontWeight.w700,
                                  ),
                                ),
                              const Spacer(),
                              if (t.weightNumerals)
                                Semantics(
                                  label: 'weight $weight of 5',
                                  child: Text(
                                    '$weight',
                                    style: t
                                        .heading(30, weight: FontWeight.w900)
                                        .copyWith(height: 1),
                                  ),
                                )
                              else
                                _WeightBars(
                                  weight: weight,
                                  color: color,
                                  square: square,
                                  idle: t.chip,
                                  line: t.line,
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: t.weightNumerals
                                ? t.heading(17, weight: FontWeight.w900)
                                : t.body(15, weight: FontWeight.w600),
                          ),
                          if (detail != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              detail!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: fill == null
                                  ? t.body(12.5, color: t.hint)
                                  : t.body(
                                      12.5,
                                      color: t.foreground,
                                      weight: FontWeight.w600,
                                    ),
                            ),
                          ],
                          if (chips.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(spacing: 6, runSpacing: 6, children: chips),
                          ],
                        ],
                      ),
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

class _Sticker extends StatelessWidget {
  const _Sticker({required this.text, required this.theme});
  final String text;
  final RaftAgentTheme theme;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: -.05,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: theme.layer,
        border: Border.all(color: theme.line, width: 2.5),
        boxShadow: [BoxShadow(color: theme.line, offset: const Offset(2, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Text(text, style: theme.body(12, weight: FontWeight.w800)),
      ),
    ),
  );
}

class _WeightBars extends StatelessWidget {
  const _WeightBars({
    required this.weight,
    required this.color,
    required this.square,
    required this.idle,
    required this.line,
  });

  final int weight;
  final Color color, idle, line;
  final bool square;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'weight $weight of 5',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: const EdgeInsets.only(left: 3),
            child: Container(
              width: 5,
              height: 12,
              decoration: BoxDecoration(
                color: i < weight ? color : (square ? null : idle),
                borderRadius: BorderRadius.circular(square ? 0 : 2),
                border: square ? Border.all(color: line, width: 1) : null,
              ),
            ),
          ),
      ],
    ),
  );
}
