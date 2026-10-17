import '../../../data/workspace_controller.dart';
import '../../../data/workspace_entity_directory.dart';
import '../../resource_filters.dart';
import '../../agent_metadata_projection.dart' show agentRowName;
import 'agent_capability.dart';
import 'capability_support.dart';

/// Message search, a message in context, and Saved.

/// A person or Agent by name or id, from the entity directory the app
/// already holds. Throws with candidates when the name fits several.
Future<ResourceSender> senderByRef(
  WorkspaceController w,
  String ref, {
  String? type,
}) async {
  final want = ref.trim().toLowerCase();
  final found = <ResourceSender>[];
  void add(String id, String type, String label, String handle) {
    if (id.isEmpty) return;
    found.add(ResourceSender(id, type, label, handle: handle));
  }

  if (type != 'agent') {
    for (final m in await directoryRows(w, WorkspaceEntityKind.members)) {
      add(
        '${m['userId'] ?? m['id'] ?? ''}',
        'user',
        '${m['displayName'] ?? m['name'] ?? ''}',
        '${m['name'] ?? ''}',
      );
    }
  }
  if (type != 'user') {
    for (final a in await directoryRows(w, WorkspaceEntityKind.agents)) {
      add('${a['id'] ?? ''}', 'agent', agentRowName(a), '${a['name'] ?? ''}');
    }
  }
  bool eq(ResourceSender s) =>
      s.id == ref.trim() ||
      s.label.toLowerCase() == want ||
      s.handle.toLowerCase() == want;
  var hits = found.where(eq).toList();
  if (hits.isEmpty) {
    hits = found
        .where(
          (s) =>
              s.label.toLowerCase().contains(want) ||
              s.handle.toLowerCase().contains(want),
        )
        .toList();
  }
  if (hits.length == 1) return hits.single;
  if (hits.isEmpty) throw AgentCapabilityError('没有叫“$ref”的成员或 Agent');
  throw AgentCapabilityError(
    '“$ref”对得上多个人，请问用户是哪一个',
    candidates: [
      for (final s in hits.take(6))
        {'id': s.id, 'type': s.type, 'name': s.label},
    ],
  );
}

String _day(String raw, {bool end = false}) {
  final at = DateTime.tryParse(raw);
  if (at == null) {
    throw AgentCapabilityError(
      '时间“$raw”看不懂，请用 2026-10-15 或 2026-10-15T08:00:00 这样的写法',
    );
  }
  final day = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw);
  final local = day && end ? at.add(const Duration(days: 1)) : at;
  return DateTime.fromMillisecondsSinceEpoch(
    (day ? DateTime(local.year, local.month, local.day) : local)
        .millisecondsSinceEpoch,
    isUtc: true,
  ).toIso8601String();
}

Map<String, Object?> _savedRow(Map<String, dynamic> r) => compact({
  'id': r['messageId'] ?? r['id'],
  'channelId': r['channelId'],
  'channel': r['channelName'],
  'from': r['senderDisplayName'] ?? r['senderName'],
  'time': stamp(r['createdAt']),
  'text': clip(r['content'] ?? r['preview'], 240),
});

final messageCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'messages.search',
    title: '在整个工作区搜消息：关键词，可按频道、发送人、人/Agent、时间范围、是否提到我、是否带图片或文件过滤',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /messages/search',
    keywords: const [
      '搜索',
      '搜消息',
      '找消息',
      '查消息',
      '谁说过',
      '说过什么',
      '聊过',
      '有没有提到',
      '搜一下',
      '找一下',
      '历史消息',
      '某个人说的',
      '昨天的消息',
      '这周的消息',
      '带图片的消息',
      '带文件的消息',
      '某人发的图片',
      'search',
    ],
    paramsSchema: objectSchema({
      'q': strArg('关键词，可省略（只按过滤条件找）'),
      'channel': strArg('限定频道（id 或名字）'),
      'sender': strArg('限定发送人（成员或 Agent 的名字或 id）'),
      'senderType': strArg(
        '只看 user 人类 / agent',
        values: const ['user', 'agent'],
      ),
      'mentionedMe': boolArg('只看提到我的'),
      'attachment': strArg(
        '只看带附件的消息：image 带图片的 / file 带文件（非图片）的；与 sender 一起用就是“某人发的图 / 文件”',
        values: const ['image', 'file'],
      ),
      'within': strArg(
        '最近多久：today 今天 / 7d / 30d',
        values: const ['today', '7d', '30d'],
      ),
      'after': strArg('起始时间，如 2026-10-15，与 within 二选一', max: 40),
      'before': strArg('截止时间，如 2026-10-16', max: 40),
      'sort': strArg(
        'relevance 相关度 / recent 最新',
        values: const ['relevance', 'recent'],
      ),
      'limit': intArg('几条，默认 10', min: 1, max: 20, dflt: 10),
      'offset': intArg('跳过几条，翻页用', min: 0, max: 500, dflt: 0),
    }),
    resultSummary: 'messages[{id,channelId,channel,from,senderId,time,text,threadId}], hasMore',
    run: (w, args, env) async {
      final filters = ResourceFilters();
      final channel = text(args['channel']);
      if (channel != null) filters.channelId = channelByRef(w, channel).id;
      final sender = text(args['sender']);
      final type = text(args['senderType']);
      if (type != null) {
        filters.scopes.add(type == 'agent' ? 'agents' : 'humans');
      }
      if (sender != null) {
        filters.selectSender(await senderByRef(w, sender, type: type));
      }
      if (args['mentionedMe'] == true) filters.scopes.add('mentioned');
      filters.timeRange = text(args['within']) ?? 'any';
      if (args['sort'] == 'recent') filters.searchSort = 'recent';
      final params = filters.search(
        '${args['q'] ?? ''}',
        offset: (args['offset'] as int?) ?? 0,
      );
      if (params == null) {
        throw const AgentCapabilityError('需要关键词 q，或至少一个过滤条件（频道、发送人、时间）');
      }
      final attachment = text(args['attachment']);
      // The filter is applied here, so read the most a page gives.
      params['limit'] = attachment == null ? limitOf(args) : 20;
      final after = text(args['after']), before = text(args['before']);
      if (after != null) params['after'] = _day(after);
      if (before != null) params['before'] = _day(before, end: true);
      final body = await w.query('/messages/search', query: params);
      var rows = rowsOf(body, const ['results']);
      if (attachment != null) {
        // The search has no file-type filter of its own: keep the rows whose
        // files fit. A reply that carries no file information at all cannot
        // be filtered, and saying "none" would be false.
        if (rows.isNotEmpty && !rows.any((m) => m.containsKey('attachments'))) {
          throw const AgentCapabilityError(
            '这次搜索的结果里没有附件信息，按图片 / 文件筛不了：改用 channels.files 看某个频道的文件',
          );
        }
        bool image(Object? a) =>
            a is Map && '${a['mimeType']}'.toLowerCase().startsWith('image/');
        rows = [
          for (final m in rows)
            if (m['attachments'] is List &&
                (m['attachments'] as List).any(
                  (a) =>
                      attachment == 'image' ? image(a) : a is Map && !image(a),
                ))
              m,
        ].take(limitOf(args)).toList();
      }
      for (final m in rows) {
        env.facts?.learnMessage(
          '${m['senderDisplayName'] ?? m['senderName'] ?? ''}',
          '${m['content'] ?? ''}',
          id: m['id'] is String ? m['id'] as String : null,
        );
      }
      return compact({
        'count': rows.length,
        'hasMore': body is Map ? body['hasMore'] : null,
        'filteredBy': attachment == null
            ? null
            : '带${attachment == 'image' ? '图片' : '文件'}的消息（在搜索结果里筛的，可能漏掉更早的）',
        'messages': [for (final m in rows) messageRow(m)],
      });
    },
  ),
  AgentCapability(
    id: 'messages.context',
    title: '打开某条消息和它前后的几条（要看一条消息的上下文时用）',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /messages/context/:id',
    keywords: const ['消息上下文', '这条消息前后', '这条消息的来龙去脉', '前后文', '上下文', '这条消息是在聊什么'],
    paramsSchema: objectSchema(
      {
        'messageId': strArg('消息 id', max: 80),
        'channel': strArg('消息所在频道 id，已知时带上'),
      },
      required: const ['messageId'],
    ),
    resultSummary: 'target 消息 id，messages[{id,from,time,text,seq}] 旧到新',
    run: (w, args, env) async {
      final channel = text(args['channel']);
      final body = await w.client.get(
        '/messages/context/${args['messageId']}',
        query: {
          'channelId': ?(channel == null ? null : channelByRef(w, channel).id),
        },
      );
      final rows = rowsOf(body, const ['messages']);
      if (rows.isEmpty) {
        throw const AgentCapabilityError('这条消息读不到（可能已删除，或没有权限）');
      }
      return compact({
        'target': body is Map
            ? body['targetMessageId'] ?? args['messageId']
            : null,
        'messages': [for (final m in rows.take(15)) messageRow(m)],
      });
    },
  ),
  AgentCapability(
    id: 'saved.list',
    title: '我收藏（Saved）的消息，可按关键词、频道筛',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/saved',
    keywords: const ['收藏', '已保存', '保存的消息', 'saved', '我存的', '书签', '稍后看', '收藏夹'],
    paramsSchema: objectSchema({
      'q': strArg('关键词，可省略'),
      'channel': strArg('只看这个频道（id 或名字）'),
      'limit': intArg('几条，默认 10', min: 1, max: 20, dflt: 10),
      'offset': intArg('跳过几条，翻页用', min: 0, max: 500, dflt: 0),
    }),
    resultSummary:
        'saved[{id(消息 id),channelId,channel,from,time,text}], total, hasMore',
    run: (w, args, env) async {
      final filters = ResourceFilters();
      final channel = text(args['channel']);
      if (channel != null) filters.channelId = channelByRef(w, channel).id;
      final limit = limitOf(args, dflt: 10, max: 20);
      final body = await w.query(
        '/channels/saved',
        query: filters.list(
          '${args['q'] ?? ''}',
          offset: (args['offset'] as int?) ?? 0,
          limit: limit,
        ),
      );
      final rows = rowsOf(body, const ['saved', 'items']);
      return compact({
        'count': rows.length,
        'total': body is Map ? body['total'] : null,
        'hasMore': body is Map ? body['hasMore'] : null,
        'saved': [for (final r in rows.take(limit)) _savedRow(r)],
      });
    },
  ),
];
