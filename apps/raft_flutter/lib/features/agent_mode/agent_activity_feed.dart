import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';

import '../../data/resource_row_reconcile.dart' show activityItemKey;
import '../activity_destination.dart';
import '../resource_view.dart' show activityRowTitle, activityThreadSubtitle;
import 'agent_mode_data.dart';

/// The home of agent mode is the App's Activity (動態): the rows of the
/// inbox window the Activity badge and the Activity page read
/// (`/channels/inbox`, newest first, as the server orders them), shown as
/// items. This turns one row into one item, and puts the tasks that wait for
/// the person's decision among them by recency.
///
/// Nothing here ranks Activity rows: the order is the App's. A task is never
/// placed by how long it waited.
class AgentActivityFeed {
  AgentActivityFeed({
    required this.now,
    required this.myId,
    this.channels = const [],
    this.dms = const [],
    this.nameOf,
  });

  final DateTime now;

  /// The signed-in user: a message from them reads "你".
  final String? myId;
  final List<RaftChannel> channels, dms;

  /// The name of a person or Agent by id and sender type (`user`, `agent`):
  /// the shared author directory the Activity page reads. An Activity row
  /// from the server often carries only the sender's id.
  final String? Function(String id, String type)? nameOf;

  static String? _s(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  /// A message as the person reads it in a list: markdown marks and code
  /// blocks removed, @mentions kept (they are why it is here), one line.
  static String excerptOf(String raw, {int max = 4000}) {
    final text = raw
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1] ?? '')
        .replaceAll(RegExp(r'^[#>\-*+\s]+', multiLine: true), '')
        .replaceAll(RegExp(r'\*\*|__|~~|`'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length <= max ? text : '${text.substring(0, max).trimRight()}…';
  }

  ({int value, String unit}) _ago(DateTime at) {
    final d = now.difference(at);
    if (d.inMinutes < 1) return (value: 1, unit: '分钟');
    if (d.inMinutes < 60) return (value: d.inMinutes, unit: '分钟');
    if (d.inHours < 48) return (value: d.inHours, unit: '小时');
    return (value: d.inDays, unit: '天');
  }

  String _stamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final n = now.toLocal(), t = at.toLocal();
    final days = DateTime(
      n.year,
      n.month,
      n.day,
    ).difference(DateTime(t.year, t.month, t.day)).inDays;
    final clock = '${two(t.hour)}:${two(t.minute)}';
    return switch (days) {
      0 => '今天 $clock',
      1 => '昨天 $clock',
      _ => '${t.month}月${t.day}日 $clock',
    };
  }

  /// The items of [rows], in the order of [rows].
  List<AgentAttentionItem> itemsOf(Iterable<Map> rows) => [
    for (final row in rows) ?itemOf(Map<String, dynamic>.from(row)),
  ];

  /// Why the row is in the person's Activity, in their words.
  String whyOf(Map<String, dynamic> row, {required bool me}) {
    final kind = row['kind'];
    if (kind == 'mention_action') return '点名后等你处理';
    if (row['hasMention'] == true) return '点名了你';
    if (kind == 'dm') return me ? '你发的私信' : '私信你';
    if (kind == 'thread') {
      if (_s(row['parentMessageSenderId']) == myId && myId != null) {
        return '回复了你的消息';
      }
      if (row['isFollowing'] == true) return '你关注的讨论';
      return row['taskNumber'] != null ? '任务有新回复' : '讨论有新回复';
    }
    return ((row['unreadCount'] as num?) ?? 0) > 0 ? '频道有新消息' : '最近动态';
  }

  /// One Activity row as an item; null for a row with no identity.
  AgentAttentionItem? itemOf(Map<String, dynamic> row) {
    final key = activityItemKey(row);
    if (key == null) return null;
    final kind = '${row['kind']}';
    final thread = kind == 'thread';
    final action = kind == 'mention_action';
    final dm = kind == 'dm' || (action && row['channelType'] == 'dm');
    final senderId = _s(
      row[thread ? 'latestActivitySenderId' : 'lastMessageSenderId'],
    );
    final mine = senderId != null && senderId == myId;
    final senderType = _s(
      row[thread ? 'latestActivitySenderType' : 'lastMessageSenderType'],
    );
    final named =
        _s(
          row[thread ? 'latestActivitySenderName' : 'lastMessageSenderName'],
        ) ??
        (senderId == null || senderType == null
            ? null
            : _s(nameOf?.call(senderId, senderType)));
    // System events ("🔄 Cody moved #136 …") name their actor in the text,
    // so they get no sender prefix.
    final event =
        senderType == 'system' ||
        senderId == 'system' ||
        senderId == null && named == null;
    final who = mine ? '你' : (event ? null : (named ?? (action ? null : '有人')));
    final raw =
        '${(thread ? row['latestActivityPreview'] : row['lastMessagePreview']) ?? row['messagePreview'] ?? ''}';
    final excerpt = excerptOf(raw);
    final at =
        _time(
          row['lastActivityAt'] ?? row['lastMessageAt'] ?? row['lastReplyAt'],
        ) ??
        now;
    final unread = ((row['unreadCount'] as num?) ?? 0).toInt();
    final mentioned = row['hasMention'] == true || action;
    final channelId = _s(thread ? row['parentChannelId'] : row['channelId']);
    final channelName = _s(
      thread ? row['parentChannelName'] : row['channelName'],
    );
    final parentTitle = thread
        ? AgentHeadlines.clean('${row['parentMessagePreview'] ?? ''}', max: 24)
        : '';
    final place = thread
        ? [
            activityThreadSubtitle(row, [...channels, ...dms]),
            if (parentTitle.isNotEmpty) parentTitle,
          ].join(' › ')
        : dm
        ? '@${activityRowTitle(row, dms)}'
        : '#${channelName ?? ''}';
    final why = whyOf(row, me: mine);
    final replyable =
        mentioned ||
        dm ||
        (thread && why == '回复了你的消息') ||
        row['isFollowing'] == true;
    final ago = _ago(at);
    final destination = ActivityDestination.fromRow(row, canonical: false);
    final said = excerpt.isEmpty
        ? place
        : '${who == null ? '' : '$who：'}$excerpt';
    return AgentAttentionItem(
      id: 'activity:$key',
      kind: AgentItemKind.activity,
      priority: mentioned ? AgentPriority.mention : AgentPriority.progress,
      headline: said,
      ask: replyable ? '回复' : '查看',
      askLine: replyable ? (who == null || mine ? '回复' : '回复 $who') : '查看这段对话',
      action: replyable ? AgentAction.reply : AgentAction.open,
      reason: why,
      at: at,
      waitValue: ago.value,
      waitUnit: ago.unit,
      doer: mine ? null : who,
      waiters: [if (!mine && who != null) who],
      channelId: channelId,
      channelName: channelName,
      threadTitle: parentTitle.isEmpty ? null : parentTitle,
      taskNumber: row['taskNumber'] is int ? row['taskNumber'] as int : null,
      taskStatus: _s(row['taskStatus']),
      unread: unread,
      excerpt: excerpt.isEmpty ? null : excerpt,
      place: place,
      dm: dm,
      messageId: _s(
        thread
            ? row['latestActivityMessageId']
            : (action ? row['messageId'] : row['lastMessageId']),
      ),
      focusMessageId: destination?.messageId,
      parentMessageId: _s(row['parentMessageId']),
      threadChannelId: _s(row['threadChannelId']),
      rowKind: kind,
      progress: [
        if (excerpt.isNotEmpty)
          AgentProgressLine(who: who ?? '', time: _stamp(at), text: excerpt),
      ],
    );
  }

  /// The feed: [activity] in its order, with each decision [pool] item that
  /// is an Activity row's own task merged into the row (the row gains the
  /// decision), and the others placed among the rows by how recent they are,
  /// the more direct first on a tie. A task is never placed by how long it
  /// waited.
  static List<AgentAttentionItem> compose(
    List<AgentAttentionItem> activity,
    List<AgentAttentionItem> pool,
  ) {
    if (pool.isEmpty) return activity;
    String? taskKey(AgentAttentionItem i) =>
        i.channelId == null || i.taskNumber == null
        ? null
        : '${i.channelId}#${i.taskNumber}';
    final byTask = {
      for (final p in pool)
        if (taskKey(p) != null) taskKey(p)!: p,
    };
    final used = <String>{};
    final rows = <AgentAttentionItem>[];
    for (final a in activity) {
      final k = taskKey(a);
      final task = k == null ? null : byTask[k];
      if (task == null || !used.add(k!)) {
        rows.add(a);
      } else if (task.priority == AgentPriority.blocked) {
        // A task whose thread moved after it was last touched is not stuck.
        rows.add(a);
      } else {
        rows.add(a.withDecision(task));
      }
    }
    final alive = {
      for (final a in activity)
        if (taskKey(a) != null) taskKey(a)!: a.at,
    };
    final extras =
        [
          for (final p in pool)
            if (!used.contains(taskKey(p)) ||
                (p.priority == AgentPriority.blocked &&
                    !(alive[taskKey(p)]?.isAfter(p.at) ?? false)))
              p,
        ]..sort((a, b) {
          final t = b.at.compareTo(a.at);
          return t != 0 ? t : b.score.compareTo(a.score);
        });
    final out = <AgentAttentionItem>[];
    var e = 0;
    for (final r in rows) {
      while (e < extras.length && extras[e].at.isAfter(r.at)) {
        out.add(extras[e++]);
      }
      out.add(r);
    }
    out.addAll(extras.skip(e));
    return out;
  }
}
