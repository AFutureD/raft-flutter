import 'message_history_pages.dart';
import 'message_window_snapshot.dart';
import 'workspace_controller.dart';
import 'workspace_message_windows.dart';

/// Compatibility snapshot adapter. Durable rows/ranges are owned separately;
/// this keeps the previous version's rollback format and window boundaries.
class MessageHistorySnapshots {
  static Future<void> save(
    WorkspaceController w,
    String id, {
    required bool thread,
    required WorkspaceThreadIdentity? identity,
    required String Function(String?) replyToken,
    required Future<void> Function(String, String, dynamic) write,
  }) async {
    if (!w.cacheWritable ||
        w.channelLoading && w.messageWindows.isContext(id) ||
        !thread && w.channel == null ||
        (thread ? id != w.threadChannelId : id != w.channel!.id) ||
        !w.messageWindows.notRevoked(id) ||
        w.hasNewer ||
        w.highlightedMessageId != null) {
      return;
    }
    final resource = thread ? w.threadSourceChannel : w.channel;
    if (resource == null || !w.can('viewChannel', resource: resource)) return;
    final authority = messageWindowAuthority(
      w.server?.string('role'),
      resource.json,
    );
    w.messageWindows.rememberWindow(
      liveWindowWrite,
      id,
      authority,
      thread ? w.threadHasMore : w.hasMore,
      replyToken(thread ? w.threadParentChannelId : id),
      historyLimited: thread ? w.threadHistoryLimited : w.historyLimited,
    );
    w.messageWindows.setContextMode(liveWindowWrite, id, null);
    final rows = thread ? w.replies : w.messages;
    final payload = {
      'version': 1,
      'windowKind': 'tail',
      'authority': authority,
      'parentChannelId': thread ? w.threadParentChannelId : id,
      'messages': MessageHistoryPages.snapshotRows(w.cache, rows),
      'hasMore': thread ? w.threadHasMore : w.hasMore,
      'historyLimited': thread ? w.threadHistoryLimited : w.historyLimited,
    };
    final saved = write('window', id, {
      ...payload,
      'hasNewer': false,
      'threadSummaries': thread
          ? {}
          : Map<String, dynamic>.from(w.threadSummaries),
    });
    if (thread &&
        identity != null &&
        identity.focusedMessageId == null &&
        w.messageWindows.notRevoked(identity.parentChannelId) &&
        w.messageWindows.notRevoked(id)) {
      final parent = w.threadParent;
      await write('thread-window', identity.parentMessageId, {
        ...payload,
        'parentChannelId': identity.parentChannelId,
        'threadChannelId': id,
        if (parent != null &&
            parent.id == identity.parentMessageId &&
            parent.channelId == identity.parentChannelId)
          'parent': parent.json,
      });
    }
    await saved;
  }
}
