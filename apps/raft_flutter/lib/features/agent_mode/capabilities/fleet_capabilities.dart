import '../../../data/workspace_controller.dart';
import '../../../data/workspace_entity_directory.dart';
import '../../agent_metadata_projection.dart' show agentRowName;
import 'agent_capability.dart';
import 'capability_support.dart';
import 'message_capabilities.dart' show senderByRef;

/// Computers, members and the workspace itself.

Future<Map<String, dynamic>> computerByRef(
  WorkspaceController w,
  String ref,
) async {
  final d = w.entityDirectory;
  var rows = d.rows(WorkspaceEntityKind.computers);
  if (rows.isEmpty) {
    try {
      await d
          .refresh(WorkspaceEntityKind.computers)
          .timeout(const Duration(seconds: 6));
    } on Object {
      // Nothing better to use.
    }
    rows = d.rows(WorkspaceEntityKind.computers);
  }
  final want = ref.trim().toLowerCase();
  var hits = [
    for (final c in rows)
      if ('${c['id']}' == ref.trim() || '${c['name']}'.toLowerCase() == want) c,
  ];
  if (hits.isEmpty) {
    hits = [
      for (final c in rows)
        if (want.isNotEmpty && '${c['name']}'.toLowerCase().contains(want)) c,
    ];
  }
  if (hits.length == 1) return hits.single;
  if (hits.isEmpty) throw AgentCapabilityError('没有叫“$ref”的电脑');
  throw AgentCapabilityError(
    '“$ref”对得上多台电脑，请问用户是哪一台',
    candidates: [
      for (final c in hits.take(6)) {'id': c['id'], 'name': c['name']},
    ],
  );
}

Map<String, Object?> _computerRow(
  WorkspaceController w,
  Map<String, dynamic> c,
) {
  final agents = w.entityDirectory
      .rows(WorkspaceEntityKind.agents)
      .where((a) => a['machineId'] == c['id'])
      .map(agentRowName)
      .toList();
  return compact({
    'id': c['id'],
    'name': c['name'],
    'status': c['status'],
    'hostname': c['hostname'],
    'os': c['os'],
    'version': c['version'] ?? c['appVersion'],
    'lastSeen': stamp(c['lastSeenAt']),
    'agents': agents.take(12).toList(),
    'agentCount': agents.isEmpty ? null : agents.length,
  });
}

Future<void> _ensure(WorkspaceController w, WorkspaceEntityKind kind) =>
    directoryRows(w, kind);

final fleetCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'computers.list',
    title: '所有电脑（运行 Agent 的机器）：在线还是离线、上面跑着哪些 Agent',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /servers/:id/machines',
    keywords: const [
      '电脑',
      '机器',
      '电脑列表',
      '有哪些电脑',
      '哪台电脑在线',
      '哪台离线',
      'computer',
      '服务器上的机器',
      '设备',
      '主机',
    ],
    paramsSchema: objectSchema({
      'status': strArg('只看某种状态，如 online / offline'),
      'limit': intArg('最多几台，默认 20', min: 1, max: 40, dflt: 20),
    }),
    resultSummary: 'computers[{id,name,status,hostname,os,version,lastSeen,agents[],agentCount}]',
    run: (w, args, env) async {
      await _ensure(w, WorkspaceEntityKind.computers);
      await _ensure(w, WorkspaceEntityKind.agents);
      final status = (text(args['status']) ?? '').toLowerCase();
      final rows = [
        for (final c in w.entityDirectory.rows(WorkspaceEntityKind.computers))
          if (status.isEmpty || '${c['status']}'.toLowerCase() == status) c,
      ];
      return {
        'total': rows.length,
        'computers': [
          for (final c in rows.take(limitOf(args, dflt: 20, max: 40)))
            _computerRow(w, c),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'computers.detail',
    title: '一台电脑的详情：系统、版本、在线状态、上面的 Agent',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /servers/:id/machines/:id/runtime-options',
    keywords: const [
      '电脑详情',
      '这台电脑',
      '电脑信息',
      '电脑状态',
      '电脑上跑了什么',
      '电脑的版本',
      '电脑运行时',
    ],
    paramsSchema: objectSchema(
      {'computer': strArg('电脑的 id 或名字')},
      required: const ['computer'],
    ),
    resultSummary: 'computer{id,name,status,hostname,os,version,lastSeen,agents[]}，runtimes[{id,name,available}]',
    run: (w, args, env) async {
      await _ensure(w, WorkspaceEntityKind.agents);
      final row = await computerByRef(w, '${args['computer']}');
      final server = w.server?.id;
      var runtimes = const <Map<String, dynamic>>[];
      if (server != null) {
        try {
          runtimes = rowsOf(
            await w.query(
              '/servers/$server/machines/${row['id']}/runtime-options',
            ),
            const ['runtimes', 'options'],
          );
        } on Object {
          // The row alone still answers the question.
        }
      }
      return {
        'computer': _computerRow(w, row),
        if (runtimes.isNotEmpty)
          'runtimes': [
            for (final r in runtimes.take(12))
              compact({
                'id': r['id'] ?? r['runtime'],
                'name': r['name'] ?? r['label'] ?? r['id'],
                'available': r['available'],
              }),
          ],
      };
    },
  ),
  AgentCapability(
    id: 'members.list',
    title: '工作区里的人类成员名单，可按名字搜、按角色筛',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /servers/:id/members',
    keywords: const [
      '成员',
      '成员列表',
      '有哪些人',
      '团队成员',
      '同事',
      '队友',
      '谁在工作区',
      '管理员是谁',
      'members',
      '人类成员',
      '找人',
    ],
    paramsSchema: objectSchema({
      'query': strArg('名字里的字'),
      'role': strArg('角色，如 owner / admin / member'),
      'limit': intArg('最多几个，默认 30', min: 1, max: 60, dflt: 30),
    }),
    resultSummary: 'members[{id,name,role}]，total 是总数',
    run: (w, args, env) async {
      await _ensure(w, WorkspaceEntityKind.members);
      final q = (text(args['query']) ?? '').toLowerCase();
      final role = (text(args['role']) ?? '').toLowerCase();
      final rows = [
        for (final m in w.entityDirectory.rows(WorkspaceEntityKind.members))
          if ((q.isEmpty ||
                  '${m['displayName'] ?? ''} ${m['name'] ?? ''}'
                      .toLowerCase()
                      .contains(q)) &&
              (role.isEmpty || '${m['role']}'.toLowerCase() == role))
            m,
      ];
      return {
        'total': rows.length,
        'members': [
          for (final m in rows.take(limitOf(args, dflt: 30, max: 60)))
            compact({
              'id': m['userId'] ?? m['id'],
              'name': m['displayName'] ?? m['name'],
              'role': m['role'],
            }),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'members.profile',
    title: '一个成员的资料：名字、角色、加入时间、创建的 Agent',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /servers/:id/members/:id/profile',
    keywords: const [
      '成员资料',
      '某人的资料',
      '他是谁',
      '她是谁',
      '成员详情',
      '谁是',
      '加入时间',
      '成员信息',
      '个人资料',
    ],
    paramsSchema: objectSchema(
      {'member': strArg('成员的 id 或名字')},
      required: const ['member'],
    ),
    resultSummary: 'member{id,name,role,joinedAt,agents[]}（不含邮箱等联系方式）',
    run: (w, args, env) async {
      await _ensure(w, WorkspaceEntityKind.members);
      final person = await senderByRef(w, '${args['member']}', type: 'user');
      final server = w.server?.id;
      if (server == null) throw const AgentCapabilityError('还没有选中工作区');
      final body = await w.query(
        '/servers/$server/members/${person.id}/profile',
      );
      final p = body is Map
          ? Map<String, dynamic>.from(body)
          : <String, dynamic>{};
      return {
        'member': compact({
          'id': person.id,
          'name': p['displayName'] ?? p['name'] ?? person.label,
          'role': p['role'],
          'joinedAt': stamp(p['joinedAt'] ?? p['createdAt']),
          'agents': p['agents'] is List
              ? [
                  for (final a in (p['agents'] as List).whereType<Map>().take(
                    10,
                  ))
                    '${a['displayName'] ?? a['name'] ?? ''}',
                ]
              : null,
        }),
      };
    },
  ),
  AgentCapability(
    id: 'server.info',
    title: '当前所在的工作区（服务器）和我的角色，以及我加入的其他工作区',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /servers',
    keywords: const [
      '工作区',
      '服务器',
      '当前工作区',
      '我的角色',
      '我是管理员吗',
      '我的权限',
      '其他工作区',
      'server',
      '切换工作区',
      '当前在哪个',
    ],
    paramsSchema: noArgs,
    resultSummary: 'current{id,name,role}, others[{id,name}]',
    run: (w, args, env) async {
      final current = w.server;
      return {
        'current': compact({
          'id': current?.id,
          'name': current?.string('name'),
          'role': current?.string('role'),
        }),
        'others': [
          for (final s in w.servers.where((s) => s.id != current?.id).take(10))
            compact({'id': s.id, 'name': s.string('name')}),
        ],
      };
    },
  ),
];
