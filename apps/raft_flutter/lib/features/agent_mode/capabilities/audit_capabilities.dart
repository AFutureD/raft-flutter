import 'agent_capability.dart';
import 'capability_support.dart';

/// What the agent did in this session. Local to the app (no server read), so
/// it carries no parity entry.
String _hm(DateTime at) {
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}

final auditCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'agent.audit_log',
    title: '这次我替用户做过的操作记录：什么时候、做了什么、结果如何（包括失败和撤销）',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    keywords: const [
      '你帮我做了什么',
      '你替我做了什么',
      '你刚才帮我做了什么',
      '帮我做过的操作',
      '操作记录',
      '执行记录',
      '审计',
      '你改了什么',
      '你发了什么',
      '撤销记录',
      'audit',
    ],
    paramsSchema: objectSchema({
      'limit': intArg('最近几条，默认 12', min: 1, max: 12, dflt: 12),
    }),
    resultSummary: 'entries[{time,capability,summary,args,result,ok,undo,entity,id}] 旧到新；timeline 是可以直接放进 Timeline 组件 items 的一份',
    run: (w, args, env) async {
      final all = env.audit?.entries ?? const [];
      final shown = all.length > limitOf(args, dflt: 12, max: 12)
          ? all.sublist(all.length - limitOf(args, dflt: 12, max: 12))
          : all;
      return {
        'total': all.length,
        if (all.isEmpty) 'message': '这次还没有替用户执行过任何操作',
        'entries': [
          for (final e in shown)
            compact({
              'time': _hm(e.at),
              'capability': e.capability,
              'summary': e.summary,
              'args': e.args,
              'result': e.result,
              'ok': e.ok,
              'undo': e.undo ? true : null,
              'entity': e.entity,
              'id': e.entityId,
            }),
        ],
        if (shown.isNotEmpty) ...{
          'timeline': [
            for (final e in shown)
              compact({
                'time': _hm(e.at),
                'title': clip(
                  '${e.ok ? '' : '失败：'}${e.undo ? '撤销了 ' : ''}${e.summary}（${e.result}）',
                  78,
                ),
                'entity': e.entityId == null ? null : e.entity,
                'id': e.entityId,
              }),
          ],
          'render': '用 Timeline 组件展示：items 直接用 timeline；说一句话概括做了几件事',
        },
      };
    },
  ),
];
