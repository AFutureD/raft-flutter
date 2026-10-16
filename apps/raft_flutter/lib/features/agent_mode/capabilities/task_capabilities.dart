import '../../../data/workspace_controller.dart';
import '../agent_mode_data.dart';
import 'agent_capability.dart';
import 'capability_support.dart';

/// Tasks: the server board, one task, its history, search.

const taskStatuses = ['todo', 'in_progress', 'in_review', 'done', 'closed'];

Map<String, Object?> taskRowOf(Map<String, dynamic> t) => compact({
  'id': t['id'],
  'number': t['taskNumber'],
  'title': clip(t['title'], 120),
  'status': t['status'],
  'owner': t['claimedByName'],
  'ownerId': t['claimedById'],
  'creator': t['createdByName'],
  'channel': t['channelName'],
  'channelId': t['channelId'],
  'threadId': t['threadChannelId'],
  'updated': stamp(t['updatedAt']),
});

bool _is(
  Map<String, dynamic> t,
  String idKey,
  String nameKey,
  String want,
  ({String? id, Set<String> names}) me,
) {
  final w = want.trim().toLowerCase();
  final id = '${t[idKey] ?? ''}';
  final name = '${t[nameKey] ?? ''}'.toLowerCase();
  if (w == 'me' || w == '我' || w == '自己') {
    return me.id != null && id == me.id;
  }
  if (w == 'unassigned' || w == '无人认领' || w == '没人') return id.isEmpty;
  return id == want.trim() || (name.isNotEmpty && name.contains(w));
}

Future<Map<String, Object?>> _board(
  WorkspaceController w,
  Map<String, Object?> args,
  AgentCapabilityEnv env,
) async {
  final data = env.dataFor(w);
  final status = text(args['status']);
  final statuses = switch (status) {
    null => const ['in_progress', 'in_review', 'todo'],
    'open' => const ['in_progress', 'in_review', 'todo'],
    _ => [status],
  };
  final channel = text(args['channel']);
  final channelId = channel == null ? null : channelByRef(w, channel).id;
  final lanes = await Future.wait([
    for (final s in statuses)
      data
          .taskLane(s, channelId: channelId)
          .then<({List<Map<String, dynamic>> rows, bool truncated})?>(
            (v) => v,
            onError: (Object _) => null,
          ),
  ]);
  if (lanes.every((l) => l == null)) {
    throw const AgentCapabilityError('任务现在读不到，请稍后再试');
  }
  final me = data.me;
  final assignee = text(args['assignee']), creator = text(args['creator']);
  final q = (text(args['q']) ?? '').toLowerCase();
  final rows =
      [
        for (final lane in lanes)
          if (lane != null)
            for (final t in lane.rows)
              if ((assignee == null ||
                      _is(t, 'claimedById', 'claimedByName', assignee, me)) &&
                  (creator == null ||
                      _is(t, 'createdById', 'createdByName', creator, me)) &&
                  (q.isEmpty ||
                      '${t['title']} ${t['description'] ?? t['descriptionPreview'] ?? ''}'
                          .toLowerCase()
                          .contains(q)))
                t,
      ]..sort(
        (a, b) => (AgentModeData.timeOf(b['updatedAt']) ?? DateTime(0))
            .compareTo(AgentModeData.timeOf(a['updatedAt']) ?? DateTime(0)),
      );
  env.facts?.learnTaskRows(rows);
  final limit = limitOf(args, dflt: 12);
  return compact({
    'total': rows.length,
    'counts': {
      for (final s in statuses) s: rows.where((t) => t['status'] == s).length,
    },
    'truncated': lanes.any((l) => l == null || l.truncated) ? true : null,
    'tasks': [for (final t in rows.take(limit)) taskRowOf(t)],
  });
}

/// The task of [args]: by `taskId`, or by number (numbers repeat across
/// channels, so a channel name settles it).
Future<AgentTaskDetail> _taskOf(
  WorkspaceController w,
  Map<String, Object?> args,
  AgentCapabilityEnv env,
) async {
  final data = env.dataFor(w);
  var number = args['number'] as int?;
  var channel = text(args['channel']);
  final id = text(args['taskId']);
  if (id != null) {
    final all = await data.searchTasks('');
    final row = all.where((t) => '${t['id']}' == id).firstOrNull;
    if (row == null) throw AgentCapabilityError('没有找到任务 $id');
    number = row['taskNumber'] as int?;
    channel = text(row['channelName']);
  }
  if (number == null) {
    throw const AgentCapabilityError('需要任务编号 number（或 taskId）');
  }
  final found = await data.tasksNumbered(number, channel: channel);
  if (found.isEmpty) throw AgentCapabilityError('没有找到任务 #$number');
  if (found.length > 1) {
    throw AgentCapabilityError(
      '多个频道都有任务 #$number，请带上 channel 再问',
      candidates: [
        for (final t in found) {'channel': t.channelName, 'taskId': t.id},
      ],
      extra: {
        'channels': [for (final t in found) t.channelName],
      },
    );
  }
  return found.single;
}

final taskCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'tasks.board',
    title: '任务看板：按状态、频道、负责人、创建人筛选任务（默认看进行中、待验收和待办）',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /tasks/server',
    keywords: const [
      '任务',
      '任务看板',
      '任务列表',
      '有哪些任务',
      '待验收',
      '等验收',
      '进行中的任务',
      '待办',
      '谁在做什么任务',
      '分给谁的任务',
      '某个人的任务',
      '已完成的任务',
      '这个频道的任务',
      'tasks',
      'board',
    ],
    paramsSchema: objectSchema({
      'status': strArg(
        '状态；open 是进行中+待验收+待办（默认）',
        values: const [...taskStatuses, 'open'],
      ),
      'channel': strArg('只看这个频道的任务（id 或名字）'),
      'assignee': strArg('负责人（名字或 id；me 是我自己，unassigned 是没人认领）'),
      'creator': strArg('创建人（名字或 id；me 是我自己）'),
      'q': strArg('标题或描述里的字'),
      'limit': intArg('最多几个，默认 12', min: 1, max: 30, dflt: 12),
    }),
    resultSummary: 'tasks[{id,number,title,status,owner,ownerId,creator,channel,channelId,threadId,updated}] 新到旧；total、counts 按状态；truncated 表示还有没读完的',
    run: _board,
  ),
  AgentCapability(
    id: 'tasks.mine',
    title: '我的任务：派给我的、我创建的、或等我验收的',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /tasks/server',
    keywords: const [
      '我的任务',
      '派给我的',
      '我创建的任务',
      '我要做的',
      '我手上的任务',
      '等我验收',
      '我该做什么',
      '我的待办',
    ],
    paramsSchema: objectSchema({
      'role': strArg(
        'assigned 派给我 / created 我创建的',
        values: const ['assigned', 'created'],
      ),
      'status': strArg(
        '状态，默认进行中+待验收+待办',
        values: const [...taskStatuses, 'open'],
      ),
      'limit': intArg('最多几个，默认 12', min: 1, max: 30, dflt: 12),
    }),
    resultSummary: '同 tasks.board',
    run: (w, args, env) => _board(w, {
      'status': args['status'],
      if (args['role'] == 'created') 'creator': 'me' else 'assignee': 'me',
      'limit': args['limit'],
    }, env),
  ),
  AgentCapability(
    id: 'tasks.detail',
    title: '按任务编号读一个任务的全部内容：标题、描述、状态、负责人、讨论串最后几条',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /tasks/channel/:id/number/:id',
    keywords: const [
      '任务详情',
      '任务怎么样了',
      '这个任务',
      '任务进展',
      '任务情况',
      '任务状态',
      '#号任务',
      '编号任务',
      '看一下任务',
      '任务的描述',
      'PR',
      '进度',
    ],
    paramsSchema: objectSchema({
      'number': intArg('任务编号，不带 #', min: 1),
      'channel': strArg('频道名，不带 #；不同频道编号会重复，重复时才需要'),
      'taskId': strArg('任务 id，已知时可代替 number', max: 80),
    }),
    resultSummary: 'task{id,number,title,status,description,creator,claimer,channel,channelId,updated,thread[{who,time,text}]}',
    run: (w, args, env) async {
      final t = await _taskOf(w, args, env);
      env.facts?.learnTask(t);
      return {
        'task': {
          ...t.toJson(),
          'id': t.id,
          if (t.channelId != null) 'channelId': t.channelId,
        },
      };
    },
  ),
  AgentCapability(
    id: 'tasks.history',
    title: '一个任务的历史：谁在什么时候创建、改状态、改负责人、改内容',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /tasks/:id/history',
    keywords: const [
      '任务历史',
      '任务记录',
      '任务变更',
      '谁改过',
      '什么时候改的状态',
      '状态变化',
      '时间线',
      '任务时间线',
      '什么时候完成的',
      '谁指派的',
    ],
    paramsSchema: objectSchema({
      'taskId': strArg('任务 id（读过任务后带有）', max: 80),
      'number': intArg('任务编号，没有 id 时用', min: 1),
      'channel': strArg('频道名，编号重复时才需要'),
      'limit': intArg('最近几条，默认 15', min: 1, max: 40, dflt: 15),
    }),
    resultSummary: 'events[{type,by,time,from,to,changes}] 旧到新',
    run: (w, args, env) async {
      var id = text(args['taskId']);
      id ??= (await _taskOf(w, args, env)).id;
      final cached = w.taskHistoryCache.peek(id)?.events;
      List<Map<String, dynamic>> events;
      try {
        final body = await w.query('/tasks/$id/history');
        events = rowsOf(body, const ['events']);
      } on Object {
        if (cached == null) rethrow;
        events = cached;
      }
      events = [
        for (final e in events)
          if (e['eventType'] != 'resource_receipt_recorded') e,
      ];
      final limit = limitOf(args, dflt: 15, max: 40);
      final shown = events.length > limit
          ? events.sublist(events.length - limit)
          : events;
      return {
        'taskId': id,
        'total': events.length,
        'events': [
          for (final e in shown)
            () {
              final p = e['payload'] is Map
                  ? Map<String, dynamic>.from(e['payload'] as Map)
                  : <String, dynamic>{};
              return compact({
                'type': e['eventType'],
                'by': e['actorName'] ?? e['actorType'],
                'time': stamp(e['createdAt']),
                'from': p['from'] is Map ? null : clip(p['from'], 60),
                'to': p['to'] is Map ? null : clip(p['to'], 60),
                'status': p['status'],
                'changes': p['changes'] is Map
                    ? (p['changes'] as Map).keys.map((k) => '$k').toList()
                    : null,
              });
            }(),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'tasks.search',
    title: '按关键词或 #编号搜任务（标题、描述、负责人、频道里的字都能搜），可限定状态',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /tasks/server',
    keywords: const [
      '搜任务',
      '找任务',
      '查任务',
      '任务搜索',
      '有没有关于',
      '哪个任务是',
      '包含的任务',
      '关于某某的任务',
    ],
    paramsSchema: objectSchema({
      'query': strArg('关键词，空格分隔，全部命中才算；#94 或 94 按编号；省略就是不限关键词'),
      'status': strArg('限定状态', values: taskStatuses),
    }),
    resultSummary: 'count, tasks[{id,number,title,status,owner,creator,channel,channelId,updated}] 新到旧',
    run: (w, args, env) async {
      final rows = await env
          .dataFor(w)
          .searchTasks(
            '${args['query'] ?? ''}',
            status: args['status'] as String?,
          );
      env.facts?.learnTaskRows(rows);
      return {
        'count': rows.length,
        'tasks': [for (final t in rows.take(12)) taskRowOf(t)],
      };
    },
  ),
];
