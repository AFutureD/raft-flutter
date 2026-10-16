import 'message_history_pages.dart';
import 'workspace_controller.dart';

/// Reply previews are stored with the history rows of their parents (same
/// store, retention and revocation). This is the controller-side adapter:
/// what a local page brings is merged without displacing newer held state,
/// and live changes are written through.
class MessageHistorySummaries {
  /// Summaries of a page served from the device, for parents the window does
  /// not already hold. A held summary is at least as new as the stored one.
  static dynamic unheld(WorkspaceController w, String channelId, dynamic rows) {
    if (rows is! Map || rows.isEmpty) return rows;
    final held = w.threadSummariesFor(channelId);
    return {
      for (final entry in rows.entries)
        if (!held.containsKey(entry.key)) entry.key: entry.value,
    };
  }

  /// Presents the previews that came with a local page.
  static void restore(WorkspaceController w, String channelId, dynamic page) {
    final rows = unheld(
      w,
      channelId,
      page is Map ? page['threadSummariesByParentMessageId'] : null,
    );
    if (rows is Map && rows.isNotEmpty) w.mergeThreadSummaries(channelId, rows);
  }

  /// Persists live summary changes (a reply arrived, a count was rebaselined)
  /// without waiting for the next window save.
  static void store(
    WorkspaceController w,
    String channelId,
    Map<String, dynamic> summaries,
  ) {
    final device = MessageHistoryPages.storage(w.cache);
    if (device == null ||
        !w.cacheWritable ||
        w.client.user == null ||
        w.client.serverId == null ||
        !w.messageWindows.notRevoked(channelId)) {
      return;
    }
    final scope = MessageHistoryPages.scope(w, channelId);
    if (scope == null) return;
    device.saveSummaries(scope, summaries).ignore();
  }
}
