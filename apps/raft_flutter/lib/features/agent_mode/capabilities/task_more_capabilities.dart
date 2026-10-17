import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import 'action_support.dart';
import 'agent_capability.dart';
import 'capability_support.dart';

/// More task operations: send a task back with the reason (one action that
/// moves it and tells its thread why), make tasks from a message, make
/// several tasks at once.
///
/// The App has no way to edit a task's title or description (neither the
/// Flutter client nor Web has `PATCH /tasks/:id`; see
/// docs/capability-parity.json), so there is no such capability.

Future<Map<String, dynamic>> _patchStatus(
  WorkspaceController w,
  Map<String, dynamic> task,
  String status,
) async {
  final body = await w.command(
    'PATCH',
    '/tasks/${task['id']}/status',
    data: {'status': status},
  );
  return body is Map && body['task'] is Map
      ? Map<String, dynamic>.from(body['task'] as Map)
      : <String, dynamic>{};
}

/// The thread a task's discussion lives in hangs off the message the task
/// was made from; without one there is nowhere to say why.
RaftMessage _taskParent(Map<String, dynamic> task) {
  final id = task['messageId'];
  if (id is! String || id.isEmpty) {
    throw AgentCapabilityError('${taskWord(task)} 没有对应的讨论串（它不是从消息建的），不能在串里留言');
  }
  return RaftMessage({'id': id, 'channelId': task['channelId']});
}

RaftChannel _joinedChannelOf(WorkspaceController w, Map<String, dynamic> task) {
  final c = w.channelById('${task['channelId']}');
  if (c == null || !c.joined || c.archived) {
    throw AgentCapabilityError('${taskWord(task)} 所在的频道你没有加入或已归档，不能留言');
  }
  return sendableChannel(w, c.id);
}

/// What goes in the thread: it names the person who has the task, so they
/// (or the Agent) hear it, and says where the task went.
Future<({String text, List<Map<String, dynamic>> mentions})> _rejectText(
  WorkspaceController w,
  Map<String, dynamic> task,
  String status,
  String reason,
) async {
  final who = '${task['claimedByName'] ?? ''}'.trim();
  final lead = who.isEmpty ? '' : '@$who ';
  return mentionsIn(w, '$lead打回，任务改回“${statusWord(status)}”：$reason');
}

const _rejectTargets = ['in_progress', 'todo'];

final taskMoreCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'tasks.reject_with_reason',
    title: '把任务打回去：状态改回进行中（或待办），同时在它的讨论串里留言说明原因，通知负责人；一次预览、一次确认',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'PATCH /tasks/:id/status',
    keywords: const [
      '打回',
      '打回去',
      '打回重做',
      '驳回',
      '退回',
      '让他重做',
      '重做',
      '不通过',
      '验收不通过',
      '不合格',
      '改回进行中',
      '附上原因',
      '说明原因',
      'reject',
    ],
    paramsSchema: objectSchema(
      {
        'task': strArg('任务 id，或编号（#98 / 98）', max: 80),
        'reason': strArg('打回的原因，会作为留言发到任务的讨论串', max: 1000),
        'status': strArg(
          '打回到哪个状态：in_progress 进行中（默认）/ todo 待办',
          values: _rejectTargets,
        ),
        'channel': strArg('频道名；编号在多个频道重复时才需要'),
      },
      required: const ['task', 'reason'],
    ),
    resultSummary: 'done, entity=task, id',
    prepareUndo: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final before = '${task['status']}';
      final parent = _taskParent(task);
      return AgentUndoPlan(
        label: '改回 ${statusWord(before)} 并在串里说明',
        run: () async {
          await _patchStatus(w, task, before);
          // A sent message cannot be taken back: say that the send-back was.
          final text = '（撤销了刚才的打回：任务已改回“${statusWord(before)}”）';
          final ok = await w.sendThreadReply(
            parent,
            text,
            randomId: w.client.newRandomId(),
          );
          return ok
              ? '已改回 ${statusWord(before)}，并在讨论串里说明了'
              : '已改回 ${statusWord(before)}，但串里的说明没有发出去（原来的留言删不掉）';
        },
      );
    },
    preview: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final next = '${args['status'] ?? 'in_progress'}';
      _joinedChannelOf(w, task);
      _taskParent(task);
      if (task['status'] == next) {
        throw AgentCapabilityError('${taskWord(task)} 已经是 ${statusWord(next)}');
      }
      if (!canMoveTaskTo(w, task, next)) {
        throw AgentCapabilityError(
          '${taskWord(task)} 现在（${statusWord(task['status'])}）不能直接改成 ${statusWord(next)}',
        );
      }
      final said = await _rejectText(w, task, next, '${args['reason']}');
      return AgentActionPreview(
        summary:
            '把 ${taskWord(task)} 打回（改为 ${statusWord(next)}），并在讨论串里留言：“${quote(said.text, 40)}”',
        changes: [
          change('状态', statusWord(task['status']), statusWord(next)),
          change('讨论串留言', '', said.text),
          if (said.mentions.isNotEmpty)
            change(
              '通知',
              '',
              [for (final m in said.mentions) '@${m['name']}'].join(' '),
            ),
        ],
        reversible: true,
        refs: [AgentPreviewRef('task', '${task['id']}')],
      );
    },
    run: (w, args, env) async {
      final task = await taskFor(w, env, args);
      final next = '${args['status'] ?? 'in_progress'}';
      final before = '${task['status']}';
      _joinedChannelOf(w, task);
      final parent = _taskParent(task);
      if (!canMoveTaskTo(w, task, next)) {
        throw AgentCapabilityError(
          '${taskWord(task)} 现在（${statusWord(before)}）不能直接改成 ${statusWord(next)}',
        );
      }
      final said = await _rejectText(w, task, next, '${args['reason']}');
      await _patchStatus(w, task, next);
      final bool sent;
      try {
        sent = await w.sendThreadReply(
          parent,
          said.text,
          mentions: said.mentions,
          randomId: w.client.newRandomId(),
        );
      } on Object {
        await _restore(w, task, before);
        rethrow;
      }
      if (!sent) {
        final restored = await _restore(w, task, before);
        throw AgentCapabilityError(
          '${w.error ?? '留言没有发出去'}：'
          '${restored ? '任务状态已恢复为 ${statusWord(before)}，什么都没改' : '任务状态没能恢复，现在是 ${statusWord(next)}，请去任务页确认'}',
        );
      }
      return actionResult(
        '已打回 #${task['taskNumber']}，原因已留言',
        entity: 'task',
        id: '${task['id']}',
      );
    },
  ),
];

/// Puts the status back after a half-finished send-back. True when it worked.
Future<bool> _restore(
  WorkspaceController w,
  Map<String, dynamic> task,
  String status,
) async {
  try {
    await _patchStatus(w, task, status);
    return true;
  } on Object {
    return false;
  }
}

// ---- tasks made from messages, and several at once -----------------------

List<Map<String, dynamic>> _created(Object? body) => body is Map
    ? [
        if (body['tasks'] is List) ...rowsOf(body['tasks'], const []),
        if (body['task'] is Map) Map<String, dynamic>.from(body['task'] as Map),
      ]
    : <Map<String, dynamic>>[];

final taskFromMessageCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'tasks.create_from_message',
    title: '把一条消息变成任务：任务连着这条消息，讨论串就是这条消息的串',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /tasks/convert-message',
    keywords: const [
      '转成任务',
      '变成任务',
      '把这条消息变成任务',
      '这条建个任务',
      '这个做成任务',
      '消息转任务',
      '记成任务',
      'convert to task',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg('消息 id（取自读取工具，或先 resolve 屏幕上的“这条”）', max: 80),
        'channel': strArg('消息所在频道，已知时带上'),
      },
      required: const ['message'],
    ),
    resultSummary: 'done, entity=task, id, number（服务器返回时）',
    preview: (w, args, env) async {
      final m = await _taskable(w, args);
      return AgentActionPreview(
        summary: '把 ${m.author} 的消息“${quote(m.content, 28)}”变成任务',
        changes: [
          change('消息', '', '${m.author}：${quote(m.content, 30)}'),
          change('任务', '', '新建，状态 ${statusWord('todo')}，连着这条消息'),
        ],
        refs: [AgentPreviewRef('message', m.id)],
      );
    },
    run: (w, args, env) async {
      final m = await _taskable(w, args);
      final body = await w.command(
        'POST',
        '/tasks/convert-message',
        data: {'messageId': m.id},
      );
      final task =
          _created(body).firstOrNull ??
          (body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{});
      final id = task['id'];
      return actionResult(
        task['taskNumber'] == null ? '已变成任务' : '已变成任务 #${task['taskNumber']}',
        entity: id == null ? 'message' : 'task',
        id: id == null ? m.id : '$id',
        extra: {'number': task['taskNumber']},
      );
    },
  ),
  AgentCapability(
    id: 'tasks.create_batch',
    title: '在一个频道里一次建多个任务（每个一个标题，可统一指派给一个人）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /tasks/channel/:id',
    keywords: const [
      '一次建几个任务',
      '批量建任务',
      '建这三个任务',
      '一起建任务',
      '建几个任务',
      '多个任务',
      '这几个都建成任务',
      'batch tasks',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('任务放在哪个频道（名字或 id，要是已加入的频道）'),
        'titles': {
          'type': 'array',
          'description': '每个任务的标题，1 到 20 个',
          'items': {'type': 'string', 'maxLength': 200},
        },
        'assignee': strArg('统一指派给谁（成员或 Agent 的名字），可省略'),
      },
      required: const ['channel', 'titles'],
    ),
    resultSummary: 'done, entity=channel, id, count',
    preview: (w, args, env) async {
      final c = _batchChannel(w, args);
      final titles = _titles(args);
      final who = text(args['assignee']);
      if (who != null) {
        _mayAssignAll(w);
        await _pickIn(w, c.id, who);
      }
      return AgentActionPreview(
        summary: '在 #${c.name} 新建 ${titles.length} 个任务',
        changes: [
          change('频道', '', '#${c.name}'),
          for (final (i, t) in titles.indexed)
            change('任务 ${i + 1}', '', quote(t, 40)),
          change('状态', '', statusWord('todo')),
          if (who != null) change('负责人', '', who),
        ],
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = _batchChannel(w, args);
      final titles = _titles(args);
      final who = text(args['assignee']);
      final person = who == null ? null : await _pickIn(w, c.id, who);
      final body = await w.command(
        'POST',
        '/tasks/channel/${c.id}',
        data: {
          'tasks': [
            for (final t in titles) {'title': t},
          ],
        },
      );
      final made = _created(body);
      if (made.isEmpty) {
        throw const AgentCapabilityError('任务可能建好了，但服务器没有返回：请去任务页确认，不要重复创建');
      }
      var assigned = 0;
      if (person != null) {
        for (final task in made) {
          try {
            await w.command(
              'PATCH',
              '/tasks/${task['id']}/assignee',
              data: {
                ...assigneePatch(person),
                if (task['revision'] is num)
                  'expectedRevision': task['revision'],
              },
            );
            assigned++;
          } on Object {
            // Reported below; the tasks themselves exist.
          }
        }
      }
      final missed = person != null && assigned < made.length;
      return actionResult(
        '已在 #${c.name} 建了 ${made.length} 个任务${missed ? '，其中 ${made.length - assigned} 个没能指派给 $who' : ''}',
        entity: 'channel',
        id: c.id,
        extra: {'count': made.length},
      );
    },
  ),
];

Future<RaftMessage> _taskable(
  WorkspaceController w,
  Map<String, Object?> args,
) async {
  if (w.server?.string('role') == 'guest') {
    throw const AgentCapabilityError('访客不能建任务');
  }
  final m = await messageById(
    w,
    '${args['message']}',
    channelRef: text(args['channel']),
  );
  final c = w.channelById(m.channelId);
  if (c == null || !c.joined || c.archived) {
    throw const AgentCapabilityError('这条消息所在的频道你没有加入或已归档，不能变成任务');
  }
  if (c.type == 'dm') throw const AgentCapabilityError('私信里的消息不能变成任务');
  if (m.string('messageType') == 'system' || m.content.trim().isEmpty) {
    throw const AgentCapabilityError('这条消息不能变成任务（系统消息或没有文字）');
  }
  return m;
}

RaftChannel _batchChannel(WorkspaceController w, Map<String, Object?> args) {
  final c = sendableChannel(w, '${args['channel']}');
  if (c.type == 'dm') throw const AgentCapabilityError('任务要建在频道里，不能建在私信里');
  return c;
}

List<String> _titles(Map<String, Object?> args) {
  final titles = [
    for (final t in (args['titles'] as List? ?? const []))
      if ('$t'.trim().isNotEmpty) '$t'.trim(),
  ];
  if (titles.isEmpty) throw const AgentCapabilityError('需要 titles：至少一个任务标题');
  if (titles.length > 20) throw const AgentCapabilityError('一次最多建 20 个任务');
  return titles;
}

void _mayAssignAll(WorkspaceController w) {
  if (!w.can('assignTasks')) {
    throw const AgentCapabilityError('你没有指派任务的权限');
  }
}

Future<Map<String, dynamic>> _pickIn(
  WorkspaceController w,
  String channelId,
  String ref,
) async => pickPerson(await assignableOf(w, {'channelId': channelId}), ref);
