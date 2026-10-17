import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import '../../message_action_card.dart'
    show actionCardReadOnlyInServer, messageParentChannelId;
import 'action_support.dart';
import 'agent_capability.dart';
import 'capability_support.dart';

/// Approvals: the action cards Agents leave in channels (approve a login,
/// install an app, re-confirm) and the authorization requests of connected
/// apps. Approving gives something access or installs it, so it is
/// [AgentCapabilityRisk.sensitive]: previewed, and confirmed twice. Saying no
/// to a connected app is an ordinary change.

/// The action types the card's own button runs without a form.
const _inlineActionTypes = {
  'integration:approve_agent_login',
  'integration:install_marketplace_app',
};

/// The form-bound types, named for the person.
const _formActionTypes = {
  'channel:create': '创建频道',
  'agent:create': '创建 Agent',
  'channel:add_member': '给频道加成员',
  'integration:register_app': '注册应用',
  'integration:update_app_registration': '更新应用注册',
  'integration:recover_app_owner': '找回应用所有者',
};

Map<String, dynamic> _meta(Map<String, dynamic> m) {
  final v = m['actionMetadata'];
  return v is Map ? Map<String, dynamic>.from(v) : const {};
}

Map<String, dynamic> _action(Map<String, dynamic> meta) {
  final v = meta['action'];
  return v is Map ? Map<String, dynamic>.from(v) : const {};
}

/// What a card asks, in a sentence.
String actionCardWord(Map<String, dynamic> meta) {
  final a = _action(meta);
  String s(String key) => '${a[key] ?? ''}';
  return switch (a['type']) {
    'integration:approve_agent_login' =>
      '批准应用“${s('clientName')}”登录 @${s('agentName')}',
    'integration:install_marketplace_app' =>
      '安装应用“${s('clientName')}”（@${s('agentName')} 请求）',
    final String t when _formActionTypes.containsKey(t) =>
      '${_formActionTypes[t]}${a['name'] == null ? '' : '“${a['name']}”'}（要在卡片里填写）',
    _ => '一张操作卡片',
  };
}

String _scopes(Map<String, dynamic> meta) {
  final scopes = _action(meta)['scopes'];
  return scopes is List && scopes.isNotEmpty ? scopes.join('、') : '';
}

/// The action-card message [id] and its metadata, or why it is not one.
Future<({RaftMessage row, Map<String, dynamic> meta})> _card(
  WorkspaceController w,
  Map<String, Object?> args,
) async {
  final m = await messageById(
    w,
    '${args['message']}',
    channelRef: text(args['channel']),
  );
  final meta = _meta(m.json);
  if (meta['kind'] != 'action-card' && meta['action'] is! Map) {
    throw const AgentCapabilityError('这条消息不是操作卡片');
  }
  return (row: m, meta: meta);
}

/// Why the card cannot be answered here, in the order the card itself
/// checks (message_action_card.dart `blocked`).
String? _blocked(
  WorkspaceController w,
  Map<String, dynamic> row,
  Map<String, dynamic> meta,
) {
  if (actionCardReadOnlyInServer(meta, w.server?.id)) {
    final name = meta['targetServerName'];
    return name is String
        ? '这张卡片要在服务器“$name”里批准，先切到那个服务器'
        : '这是一张历史副本，只能在它来源的服务器里批准';
  }
  final carrierId = messageParentChannelId(row) ?? '${row['channelId']}';
  final carrier =
      w.channelById(carrierId) ?? w.channelById('${row['channelId']}');
  if (carrier == null) return '卡片所在的频道你看不到';
  if (carrier.archived) return '卡片所在的频道已归档，不能再批准';
  if (w.server?.string('role') == 'guest') return '访客不能批准操作卡片';
  final role = w.server?.string('role');
  if (!carrier.joined &&
      carrier.type != 'dm' &&
      !const ['owner', 'admin'].contains(role)) {
    return '先加入 #${carrier.name} 才能批准';
  }
  final type = _action(meta)['type'];
  if (type == 'integration:install_marketplace_app' &&
      !const ['owner', 'admin'].contains(role)) {
    return '只有服务器的所有者或管理员能安装市场应用';
  }
  return null;
}

/// Pending action cards the app holds (the windows it has loaded) plus,
/// when a channel is named, that channel's latest messages.
Future<List<Map<String, dynamic>>> _pendingCards(
  WorkspaceController w,
  String? channelRef,
) async {
  final rows = <String, Map<String, dynamic>>{};
  void take(Iterable<Map<String, dynamic>> list) {
    for (final m in list) {
      final meta = _meta(m);
      final state = meta['state'];
      if ((meta['kind'] == 'action-card' || meta['action'] is Map) &&
          (state == 'prepared' || state == 'reconfirm_required') &&
          m['id'] is String) {
        rows['${m['id']}'] = m;
      }
    }
  }

  for (final c in [...w.channels, ...w.dms]) {
    if (c.joined || c.type == 'dm') take(w.ledger.messages(c.id));
  }
  if (channelRef != null) {
    final c = channelByRef(w, channelRef);
    final page = await w.client.messagePage(c.id, limit: 50);
    take(rowsOf(page, const ['messages']));
  }
  return rows.values.toList();
}

Map<String, Object?> _cardRow(WorkspaceController w, Map<String, dynamic> m) {
  final meta = _meta(m);
  final blocked = _blocked(w, m, meta);
  final type = _action(meta)['type'];
  return compact({
    'messageId': m['id'],
    'channelId': m['channelId'],
    'what': actionCardWord(meta),
    'state': meta['state'] == 'reconfirm_required' ? '需要重新确认' : '待批准',
    'scopes': _scopes(meta),
    'from': m['senderDisplayName'] ?? m['senderName'],
    'canApproveByVoice': blocked == null && _inlineActionTypes.contains(type)
        ? true
        : null,
    'blocked':
        blocked ??
        (_inlineActionTypes.contains(type) ? null : '要在卡片里填写，请用户自己点开'),
  });
}

/// The pending connected-app authorization requests (rows of
/// `GET /integrations/overview` of type `pending`).
Future<List<Map<String, dynamic>>> _pendingRequests(
  WorkspaceController w,
) async {
  final body = await w.query('/integrations/overview');
  return [
    for (final r in rowsOf(body, const ['access', 'items', 'grants']))
      if (r['type'] == 'pending') r,
  ];
}

String _requestWord(Map<String, dynamic> r) {
  final app = '${r['clientName'] ?? r['clientId'] ?? '应用'}';
  final agent = r['agentName'] ?? r['agentDisplayName'];
  return agent == null ? '应用“$app”的授权请求' : '应用“$app”请求授权给 @$agent';
}

Future<Map<String, dynamic>> _request(
  WorkspaceController w,
  Map<String, Object?> args,
) async {
  final id = '${args['request']}';
  final hit = (await _pendingRequests(w))
      .where((r) => '${r['id']}' == id)
      .firstOrNull;
  if (hit == null) {
    throw const AgentCapabilityError(
      '没有这个待批准的授权请求（可能已被处理）：先用 approvals.pending 看一遍',
    );
  }
  return hit;
}

void _mayManageApps(WorkspaceController w, Map<String, dynamic> request) {
  if (w.server?.string('role') == 'guest') {
    throw const AgentCapabilityError('访客不能处理应用授权');
  }
  if (w.can('manageIntegrations')) return;
  final agentId = '${request['agentId'] ?? ''}';
  final agent = agentId.isEmpty ? null : w.entityDirectory.agent(agentId);
  if (agent != null &&
      agent['creatorType'] == 'user' &&
      agent['creatorId'] == w.client.user?.id) {
    return;
  }
  throw const AgentCapabilityError('你没有处理应用授权的权限：需要服务器管理员，或这个 Agent 的创建者');
}

final approvalCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'approvals.pending',
    title: '等我批准的事：Agent 留在频道里的操作卡片（批准登录、安装应用、重新确认）和应用来要的授权',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /integrations/overview',
    keywords: const [
      '等我批准',
      '待批准',
      '要我批准的',
      '审批',
      '批准请求',
      '谁要权限',
      '谁在要权限',
      '授权请求',
      '登录请求',
      '安装请求',
      '操作卡片',
      '有什么要批的',
      'approvals',
    ],
    paramsSchema: objectSchema({
      'channel': strArg('也去读这个频道最近的消息里找卡片（App 还没加载它时用）'),
    }),
    resultSummary: 'cards[{messageId,channelId,what,state,scopes,from,canApproveByVoice,blocked}]，apps[{requestId,what,scopes}]；批卡片用 actions.approve，批应用授权用 apps.approve_request',
    run: (w, args, env) async {
      final cards = await _pendingCards(w, text(args['channel']));
      List<Map<String, dynamic>> requests;
      String? appsProblem;
      try {
        requests = await _pendingRequests(w);
      } on Object {
        requests = const [];
        appsProblem = '应用授权请求现在读不到';
      }
      return compact({
        'total': cards.length + requests.length,
        'cards': [for (final m in cards.take(15)) _cardRow(w, m)],
        'apps': [
          for (final r in requests.take(15))
            compact({
              'requestId': r['id'],
              'what': _requestWord(r),
              'scopes': r['scopes'] is List
                  ? (r['scopes'] as List).join('、')
                  : null,
              'agentId': r['agentId'],
            }),
        ],
        'problem': appsProblem,
        if (cards.isEmpty && requests.isEmpty && appsProblem == null)
          'message': '没有等你批准的事',
      });
    },
  ),
  AgentCapability(
    id: 'actions.approve',
    title: '批准频道里的一张操作卡片（批准应用登录、安装市场应用；需要重新确认的先重新确认）；敏感，要确认两次',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.sensitive,
    parity: 'POST /actions/:id/execute',
    keywords: const [
      '批准卡片',
      '批准登录',
      '批准这个登录',
      '批准安装',
      '同意安装',
      '同意登录',
      '允许登录',
      '重新确认',
      '批准这个请求',
      '执行这张卡片',
      'approve',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg(
          '操作卡片所在的消息 id（取自 approvals.pending 的 messageId）',
          max: 80,
        ),
        'channel': strArg('卡片所在频道，已知时带上'),
      },
      required: const ['message'],
    ),
    resultSummary: 'done, entity=message, id',
    preview: (w, args, env) async {
      final c = await _card(w, args);
      final row = Map<String, dynamic>.from(c.row.json);
      final reason = _blocked(w, row, c.meta);
      if (reason != null) throw AgentCapabilityError(reason);
      final type = _action(c.meta)['type'];
      if (!_inlineActionTypes.contains(type)) {
        throw AgentCapabilityError(
          '${actionCardWord(c.meta)}：这类卡片要在频道里点开、自己填写，语音不能代批',
        );
      }
      final state = c.meta['state'];
      if (state == 'reconfirm_required') {
        return AgentActionPreview(
          summary: '重新确认这张卡片：${actionCardWord(c.meta)}（之后它会回到“待批准”，还需要再批准一次）',
          changes: [change('卡片状态', '需要重新确认', '待批准')],
          refs: [AgentPreviewRef('message', '${row['id']}')],
        );
      }
      if (state != 'prepared') {
        throw AgentCapabilityError('这张卡片现在是“$state”，不是待批准');
      }
      final scopes = _scopes(c.meta);
      return AgentActionPreview(
        summary: '批准：${actionCardWord(c.meta)}',
        changes: [
          change('卡片状态', '待批准', '已批准并执行'),
          if (scopes.isNotEmpty) change('开放的权限', '', scopes),
        ],
        refs: [AgentPreviewRef('message', '${row['id']}')],
      );
    },
    run: (w, args, env) async {
      final c = await _card(w, args);
      final row = Map<String, dynamic>.from(c.row.json);
      final reason = _blocked(w, row, c.meta);
      if (reason != null) throw AgentCapabilityError(reason);
      final id = '${row['id']}';
      final state = c.meta['state'];
      if (state == 'reconfirm_required') {
        await w.client.request('POST', '/actions/$id/reconfirm');
        return actionResult(
          '已重新确认，卡片回到“待批准”，再批准一次才会执行',
          entity: 'message',
          id: id,
        );
      }
      if (state != 'prepared') {
        throw AgentCapabilityError('这张卡片现在是“$state”，不是待批准');
      }
      final out = await w.client.request(
        'POST',
        '/actions/$id/execute',
        data: {
          'expectedState': 'prepared',
          'expectedConfirmationVersion': c.meta['confirmationVersion'],
        },
      );
      final after = out is Map && out['metadata'] is Map
          ? (out['metadata'] as Map)['state']
          : null;
      if (after != null && after != 'executed') {
        throw AgentCapabilityError('服务器没有执行这张卡片，它现在是“$after”');
      }
      return actionResult(
        '已批准：${actionCardWord(c.meta)}',
        entity: 'message',
        id: id,
      );
    },
  ),
  AgentCapability(
    id: 'actions.dismiss',
    title: '不批准一张操作卡片：只记下“用户没批准”，卡片本身仍留在频道里（服务器没有拒绝接口）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /actions/:id/event',
    keywords: const [
      '不批准',
      '拒绝卡片',
      '不同意这个登录',
      '不要安装',
      '拒绝这个请求',
      '忽略这张卡片',
      'deny',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg('操作卡片所在的消息 id', max: 80),
        'channel': strArg('卡片所在频道，已知时带上'),
      },
      required: const ['message'],
    ),
    resultSummary: 'done, entity=message, id',
    preview: (w, args, env) async {
      final c = await _card(w, args);
      return AgentActionPreview(
        summary: '不批准：${actionCardWord(c.meta)}（卡片仍留在频道里，你以后还能批准）',
        changes: [change('你的决定', '未决定', '不批准')],
        refs: [AgentPreviewRef('message', '${c.row.json['id']}')],
      );
    },
    run: (w, args, env) async {
      final c = await _card(w, args);
      final id = '${c.row.json['id']}';
      await w.client.request(
        'POST',
        '/actions/$id/event',
        data: {'eventType': 'action_card.dismiss', 'metadata': {}},
      );
      return actionResult(
        '已记下不批准：${actionCardWord(c.meta)}（卡片仍在频道里）',
        entity: 'message',
        id: id,
      );
    },
  ),
  AgentCapability(
    id: 'apps.approve_request',
    title: '批准一个应用来要的授权（让应用以某个 Agent 的身份登录、使用权限）；敏感，要确认两次',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.sensitive,
    parity: 'POST /integrations/requests/:id/approve',
    keywords: const [
      '批准应用授权',
      '给应用权限',
      '给他权限',
      '同意授权',
      '授权给',
      '要的权限给他',
      '批准授权',
      '允许应用',
    ],
    paramsSchema: objectSchema(
      {
        'request': strArg(
          '授权请求的 id（取自 approvals.pending 的 requestId）',
          max: 80,
        ),
      },
      required: const ['request'],
    ),
    resultSummary: 'done',
    preview: (w, args, env) async {
      final r = await _request(w, args);
      _mayManageApps(w, r);
      final scopes = r['scopes'] is List ? (r['scopes'] as List).join('、') : '';
      return AgentActionPreview(
        summary: '批准：${_requestWord(r)}',
        changes: [
          change('授权', '待批准', '已批准（记住这次选择）'),
          if (scopes.isNotEmpty) change('开放的权限', '', scopes),
        ],
      );
    },
    run: (w, args, env) async {
      final r = await _request(w, args);
      _mayManageApps(w, r);
      await w.client.post(
        '/integrations/requests/${r['id']}/approve',
        data: {'remember': true},
      );
      return actionResult('已批准：${_requestWord(r)}');
    },
  ),
  AgentCapability(
    id: 'apps.deny_request',
    title: '拒绝一个应用来要的授权',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /integrations/requests/:id/deny',
    keywords: const ['拒绝授权', '不给权限', '不给他权限', '拒绝应用', '拒绝这个授权请求', '不同意授权'],
    paramsSchema: objectSchema(
      {
        'request': strArg(
          '授权请求的 id（取自 approvals.pending 的 requestId）',
          max: 80,
        ),
      },
      required: const ['request'],
    ),
    resultSummary: 'done',
    preview: (w, args, env) async {
      final r = await _request(w, args);
      _mayManageApps(w, r);
      return AgentActionPreview(
        summary: '拒绝：${_requestWord(r)}',
        changes: [change('授权', '待批准', '已拒绝')],
      );
    },
    run: (w, args, env) async {
      final r = await _request(w, args);
      _mayManageApps(w, r);
      await w.client.post('/integrations/requests/${r['id']}/deny');
      return actionResult('已拒绝：${_requestWord(r)}');
    },
  ),
];
