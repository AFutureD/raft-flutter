import 'agent_capability.dart';

/// The high-frequency operations the model calls in one step, each as its own
/// tool with a name that says what it does. Calling one is `act` on its
/// capability: the app draws the confirm card, the person agrees, `confirm`
/// runs it. Everything else stays behind `find` and `act`.
///
/// No claim tool: the app has no claim action to ride on (the Flutter client
/// has no `PATCH /tasks/:id/claim`; see docs/capability-parity.json).
const agentDirectActionTools = <String, String>{
  'send_message': 'messages.send',
  'reply_in_thread': 'messages.reply_thread',
  'react': 'messages.react',
  'mark_read': 'activity.mark_read',
  'mark_done': 'activity.mark_done',
  'create_task': 'tasks.create',
  'set_task_status': 'tasks.set_status',
  'assign_task': 'tasks.assign',
  'unassign_task': 'tasks.unassign',
  'join_channel': 'channels.join',
  'reject_task': 'tasks.reject_with_reason',
  'snooze_item': 'attention.snooze',
};

/// What the model reads for each; short, and no two overlap.
const _descriptions = <String, String>{
  'send_message': '往一个频道或私信发一条新消息，可 @人或 Agent。回复某条消息用 reply_in_thread。',
  'reply_in_thread': '在某条消息的讨论串里回复（要给消息 id，或屏幕上的编号）。',
  'react': '给一条消息加表情反应。',
  'mark_read': '把一个频道或私信标为已读，或全部已读。',
  'mark_done': '把动态（Activity）里的一个会话标为已处理（Done），从动态里移走。',
  'create_task': '在一个频道里新建一个任务，可同时指派负责人。',
  'set_task_status': '改一个任务的状态（待办、进行中、待验收、已完成、已关闭）。',
  'assign_task': '把一个任务指派给某个成员或 Agent。',
  'unassign_task': '清掉一个任务的负责人。',
  'join_channel': '加入一个公开频道。',
  'reject_task': '把任务打回去（改回进行中或待办）并在讨论串里留言说明原因，一步完成。',
  'snooze_item': '把“现在需要你”里的一件事稍后再看（今晚、明天早上、几小时后），到点再提醒。',
};

const _suffix = '只生成预览和 confirmToken，屏幕上出现确认卡；用一句话说出预览，等用户确认后才 confirm。';

Map<String, Object?> _slim(Map<String, Object?> schema) => {
  'type': 'object',
  'properties': {
    for (final e in (schema['properties'] as Map).entries)
      '${e.key}': {
        for (final k in const ['type', 'description', 'enum'])
          if ((e.value as Map).containsKey(k)) k: (e.value as Map)[k],
      },
  },
  if (schema['required'] is List) 'required': schema['required'],
};

/// The declarations of the one-step tools whose capability the registry
/// holds, with the parameters of the capability.
List<Map<String, Object?>> directActionDeclarations(
  AgentCapabilityRegistry registry,
) => [
  for (final e in agentDirectActionTools.entries)
    if (registry[e.value] != null)
      {
        'name': e.key,
        'description': '${_descriptions[e.key]}$_suffix',
        'parameters': _slim(registry[e.value]!.paramsSchema),
      },
];
