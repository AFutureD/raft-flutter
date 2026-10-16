import 'package:flutter/material.dart';

import 'agent_theme.dart';
import 'enter.dart';

/// The agent's state and mood as one emoji in a sticker bubble, so waiting
/// is not dry. Swapping the emoji pops the new one in (scale with a small
/// overshoot, using the theme's motion); with reduced motion it just
/// changes.
///
/// The bubble keeps its size whatever the emoji, and does not follow the
/// system text size (it is a glyph, not text to read).
class AgentMoodBadge extends StatelessWidget {
  const AgentMoodBadge({
    super.key,
    required this.emoji,
    this.label,
    this.size = 56,
  });

  /// One emoji.
  final String emoji;

  /// What it says for a screen reader ("在想").
  final String? label;

  /// Width and height of the bubble; the emoji is ~60% of it.
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final square = t.orbSquare;
    return Semantics(
      container: true,
      label: label == null ? '心情 $emoji' : '$label $emoji',
      excludeSemantics: true,
      child: AgentAppear(
        child: Transform.rotate(
          angle: t.stickerLabels ? -.05 : 0,
          child: Container(
            key: const ValueKey('agent-mood-badge'),
            constraints: BoxConstraints(minWidth: size, minHeight: size),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.cardFills?[AgentPriority.mention] ?? t.card,
              shape: square ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: square ? BorderRadius.zero : null,
              border: Border.all(color: t.line, width: t.cardBorderWidth),
              boxShadow: t.cardShadow,
            ),
            child: AnimatedSwitcher(
              duration: reduced ? Duration.zero : t.duration * .6,
              transitionBuilder: (child, animation) => ScaleTransition(
                // The new one overshoots a little as it lands.
                scale: animation.drive(CurveTween(curve: Curves.easeOutBack)),
                child: FadeTransition(
                  opacity: animation.drive(
                    CurveTween(curve: const Interval(0, .6)),
                  ),
                  child: child,
                ),
              ),
              child: Text(
                emoji,
                key: ValueKey(emoji),
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: size * .6, height: 1.15),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
