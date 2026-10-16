import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart' show raftTaskTransitions;

import '../../../data/workspace_controller.dart';
import '../../../data/workspace_entity_directory.dart';
import 'agent_capability.dart';
import 'capability_support.dart';

/// Shared by the operations: finding the thing a call is about, wording a
/// change, and the checks the pages make before they offer the same action.

const taskStatusWords = {
  'todo': '待办',
  'in_progress': '进行中',
  'in_review': '等验收',
  'done': '已完成',
  'closed': '已关闭',
};

String statusWord(Object? status) => taskStatusWords['$status'] ?? '$status';

/// One line of a confirm card: `字段: 原值 → 新值`. Newlines and the arrow
/// itself are kept out of the values so the card can split the line again.
String change(String field, String? from, String to) {
  String one(String v) =>
      v.replaceAll(RegExp(r'\s+'), ' ').replaceAll('→', '›').trim();
  return '$field: ${one(from ?? '')} → ${one(to)}';
}

/// "#general", "私信 Ada".
String channelWord(RaftChannel c) =>
    c.type == 'dm' ? '私信 ${c.peerLabel}' : '#${c.name}';

/// The person reads a message in one line.
String quote(String text, [int max = 40]) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max)}…';
}

/// The channel a message may be sent to, or why not.
RaftChannel sendableChannel(WorkspaceController w, String ref) {
  final c = channelByRef(w, ref);
  if (c.archived) throw AgentCapabilityError('${channelWord(c)} 已归档，不能发消息');
  if (c.json['readOnlyReason'] != null) {
    throw AgentCapabilityError('${channelWord(c)} 是只读的，不能发消息');
  }
  if (!c.joined) {
    throw AgentCapabilityError(
      '你还没有加入 ${channelWord(c)}：先加入它（join_channel）再发消息',
    );
  }
  if (w.server?.string('role') == 'guest') {
    throw const AgentCapabilityError('访客不能发消息');
  }
  return c;
}

/// A message by id: the windows the app holds first, then the read the
/// entity cards use. Throws when it cannot be read.
Future<RaftMessage> messageById(
  WorkspaceController w,
  String id, {
  String? channelRef,
}) async {
  final want = id.trim();
  final hint = channelRef == null ? null : channelByRef(w, channelRef).id;
  for (final c in [...w.channels, ...w.dms, ?w.channel]) {
    final row = w.ledger.message(c.id, want);
    if (row != null) return RaftMessage(row);
  }
  final thread = w.threadChannelId;
  final held = thread == null ? null : w.ledger.message(thread, want);
  if (held != null) return RaftMessage(held);
  final body = await w.query(
    '/messages/context/${Uri.encodeComponent(want)}',
    query: {'channelId': ?hint},
  );
  final hit = rowsOf(body, const [
    'messages',
  ]).where((m) => m['id'] == want).firstOrNull;
  if (hit == null) {
    throw AgentCapabilityError('没有找到消息 $want（id 要取自读取工具或 resolve 的结果）');
  }
  return RaftMessage(hit);
}

/// What `w.send` made, found again by the random id it was given.
String? sentMessageId(
  WorkspaceController w,
  String channelId,
  String randomId,
) {
  final rows = w.ledger.messages(channelId);
  for (final m in rows.reversed) {
    if (m['randomId'] == randomId && m['id'] is String) {
      final id = m['id'] as String;
      return id.startsWith('optimistic-') ? null : id;
    }
  }
  return null;
}

/// People and Agents a text may mention, by what follows the `@`.
Future<({String text, List<Map<String, dynamic>> mentions})> mentionsIn(
  WorkspaceController w,
  String text,
) async {
  final tokens = {
    for (final m in RegExp(r'@([\w.\-一-龥]+)').allMatches(text)) m.group(1)!,
  };
  if (tokens.isEmpty) return (text: text, mentions: <Map<String, dynamic>>[]);
  final people = <({String type, String id, String handle, String label})>[];
  for (final m in await directoryRows(w, WorkspaceEntityKind.members)) {
    final id = '${m['userId'] ?? m['id'] ?? ''}';
    final handle = '${m['name'] ?? ''}';
    if (id.isNotEmpty && handle.isNotEmpty) {
      people.add((
        type: 'user',
        id: id,
        handle: handle,
        label: '${m['displayName'] ?? handle}',
      ));
    }
  }
  for (final a in await directoryRows(w, WorkspaceEntityKind.agents)) {
    final id = '${a['id'] ?? ''}';
    final handle = '${a['name'] ?? ''}';
    if (id.isNotEmpty && handle.isNotEmpty && a['deletedAt'] == null) {
      people.add((
        type: 'agent',
        id: id,
        handle: handle,
        label: '${a['displayName'] ?? handle}',
      ));
    }
  }
  var out = text;
  final mentions = <Map<String, dynamic>>[];
  for (final t in tokens) {
    final want = t.toLowerCase();
    final hits = people
        .where(
          (p) =>
              p.handle.toLowerCase() == want || p.label.toLowerCase() == want,
        )
        .toList();
    if (hits.length != 1) continue;
    final p = hits.single;
    if (mentions.any((m) => m['id'] == p.id)) continue;
    mentions.add({'type': p.type, 'id': p.id, 'name': p.handle});
    if (p.handle != t) out = out.replaceAll('@$t', '@${p.handle}');
  }
  return (text: out, mentions: mentions);
}

/// Whether the person may move the task to [next] the way the board does:
/// owners and admins any status, members the legal transitions.
bool canMoveTaskTo(
  WorkspaceController w,
  Map<String, dynamic> task,
  String next,
) {
  final role = w.server?.string('role');
  if (role == 'guest') return false;
  if (task['readOnlyReason'] != null) return false;
  if (task['status'] == next) return false;
  if (!w.channels.any(
    (c) => c.id == task['channelId'] && c.joined && !c.archived,
  )) {
    return false;
  }
  return const ['owner', 'admin'].contains(role) ||
      (raftTaskTransitions['${task['status']}'] ?? const []).contains(next);
}

/// A task by id or number: the server board first, then the full row (it
/// carries the revision an assignee change must quote).
Future<Map<String, dynamic>> taskFor(
  WorkspaceController w,
  AgentCapabilityEnv env,
  Map<String, Object?> args,
) async {
  final ref = (text(args['task']) ?? '').replaceAll(RegExp(r'^#'), '').trim();
  if (ref.isEmpty) throw const AgentCapabilityError('需要 task：任务 id 或编号');
  final channel = text(args['channel'])?.replaceAll('#', '').toLowerCase();
  final rows = await env.dataFor(w).searchTasks('');
  var hits = rows.where((t) => '${t['id']}' == ref).toList();
  if (hits.isEmpty) {
    final number = int.tryParse(ref);
    if (number != null) {
      hits = rows
          .where(
            (t) =>
                t['taskNumber'] == number &&
                (channel == null ||
                    '${t['channelName']}'.toLowerCase() == channel),
          )
          .toList();
    }
  }
  final seen = <String>{};
  hits = [
    for (final t in hits)
      if (seen.add('${t['id']}')) t,
  ];
  if (hits.isEmpty) throw AgentCapabilityError('没有找到任务 $ref');
  if (hits.length > 1) {
    throw AgentCapabilityError(
      '多个频道都有任务 #$ref，请问用户是哪个频道的',
      candidates: [
        for (final t in hits.take(6))
          {
            'taskId': t['id'],
            'channel': t['channelName'],
            'title': clip(t['title'], 60),
          },
      ],
    );
  }
  var task = hits.single;
  try {
    final full = await w.query(
      '/tasks/channel/${task['channelId']}/number/${task['taskNumber']}',
    );
    if (full is Map && full['task'] is Map) {
      task = {...task, ...Map<String, dynamic>.from(full['task'] as Map)};
    }
  } on Object {
    // The board row has what the preview needs.
  }
  return task;
}

String taskWord(Map<String, dynamic> t) =>
    '#${t['taskNumber']} ${clip(t['title'], 40)}';

/// The members and Agents of the task's channel, as the assignee picker
/// lists them.
Future<List<Map<String, dynamic>>> assignableOf(
  WorkspaceController w,
  Map<String, dynamic> task,
) async {
  final people = await w.query('/channels/${task['channelId']}/members');
  return [
    for (final type in ['user', 'agent'])
      for (final raw in rowsOf(people, [type == 'user' ? 'humans' : 'agents']))
        if ('${raw['userId'] ?? raw['id'] ?? ''}'.isNotEmpty)
          {...raw, 'actorType': type},
  ];
}

Map<String, dynamic> assigneePatch(Map<String, dynamic>? who) => {
  'assignee': who == null
      ? null
      : {'type': who['actorType'], 'id': who['userId'] ?? who['id']},
};

String personWord(Map<String, dynamic> p) =>
    '${p['displayName'] ?? p['name'] ?? p['userId'] ?? p['id']}';

/// The one person or Agent [ref] means among [people].
Map<String, dynamic> pickPerson(List<Map<String, dynamic>> people, String ref) {
  final want = ref.trim().replaceAll('@', '').toLowerCase();
  bool is_(Map<String, dynamic> p, bool exact) {
    final ids = '${p['userId'] ?? p['id']}'.toLowerCase();
    final names = [
      '${p['name'] ?? ''}'.toLowerCase(),
      '${p['displayName'] ?? ''}'.toLowerCase(),
    ];
    return ids == want ||
        (exact
            ? names.contains(want)
            : names.any((n) => n.isNotEmpty && n.contains(want)));
  }

  var hits = people.where((p) => is_(p, true)).toList();
  if (hits.isEmpty) hits = people.where((p) => is_(p, false)).toList();
  if (hits.length == 1) return hits.single;
  if (hits.isEmpty) {
    throw AgentCapabilityError('这个任务所在的频道里没有叫“$ref”的成员或 Agent');
  }
  throw AgentCapabilityError(
    '“$ref”对得上多个人，请问用户是哪一个',
    candidates: [
      for (final p in hits.take(6))
        {
          'id': p['userId'] ?? p['id'],
          'type': p['actorType'],
          'name': personWord(p),
        },
    ],
  );
}

/// The result of an operation: what the card says, and what it made or
/// changed (an `EntityCard` kind and id).
Map<String, Object?> actionResult(
  String done, {
  String? entity,
  String? id,
  Map<String, Object?> extra = const {},
}) => {'done': done, 'entity': ?entity, 'id': ?id, ...extra};
