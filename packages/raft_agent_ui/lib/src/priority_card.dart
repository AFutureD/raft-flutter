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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(t.cardRadius),
          border: Border.all(color: t.line, width: t.border),
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
                    Container(
                      width: 5,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(square ? 0 : 3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                label ?? agentPriorityLabels[priority] ?? '',
                                style: t.body(
                                  11.5,
                                  color: color,
                                  weight: FontWeight.w700,
                                ),
                              ),
                              const Spacer(),
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
                            style: t.body(15, weight: FontWeight.w600),
                          ),
                          if (detail != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              detail!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: t.body(12.5, color: t.hint),
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
