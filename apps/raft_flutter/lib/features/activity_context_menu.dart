import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

/// Builds the Web InboxContextMenu with the existing design system menu.
///
/// Every row has Done. Unfollowed threads offer Follow without a read toggle.
Widget buildActivityContextMenu(
  BuildContext context,
  Map<String, dynamic> row, {
  required VoidCallback onDismiss,
  required VoidCallback onToggleRead,
  required VoidCallback onDone,
  required VoidCallback onToggleFollow,
}) {
  final thread = row['kind'] == 'thread';
  final following = row['isFollowing'] != false;
  final unread = (row['unreadCount'] as num? ?? 0) > 0;
  return RaftSidebarContextMenu(
    width: 184,
    onDismiss: onDismiss,
    entries: [
      if (!thread || following)
        RaftSidebarMenuItem(
          label: raftText(context, unread ? 'Mark as Read' : 'Mark as Unread'),
          glyph: unread
              ? RaftGlyph.messageSquareCheck
              : RaftGlyph.messageSquareDot,
          itemKey: const ValueKey('activity-menu-toggle-read'),
          onPressed: onToggleRead,
        ),
      RaftSidebarMenuItem(
        label: raftText(context, 'Done'),
        glyph: RaftGlyph.check,
        onPressed: onDone,
      ),
      if (thread)
        RaftSidebarMenuItem(
          label: raftText(context, following ? 'Unfollow' : 'Follow'),
          glyph: following ? RaftGlyph.bellOff : RaftGlyph.bell,
          onPressed: onToggleFollow,
        ),
    ],
  );
}
