import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import 'action_support.dart';
import 'agent_capability.dart';
import 'capability_support.dart';
import 'message_capabilities.dart' show senderByRef;

/// Channels: mute and pin (what the sidebar menu does), create a channel with
/// its first members, add members. Leaving and archiving a channel stay pages
/// to go to (see open_page_capabilities.dart).

// ---- mute ------------------------------------------------------------------

/// Source `canToggleActivityMute`: channels the person has joined (never DMs
/// or threads).
bool _canMute(RaftChannel c) =>
    c.joined && const {'channel', 'private', 'joint'}.contains(c.type);

RaftChannel _mutable(WorkspaceController w, String ref) {
  final c = channelByRef(w, ref);
  if (c.type == 'dm') {
    throw const AgentCapabilityError('私信不能静音（静音只管频道在动态里的提醒）');
  }
  if (c.archived) throw AgentCapabilityError('${channelWord(c)} 已归档');
  if (!_canMute(c)) {
    throw AgentCapabilityError('你还没有加入 ${channelWord(c)}，加入之后才能静音');
  }
  return c;
}

Future<void> _setMute(WorkspaceController w, RaftChannel c, bool muted) async {
  final previous = {
    'activityMuted': c.flag('activityMuted'),
    'muteFromSeq': c.json['muteFromSeq'],
    'prefsVersion': c.json['prefsVersion'],
  };
  w.setActivityMuteState(c.id, {...previous, 'activityMuted': muted});
  try {
    final reply = await w.command(
      'PATCH',
      '/channels/${c.id}/notification-settings',
      data: {'activityMuted': muted},
    );
    if (reply is Map) {
      w.setActivityMuteState(c.id, {
        'activityMuted': reply['activityMuted'] == true,
        'muteFromSeq': reply['muteFromSeq'],
        'prefsVersion': reply['prefsVersion'],
      });
    }
  } on Object {
    final held = w.channelById(c.id);
    if (held != null && held.flag('activityMuted') == muted) {
      w.setActivityMuteState(c.id, previous);
    }
    rethrow;
  }
}

// ---- pin ----------------------------------------------------------------------

List<Map<String, dynamic>> _maps(Object? value) => [
  for (final e in (value as List? ?? const []))
    if (e is Map) Map<String, dynamic>.from(e),
];

bool _same(Map<String, dynamic> p, String kind, String id) =>
    p['kind'] == kind && p['id'] == id;

/// How the sidebar refers to the row when pinned: a human DM pins as `human`,
/// an agent DM as `agent`, a channel as `channel`.
(String, String) _pinRef(RaftChannel c) {
  if (c.type != 'dm') return ('channel', c.id);
  final peer = c.string('peerId');
  return c.string('peerType') == 'agent' ? ('agent', peer) : ('human', peer);
}

bool _pinned(WorkspaceController w, RaftChannel c) {
  final ref = _pinRef(c);
  return _maps(w.sidebarOrder['pinned']).any((p) => _same(p, ref.$1, ref.$2));
}

Future<void> _ensureSidebar(WorkspaceController w) async {
  if (w.sidebarOrder.isNotEmpty) return;
  await w.loadSidebar();
  if (w.sidebarOrder.isEmpty) {
    throw const AgentCapabilityError('现在读不到侧栏的置顶设置，稍后再试');
  }
}

/// Sidebar.tsx `togglePinnedRef`: pinning appends the ref and drops the row's
/// custom-section placements; `sectionPlacements` goes only when one dropped.
Future<void> _setPinned(
  WorkspaceController w,
  RaftChannel c,
  bool pinned,
) async {
  await _ensureSidebar(w);
  final ref = _pinRef(c);
  final list = _maps(w.sidebarOrder['pinned']);
  final update = <String, dynamic>{};
  if (pinned) {
    update['pinned'] = [
      ...list,
      {'kind': ref.$1, 'id': ref.$2},
    ];
    final before = _maps(w.sidebarOrder['sectionPlacements']);
    final drop = [
      ('channel', c.id),
      if (ref.$1 == 'agent') ('agent', ref.$2),
    ];
    final after = [
      for (final p in before)
        if (!drop.any((d) => _same(p, d.$1, d.$2))) p,
    ];
    if (after.length != before.length) update['sectionPlacements'] = after;
  } else {
    update['pinned'] = [
      for (final p in list)
        if (!_same(p, ref.$1, ref.$2)) p,
    ];
  }
  await w.updateSidebarOrder(update);
  // The sidebar write rolls itself back on a failure and does not throw.
  if (_pinned(w, c) != pinned) {
    throw const AgentCapabilityError('服务器没有接受这次置顶设置，已经恢复原样');
  }
}

// ---- create / add members ------------------------------------------------------

final _nameRule = RegExp(r'^\p{L}[\p{L}\p{N}_-]*$', unicode: true);

/// The channel-name rule of the Create Channel dialog.
String? channelNameProblem(String name) {
  if (name.isEmpty) return '频道名不能为空';
  if (name.runes.length > 32) return '频道名最长 32 个字符';
  if (!_nameRule.hasMatch(name)) {
    return '频道名要以字母开头，后面是字母、数字、- 或 _（不带 #，不能有空格）';
  }
  return null;
}

typedef _Person = ({String id, String type, String label});

Future<List<_Person>> _people(
  WorkspaceController w,
  Object? refs, {
  bool skipSelf = false,
}) async {
  final out = <_Person>[];
  for (final r in (refs as List? ?? const [])) {
    final s = await senderByRef(w, '$r');
    if (skipSelf && s.id == w.client.user?.id) continue;
    if (!out.any((o) => o.id == s.id && o.type == s.type)) {
      out.add((id: s.id, type: s.type, label: s.label));
    }
  }
  return out;
}

Map<String, Object?> _memberIds(List<_Person> people) => {
  'userIds': [
    for (final p in people)
      if (p.type == 'user') p.id,
  ],
  'agentIds': [
    for (final p in people)
      if (p.type == 'agent') p.id,
  ],
};

String _names(List<_Person> people) => people.map((p) => p.label).join('、');

final _membersArg = {
  'type': 'array',
  'description': '成员或 Agent 的名字',
  'items': {'type': 'string', 'maxLength': 80},
};

final channelActionCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'channels.set_muted',
    title: '静音一个频道（它在动态里不再提醒），或取消静音（muted 默认 true）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'PATCH /channels/:id/notification-settings',
    keywords: const [
      '静音',
      '静音这个频道',
      '别提醒这个频道',
      '取消静音',
      '解除静音',
      '频道免打扰',
      '屏蔽这个频道',
      'mute',
      'unmute',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('频道的 id 或名字（不带 #）'),
        'muted': boolArg('true 静音（默认）/ false 取消静音'),
      },
      required: const ['channel'],
    ),
    resultSummary: 'done, entity=channel, id',
    prepareUndo: (w, args, env) async {
      final c = _mutable(w, '${args['channel']}');
      final muted = args['muted'] != false;
      return AgentUndoPlan(
        label: muted ? '取消静音' : '重新静音',
        run: () async {
          await _setMute(w, c, !muted);
          return muted ? '已取消静音 ${channelWord(c)}' : '已重新静音 ${channelWord(c)}';
        },
      );
    },
    preview: (w, args, env) async {
      final c = _mutable(w, '${args['channel']}');
      final muted = args['muted'] != false;
      if (c.flag('activityMuted') == muted) {
        throw AgentCapabilityError('${channelWord(c)} 已经${muted ? '静音' : '没有静音'}了');
      }
      return AgentActionPreview(
        summary: '${muted ? '静音' : '取消静音'}${channelWord(c)}（只管动态里的提醒，消息照常收）',
        changes: [
          change('${channelWord(c)} 静音', muted ? '否' : '是', muted ? '是' : '否'),
        ],
        reversible: true,
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = _mutable(w, '${args['channel']}');
      final muted = args['muted'] != false;
      await _setMute(w, c, muted);
      return actionResult(
        muted ? '已静音 ${channelWord(c)}' : '已取消静音 ${channelWord(c)}',
        entity: 'channel',
        id: c.id,
      );
    },
  ),
  AgentCapability(
    id: 'channels.set_pinned',
    title: '把一个频道或私信置顶到侧栏，或取消置顶（pinned 默认 true）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'PATCH /servers/:id/sidebar-order',
    keywords: const [
      '置顶',
      '置顶这个频道',
      '钉在上面',
      '固定在侧栏',
      '取消置顶',
      '不置顶了',
      'pin',
      'unpin',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('频道或私信的 id / 名字'),
        'pinned': boolArg('true 置顶（默认）/ false 取消置顶'),
      },
      required: const ['channel'],
    ),
    resultSummary: 'done, entity=channel, id',
    prepareUndo: (w, args, env) async {
      final c = channelByRef(w, '${args['channel']}');
      final pinned = args['pinned'] != false;
      return AgentUndoPlan(
        label: pinned ? '取消置顶' : '重新置顶',
        run: () async {
          await _setPinned(w, c, !pinned);
          return pinned ? '已取消置顶 ${channelWord(c)}' : '已重新置顶 ${channelWord(c)}';
        },
      );
    },
    preview: (w, args, env) async {
      final c = channelByRef(w, '${args['channel']}');
      if (c.archived) throw AgentCapabilityError('${channelWord(c)} 已归档');
      final pinned = args['pinned'] != false;
      await _ensureSidebar(w);
      final now = _pinned(w, c);
      if (now == pinned) {
        throw AgentCapabilityError('${channelWord(c)} 已经${pinned ? '置顶' : '没有置顶'}了');
      }
      return AgentActionPreview(
        summary: '${pinned ? '置顶' : '取消置顶'}${channelWord(c)}',
        changes: [
          change('${channelWord(c)} 置顶', now ? '是' : '否', pinned ? '是' : '否'),
        ],
        reversible: true,
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = channelByRef(w, '${args['channel']}');
      final pinned = args['pinned'] != false;
      await _setPinned(w, c, pinned);
      return actionResult(
        pinned ? '已置顶 ${channelWord(c)}' : '已取消置顶 ${channelWord(c)}',
        entity: 'channel',
        id: c.id,
      );
    },
  ),
  AgentCapability(
    id: 'channels.create',
    title: '新建一个频道（公开或私有），可同时拉进成员和 Agent；建好之后不能撤销（要归档得去页面）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels',
    keywords: const [
      '建频道',
      '新建频道',
      '创建频道',
      '开个频道',
      '建个群',
      '加个频道',
      '拉人进新频道',
      'create channel',
    ],
    paramsSchema: objectSchema(
      {
        'name': strArg('频道名：字母开头，字母数字 - _，不带 #，最长 32', max: 40),
        'description': strArg('简介，可省略', max: 500),
        'visibility': strArg(
          'public 公开（默认）/ private 私有',
          values: const ['public', 'private'],
        ),
        'members': _membersArg,
      },
      required: const ['name'],
    ),
    resultSummary: 'done, entity=channel, id',
    preview: (w, args, env) async {
      final name = '${args['name']}'.replaceFirst(RegExp(r'^#'), '');
      await _createCheck(w, name);
      final people = await _people(w, args['members'], skipSelf: true);
      final visibility = '${args['visibility'] ?? 'public'}';
      return AgentActionPreview(
        summary:
            '新建${visibility == 'private' ? '私有' : '公开'}频道 #$name${people.isEmpty ? '' : '，拉进 ${_names(people)}'}',
        changes: [
          change('频道', '', '#$name'),
          change('可见性', '', visibility == 'private' ? '私有' : '公开'),
          if (text(args['description']) != null)
            change('简介', '', quote('${args['description']}', 40)),
          if (people.isNotEmpty) change('成员', '', _names(people)),
        ],
      );
    },
    run: (w, args, env) async {
      final name = '${args['name']}'.replaceFirst(RegExp(r'^#'), '');
      await _createCheck(w, name);
      final people = await _people(w, args['members'], skipSelf: true);
      final result = await w.command(
        'POST',
        '/channels',
        data: {
          'name': name,
          if (text(args['description']) != null)
            'description': '${args['description']}',
          'visibility': '${args['visibility'] ?? 'public'}',
          'type': 'channel',
          ..._memberIds(people),
        },
      );
      await w.refreshChannels();
      final id = result is Map && result['id'] is String
          ? result['id'] as String
          : null;
      return actionResult(
        '已新建 #$name${people.isEmpty ? '' : '，拉进了 ${_names(people)}'}',
        entity: id == null ? null : 'channel',
        id: id,
      );
    },
  ),
  AgentCapability(
    id: 'channels.add_members',
    title: '把成员或 Agent 加进一个已有的频道',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels/:id/members/batch',
    keywords: const [
      '拉进频道',
      '加到频道',
      '拉他进来',
      '邀请进频道',
      '把他加进',
      '加成员',
      '频道加人',
      '拉进来',
      'add member',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('频道的 id 或名字（不带 #）'),
        'members': _membersArg,
      },
      required: const ['channel', 'members'],
    ),
    resultSummary: 'done, entity=channel, id',
    prepareUndo: (w, args, env) async {
      final c = await _addable(w, '${args['channel']}');
      final fresh = await _newPeople(w, c, args['members']);
      if (!w.can('removeChannelMembers', resource: c)) return null;
      return AgentUndoPlan(
        label: '把 ${_names(fresh)} 移出 #${c.name}',
        run: () async {
          for (final p in fresh) {
            await w.command(
              'DELETE',
              '/channels/${c.id}/members/${p.type == 'agent' ? 'agent' : 'user'}/${p.id}',
            );
          }
          return '已把 ${_names(fresh)} 移出 #${c.name}';
        },
      );
    },
    preview: (w, args, env) async {
      final c = await _addable(w, '${args['channel']}');
      final fresh = await _newPeople(w, c, args['members']);
      return AgentActionPreview(
        summary: '把 ${_names(fresh)} 加进 #${c.name}',
        changes: [change('#${c.name} 成员', '', '加入 ${_names(fresh)}')],
        reversible: w.can('removeChannelMembers', resource: c),
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = await _addable(w, '${args['channel']}');
      final fresh = await _newPeople(w, c, args['members']);
      await w.command(
        'POST',
        '/channels/${c.id}/members/batch',
        data: _memberIds(fresh),
      );
      await w.refreshChannels();
      return actionResult(
        '已把 ${_names(fresh)} 加进 #${c.name}',
        entity: 'channel',
        id: c.id,
      );
    },
  ),
];

Future<void> _createCheck(WorkspaceController w, String name) async {
  if (!w.can('createChannels')) {
    throw const AgentCapabilityError('你没有创建频道的权限');
  }
  final problem = channelNameProblem(name);
  if (problem != null) throw AgentCapabilityError(problem);
  final clash = w.channels
      .where((c) => c.name.toLowerCase() == name.toLowerCase())
      .firstOrNull;
  if (clash != null) {
    throw AgentCapabilityError(
      clash.archived
          ? '已经有一个归档的 #${clash.name}：要在服务器设置里取消归档，或换个名字'
          : '已经有叫 #${clash.name} 的频道了',
    );
  }
}

Future<RaftChannel> _addable(WorkspaceController w, String ref) async {
  final c = channelByRef(w, ref);
  if (c.type == 'dm') throw const AgentCapabilityError('私信里不能加成员');
  if (c.archived) throw AgentCapabilityError('#${c.name} 已归档');
  if (!w.can('addChannelMembers', resource: c)) {
    throw AgentCapabilityError('你没有给 #${c.name} 加成员的权限');
  }
  return c;
}

/// The people asked for who are not in [c] yet.
Future<List<_Person>> _newPeople(
  WorkspaceController w,
  RaftChannel c,
  Object? refs,
) async {
  final people = await _people(w, refs);
  if (people.isEmpty) throw const AgentCapabilityError('需要 members：要加谁');
  final roster = await w.query('/channels/${c.id}/members');
  final inside = {
    for (final h in rowsOf(roster, const ['humans']))
      'user:${h['userId'] ?? h['id']}',
    for (final a in rowsOf(roster, const ['agents'])) 'agent:${a['id']}',
  };
  final fresh = [
    for (final p in people)
      if (!inside.contains('${p.type}:${p.id}')) p,
  ];
  if (fresh.isEmpty) {
    throw AgentCapabilityError('${_names(people)} 已经在 #${c.name} 里了');
  }
  return fresh;
}
