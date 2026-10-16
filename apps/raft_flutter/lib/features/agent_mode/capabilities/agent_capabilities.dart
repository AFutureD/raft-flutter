import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentWorkState;

import '../../../data/workspace_controller.dart';
import '../../../data/workspace_entity_directory.dart';
import '../../agent_metadata_projection.dart'
    show agentRowName, agentRowAmbientDisplay;
import '../../agent_trajectory_log.dart' show admittedAgentTrajectoryRows;
import 'agent_capability.dart';
import 'capability_support.dart';

/// Agents: list with state, detail, activity log, reminders, channels.

/// One live agent row by id or name; throws with candidates when the name
/// fits several, and when it fits none.
Future<Map<String, dynamic>> agentByRef(
  WorkspaceController w,
  String ref,
) async {
  final rows = await directoryRows(w, WorkspaceEntityKind.agents);
  final want = ref.trim().toLowerCase().replaceAll('@', '');
  bool name(Map<String, dynamic> a, bool Function(String) test) =>
      test(agentRowName(a).toLowerCase()) ||
      test('${a['name'] ?? ''}'.toLowerCase());
  var hits = [
    for (final a in rows)
      if ('${a['id']}' == ref.trim() || name(a, (n) => n == want)) a,
  ];
  if (hits.isEmpty) {
    hits = [
      for (final a in rows)
        if (want.isNotEmpty && name(a, (n) => n.contains(want))) a,
    ];
  }
  if (hits.length == 1) return hits.single;
  if (hits.isEmpty) throw AgentCapabilityError('没有叫“$ref”的 Agent');
  throw AgentCapabilityError(
    '“$ref”对得上多个 Agent，请问用户是哪一个',
    candidates: [
      for (final a in hits.take(6)) {'id': a['id'], 'name': agentRowName(a)},
    ],
  );
}

final _agentRef = strArg('Agent 的 id 或名字');

final agentCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'agents.list',
    title: '所有 Agent 现在的状态：在忙 / 卡住 / 空闲 / 离线，正在做什么、持续多久',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /agents',
    keywords: const [
      'Agent',
      'agent们',
      '所有agent',
      'agent在干什么',
      'agent状态',
      '谁在忙',
      '谁卡住了',
      '谁空闲',
      '谁离线',
      '机器人在做什么',
      '有哪些agent',
      'agent列表',
      '团队在干嘛',
      '大家在忙什么',
    ],
    paramsSchema: objectSchema({
      'state': strArg(
        '只看某种状态',
        values: const ['busy', 'idle', 'blocked', 'offline'],
      ),
      'query': strArg('名字里的字'),
      'fresh': boolArg('一定向服务器读最新的；默认先用 App 已有的数据，更快'),
      'limit': intArg('最多几个，默认 40', min: 1, max: 60, dflt: 40),
    }),
    resultSummary: 'total, counts{busy,idle,blocked,offline}, agents[{id,name,state,activity,since,channel,task}]；source 为 cache 表示是 App 已有的数据',
    run: (w, args, env) async {
      final data = env.dataFor(w);
      final cached = args['fresh'] == true ? null : data.cachedAgents();
      final fromCache = cached != null && cached.isNotEmpty;
      final agents = fromCache ? cached : await data.agents();
      env.facts?.learnAgents(agents);
      env.onAgents?.call(agents, cached: fromCache);
      final state = text(args['state']);
      final q = (text(args['query']) ?? '').toLowerCase();
      final shown = [
        for (final a in agents)
          if ((state == null || a.state.name == state) &&
              (q.isEmpty || a.name.toLowerCase().contains(q)))
            a,
      ];
      return {
        'total': agents.length,
        'counts': {
          for (final s in AgentWorkState.values)
            s.name: agents.where((a) => a.state == s).length,
        },
        'agents': [
          for (final a in shown.take(limitOf(args, dflt: 40, max: 60)))
            a.toJson(),
        ],
        if (fromCache) 'source': 'cache',
      };
    },
  ),
  AgentCapability(
    id: 'agents.detail',
    title: '一个 Agent 的详细信息：简介、运行时、模型、在哪台电脑、现在的状态',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /agents/:id',
    keywords: const [
      'agent详情',
      'agent信息',
      'agent是谁',
      '这个agent',
      '它用什么模型',
      'agent的运行时',
      '在哪台电脑上',
      'agent资料',
      '介绍一下agent',
    ],
    paramsSchema: objectSchema({'agent': _agentRef}, required: const ['agent']),
    resultSummary: 'agent{id,name,description,runtime,model,machine,machineId,external,state,activity,lastSeen,createdAt}',
    run: (w, args, env) async {
      var row = await agentByRef(w, '${args['agent']}');
      try {
        final detail = await w.query('/agents/${row['id']}');
        if (detail is Map) row = {...row, ...Map<String, dynamic>.from(detail)};
      } on Object {
        // The directory row is still true.
      }
      final id = '${row['id']}';
      final machineId = text(row['machineId']);
      final machine = machineId == null
          ? null
          : w.entityDirectory.computer(machineId);
      final live = env
          .dataFor(w)
          .cachedAgents()
          ?.where((a) => a.id == id)
          .firstOrNull;
      final display = agentRowAmbientDisplay(row);
      return {
        'agent': compact({
          'id': id,
          'name': agentRowName(row),
          'description': clip(row['description'], 300),
          'runtime': row['runtime'],
          'model': row['model'],
          'machineId': machineId,
          'machine': machine?['name'],
          'external': row['external'] == true ? true : null,
          'state': live?.state.name,
          'activity':
              live?.activity ?? (display.online ? display.activity : '离线'),
          'lastSeen': stamp(row['lastSeenAt']),
          'createdAt': stamp(row['createdAt']),
        }),
      };
    },
  ),
  AgentCapability(
    id: 'agents.activity_log',
    title: '一个 Agent 最近的活动日志：它刚才做了什么、用了哪些工具、出过什么错',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /agents/:id/activity-log',
    keywords: const [
      '活动日志',
      'agent日志',
      '刚才做了什么',
      'agent的轨迹',
      '运行记录',
      '执行记录',
      '用了什么工具',
      '出了什么错',
      'trajectory',
      '它在干嘛',
    ],
    paramsSchema: objectSchema(
      {
        'agent': _agentRef,
        'limit': intArg('最近几条，默认 12', min: 1, max: 30, dflt: 12),
      },
      required: const ['agent'],
    ),
    resultSummary: 'entries[{time,kind,activity,detail,tool}] 旧到新',
    run: (w, args, env) async {
      final row = await agentByRef(w, '${args['agent']}');
      final body = await w.query(
        '/agents/${row['id']}/activity-log',
        query: {'limit': '50'},
      );
      final rows = admittedAgentTrajectoryRows(body)
        ..sort(
          (a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num),
        );
      final limit = limitOf(args, dflt: 12);
      final shown = rows.length > limit
          ? rows.sublist(rows.length - limit)
          : rows;
      return {
        'agent': agentRowName(row),
        'agentId': row['id'],
        'entries': [
          for (final r in shown)
            () {
              final e = Map<String, dynamic>.from(r['entry'] as Map);
              return compact({
                'time': stamp(
                  DateTime.fromMillisecondsSinceEpoch(
                    (r['timestamp'] as num).toInt(),
                    isUtc: true,
                  ).toIso8601String(),
                ),
                'kind': e['kind'],
                'activity': e['activityKind'] ?? e['activity'],
                'detail': clip(e['detail'] ?? e['text'] ?? e['title'], 160),
                'tool': e['toolName'],
              });
            }(),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'agents.reminders',
    title: '一个 Agent 设好的定时提醒（还没触发的）',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /reminders',
    keywords: const [
      '提醒',
      '定时提醒',
      'agent的提醒',
      '定时任务',
      '什么时候提醒',
      'reminders',
      '闹钟',
      '计划',
    ],
    paramsSchema: objectSchema({'agent': _agentRef}, required: const ['agent']),
    resultSummary: 'reminders[{id,title,fireAt,recurrence}]',
    run: (w, args, env) async {
      final row = await agentByRef(w, '${args['agent']}');
      final body = await w.query(
        '/reminders',
        query: {'ownerAgentId': row['id'], 'status': 'scheduled'},
      );
      final rows = rowsOf(body, const ['reminders']);
      return {
        'agent': agentRowName(row),
        'count': rows.length,
        'reminders': [
          for (final r in rows.take(20))
            compact({
              'id': r['reminderId'] ?? r['id'],
              'title': clip(r['title'], 120),
              'fireAt': stamp(r['fireAt']),
              'recurrence': r['recurrence'] is Map
                  ? (r['recurrence'] as Map)['description']
                  : null,
            }),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'agents.channels',
    title: '一个 Agent 加入了哪些频道',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /agents/:id/channels',
    keywords: const ['agent在哪些频道', 'agent加入的频道', 'agent的频道', '它在哪些群'],
    paramsSchema: objectSchema({'agent': _agentRef}, required: const ['agent']),
    resultSummary: 'channels[{id,name,type}]',
    run: (w, args, env) async {
      final row = await agentByRef(w, '${args['agent']}');
      final body = await w.query('/agents/${row['id']}/channels');
      final rows = rowsOf(body, const ['channels']);
      return {
        'agent': agentRowName(row),
        'count': rows.length,
        'channels': [
          for (final c in rows.take(40))
            compact({
              'id': c['id'] ?? c['channelId'],
              'name': c['name'] ?? c['channelName'],
              'type': c['type'],
            }),
        ],
      };
    },
  ),
];
