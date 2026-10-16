import 'package:flutter/material.dart';

import 'enter.dart';
import 'handsfree/hf_scope.dart';
import 'handsfree/hf_tokens.dart';

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
    this.size = 52,
  });

  /// One emoji.
  final String emoji;

  /// What it says for a screen reader ("在想").
  final String? label;

  /// Width and height of the disc in s-units; the emoji is ~55% of it.
  final double size;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final px = hf.sp(size);
    return Semantics(
      container: true,
      label: label == null ? '心情 $emoji' : '$label $emoji',
      excludeSemantics: true,
      child: AgentAppear(
        child: Container(
          key: const ValueKey('agent-mood-badge'),
          width: px,
          height: px,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: HfColors.cream,
            shape: BoxShape.circle,
            border: Border.all(color: HfColors.ink, width: hf.sp(3)),
          ),
          child: AnimatedSwitcher(
            duration: reduced ? Duration.zero : hf.theme.duration * .6,
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
              style: TextStyle(fontSize: px * .55, height: 1.15),
            ),
          ),
        ),
      ),
    );
  }
}
