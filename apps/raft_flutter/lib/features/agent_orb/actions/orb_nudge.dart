import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import '../../agent_mode/capabilities/action_support.dart';
import '../../agent_mode/capabilities/agent_capability.dart';
import '../../agent_mode/capabilities/agent_capability_standard.dart';
import '../../agent_mode/capabilities/capability_support.dart';
import '../../agent_mode/agent_mode_data.dart' show AgentModeData;
import '../screen/orb_screen_capability.dart' show orbScreenCapability;
import 'orb_task_tools.dart' show orbIdleText;

/// "催一下": a reply in the task's thread that names whoever has the task and
/// asks where it is. It is a thread reply like the one Agent mode's
/// `reply_in_thread` makes, found by the task's number so the person can say
/// "催一下 138". Orb only: the standard capabilities do not have it.

typedef _Nudge = ({
  Map<String, dynamic> task,
  String assignee,
  RaftMessage parent,
  RaftChannel channel,
  String text,
  List<Map<String, dynamic>> mentions,
});

Future<_Nudge> _nudge(
  WorkspaceController w,
  Map<String, Object?> args,
  AgentCapabilityEnv env,
) async {
  final task = await taskFor(w, env, args);
  final status = '${task['status']}';
  if (status == 'done' || status == 'closed') {
    throw AgentCapabilityError('${taskWord(task)} 已经${statusWord(status)}，不用催');
  }
  final assignee = text(task['claimedByName']);
  if (assignee == null) {
    throw AgentCapabilityError('${taskWord(task)} 还没有负责人，没人可催：可以先交给某个人');
  }
  final messageId = text(task['messageId']);
  if (messageId == null) {
    throw AgentCapabilityError('${taskWord(task)} 没有对应的讨论串（它不是从消息建的），不能在串里催');
  }
  final channel = w.channelById('${task['channelId']}');
  if (channel == null || !channel.joined || channel.archived) {
    throw AgentCapabilityError('${taskWord(task)} 所在的频道你没有加入或已归档，不能留言');
  }
  final sendable = sendableChannel(w, channel.id);
  final said = text(args['text']);
  final since = AgentModeData.timeOf(task['updatedAt']);
  final still = since == null ? null : env.dataFor(w).now().difference(since);
  final body =
      said ??
      (still == null || still.inMinutes < 60
          ? '这个任务现在到哪了？'
          : '这个任务 ${orbIdleText(still)}没动了，现在到哪了？');
  final lead = body.contains('@') ? '' : '@$assignee ';
  final m = await mentionsIn(w, '$lead$body');
  return (
    task: task,
    assignee: assignee,
    parent: RaftMessage({'id': messageId, 'channelId': task['channelId']}),
    channel: sendable,
    text: m.text,
    mentions: m.mentions,
  );
}

final orbNudgeCapability = AgentCapability(
  id: 'tasks.nudge',
  title: '催一下任务的负责人：在任务的讨论串里 @他问进展',
  kind: AgentCapabilityKind.action,
  risk: AgentCapabilityRisk.change,
  keywords: const ['催', '催一下', '催催', '问进展', '问问进度', '提醒他', '推一下', 'nudge'],
  paramsSchema: objectSchema(
    {
      'task': strArg('任务编号（#98 / 98）', max: 80),
      'text': strArg('催的话，可省略（默认问现在到哪了）', max: 1000),
      'channel': strArg('频道名；编号在多个频道重复时才需要'),
    },
    required: const ['task'],
  ),
  resultSummary: 'done, entity=task, id',
  preview: (w, args, env) async {
    final n = await _nudge(w, args, env);
    return AgentActionPreview(
      summary: '催 ${n.assignee}（${taskWord(n.task)}）：“${quote(n.text, 30)}”',
      changes: [
        change('催', '', n.assignee),
        change('任务', '', taskWord(n.task)),
        change('内容', '', n.text),
        change('发到', '', '任务的讨论串 · ${channelWord(n.channel)}'),
      ],
      refs: [AgentPreviewRef('task', '${n.task['id']}')],
    );
  },
  run: (w, args, env) async {
    final n = await _nudge(w, args, env);
    final ok = await w.sendThreadReply(
      n.parent,
      n.text,
      mentions: n.mentions,
      randomId: w.client.newRandomId(),
    );
    if (!ok) throw AgentCapabilityError(w.error ?? '留言没有发出去');
    return actionResult(
      '已催 ${n.assignee}',
      entity: 'task',
      id: '${n.task['id']}',
    );
  },
);

/// What the orb's actions run on: every standard capability, the nudge, and
/// the press of a risky control on the screen.
final orbActionRegistry = AgentCapabilityRegistry([
  ...agentStandardCapabilities.all,
  orbNudgeCapability,
  orbScreenCapability,
]);
