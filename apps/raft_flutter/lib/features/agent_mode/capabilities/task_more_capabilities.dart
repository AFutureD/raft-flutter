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

RaftChannel _joinedChannelOf(
  WorkspaceController w,
  Map<String, dynamic> task,
) {
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
          final text =
              '（撤销了刚才的打回：任务已改回“${statusWord(before)}”）';
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
