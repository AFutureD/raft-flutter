import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';

import '../../data/workspace_controller.dart';

/// One proactive item: what it needs from the person and why.
class AgentAttentionItem {
  const AgentAttentionItem({
    required this.priority,
    required this.weight,
    required this.title,
    required this.at,
    this.detail,
    this.chips = const [],
    this.hot = false,
    this.channelId,
  });

  final AgentPriority priority;

  /// 0-5, drawn as bars. Higher sorts first within a priority.
  final int weight;
  final String title;
  final DateTime at;
  final String? detail;
  final List<String> chips;

  /// Seen but not handled: it keeps its weight instead of dropping away.
  final bool hot;
  final String? channelId;
}

/// A compact view of one channel for a Z layer.
class AgentChannelBrief {
  const AgentChannelBrief({
    required this.channel,
    required this.messages,
    required this.tasks,
    required this.windowHours,
  });

  final RaftChannel channel;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> tasks;
  final int windowHours;

  int get recentCount => messages.length;
  int get inReview => tasks.where((t) => t['status'] == 'in_review').length;
  int get inProgress => tasks.where((t) => t['status'] == 'in_progress').length;
}

/// Reads existing workspace endpoints for agent mode. Nothing is written.
///
/// Weighting (demo): tasks waiting for review are decisions; work in progress
/// that has not moved for a while is blocked; mentions in Activity follow,
/// and stay weighted after they were read until the row is handled; recent
/// completions are progress.
class AgentModeData {
  AgentModeData(this.w, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final WorkspaceController w;
  final DateTime Function() _now;

  static const stalledAfter = Duration(hours: 4);

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  static List<Map<String, dynamic>> _rows(Object? body, String key) {
    final list = body is Map ? body[key] : null;
    return [
      if (list is List)
        for (final r in list)
          if (r is Map) Map<String, dynamic>.from(r),
    ];
  }

  Future<List<Map<String, dynamic>>> _tasks(
    String status, {
    String? channelId,
    int limit = 50,
  }) async {
    final path = channelId == null
        ? '/tasks/server'
        : '/tasks/channel/$channelId';
    final body = await w.query(
      path,
      query: {'status': status, 'detail': 'summary', 'limit': limit},
    );
    return _rows(body, 'tasks');
  }

  String _ago(DateTime at) {
    final d = _now().difference(at);
    if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} 分钟';
    if (d.inHours < 48) return '${d.inHours} 小时';
    return '${d.inDays} 天';
  }

  Future<List<AgentAttentionItem>> attention() async {
    final results = await Future.wait([
      _tasks('in_review'),
      _tasks('in_progress'),
      _tasks('done', limit: 10),
      w.sharedQuery(
        '/channels/inbox',
        query: {'filter': 'all', 'sort': 'desc', 'limit': 30, 'offset': 0},
      ),
    ]);
    final now = _now();
    final items = <AgentAttentionItem>[];

    for (final t in results[0] as List<Map<String, dynamic>>) {
      final at = _time(t['updatedAt']) ?? now;
      final waiting = now.difference(at);
      items.add(
        AgentAttentionItem(
          priority: AgentPriority.decision,
          weight: waiting > const Duration(hours: 2) ? 5 : 4,
          title: '${t['title'] ?? '未命名任务'}',
          detail: '#${t['taskNumber']} 等你验收 · ${t['claimedByName'] ?? '未认领'}',
          chips: ['等了 ${_ago(at)}', '#${t['channelName'] ?? ''}'],
          hot: waiting > const Duration(hours: 2),
          at: at,
          channelId: t['channelId'] as String?,
        ),
      );
    }

    for (final t in results[1] as List<Map<String, dynamic>>) {
      final at = _time(t['updatedAt']) ?? now;
      final idle = now.difference(at);
      if (idle < stalledAfter) continue;
      items.add(
        AgentAttentionItem(
          priority: AgentPriority.blocked,
          weight: idle > const Duration(hours: 24) ? 4 : 3,
          title: '${t['title'] ?? '未命名任务'}',
          detail:
              '#${t['taskNumber']} · ${t['claimedByName'] ?? '未认领'} · ${_ago(at)}没有进展',
          chips: ['#${t['channelName'] ?? ''}'],
          at: at,
          channelId: t['channelId'] as String?,
        ),
      );
    }

    final inbox = _rows(results[3], 'items');
    for (final r in inbox) {
      if (r['hasMention'] != true) continue;
      final unread =
          (r['unreadCount'] is int ? r['unreadCount'] as int : 0) > 0;
      final at = _time(r['lastActivityAt'] ?? r['lastMessageAt']) ?? now;
      final thread = r['kind'] == 'thread';
      final where = thread
          ? '#${r['parentChannelName'] ?? ''} 的讨论'
          : '#${r['channelName'] ?? ''}';
      final who =
          r[thread ? 'latestActivitySenderName' : 'lastMessageSenderName'];
      final preview =
          r[thread ? 'latestActivityPreview' : 'lastMessagePreview'] ??
          r['messagePreview'];
      items.add(
        AgentAttentionItem(
          priority: AgentPriority.mention,
          weight: unread ? 3 : 2,
          title: '${who ?? '有人'}：${preview ?? ''}'.trim(),
          detail: where,
          chips: [unread ? '未读' : '已读未处理', _ago(at)],
          hot: !unread,
          at: at,
          channelId:
              (thread ? r['parentChannelId'] : r['channelId']) as String?,
        ),
      );
    }

    for (final t in results[2] as List<Map<String, dynamic>>) {
      final at = _time(t['completedAt'] ?? t['updatedAt']);
      if (at == null || now.difference(at) > const Duration(hours: 24)) {
        continue;
      }
      items.add(
        AgentAttentionItem(
          priority: AgentPriority.progress,
          weight: 1,
          title: '${t['title'] ?? '任务'} 已完成',
          detail: '#${t['taskNumber']} · ${t['claimedByName'] ?? ''}',
          at: at,
          channelId: t['channelId'] as String?,
        ),
      );
    }

    items.sort((a, b) {
      final p = a.priority.index.compareTo(b.priority.index);
      if (p != 0) return p;
      final wgt = b.weight.compareTo(a.weight);
      if (wgt != 0) return wgt;
      return b.at.compareTo(a.at);
    });
    return items;
  }

  Future<AgentChannelBrief> channel(
    RaftChannel c, {
    int windowHours = 6,
  }) async {
    final results = await Future.wait([
      w.client.messagePage(c.id, limit: 30),
      _tasks('in_review', channelId: c.id),
      _tasks('in_progress', channelId: c.id),
    ]);
    final page = results[0] as Map<String, dynamic>;
    final since = _now().subtract(Duration(hours: windowHours));
    final messages = _rows(page, 'messages')
      ..sort((a, b) {
        final sa = BigInt.tryParse('${a['seq']}') ?? BigInt.zero;
        final sb = BigInt.tryParse('${b['seq']}') ?? BigInt.zero;
        return sa.compareTo(sb);
      });
    final recent = [
      for (final m in messages)
        if ((_time(m['createdAt']) ?? since).isAfter(since)) m,
    ];
    return AgentChannelBrief(
      channel: c,
      messages: recent.isEmpty
          ? messages.sublist(messages.length > 5 ? messages.length - 5 : 0)
          : recent,
      tasks: [
        ...results[1] as List<Map<String, dynamic>>,
        ...results[2] as List<Map<String, dynamic>>,
      ],
      windowHours: windowHours,
    );
  }

  Future<List<Map<String, dynamic>>> openTasks() async {
    final results = await Future.wait([
      _tasks('in_review'),
      _tasks('in_progress'),
    ]);
    return [...results[0], ...results[1]];
  }
}

/// What a typed (later spoken) request asks for.
sealed class AgentIntent {
  const AgentIntent();
}

class AgentBack extends AgentIntent {
  const AgentBack();
}

class AgentHome extends AgentIntent {
  const AgentHome();
}

class AgentTasks extends AgentIntent {
  const AgentTasks();
}

class AgentOpenChannel extends AgentIntent {
  const AgentOpenChannel(this.channel);
  final RaftChannel channel;
}

class AgentUnknown extends AgentIntent {
  const AgentUnknown();
}

/// Demo intent matching. A realtime voice model replaces this with tool calls
/// that map onto the same intents.
AgentIntent parseAgentIntent(String text, List<RaftChannel> channels) {
  final s = text.trim().toLowerCase();
  if (RegExp(r'^(返回|回去|后退|back)$').hasMatch(s)) return const AgentBack();
  if (RegExp(r'(提醒|需要我|首页|home|回到开始)').hasMatch(s)) {
    return const AgentHome();
  }
  RaftChannel? best;
  for (final c in channels) {
    if (c.archived || c.name.isEmpty) continue;
    final name = c.name.toLowerCase();
    if (s.contains(name) && (best == null || name.length > best.name.length)) {
      best = c;
    }
  }
  if (best != null) return AgentOpenChannel(best);
  if (RegExp(r'(任务|task)').hasMatch(s)) return const AgentTasks();
  return const AgentUnknown();
}
