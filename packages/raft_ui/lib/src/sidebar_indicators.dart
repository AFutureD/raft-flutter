import 'package:flutter/material.dart';

import 'icons.dart';
import 'design_primitives.dart';
import 'theme.dart';
import 'tooltip.dart' show RaftTooltip;

/// Quiet count from mounted Sidebar.tsx:902–905. Muted or unjoined channels
/// retain their unread count without inheriting the accent badge.
class RaftSidebarQuietUnreadCount extends StatelessWidget {
  const RaftSidebarQuietUnreadCount({super.key, required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: RaftTypography.mono(t, size: 10, line: 10).copyWith(
          fontWeight: FontWeight.w500,
          color: t.colors['foreground-muted'],
        ),
      ),
    );
  }
}

/// SidebarItemMetaIcon uses a 16px slot around the mounted 12px BellOff.
class RaftSidebarMutedIcon extends StatelessWidget {
  const RaftSidebarMutedIcon({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return RaftTooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        child: SizedBox.square(
          dimension: 16,
          child: Center(
            child: RaftIcon(
              RaftGlyph.bellOff,
              size: 12,
              color: t.colors['foreground-icon'],
            ),
          ),
        ),
      ),
    );
  }
}

/// A draft is the fallback marker after a conversation's unread indicator.
class RaftSidebarDraftIcon extends StatelessWidget {
  const RaftSidebarDraftIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return RaftIcon(
      RaftGlyph.pencil,
      size: 12,
      color: t.colors['foreground-placeholder'],
    );
  }
}

/// Sidebar.tsx ChannelRow `sidebar-mention-marker`: a 16px chip with an 10px
/// AtSign, `border-line-strong bg-primary-soft text-primary-strong`
/// (Brutal `border-black bg-soft-signal text-black`).
class RaftSidebarMentionMarker extends StatelessWidget {
  const RaftSidebarMentionMarker({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return RaftTooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        child: Container(
          key: const ValueKey('sidebar-mention-marker'),
          width: 16,
          height: 16,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.colors['primary-soft'],
            border: Border.all(color: t.colors['line-strong']!),
            borderRadius: BorderRadius.circular(4),
          ),
          child: RaftIcon(
            RaftGlyph.atSign,
            size: 10,
            color: t.colors['primary-strong'],
          ),
        ),
      ),
    );
  }
}
