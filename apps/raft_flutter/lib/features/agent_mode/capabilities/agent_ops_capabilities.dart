import 'package:raft_client/raft_client.dart';

import '../../../data/system_notification_projection.dart';
import '../../../data/workspace_controller.dart';
import '../../../data/workspace_entity_directory.dart';
import '../../agent_metadata_projection.dart' show agentRowName;
import 'action_support.dart';
import 'agent_capabilities.dart' show agentByRef;
import 'agent_capability.dart';
import 'capability_support.dart';

/// Running Agents: stop, start, restart, reset the session, the emergency
/// stop of a channel, and what to read about an Agent (its workspace files,
/// its MCP calls) and about the workspace (the notification center). The
/// operations change what runs, so each is [AgentCapabilityRisk.sensitive]:
/// previewed and confirmed twice. A full workspace reset, deleting or
/// migrating an Agent stay pages to go to.

Map<String, dynamic> _runnable(
  WorkspaceController w,
  Map<String, dynamic> row, {
  String capability = 'controlAgentRuntime',
}) {
  final name = agentRowName(row);
  if (row['deletedAt'] != null) {
    throw AgentCapabilityError('$name 已经归档，不能再控制它的运行');
  }
  if (row['external'] == true || row['runtime'] == 'external') {
    throw AgentCapabilityError('$name 是外部 Agent，它跑在 Raft 管不到的地方，不能从这里启停或重启');
  }
  final owned =
      row['creatorType'] == 'user' && row['creatorId'] == w.client.user?.id;
  if (!owned && !w.can(capability)) {
    throw AgentCapabilityError('你没有控制 $name 运行的权限');
  }
  return row;
}

final _agentArg = strArg('Agent 的 id 或名字');

AgentCapability _runtimeAction({
  required String id,
  required String title,
  required List<String> keywords,
  required String parity,
  required String Function(String name) say,
  String field = '的运行',
  required String path,
  Map<String, Object?>? body,
  required String doneText,
  String before = '运行中',
  String after = '',
  String? undoLabel,
  String? undoPath,
  String? undoText,
  String capability = 'controlAgentRuntime',
  String warning = '',
}) => AgentCapability(
  id: id,
  title: title,
  kind: AgentCapabilityKind.action,
  risk: AgentCapabilityRisk.sensitive,
  parity: parity,
  keywords: keywords,
  paramsSchema: objectSchema({'agent': _agentArg}, required: const ['agent']),
  resultSummary: 'done, entity=agent, id',
  prepareUndo: undoPath == null
      ? null
      : (w, args, env) async {
          final row = _runnable(w, await agentByRef(w, '${args['agent']}'));
          return AgentUndoPlan(
            label: undoLabel!,
            run: () async {
              await w.command(
                'POST',
                '/agents/${row['id']}/$undoPath',
                data: {},
              );
              return '${agentRowName(row)} $undoText';
            },
          );
        },
  preview: (w, args, env) async {
    final row = _runnable(
      w,
      await agentByRef(w, '${args['agent']}'),
      capability: capability,
    );
    final name = agentRowName(row);
    return AgentActionPreview(
      summary: '${say(name)}$warning',
      changes: [change('$name$field', before, after)],
      reversible: undoPath != null,
      refs: [AgentPreviewRef('agent', '${row['id']}')],
    );
  },
  run: (w, args, env) async {
    final row = _runnable(
      w,
      await agentByRef(w, '${args['agent']}'),
      capability: capability,
    );
    await w.command('POST', '/agents/${row['id']}/$path', data: body ?? {});
    return actionResult(
      '$doneText ${agentRowName(row)}',
      entity: 'agent',
      id: '${row['id']}',
    );
  },
);

final agentOpsCapabilities = <AgentCapability>[
  _runtimeAction(
    id: 'agents.stop',
    title: '停掉一个 Agent（它不再处理消息，直到再启动）；敏感，要确认两次',
    keywords: const [
      '停掉agent',
      '让他停下',
      '停止agent',
      '关掉agent',
      '别让他跑了',
      '停一下cody',
      'stop agent',
    ],
    parity: 'POST /agents/:id/stop',
    say: (n) => '停掉 $n',
    path: 'stop',
    doneText: '已停掉',
    before: '运行中',
    after: '已停止',
    warning: '（它会停止处理消息，之后可以再启动）',
    undoLabel: '重新启动',
    undoPath: 'start',
    undoText: '已重新启动',
  ),
  _runtimeAction(
    id: 'agents.start',
    title: '启动一个已经停掉的 Agent；敏感，要确认两次',
    keywords: const [
      '启动agent',
      '开始运行',
      '把他开起来',
      '重新启动agent',
      '启动cody',
      'start agent',
    ],
    parity: 'POST /agents/:id/start',
    say: (n) => '启动 $n',
    path: 'start',
    doneText: '已启动',
    before: '已停止',
    after: '运行中',
    undoLabel: '再停掉',
    undoPath: 'stop',
    undoText: '已再次停掉',
  ),
  _runtimeAction(
    id: 'agents.restart',
    title: '重启一个 Agent 的运行时（会打断它手上正在做的事）；敏感，要确认两次',
    keywords: const [
      '重启agent',
      '重启一下',
      '重启grok',
      '重启cody',
      '让他重新跑',
      'restart agent',
    ],
    parity: 'POST /agents/:id/reset',
    say: (n) => '重启 $n',
    path: 'reset',
    body: const {'mode': 'restart'},
    doneText: '已重启',
    before: '运行中',
    after: '重启',
    warning: '（会打断它正在做的事）',
  ),
  _runtimeAction(
    id: 'agents.reset_session',
    title: '重置一个 Agent 的会话（它忘掉当前对话上下文，工作区文件保留）；敏感，要确认两次',
    keywords: const [
      '重置会话',
      '重置agent的会话',
      '清掉上下文',
      '忘掉对话',
      'reset session',
      '开个新会话',
    ],
    parity: 'POST /agents/:id/reset',
    say: (n) => '重置 $n 的会话',
    field: '的会话',
    path: 'reset',
    body: const {'mode': 'session'},
    doneText: '已重置会话',
    before: '当前会话',
    after: '新会话',
    warning: '（它会忘掉当前对话的上下文，工作区文件不动）',
  ),
  AgentCapability(
    id: 'channels.sos_stop',
    title: '紧急停止：一键停掉一个频道里所有 Agent（SOS）；敏感，要确认两次。之后用 channels.sos_resume 带着新指示让它们继续',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.sensitive,
    parity: 'POST /channels/:id/stop-all-agents',
    keywords: const [
      '紧急停止',
      'SOS',
      '全部停下',
      '停掉所有agent',
      '让所有agent停下',
      '所有agent都停',
      '他们跑偏了',
      '一键停止',
    ],
    paramsSchema: objectSchema(
      {'channel': strArg('频道的 id 或名字（不带 #）')},
      required: const ['channel'],
    ),
    resultSummary: 'done, entity=channel, id',
    preview: (w, args, env) async {
      final c = _sosChannel(w, '${args['channel']}');
      return AgentActionPreview(
        summary: '紧急停止 #${c.name} 里的所有 Agent（它们马上停下，等你给新指示再继续）',
        changes: [change('#${c.name} 的 Agent', '运行中', '全部停止')],
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = _sosChannel(w, '${args['channel']}');
      await w.command('POST', '/channels/${c.id}/stop-all-agents');
      return actionResult(
        '已紧急停止 #${c.name} 里的所有 Agent',
        entity: 'channel',
        id: c.id,
      );
    },
  ),
  AgentCapability(
    id: 'channels.sos_resume',
    title: '紧急停止之后让频道里的 Agent 继续：带上用户的纠正和新指示；敏感，要确认两次',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.sensitive,
    parity: 'POST /channels/:id/resume-all-agents',
    keywords: const [
      '恢复agent',
      '让他们继续',
      '紧急停止后继续',
      '恢复运行',
      '带着新指示继续',
      '继续干活',
      'resume agents',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('频道的 id 或名字（不带 #）'),
        'guidance': strArg('用户的纠正和新指示，会原话发给 Agent', max: 1500),
      },
      required: const ['channel', 'guidance'],
    ),
    resultSummary: 'done, entity=channel, id',
    preview: (w, args, env) async {
      final c = _sosChannel(w, '${args['channel']}');
      return AgentActionPreview(
        summary:
            '让 #${c.name} 里的 Agent 继续，并告诉它们：“${quote('${args['guidance']}', 40)}”',
        changes: [
          change('#${c.name} 的 Agent', '已停止', '继续运行'),
          change('新指示', '', '${args['guidance']}'),
        ],
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = _sosChannel(w, '${args['channel']}');
      // The wording of the SOS dialog, so Agents read the same thing.
      final prompt =
          "[SOS] The user has emergency-stopped all agents in #${c.name} because they were going off-track. Here is the user's correction and new guidance:\n\n${args['guidance']}\n\nRead this carefully, acknowledge the correction, and adjust your approach accordingly. Use check_messages and read_history to understand the current state before taking any action.";
      await w.command(
        'POST',
        '/channels/${c.id}/resume-all-agents',
        data: {'prompt': prompt},
      );
      return actionResult(
        '已让 #${c.name} 里的 Agent 带着新指示继续',
        entity: 'channel',
        id: c.id,
      );
    },
  ),
  AgentCapability(
    id: 'agents.workspace_files',
    title: '看任意一个 Agent 工作区里的文件：列出目录，或读一个文件（比如它的 MEMORY.md）',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /agents/:id/workspace-files',
    keywords: const [
      '工作区文件',
      'agent的文件',
      '记忆里写了什么',
      'memory.md',
      '看他的记忆',
      'agent的记忆',
      '工作区里有什么',
      '读agent的文件',
      'workspace files',
    ],
    paramsSchema: objectSchema(
      {
        'agent': _agentArg,
        'file': strArg('要读的文件路径，如 MEMORY.md；不写就是列目录', max: 300),
        'dir': strArg('要列的目录，默认根目录', max: 300),
        'hidden': boolArg('列出隐藏文件'),
      },
      required: const ['agent'],
    ),
    resultSummary:
        '列目录：files[{name,path,kind,size}]；读文件：content（过长会截断，truncated=true）',
    run: (w, args, env) async {
      final row = await agentByRef(w, '${args['agent']}');
      final base = '/agents/${row['id']}/workspace-files';
      final file = text(args['file']);
      if (file != null) {
        final body = await w.query('$base/read', query: {'path': file});
        final content = body is Map ? '${body['content'] ?? ''}' : '$body';
        const limit = 3000;
        return compact({
          'agent': agentRowName(row),
          'file': file,
          'content': content.length <= limit
              ? content
              : content.substring(0, limit),
          'truncated': content.length > limit ? true : null,
          'length': content.length,
          'message': content.trim().isEmpty ? '这个文件是空的' : null,
        });
      }
      final dir = text(args['dir']);
      final body = await w.query(
        base,
        query: {'dirPath': ?dir, 'includeHidden': '${args['hidden'] == true}'},
      );
      final rows = rowsOf(body, const ['files']);
      return compact({
        'agent': agentRowName(row),
        'dir': dir ?? '/',
        'count': rows.length,
        'truncated': body is Map && body['truncated'] == true ? true : null,
        'files': [
          for (final f in rows.take(40))
            compact({
              'name': f['name'],
              'path': f['path'] ?? f['name'],
              'kind': f['type'] == 'directory' || f['isDirectory'] == true
                  ? 'directory'
                  : 'file',
              'size': f['size'] ?? f['sizeBytes'],
            }),
        ],
      });
    },
  ),
  AgentCapability(
    id: 'agents.mcp_usage',
    title: '一个 Agent 调用过哪些 MCP 服务器：各调了几次、最后一次什么时候、用的哪个工具',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /mcp/agents/:id',
    keywords: const [
      'mcp调用',
      '调用了哪些工具',
      '最近调用了什么',
      'mcp记录',
      '用了哪些mcp',
      '工具调用记录',
      'mcp usage',
      '调用记录',
    ],
    paramsSchema: objectSchema({'agent': _agentArg}, required: const ['agent']),
    resultSummary: 'servers[{name,calls,lastUsed,lastTool,enabled}]（只列调用过的）',
    run: (w, args, env) async {
      final row = await agentByRef(w, '${args['agent']}');
      final body = await w.query('/mcp/agents/${row['id']}');
      final servers = rowsOf(body, const ['servers']);
      final used = [
        for (final s in servers)
          if (s['usage'] is Map &&
              ((s['usage'] as Map)['invocationCount'] as num? ?? 0) > 0)
            s,
      ];
      return {
        'agent': agentRowName(row),
        'count': used.length,
        if (used.isEmpty) 'message': '${agentRowName(row)} 还没有调用过任何 MCP 服务器',
        'servers': [
          for (final s in used.take(20))
            compact({
              'name': s['name'],
              'calls': (s['usage'] as Map)['invocationCount'],
              'lastUsed': stamp((s['usage'] as Map)['lastInvokedAt']),
              'lastTool': (s['usage'] as Map)['lastToolName'],
              'enabled': s['enabled'] == false ? false : null,
            }),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'notifications.center',
    title: '通知中心里的系统提示：套餐降级、频道超限、电脑磁盘不足 / 可更新、未读反馈',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /product-feedback/tickets',
    keywords: const [
      '通知中心',
      '系统通知',
      '系统提示',
      '有什么提示',
      '套餐提示',
      '超限',
      '有系统通知吗',
      '提醒我什么',
      'notification center',
    ],
    paramsSchema: noArgs,
    resultSummary: 'count, notices[{kind,title,body,goes}]（goes：计费 / 电脑 / 反馈）；你在 App 里已关掉的提示这里仍会列出',
    run: (w, args, env) async {
      final canMachines = w.can('viewMachines');
      final machines = canMachines
          ? await directoryRows(w, WorkspaceEntityKind.computers)
          : const <Map<String, dynamic>>[];
      final agents = w.can('viewAgents')
          ? await directoryRows(w, WorkspaceEntityKind.agents)
          : const <Map<String, dynamic>>[];
      var feedback = 0;
      try {
        final body = await w.query(
          '/product-feedback/tickets',
          query: {'limit': 1},
        );
        final n = body is Map ? body['unread_total'] : null;
        if (n is int && n > 0) feedback = n;
      } on Object {
        // The other notices still stand.
      }
      final notices = projectSystemNotifications(
        server: w.server?.json,
        channels: [for (final c in w.channels) c.json],
        machines: machines,
        agents: agents,
        machinesReady: canMachines,
        canViewMachines: canMachines,
        mobile: false,
        feedbackUnread: feedback,
        now: DateTime.now(),
      );
      return {
        'count': notices.length,
        if (notices.isEmpty) 'message': '通知中心里没有系统提示',
        'notices': [
          for (final n in notices.take(15))
            compact({
              'kind': switch (n.kind) {
                SystemNoticeKind.error => '严重',
                SystemNoticeKind.warning => '警告',
                SystemNoticeKind.info => '提示',
              },
              'title': clip(n.title, 80),
              'body': clip(n.body, 200),
              'goes': switch (n.destination) {
                SystemNoticeDestination.billing => '计费页',
                SystemNoticeDestination.computer ||
                SystemNoticeDestination.computers => '电脑页',
                SystemNoticeDestination.feedback => '反馈页',
              },
            }),
        ],
      };
    },
  ),
];

RaftChannel _sosChannel(WorkspaceController w, String ref) {
  final c = channelByRef(w, ref);
  if (c.type == 'dm') throw const AgentCapabilityError('紧急停止是对频道说的，私信里没有');
  if (c.archived) throw AgentCapabilityError('#${c.name} 已归档');
  if (!w.can('controlAgentRuntime')) {
    throw const AgentCapabilityError('你没有控制 Agent 运行的权限');
  }
  return c;
}
