import 'dart:convert';

import '../../../data/workspace_controller.dart';
import '../../agent_mode/agent_mode_data.dart';
import '../../agent_mode/capabilities/action_support.dart'
    show statusWord, taskStatusWords;
import '../../agent_mode/capabilities/agent_capability.dart';
import '../../agent_mode/capabilities/agent_capability_standard.dart';
import '../../agent_mode/capabilities/capability_support.dart';
import '../../agent_mode/capabilities/task_capabilities.dart' show taskStatuses;
import '../orb_tool.dart';

/// The orb's task reads: the same task rows the Agent mode board reads
/// (`AgentModeData`), worded for a person who listens. A row has the title and
/// number, the status, who has it, where it is, how long nothing changed and
/// what it waits for; no id is in it, so the model cannot read one out.

/// Nobody touched it for this long: it may be done with only its status left.
const orbStaleAfter = AgentModeData.staleAfter;

/// The most JSON a list carries; the rest is counted, not listed (the tool
/// output limit is 16 KB).
const _listBudget = 11000;

const _open = ['in_progress', 'in_review', 'todo'];

const _statusOrder = ['in_progress', 'in_review', 'todo', 'done', 'closed'];

final _listDeclaration = <String, Object?>{
  'name': 'list_tasks',
  'description':
      '读任务列表（只读，立即返回）。默认是没做完的（进行中、等验收、待办），最近动过的在前。'
      '用户问“任务现在什么状态”“谁在做什么”“有哪些任务放了好几天”“什么在等我验收”时用。'
      '每个任务有 number（编号）、title、statusText、assignee（谁在做）、channel、idle（多久没动）、waitsFor（在等什么）。'
      '返回里没有 id：说任务时只说标题或“任务 138”，要做动作（改状态、交给别人、催）就把 number 传给动作工具。'
      'summary 是各状态的条数，用户问“什么状态”时直接据它说。',
  'parameters': {
    'type': 'object',
    'properties': {
      'status': {
        'type': 'string',
        'enum': [...taskStatuses, 'open'],
        'description': '只看这个状态；open（默认）是进行中、等验收和待办',
      },
      'assignee': {
        'type': 'string',
        'description': '谁在做：名字；me 是用户自己，unassigned 是没人认领',
      },
      'waiting_on_me': {
        'type': 'boolean',
        'description': 'true 只要在等用户验收或决定的任务',
      },
      'stale': {'type': 'boolean', 'description': 'true 只要 3 天以上没动的任务，放得最久的在前'},
      'channel': {'type': 'string', 'description': '只看这个频道的任务（频道名）'},
      'limit': {'type': 'integer', 'description': '最多几个，默认 12，最多 30'},
    },
  },
};

final _detailDeclaration = <String, Object?>{
  'name': 'task_detail',
  'description':
      '按任务编号读一个任务（只读，立即返回）：标题、描述、状态、谁在做、谁建的、频道、多久没动、在等什么，以及讨论串最后几条。'
      '用户问“任务 138 怎么样了”“这个任务卡在哪”时用。不同频道的编号会重复，返回里说有几个频道时，问用户是哪个频道再带 channel 重读。返回里没有 id。',
  'parameters': {
    'type': 'object',
    'properties': {
      'number': {'type': 'integer', 'description': '任务编号，不带 #'},
      'channel': {'type': 'string', 'description': '频道名，编号重复时才需要'},
    },
    'required': ['number'],
  },
};

/// `list_tasks` and `task_detail`.
List<OrbTool> orbTaskTools({AgentCapabilityRegistry? registry}) => [
  OrbTool(
    declaration: _listDeclaration,
    handler: (args, ctx) => orbListTasks(ctx.workspace, args),
  ),
  OrbTool(
    declaration: _detailDeclaration,
    handler: (args, ctx) =>
        orbTaskDetail(ctx.workspace, args, registry: registry),
  ),
];

/// "5 分钟", "3 小时", "4 天".
String orbIdleText(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)} 分钟';
  if (d.inHours < 48) return '${d.inHours} 小时';
  return '${d.inDays} 天';
}

/// What a task is waiting for, in a few words (null for a finished one).
String? orbWaitsFor({
  required String status,
  String? assignee,
  String? creator,
  required bool creatorIsMe,
  required bool assigneeIsMe,
}) {
  switch (status) {
    case 'in_review':
      if (creatorIsMe) return '等你验收';
      return creator == null ? '等人验收' : '等 $creator 验收';
    case 'in_progress':
      if (assignee == null) return '没人认领';
      return assigneeIsMe ? '你在做' : '$assignee 在做';
    case 'todo':
      if (assignee == null) return '没人认领';
      return assigneeIsMe ? '等你开始' : '等 $assignee 开始';
  }
  return null;
}

bool _meNamed(({String? id, Set<String> names}) me, String? name) =>
    name != null && me.names.contains(name);

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

bool _byAssignee(
  Map<String, dynamic> t,
  String want,
  ({String? id, Set<String> names}) me,
) {
  final w = want.trim().toLowerCase();
  final id = '${t['claimedById'] ?? ''}';
  final name = '${t['claimedByName'] ?? ''}'.toLowerCase();
  if (const {'me', '我', '自己'}.contains(w)) {
    return me.id != null && id == me.id && t['claimedByType'] != 'agent';
  }
  if (const {'unassigned', '无人认领', '没人'}.contains(w)) return id.isEmpty;
  return name.isNotEmpty && name.contains(w.replaceAll('@', ''));
}

/// The list the model reads. [now] is the clock (tests set it).
Future<Map<String, Object?>> orbListTasks(
  WorkspaceController w,
  Map<String, Object?> args, {
  DateTime Function()? now,
}) async {
  final clock = now ?? DateTime.now;
  final status = _s(args['status']) ?? 'open';
  if (status != 'open' && !taskStatuses.contains(status)) {
    return {
      'error': 'status 只能是 ${[...taskStatuses, 'open'].join('、')} 之一',
    };
  }
  final statuses = status == 'open' ? _open : [status];
  final data = AgentModeData(w, now: clock);
  String? channelId;
  final channel = _s(args['channel']);
  if (channel != null) {
    try {
      channelId = channelByRef(w, channel).id;
    } on AgentCapabilityError catch (e) {
      return e.toJson();
    }
  }
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
    return {'error': '任务现在读不到，请稍后再试'};
  }
  final me = data.me;
  final at = clock();
  final assignee = _s(args['assignee']);
  final waitingOnly = args['waiting_on_me'] == true;
  final staleOnly = args['stale'] == true;

  final rows =
      <({Map<String, dynamic> raw, Map<String, Object?> row, int age})>[
        for (final lane in lanes)
          if (lane != null)
            for (final t in lane.rows)
              if (assignee == null || _byAssignee(t, assignee, me))
                () {
                  final r = _row(t, me, at);
                  return (raw: t, row: r.row, age: r.minutes);
                }(),
      ];
  bool waiting(Map<String, Object?> r) => r['waitingOnMe'] == true;
  bool stale(Map<String, Object?> r) => r['stale'] == true;
  final kept = [
    for (final r in rows)
      if ((!waitingOnly || waiting(r.row)) && (!staleOnly || stale(r.row))) r,
  ];
  // The longest still first when the question is about waiting; else the
  // newest change first, the higher number first among equals.
  kept.sort((a, b) {
    if (waitingOnly || staleOnly) {
      final c = b.age.compareTo(a.age);
      if (c != 0) return c;
    } else {
      final c = a.age.compareTo(b.age);
      if (c != 0) return c;
    }
    return ((b.row['number'] as int?) ?? 0).compareTo(
      (a.row['number'] as int?) ?? 0,
    );
  });

  final counts = <String, int>{
    for (final s in _statusOrder)
      if (kept.any((r) => r.row['status'] == s))
        s: kept.where((r) => r.row['status'] == s).length,
  };
  final limit = (((args['limit'] as num?)?.toInt()) ?? 12).clamp(1, 30);
  final shown = <Map<String, Object?>>[];
  var used = 0;
  for (final r in kept.take(limit)) {
    final size = utf8.encode(jsonEncode(r.row)).length;
    if (shown.isNotEmpty && used + size > _listBudget) break;
    used += size;
    shown.add(r.row);
  }
  final waitingCount = kept.where((r) => waiting(r.row)).length;
  final staleCount = kept.where((r) => stale(r.row)).length;
  return {
    'total': kept.length,
    'summary': kept.isEmpty
        ? '没有符合的任务'
        : '共 ${kept.length} 个：${[for (final e in counts.entries) '${statusWord(e.key)} ${e.value}'].join('、')}',
    'counts': counts,
    'waitingOnMe': ?(waitingCount > 0 ? waitingCount : null),
    'stale': ?(staleCount > 0 ? staleCount : null),
    'order': waitingOnly || staleOnly ? '放得最久的在前' : '最近动过的在前',
    if (shown.length < kept.length) 'more': kept.length - shown.length,
    if (lanes.any((l) => l == null || l.truncated)) 'truncated': true,
    'tasks': shown,
  };
}

({Map<String, Object?> row, int minutes}) _row(
  Map<String, dynamic> t,
  ({String? id, Set<String> names}) me,
  DateTime now,
) {
  final status = '${t['status'] ?? ''}';
  final updated = AgentModeData.timeOf(t['updatedAt']) ?? now;
  final idle = now.difference(updated);
  final relation = AgentModeData.relationOf(t, me);
  final assignee = _s(t['claimedByName']);
  final creator = _s(t['createdByName']);
  final open = _open.contains(status);
  final waitsMe =
      status == 'in_review' &&
      (relation.created || relation.mentioned) &&
      !relation.assigned;
  final waits = orbWaitsFor(
    status: status,
    assignee: assignee,
    creator: creator,
    creatorIsMe: relation.created,
    assigneeIsMe: relation.assigned,
  );
  final isStale = open && idle >= orbStaleAfter;
  return (
    minutes: idle.inMinutes,
    row: {
      'number': t['taskNumber'],
      ...compact({
        'title': clip(t['title'], 60),
        'status': status,
        'statusText': taskStatusWords[status],
        'assignee': assignee,
        'creator': creator,
        'channel': _s(t['channelName']),
        'idle': orbIdleText(idle),
        'idleHours': idle.inHours,
        'waitsFor': waits,
      }),
      if (waitsMe) 'waitingOnMe': true,
      if (isStale) 'stale': true,
    },
  );
}

/// One task by number, from the capability layer's `tasks.detail`, without
/// the ids and with what it waits for.
Future<Map<String, Object?>> orbTaskDetail(
  WorkspaceController w,
  Map<String, Object?> args, {
  DateTime Function()? now,
  AgentCapabilityRegistry? registry,
}) async {
  final number = args['number'] is num ? (args['number'] as num).toInt() : null;
  if (number == null) return {'error': '需要任务编号 number'};
  final capability = (registry ?? agentStandardCapabilities)['tasks.detail']!;
  final env = AgentCapabilityEnv(data: AgentModeData(w, now: now));
  final Map<String, Object?> result;
  try {
    result = await capability.run(w, {
      'number': number,
      'channel': ?_s(args['channel']),
    }, env);
  } on AgentCapabilityError catch (e) {
    return _withoutIds(e.toJson());
  } on Object {
    return {'error': '任务现在读不到，请稍后再试'};
  }
  final raw = Map<String, Object?>.from(result['task'] as Map);
  final me = AgentModeData(w, now: now).me;
  final status = '${raw['status'] ?? ''}';
  final assignee = _s(raw['claimer']);
  final creator = _s(raw['creator']);
  final waits = orbWaitsFor(
    status: status,
    assignee: assignee,
    creator: creator,
    creatorIsMe: _meNamed(me, creator),
    assigneeIsMe: _meNamed(me, assignee),
  );
  return {
    'task': compact({
      'number': raw['number'],
      'title': raw['title'],
      'status': status,
      'statusText': taskStatusWords[status],
      'description': raw['description'],
      'assignee': assignee,
      'creator': creator,
      'channel': raw['channel'],
      'idle': raw['updated'],
      'waitsFor': waits,
      'thread': raw['thread'],
    }),
  };
}

/// The error of a task lookup keeps the channels to choose from, by name.
Map<String, Object?> _withoutIds(Map<String, Object?> error) {
  final channels = error['channels'];
  return {'error': error['error'], 'channels': ?channels};
}
