import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'enter.dart';
import 'marks.dart';
import 'scroll_fade.dart';

/// Content of one Z layer: a heading, a short spoken-style summary and a
/// scrolling body. On a desktop window the content keeps to a readable column
/// ([agentLayerContentWidth]) in the middle of the layer, and the body shows
/// a scrollbar and a fade where it is cut off ([AgentScrollFade]).
class AgentLayerFrame extends StatelessWidget {
  const AgentLayerFrame({
    super.key,
    required this.title,
    this.meta,
    this.summary,
    this.children = const [],
    this.loading = false,
    this.error,
    this.dense = false,
    this.enterTitle = false,
  });

  final String title;

  /// The title is a piece of its own that enters (a streamed surface).
  final bool enterTitle;
  final String? meta;

  /// The takeaway the agent would say aloud. The rest stays on screen.
  final InlineSpan? summary;
  final List<Widget> children;
  final bool loading;
  final String? error;

  /// Phone first screen: less air above and below the title so more cards
  /// fit above the voice dock.
  final bool dense;

  Widget _title(String text, TextStyle style) {
    if (!enterTitle) {
      return Text(
        text,
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }
    return AgentAppear(
      child: AgentTypeText(text, style: style, maxLines: 2, at: .2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final wide = agentIsWide(context);
    return LayoutBuilder(
      builder: (context, box) {
        // Wide: the column, never closer to the edge than the gutter the
        // handles of the cards stand in.
        final side = wide
            ? ((box.maxWidth - agentLayerContentWidth) / 2).clamp(
                agentLayerGutter,
                double.infinity,
              )
            : 0.0;
        return AgentScrollFade(
          enabled: wide,
          builder: (context, controller) => _body(
            t,
            controller,
            EdgeInsets.fromLTRB(side, dense ? 8 : 18, side, dense ? 12 : 24),
          ),
        );
      },
    );
  }

  Widget _body(RaftAgentTheme t, ScrollController? controller, EdgeInsets pad) {
    return ListView(
      controller: controller,
      padding: pad,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: _title(
                  title,
                  t
                      .heading(
                        dense && t.titleSize > 26 ? 26 : t.titleSize,
                        weight: t.titleWeight,
                      )
                      .copyWith(
                        height: 1.1,
                        letterSpacing: t.weightNumerals ? -.8 : 0,
                      ),
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
  const AgentSectionLabel(this.text, {super.key, this.scale = 1});
  final String text;

  /// Multiplies the font size.
  final double scale;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
      child: Text(
        text,
        style: t.body(11.5 * scale, color: t.hint, weight: FontWeight.w600),
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
        color: t.messageFill ?? t.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(t.cardRadius),
          side: BorderSide(color: t.line, width: t.cardBorderWidth),
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
                AgentMarkText(
                  text,
                  maxLines: 3,
                  style: t.body(14, color: t.foreground),
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
  const AgentChip(this.label, {super.key, this.hot = false, this.size = 11});
  final String label;
  final bool hot;

  /// Font size of the label.
  final double size;

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
        border: square ? Border.all(color: t.line, width: 2) : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          style: t.body(
            size,
            color: square ? t.foreground : t.muted,
            weight: square ? FontWeight.w700 : null,
          ),
        ),
      ),
    );
  }
}

/// Canvas with an optional dot grid ([RaftAgentTheme.canvasDots]).
class AgentCanvas extends StatelessWidget {
  const AgentCanvas({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final dots = t.canvasDots;
    return ColoredBox(
      color: t.canvas,
      child: dots == null
          ? child
          : CustomPaint(painter: _DotGrid(dots), child: child),
    );
  }
}

class _DotGrid extends CustomPainter {
  _DotGrid(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 18.0;
    for (var y = step / 2; y < size.height; y += step) {
      for (var x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGrid old) => old.color != color;
}
