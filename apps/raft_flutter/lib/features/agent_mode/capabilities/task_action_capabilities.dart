import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import 'action_support.dart';
import 'agent_capability.dart';
import 'capability_support.dart';
import 'task_capabilities.dart' show taskStatuses;

/// Task operations: create, change the status, assign, unassign. They send
/// what the task pages send (`POST /tasks/channel/:id`, `PATCH /tasks/:id/
/// status`, `PATCH /tasks/:id/assignee`) through the controller's command.
///
/// There is no claim operation: the Flutter client has no `PATCH /tasks/:id/
/// claim` (docs/capability-parity.json: missing), so "I'll take it" is an
/// assign to oneself.

Future<Map<String, dynamic>> _patch(
  WorkspaceController w,
  Map<String, dynamic> task,
  String field,
  Map<String, dynamic> data,
) async {
  final body = await w.command(
    'PATCH',
    '/tasks/${task['id']}/$field',
    data: data,
  );
  return body is Map && body['task'] is Map
      ? Map<String, dynamic>.from(body['task'] as Map)
      : <String, dynamic>{};
}

Map<String, dynamic> _assigneeBody(
  Map<String, dynamic> task,
  Map<String, dynamic>? who,
) => {
  ...assigneePatch(who),
  if (task['revision'] is num) 'expectedRevision': task['revision'],
};

String? _currentAssignee(Map<String, dynamic> t) {
  final name = '${t['claimedByName'] ?? ''}';
  return name.isNotEmpty
      ? name
      : (t['claimedById'] == null ? null : '${t['claimedById']}');
}

void _mayAssign(WorkspaceController w) {
  if (!w.can('assignTasks')) {
    throw const AgentCapabilityError('你没有指派任务的权限');
  }
}

final taskActionCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'tasks.create',
    title: '在一个频道里新建任务（标题，可选描述和负责人）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /tasks/channel/:id',
    keywords: const [
      '建任务',
      '新建任务',
      '开个任务',
      '加个任务',
      '创建任务',
      '记个任务',
      '提个任务',
      'create task',
      '安排个活',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('任务放在哪个频道（名字或 id，要是已加入的频道）'),
        'title': strArg('任务标题', max: 200),
        'description': strArg('描述，可省略', max: 2000),
        'assignee': strArg('负责人（成员或 Agent 的名字），可省略'),
      },
      required: const ['channel', 'title'],
    ),
    resultSummary: 'done, entity=task, id, number',
    preview: (w, args, env) async {
      final c = _taskChannel(w, '${args['channel']}');
      final who = text(args['assignee']);
      if (who != null) {
        _mayAssign(w);
        await _personIn(w, c.id, who);
      }
      return AgentActionPreview(
        summary: '在 #${c.name} 新建任务“${quote('${args['title']}', 30)}”',
        changes: [
          change('频道', '', '#${c.name}'),
          change('标题', '', '${args['title']}'),
          if (text(args['description']) != null)
            change('描述', '', quote('${args['description']}', 40)),
          change('状态', '', statusWord('todo')),
          if (who != null) change('负责人', '', who),
        ],
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = _taskChannel(w, '${args['channel']}');
      final who = text(args['assignee']);
      final person = who == null ? null : await _personIn(w, c.id, who);
      final body = await w.command(
        'POST',
        '/tasks/channel/${c.id}',
        data: {
          'tasks': [
            {
              'title': '${args['title']}',
              if (text(args['description']) != null)
                'description': '${args['description']}',
            },
          ],
        },
      );
      final rows = body is Map
          ? [
              if (body['tasks'] is List) ...rowsOf(body['tasks'], const []),
              if (body['task'] is Map)
                Map<String, dynamic>.from(body['task'] as Map),
            ]
          : <Map<String, dynamic>>[];
      final task = rows.firstOrNull;
      if (task == null || task['id'] == null) {
        throw const AgentCapabilityError('任务可能建好了，但服务器没有返回它：请去任务页确认，不要重复创建');
      }
      if (person != null) {
        await _patch(w, task, 'assignee', _assigneeBody(task, person));
      }
      return actionResult(
        '已新建 #${task['taskNumber'] ?? ''} ${quote('${args['title']}', 20)}',
        entity: 'task',
        id: '${task['id']}',
        extra: {'number': task['taskNumber']},
      );
    },
  ),
  AgentCapability(
    id: 'tasks.set_status',
    title: '改一个任务的状态（待办、进行中、等验收、已完成、已关闭）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'PATCH /tasks/:id/status',
    keywords: const [
      '改状态',
      '标为完成',
      '标成完成',
      '开始做',
      '改成进行中',
      '关掉任务',
      '关闭任务',
      '重新打开',
      '任务做完了',
      '任务状态',
      '挪到等验收',
      'status',
    ],
    paramsSchema: objectSchema(
      {
        'task': strArg('任务 id，或编号（#98 / 98）', max: 80),
        'status': strArg('新状态', values: taskStatuses),
        'channel': strArg('频道名；编号在多个频道重复时才需要'),
      },
      required: const ['task', 'status'],
    ),
    resultSummary: 'done, entity=task, id',
    prepareUndo: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final before = '${task['status']}';
      if (!canMoveTaskTo(w, {...task, 'status': args['status']}, before)) {
        return null;
      }
      return AgentUndoPlan(
        label: '改回 ${statusWord(before)}',
        run: () async {
          await _patch(w, task, 'status', {'status': before});
          return '已改回 ${statusWord(before)}';
        },
      );
    },
    preview: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final next = '${args['status']}';
      if (task['status'] == next) {
        throw AgentCapabilityError('${taskWord(task)} 已经是 ${statusWord(next)}');
      }
      if (!canMoveTaskTo(w, task, next)) {
        throw AgentCapabilityError(
          '${taskWord(task)} 现在（${statusWord(task['status'])}）不能直接改成 ${statusWord(next)}',
        );
      }
      return AgentActionPreview(
        summary: '把 ${taskWord(task)} 改为 ${statusWord(next)}',
        changes: [change('状态', statusWord(task['status']), statusWord(next))],
        reversible: true,
        refs: [AgentPreviewRef('task', '${task['id']}')],
      );
    },
    run: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final next = '${args['status']}';
      if (!canMoveTaskTo(w, task, next)) {
        throw AgentCapabilityError(
          '${taskWord(task)} 现在（${statusWord(task['status'])}）不能直接改成 ${statusWord(next)}',
        );
      }
      await _patch(w, task, 'status', {'status': next});
      return actionResult(
        '已改为 ${statusWord(next)}',
        entity: 'task',
        id: '${task['id']}',
      );
    },
  ),
  AgentCapability(
    id: 'tasks.assign',
    title: '把一个任务指派给某个成员或 Agent（已有负责人会被换掉）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'PATCH /tasks/:id/assignee',
    keywords: const [
      '指派',
      '分配',
      '派给',
      '交给',
      '让他做',
      '负责人',
      '换负责人',
      '转给',
      '给他做',
      'assign',
    ],
    paramsSchema: objectSchema(
      {
        'task': strArg('任务 id，或编号（#98 / 98）', max: 80),
        'assignee': strArg('成员或 Agent 的名字（要是任务所在频道里的人）'),
        'channel': strArg('频道名；编号在多个频道重复时才需要'),
      },
      required: const ['task', 'assignee'],
    ),
    resultSummary: 'done, entity=task, id',
    prepareUndo: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final previous = await _previousAssignee(w, task);
      return AgentUndoPlan(
        label: previous == null ? '清掉负责人' : '改回 ${personWord(previous)}',
        run: () async {
          await _patch(w, task, 'assignee', {...assigneePatch(previous)});
          return previous == null ? '已清掉负责人' : '已改回 ${personWord(previous)}';
        },
      );
    },
    preview: (w, args, env) async {
      _mayAssign(w);
      final task = await taskFor(w, env, args);
      final who = await _personIn(
        w,
        '${task['channelId']}',
        '${args['assignee']}',
      );
      if ('${task['claimedById']}' == '${who['userId'] ?? who['id']}') {
        throw AgentCapabilityError(
          '${taskWord(task)} 已经是 ${personWord(who)} 在负责',
        );
      }
      return AgentActionPreview(
        summary: '把 ${taskWord(task)} 指派给 ${personWord(who)}',
        changes: [change('负责人', _currentAssignee(task), personWord(who))],
        reversible: true,
        refs: [AgentPreviewRef('task', '${task['id']}')],
      );
    },
    run: (w, args, env) async {
      _mayAssign(w);
      final task = await taskFor(w, env, args);
      final who = await _personIn(
        w,
        '${task['channelId']}',
        '${args['assignee']}',
      );
      await _patch(w, task, 'assignee', _assigneeBody(task, who));
      return actionResult(
        '已指派给 ${personWord(who)}',
        entity: 'task',
        id: '${task['id']}',
      );
    },
  ),
  AgentCapability(
    id: 'tasks.unassign',
    title: '清掉一个任务的负责人',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'PATCH /tasks/:id/assignee',
    keywords: const [
      '取消指派',
      '不用他做了',
      '清掉负责人',
      '去掉负责人',
      '撤掉负责人',
      'unassign',
      '没人负责',
      '释放任务',
    ],
    paramsSchema: objectSchema(
      {
        'task': strArg('任务 id，或编号（#98 / 98）', max: 80),
        'channel': strArg('频道名；编号在多个频道重复时才需要'),
      },
      required: const ['task'],
    ),
    resultSummary: 'done, entity=task, id',
    prepareUndo: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final previous = await _previousAssignee(w, task);
      if (previous == null) return null;
      return AgentUndoPlan(
        label: '改回 ${personWord(previous)}',
        run: () async {
          await _patch(w, task, 'assignee', {...assigneePatch(previous)});
          return '已改回 ${personWord(previous)}';
        },
      );
    },
    preview: (w, args, env) async {
      _mayAssign(w);
      final task = await taskFor(w, env, args);
      final current = _currentAssignee(task);
      if (current == null) {
        throw AgentCapabilityError('${taskWord(task)} 本来就没有负责人');
      }
      return AgentActionPreview(
        summary: '清掉 ${taskWord(task)} 的负责人 $current',
        changes: [change('负责人', current, '（无）')],
        reversible: true,
        refs: [AgentPreviewRef('task', '${task['id']}')],
      );
    },
    run: (w, args, env) async {
      _mayAssign(w);
      final task = await taskFor(w, env, args);
      await _patch(w, task, 'assignee', _assigneeBody(task, null));
      return actionResult('已清掉负责人', entity: 'task', id: '${task['id']}');
    },
  ),
];

/// The joined channel a task goes in.
RaftChannel _taskChannel(WorkspaceController w, String ref) {
  final c = sendableChannel(w, ref);
  if (c.type == 'dm') throw const AgentCapabilityError('任务要建在频道里，不能建在私信里');
  return c;
}

Future<Map<String, dynamic>> _personIn(
  WorkspaceController w,
  String channelId,
  String ref,
) async {
  final people = await assignableOf(w, {'channelId': channelId});
  return pickPerson(people, ref);
}

/// Who held the task a moment ago, in the shape of the assignee picker (null
/// for nobody); read from the channel's members so the id and type are the
/// picker's own.
Future<Map<String, dynamic>?> _previousAssignee(
  WorkspaceController w,
  Map<String, dynamic> task,
) async {
  final id = task['claimedById'];
  if (id == null || '$id'.isEmpty) return null;
  final type = task['claimedByType'] == 'agent' ? 'agent' : 'user';
  return {
    'actorType': type,
    'id': id,
    'displayName': task['claimedByName'] ?? '$id',
  };
}
