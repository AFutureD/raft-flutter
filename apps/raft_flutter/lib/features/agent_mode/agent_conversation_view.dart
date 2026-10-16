import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'references/agent_handle_tag.dart';

/// "任务 3 ›": the tasks of the channel, behind a chip in the header of its
/// conversation. They are not the first thing on the screen: what was said
/// is. The chip opens them as a layer of their own.
class AgentTasksChip extends StatelessWidget implements HfDescribed {
  const AgentTasksChip({super.key, required this.count, this.onTap});
  final int count;
  final VoidCallback? onTap;

  String get label => '任务 $count';

  @override
  HfDescription describe(HfDescribeEnv env) =>
      HfDescription([label], actions: onTap == null ? const [] : ['看任务']);

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final chip = Container(
      key: const ValueKey('conversation-tasks'),
      padding: EdgeInsets.symmetric(horizontal: hf.sp(12), vertical: hf.sp(4)),
      decoration: BoxDecoration(
        color: HfColors.cream,
        borderRadius: BorderRadius.circular(hf.sp(12)),
        border: Border.all(color: HfColors.ink, width: hf.sp(2.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: hf.type(HfType.headline, base: 16)),
          if (onTap != null && hf.interactive) ...[
            SizedBox(width: hf.sp(4)),
            Icon(Icons.chevron_right, size: hf.sp(22), color: HfColors.ink),
          ],
        ],
      ),
    );
    if (onTap == null || !hf.interactive) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: chip,
      ),
    );
  }
}

/// What one conversation layer draws: a channel, a private conversation or a
/// thread, as the chat it is. The phone, the desktop and the TV draw it from
/// the same data ([toFrame] / [fromFrame] carry it to the TV).
class AgentConversationData {
  const AgentConversationData({
    required this.title,
    this.meta,
    this.messages = const [],
    this.highlightId,
    this.hasMoreAbove = false,
    this.taskCount = 0,
    this.loading = false,
    this.error,
  });

  final String title;

  /// A small note at the right of the title ("在讨论「…」").
  final String? meta;
  final List<HfMessageData> messages;

  /// The message the person opened the conversation from.
  final String? highlightId;
  final bool hasMoreAbove;
  final int taskCount;
  final bool loading;
  final String? error;

  Map<String, Object?> toFrame() => {
    'title': title,
    'meta': meta,
    'loading': loading,
    'summary': error,
    'conversation': {
      'messages': [for (final m in messages) m.toJson()],
      'highlight': highlightId,
      'hasMoreAbove': hasMoreAbove,
      'tasks': taskCount,
    },
  };

  static AgentConversationData? fromFrame(Map<String, Object?> frame) {
    final c = frame['conversation'];
    if (c is! Map) return null;
    return AgentConversationData(
      title: '${frame['title'] ?? ''}',
      meta: frame['meta'] as String?,
      loading: frame['loading'] == true,
      error: frame['summary'] as String?,
      messages: [
        for (final m in (c['messages'] as List? ?? const []))
          if (m is Map) HfMessageData.fromJson(m.cast<String, Object?>()),
      ],
      highlightId: c['highlight'] as String?,
      hasMoreAbove: c['hasMoreAbove'] == true,
      taskCount: (c['tasks'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A conversation layer: the header (the name, the tasks chip), then the
/// messages as a chat, all one page that scrolls as a whole.
class AgentConversationView extends StatelessWidget {
  const AgentConversationView({
    super.key,
    required this.data,
    required this.focusPrefix,
    this.onTasks,
    this.onTapMessage,
    this.imageBuilder,
  });
  final AgentConversationData data;
  final String focusPrefix;
  final VoidCallback? onTasks;
  final void Function(int n, HfMessageData message)? onTapMessage;
  final HfImageBuilder? imageBuilder;

  /// The header, the spinner or the error, with [children] as the body.
  static HfLayerFrame frameOf(
    AgentConversationData data, {
    VoidCallback? onTasks,
    List<Widget> children = const [],
  }) => HfLayerFrame(
    title: data.title,
    meta: data.meta,
    count: data.taskCount > 0
        ? AgentTasksChip(count: data.taskCount, onTap: onTasks)
        : null,
    loading: data.loading && data.messages.isEmpty,
    error: data.error,
    children: children,
  );

  @override
  Widget build(BuildContext context) => frameOf(
    data,
    onTasks: onTasks,
    children: [
      if (!data.loading || data.messages.isNotEmpty)
        HfConversation(
          messages: data.messages,
          highlightId: data.highlightId,
          hasMoreAbove: data.hasMoreAbove,
          focusPrefix: focusPrefix,
          onTapMessage: onTapMessage,
          imageBuilder: imageBuilder,
          itemWrapper: (id, child) => AgentHandleTag(focusId: id, child: child),
        ),
    ],
  );
}
