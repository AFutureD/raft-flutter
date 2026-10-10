import 'package:flutter/material.dart';

import 'theme.dart';
import 'localization.dart';

/// Shared single-column navigation geometry. The host owns the system inset.
class RaftMobilePageHeader extends StatelessWidget
    implements PreferredSizeWidget {
  const RaftMobilePageHeader({
    super.key,
    required this.title,
    this.leading,
    this.onBack,
    this.backKey,
    this.backLabel = 'Back',
    this.actions = const [],
    this.background,
    this.border,
  });

  final Widget title;
  final Widget? leading;
  final VoidCallback? onBack;
  final Key? backKey;
  final String backLabel;
  final List<Widget> actions;
  final Color? background;
  final BorderSide? border;

  static const height = 56.0;
  static const actionExtent = 48.0;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: background ?? t.panel,
        border: Border(bottom: border ?? BorderSide(color: t.line)),
      ),
      child: Row(
        children: [
          if (onBack != null || leading != null) ...[
            SizedBox.square(
              dimension: actionExtent,
              child: onBack != null
                  ? RaftMobileBackButton(
                      key: backKey,
                      onPressed: onBack,
                      tooltip: backLabel,
                    )
                  : Center(child: leading),
            ),
            const SizedBox(width: 8),
          ] else
            const SizedBox(width: 8),
          Expanded(child: Semantics(header: true, child: title)),
          for (final action in actions)
            SizedBox.square(
              dimension: actionExtent,
              child: Center(child: action),
            ),
        ],
      ),
    );
  }
}

/// A platform back glyph in the same 48px slot on every mobile page.
class RaftMobileBackButton extends StatelessWidget {
  const RaftMobileBackButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Back',
  });
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: raftText(context, tooltip),
    constraints: const BoxConstraints.tightFor(width: 48, height: 48),
    padding: EdgeInsets.zero,
    icon: const BackButtonIcon(),
  );
}
