import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'icons.dart';
import 'recipe_surface.dart';
import 'recipes/message_system.g.dart';
import 'theme.dart';
import 'tooltip.dart';

/// Mounted SystemMessage (raft-ui0.5.27). The adapter supplies formatted receipt
/// text/time; system rows have no author/avatar, reactions or message toolbar.
class RaftSystemMessageRecipe {
  const RaftSystemMessageRecipe(this.tokens);
  final RaftTokens tokens;
  EdgeInsets get padding =>
      const EdgeInsets.symmetric(horizontal: 8, vertical: 6);
  Color get clockColor =>
      (tokens.dark ? tokens.strong : Colors.black).withValues(alpha: .4);
  Color get contentColor =>
      (tokens.dark ? tokens.strong : Colors.black).withValues(alpha: .5);
  TextStyle get clock =>
      (tokens.brutal
              ? RaftTypography.mono(tokens, size: 12, line: 16)
              : RaftTypography.body(
                  tokens,
                  size: 11,
                  line: 16.5,
                  weight: FontWeight.w500,
                ))
          .copyWith(
            color: clockColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          );
  TextStyle get content => RaftTypography.body(
    tokens,
    size: 12,
    line: tokens.brutal ? 16 : 18,
    color: contentColor,
  );
}

class RaftSystemMessage extends StatelessWidget {
  const RaftSystemMessage({
    super.key,
    required this.content,
    required this.timestamp,
    this.tooltip,
  });
  final String content, timestamp;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final recipe = RaftSystemMessageRecipe(RaftTokens.of(context));
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: recipe.padding,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(timestamp, style: recipe.clock),
            const SizedBox(width: 8),
            Flexible(
              // The line already says it; the full text only helps when cut.
              child: RaftTooltip(
                message: tooltip ?? content,
                onlyWhenTruncated: tooltip == null,
                child: Text(
                  content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: recipe.content,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// raft-ui `SystemMessageGroup*` (web SystemMessageGroupDisclosure.tsx): the
/// centred summary disclosure of an adjacent system-message run. The adapter
/// owns the summary copy and the expanded state; [children] are the run's
/// system rows, shown while [expanded].
class RaftSystemMessageGroup extends StatelessWidget {
  const RaftSystemMessageGroup({
    super.key,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.children,
    this.toggleKey,
  });
  final String summary;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  /// Key of the disclosure button (Web `system-message-group-toggle`).
  final Key? toggleKey;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), tokens = t.recipeTokens;
    final recipe = RaftMessageSystemRecipe.resolve(
      theme: t.recipeTheme,
      tokens: tokens,
      states: t.recipeStates(),
    );
    final label = recipe.systemGroupDisclosure.text(
      tokens,
      base: DefaultTextStyle.of(context).style,
    );
    final chevron = recipe.systemGroupChevron;
    return Padding(
      padding: recipe.systemGroup.margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: recipe.systemGroupHeader.padding,
            child: Center(
              child: RaftTooltip(
                message: summary,
                onlyWhenTruncated: true,
                child: GestureDetector(
                  key: toggleKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggle,
                  child: Semantics(
                    button: true,
                    expanded: expanded,
                    child: Padding(
                      padding: recipe.systemGroupDisclosure.padding,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              summary,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: label,
                            ),
                          ),
                          SizedBox(
                            width: recipe.systemGroupDisclosure.columnGap ?? 6,
                          ),
                          // ChevronRight: rotate-90 closed, -rotate-90 open.
                          RotatedBox(
                            quarterTurns: expanded ? 3 : 1,
                            child: RaftIcon(
                              RaftGlyph.chevronRight,
                              size: chevron.width ?? 12,
                              color: chevron.textStyle(tokens).color,
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
          if (expanded) ...children,
        ],
      ),
    );
  }
}
