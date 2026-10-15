import 'package:flutter/material.dart';

import 'agent_theme.dart';

/// Content of one Z layer: a heading, a short spoken-style summary and a
/// scrolling body.
class AgentLayerFrame extends StatelessWidget {
  const AgentLayerFrame({
    super.key,
    required this.title,
    this.meta,
    this.summary,
    this.children = const [],
    this.loading = false,
    this.error,
  });

  final String title;
  final String? meta;

  /// The takeaway the agent would say aloud. The rest stays on screen.
  final InlineSpan? summary;
  final List<Widget> children;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: t.heading(22),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (meta != null) Text(meta!, style: t.body(12, color: t.hint)),
            ],
          ),
        ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
            child: Text.rich(summary!, style: t.body(14, color: t.muted)),
          ),
        if (loading)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: t.muted,
                ),
              ),
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text(
              error!,
              style: t.body(13, color: t.priority(AgentPriority.decision)),
            ),
          ),
        ...children,
      ],
    );
  }
}

/// Small uppercase section label inside a layer.
class AgentSectionLabel extends StatelessWidget {
  const AgentSectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
      child: Text(
        text,
        style: t.body(11.5, color: t.hint, weight: FontWeight.w600),
      ),
    );
  }
}

/// One message in a layer: sender, time and text.
class AgentMessageTile extends StatelessWidget {
  const AgentMessageTile({
    super.key,
    required this.sender,
    required this.text,
    this.time,
    this.onTap,
  });

  final String sender, text;
  final String? time;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: t.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.cardRadius),
          side: BorderSide(color: t.line, width: t.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: sender,
                        style: t.body(12.5, weight: FontWeight.w700),
                      ),
                      if (time != null)
                        TextSpan(
                          text: '  $time',
                          style: t.body(12, color: t.hint),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: t.body(13.5, color: t.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact pill.
class AgentChip extends StatelessWidget {
  const AgentChip(this.label, {super.key, this.hot = false});
  final String label;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final square = t.cardRadius == 0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hot
            ? t.priority(AgentPriority.decision).withValues(alpha: .14)
            : (square ? t.layer : t.chip),
        borderRadius: BorderRadius.circular(square ? 0 : 999),
        border: square ? Border.all(color: t.line, width: 1) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(label, style: t.body(11, color: t.muted)),
      ),
    );
  }
}
