/// Web `threadStore.applyServerThreadUnread`: a `read_state:updated` frame may
/// carry the unread count left after the read (`unreadCount`, newer servers).
/// The "N new" count on a thread's parent message cannot be recounted from
/// loaded replies, so it follows the server's number.
///
/// A read only lowers unread. The server's count also differs from the badge's
/// own algorithm (it ignores follow state and excludes the reader's own
/// messages), so it may lower a badge but never raise one.
///
/// Replaces the changed summaries in place and returns whether any changed.
bool lowerThreadSummaryUnread(
  Map<String, Map<String, dynamic>> summariesByChannel,
  String threadChannelId,
  int unreadCount,
) {
  var changed = false;
  for (final bucket in summariesByChannel.values) {
    for (final entry in bucket.entries.toList()) {
      final summary = entry.value;
      if (summary is! Map ||
          summary['threadChannelId'] != threadChannelId ||
          summary['unreadCount'] is! int ||
          (summary['unreadCount'] as int) <= unreadCount) {
        continue;
      }
      bucket[entry.key] = {
        ...Map<String, dynamic>.from(summary),
        'unreadCount': unreadCount,
        // The server sends a count, not a position: keep the old jump target
        // while anything is unread, drop it once nothing is.
        if (unreadCount == 0) 'firstUnreadMessageId': null,
      };
      changed = true;
    }
  }
  return changed;
}
