import '../../agent_mode/capabilities/agent_capability.dart';
import '../orb_tool_docs.dart' show orbToolDescription;
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

/// Words for parameters whose wording in the capability layer is not the
/// orb's: no tool that the orb may not have, one name for each status.
const _paramWords = <String, Map<String, String>>{
  'reply_in_thread': {
    'message': '那条消息的 id，取自 read_conversation 或 describe_page；不要念出来',
  },
  'react': {'message': '消息 id，取自 read_conversation 或 describe_page'},
  'set_task_status': {
    'task': '任务编号，不带 #（如 138）；用户没说编号就问，不要猜',
    'status':
        'todo 待办 / in_progress 进行中 / in_review 等验收 / done 已完成 / closed 已关闭',
  },
};

Map<String, Object?> _slim(
  Map<String, Object?> schema, {
  Set<String>? drop,
  Map<String, String> words = const {},
}) => {
  'type': 'object',
  'properties': {
    for (final e in (schema['properties'] as Map).entries)
      '${e.key}': {
        for (final k in const ['type', 'description', 'enum'])
          if ((e.value as Map).containsKey(k)) k: (e.value as Map)[k],
        if (words.containsKey(e.key)) 'description': words[e.key],
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
        'description': orbToolDescription(e.key),
        'parameters': _slim(
          registry[e.value]!.paramsSchema,
          words: _paramWords[e.key] ?? const {},
          // The card in front of the person is the default item.
          drop: e.key == 'snooze_item' ? const {'item'} : null,
        ),
      },
  _generic('find', description: orbToolDescription('find')),
  _generic('query', description: orbToolDescription('query')),
  _generic('act', description: orbToolDescription('act')),
  {
    ..._generic('confirm', description: orbToolDescription('confirm')),
    'parameters': {
      'type': 'object',
      'properties': {
        'token': {'type': 'string', 'description': '可以省略：一次只有一项等着确认'},
      },
    },
  },
  {
    ..._generic('undo', description: orbToolDescription('undo')),
    'parameters': {
      'type': 'object',
      'properties': {
        'token': {'type': 'string', 'description': '可以省略：撤销最近一次'},
      },
    },
  },
  {'name': 'cancel_action', 'description': orbToolDescription('cancel_action')},
];

/// The one tool for answering somebody, in the agent layer: the app finds the
/// message, so the model never handles a message id and the card names the
/// person. (The realtime model keeps `send_message` and `reply_in_thread`.)
final orbReplyDeclaration = <String, Object?>{
  'name': 'reply',
  'description': orbToolDescription('reply'),
  'parameters': {
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'description': '要发的话，要 @ 谁就写 @名字'},
      'to': {'type': 'string', 'description': '可省略：人名，或 #频道名'},
    },
    'required': ['text'],
  },
};
