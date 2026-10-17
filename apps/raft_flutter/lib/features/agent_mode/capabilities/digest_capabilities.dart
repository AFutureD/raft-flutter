import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import '../../resource_filters.dart';
import 'action_support.dart';
import 'agent_capability.dart';
import 'capability_support.dart';

/// "昨天到今天整体怎么样": one read across tasks, channels and mentions for a
/// time range, and switching the workspace.

DateTime _startOf(String range, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  return switch (range) {
    'today' => day,
    '24h' => now.subtract(const Duration(hours: 24)),
    '3d' => day.subtract(const Duration(days: 2)),
    '7d' => day.subtract(const Duration(days: 6)),
    _ => day.subtract(const Duration(days: 1)),
  };
}

const _rangeWords = {
  'today': '今天 0 点起',
  'since_yesterday': '昨天 0 点起',
  '24h': '最近 24 小时',
  '3d': '最近 3 天',
  '7d': '最近 7 天',
};

DateTime? _at(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toLocal() : null;

final digestCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'digest.since',
    title: '一段时间的整体汇总：这段时间任务有什么变化（完成了几个、谁在做什么）、哪些频道有动静、谁提到了我；默认从昨天 0 点起',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /tasks/server',
    keywords: const [
      '日报',
      '汇总',
      '总结一下',
      '昨天到今天',
      '昨天以来',
      '这几天',
      '这周发生了什么',
      '今天发生了什么',
      '整体进展',
      '有什么变化',
      '过去一天',
      '简报',
      '错过了什么',
      'digest',
    ],
    paramsSchema: objectSchema({
      'range': strArg(
        '时间范围：today 今天 / since_yesterday 昨天起（默认）/ 24h / 3d / 7d',
        values: const ['today', 'since_yesterday', '24h', '3d', '7d'],
      ),
      'after': strArg('具体起点，如 2026-10-15T08:00:00；比 range 优先', max: 40),
    }),
    resultSummary: 'since, label, tasks{updated,byStatus{done,in_review,...},recent[{id,number,title,status,owner,channel,updated}]}, channels{active,rows[{id,name,from,text,time,unread,mention}]}, mentions{count,rows}, unreadTotal',
    run: (w, args, env) async {
      final data = env.dataFor(w);
      final now = data.now();
      final after = text(args['after']);
      final since = after == null
          ? _startOf('${args['range'] ?? 'since_yesterday'}', now)
          : DateTime.tryParse(after)?.toLocal();
      if (since == null) {
        throw AgentCapabilityError(
          '时间“$after”看不懂，请用 2026-10-15T08:00:00 这样的写法，或用 range',
        );
      }
      if (since.isAfter(now)) {
        throw const AgentCapabilityError('起点在未来：请说一个过去的时间');
      }
      final label = after == null
          ? _rangeWords['${args['range'] ?? 'since_yesterday'}']
          : '自 ${stamp(since.toUtc().toIso8601String())} 起';

      // Tasks changed in the range, by where they are now.
      final tasks = <Map<String, dynamic>>[];
      Object? tasksProblem;
      try {
        for (final t in await data.searchTasks('')) {
          final updated = _at(t['updatedAt']);
          if (updated != null && !updated.isBefore(since)) tasks.add(t);
        }
      } on Object catch (e) {
        tasksProblem = e;
      }
      final byStatus = <String, int>{};
      for (final t in tasks) {
        final s = '${t['status']}';
        byStatus[s] = (byStatus[s] ?? 0) + 1;
      }

      // Conversations with something new in the range (the Activity list).
      final rows = <Map<String, dynamic>>[];
      var channelsProblem = false;
      try {
        final body = await w.sharedQuery(
          '/channels/inbox',
          query: ResourceFilters().list('', limit: 30, filter: 'all'),
        );
        for (final r in rowsOf(body, const ['items'])) {
          final at = _at(r['lastMessageAt'] ?? r['latestActivityAt']);
          if (at != null && !at.isBefore(since)) rows.add(r);
        }
      } on Object {
        channelsProblem = true;
      }
      String name(Map<String, dynamic> r) =>
          '${r['kind'] == 'thread' ? r['parentChannelName'] : r['channelName']}';
      Map<String, Object?> row(Map<String, dynamic> r) {
        final thread = r['kind'] == 'thread';
        return compact({
          'id': thread ? r['parentChannelId'] : r['channelId'],
          'name': name(r),
          'thread': thread ? true : null,
          'from': thread
              ? r['latestActivitySenderName']
              : r['lastMessageSenderName'],
          'text': clip(
            thread
                ? r['latestActivityPreview'] ?? r['parentMessagePreview']
                : r['lastMessagePreview'],
            120,
          ),
          'time': stamp(r['lastMessageAt'] ?? r['latestActivityAt']),
          'unread': (r['unreadCount'] ?? 0) == 0 ? null : r['unreadCount'],
          'mention': r['hasMention'] == true ? true : null,
        });
      }

      final mentioned = [
        for (final r in rows)
          if (r['hasMention'] == true) r,
      ];
      return compact({
        'since': stamp(since.toUtc().toIso8601String()),
        'label': label,
        'tasks': tasksProblem != null
            ? {'problem': '任务现在读不到'}
            : {
                'updated': tasks.length,
                'byStatus': byStatus,
                'recent': [
                  for (final t in tasks.take(8))
                    compact({
                      'id': t['id'],
                      'number': t['taskNumber'],
                      'title': clip(t['title'], 80),
                      'status': t['status'],
                      'owner': t['claimedByName'],
                      'channel': t['channelName'],
                      'updated': stamp(t['updatedAt']),
                    }),
                ],
              },
        'channels': channelsProblem
            ? {'problem': '动态现在读不到'}
            : {
                'active': rows.length,
                'rows': [for (final r in rows.take(8)) row(r)],
              },
        'mentions': {
          'count': mentioned.length,
          'rows': [for (final r in mentioned.take(5)) row(r)],
        },
        'unreadTotal': w.unread.values.fold<int>(0, (a, b) => a + b),
        'note': rows.length >= 30 ? '动态只读了最近 30 个会话，更早的没有统计' : null,
      });
    },
  ),
  AgentCapability(
    id: 'servers.switch',
    title: '切换到另一个工作区（服务器）；切换后屏幕上的数据换成那个工作区的',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'GET /servers',
    keywords: const [
      '切换服务器',
      '切到服务器',
      '换到另一个工作区',
      '切换工作区',
      '去另一个服务器',
      '进入服务器',
      '切到myoland',
      'switch server',
    ],
    paramsSchema: objectSchema(
      {'server': strArg('工作区的名字、地址（slug）或 id')},
      required: const ['server'],
    ),
    resultSummary: 'done, id, name（切换后的工作区）',
    prepareUndo: (w, args, env) async {
      final back = w.server;
      if (back == null) return null;
      return AgentUndoPlan(
        label: '切回 ${back.string('name')}',
        run: () async {
          await _switchTo(w, back);
          env.onServerSwitched?.call();
          return '已切回 ${back.string('name')}';
        },
      );
    },
    preview: (w, args, env) async {
      final target = _server(w, '${args['server']}');
      return AgentActionPreview(
        summary:
            '从“${w.server?.string('name')}”切换到工作区“${target.string('name')}”',
        changes: [
          change('当前工作区', w.server?.string('name'), target.string('name')),
        ],
        reversible: true,
      );
    },
    run: (w, args, env) async {
      final target = _server(w, '${args['server']}');
      await _switchTo(w, target);
      env.onServerSwitched?.call();
      return actionResult(
        '已切换到“${target.string('name')}”',
        extra: {'serverId': target.id, 'name': target.string('name')},
      );
    },
  ),
];

RaftRecord _server(WorkspaceController w, String ref) {
  final want = ref.trim().toLowerCase();
  bool is_(RaftRecord s, bool exact) {
    final fields = [
      s.id.toLowerCase(),
      s.string('name').toLowerCase(),
      s.string('slug').toLowerCase(),
    ];
    return exact
        ? fields.contains(want)
        : want.isNotEmpty && fields.any((f) => f.contains(want));
  }

  var hits = w.servers.where((s) => is_(s, true)).toList();
  if (hits.isEmpty) hits = w.servers.where((s) => is_(s, false)).toList();
  if (hits.length > 1) {
    throw AgentCapabilityError(
      '“$ref”对得上多个工作区，请问用户是哪一个',
      candidates: [
        for (final s in hits.take(6)) {'id': s.id, 'name': s.string('name')},
      ],
    );
  }
  if (hits.isEmpty) {
    throw AgentCapabilityError(
      '没有叫“$ref”的工作区（你加入的有：${w.servers.map((s) => s.string('name')).join('、')}）',
    );
  }
  if (hits.single.id == w.server?.id) {
    throw AgentCapabilityError('已经在“${hits.single.string('name')}”里了');
  }
  return hits.single;
}

/// The same call the server menu makes; it answers once the new server's
/// channels are in, which can be long, so the agent stops waiting after a
/// few seconds (the switch itself goes on).
Future<void> _switchTo(WorkspaceController w, RaftRecord target) async {
  await w
      .selectServer(target)
      .timeout(const Duration(seconds: 6), onTimeout: () {});
  if (w.server?.id != target.id) {
    throw const AgentCapabilityError('没有切换成功（工作区可能已经不可用了）');
  }
}
