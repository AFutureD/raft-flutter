import '../../agent_mode/capabilities/agent_capability.dart';
import '../../agent_mode/capabilities/agent_capability_tools.dart'
    show capabilityToolDeclarations;
import '../../agent_mode/capabilities/agent_direct_tools.dart'
    show agentDirectActionTools;

/// The tools the orb's model gets for the app's whole capability layer: the
/// same ones Agent mode's model gets (`find`, `query`, `act`, `confirm`,
/// `undo` and one tool for each common operation, under the same names and
/// with the same arguments), plus `nudge_task` and `cancel_action`. Only the
/// words differ: here the card on the screen is the one thing waiting, so
/// `confirm` needs no token.

/// The operations with a tool of their own, by tool name: Agent mode's, and
/// the nudge (a reply in a task's thread that asks where it is).
const orbActionCapabilities = <String, String>{
  ...agentDirectActionTools,
  'nudge_task': 'tasks.nudge',
};

/// What is fine while the car moves: a reply, a reaction, a reminder, handing a
/// task over, a nudge. Every other operation waits for parking.
const orbDrivingCapabilities = {
  'messages.send',
  'messages.reply_thread',
  'messages.react',
  'attention.snooze',
  'tasks.assign',
  'tasks.nudge',
};

const _what = <String, String>{
  'send_message': '在一个频道或私信里发一条消息（“回复他”“跟他说”）；要 @谁就在 text 里写 @名字。回复某一条消息的讨论串用 reply_in_thread。',
  'reply_in_thread': '在某条消息的讨论串里回复。message 是那条消息的 id，取自 read_conversation 或 describe_page 返回的消息（只传给工具，不要念出来）。',
  'react': '给一条消息加表情反应；“点赞”就是 👍。message 取自 read_conversation 或 describe_page。',
  'mark_read': '把一个频道或私信标为已读，或把动态全部标为已读。',
  'mark_done': '把动态里的一个会话或讨论串标为已处理，从动态里移走；讨论串要同时给 thread。',
  'create_task': '在一个频道里新建一个任务，可同时指派负责人。',
  'set_task_status':
      '改一个任务的状态（待办、进行中、等验收、已完成、已关闭）。task 填任务编号。用户说“通过”“标完成”就是 done。驾驶中不做，要等停车。',
  'assign_task': '把一个任务交给某个成员或 Agent（会换掉现在的负责人）。task 填任务编号。',
  'unassign_task': '清掉一个任务的负责人。task 填任务编号。',
  'join_channel': '加入一个公开频道。',
  'reject_task': '把任务打回去（改回进行中或待办），并在讨论串里留言说明原因，一步完成。',
  'snooze_item': '稍后再提醒用户看一件事（今晚、明天早上、几小时后）：先从动态里拿掉，到点再提醒。驾驶中用户说“稍后提醒我”就是屏幕上这一件，item 省略即可。',
  'nudge_task': '催一下任务的负责人：在任务的讨论串里 @他问进展。task 填任务编号；text 可省略（默认问“现在到哪了”）。',
};

const _how =
    '不会马上执行：屏幕上先出现确认卡（谁、在哪、原话）。你用一句话复述将要做的事，再问“要发吗？”（改任务就问“要改吗？”）；'
    '用户点“确认”，或亲口说“确认/发吧/好”之后，才调用 confirm；他没表态就什么都不要做。敏感的操作（停 Agent、批准应用……）只认确认卡上的按钮，要点两次。';

Map<String, Object?> _slim(Map<String, Object?> schema, {Set<String>? drop}) =>
    {
      'type': 'object',
      'properties': {
        for (final e in (schema['properties'] as Map).entries)
          '${e.key}': {
            for (final k in const ['type', 'description', 'enum'])
              if ((e.value as Map).containsKey(k)) k: (e.value as Map)[k],
          },
      },
      if (schema['required'] is List)
        'required': [
          for (final r in schema['required'] as List)
            if (!(drop ?? const {}).contains(r)) r,
        ],
    };

/// Agent mode's own declaration of a generic tool, with the orb's words.
Map<String, Object?> _generic(String name, {String? description}) {
  final d = capabilityToolDeclarations.firstWhere((d) => d['name'] == name);
  return {...d, 'description': ?description};
}

/// The declarations of the orb's capability tools.
List<Map<String, Object?>> orbActionDeclarations(
  AgentCapabilityRegistry registry,
) => [
  for (final e in orbActionCapabilities.entries)
    if (registry[e.value] != null)
      {
        'name': e.key,
        'description': '${_what[e.key]}$_how',
        'parameters': _slim(
          registry[e.value]!.paramsSchema,
          // The card in front of the person is the default item.
          drop: e.key == 'snooze_item' ? const {'item'} : null,
        ),
      },
  _generic('find'),
  _generic(
    'query',
    description:
        '执行一项“查询”能力（只读，立即返回）。capability 填 find 返回的 id；args 是参数的 JSON 文本，按 find 返回的参数说明写。'
        '频道、成员、Agent、电脑、消息、任务、动态、审批、日志……App 里能读的都在这里，先 find 再 query。'
        '返回里的 id 只用来传给别的工具，不要念出来；说名字、标题和编号。读到的才是事实。',
  ),
  _generic(
    'act',
    description:
        '申请一项“操作”能力（上面有专用工具的操作优先用专用工具，这里是其余操作的入口，先 find）。'
        '$_how永远不能语音执行的操作（删除、改角色、计费、设置……）没有确认卡：App 直接带用户去对应页面，你只说一句“已带你去那个页面，自己操作”。',
  ),
  {
    ..._generic(
      'confirm',
      description:
          '执行屏幕上等着确认的那一项。只在用户点了确认，或亲口说了“确认/发吧/好”之后调用；一次只有一项，不需要 token。'
          '你自己的话不算确认：用户没有表态时调用只会返回 needs_user_confirmation，什么都不会发生，这时不要重复调用，问他一句。'
          '返回 done 就用一句话告诉他做完了；failed 就如实说原因；needs_second_confirmation 是敏感操作，请他再点一次确认卡。',
    ),
    'parameters': {
      'type': 'object',
      'properties': {
        'token': {'type': 'string', 'description': '可以省略：一次只有一项等着确认'},
      },
    },
  },
  _generic(
    'undo',
    description:
        '撤销刚刚执行完的操作（改状态、表情、指派、停 Agent 等能撤销的）。只在用户亲口说了“撤销/改回去/刚才那个不要了”之后调用；'
        '你自己不能决定撤销：用户没有说过，会返回 needs_user_consent，什么都不做。执行后 30 秒内有效。',
  ),
  const {
    'name': 'cancel_action',
    'description': '用户说取消、算了、不发了之后调用：丢掉屏幕上等着确认的那一项，什么都不做。没有参数。',
  },
];
