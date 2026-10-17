import '../../../data/workspace_controller.dart';
import '../../resource_filters.dart';
import 'agent_capability.dart';
import 'action_support.dart' show messageById;
import 'capability_support.dart';
import 'message_capabilities.dart' show senderByRef;

/// Channels, DMs, threads, unread and the Activity inbox.

Map<String, Object?> _activityRow(Map<String, dynamic> r) {
  final thread = r['kind'] == 'thread';
  return compact({
    'kind': r['kind'],
    'channelId': thread ? r['parentChannelId'] : r['channelId'],
    'channel': thread ? r['parentChannelName'] : r['channelName'],
    'threadId': thread ? r['threadChannelId'] : null,
    'parentMessageId': r['parentMessageId'],
    'from': thread ? r['latestActivitySenderName'] : r['lastMessageSenderName'],
    'text': clip(
      thread
          ? r['latestActivityPreview'] ?? r['parentMessagePreview']
          : r['lastMessagePreview'],
      160,
    ),
    'time': stamp(r['lastMessageAt'] ?? r['latestActivityAt']),
    'unread': (r['unreadCount'] ?? 0) == 0 ? null : r['unreadCount'],
    'mention': r['hasMention'] == true ? true : null,
  });
}

Future<Map<String, Object?>> _inbox(
  AgentCapabilityEnv env,
  WorkspaceController w,
  Map<String, Object?> args,
  String filter, {
  String path = '/channels/inbox',
}) async {
  final filters = ResourceFilters();
  final ref = text(args['channel']);
  if (ref != null) filters.channelId = channelByRef(w, ref).id;
  final limit = limitOf(args, dflt: 15);
  final params = filters.list(
    '${args['q'] ?? ''}',
    offset: (args['offset'] as int?) ?? 0,
    limit: limit,
    filter: path == '/channels/inbox' ? filter : null,
  );
  final body = await w.sharedQuery(path, query: params);
  final rows = rowsOf(body, const ['items']);
  return compact({
    'filter': filter,
    'count': rows.length,
    'totalUnread': body is Map ? body['totalUnreadCount'] : null,
    'total': body is Map ? body['totalCount'] : null,
    'hasMore': body is Map ? body['hasMore'] : null,
    'items': [for (final r in rows.take(limit)) _activityRow(r)],
  });
}

Map<String, Object?> _messagePage(
  AgentCapabilityEnv env,
  Map<String, dynamic> page,
  int limit,
) {
  final rows = rowsOf(page, const ['messages']);
  BigInt seq(Map m) => BigInt.tryParse('${m['seq']}') ?? BigInt.zero;
  rows.sort((a, b) => seq(a).compareTo(seq(b)));
  final shown = rows.length > limit ? rows.sublist(rows.length - limit) : rows;
  for (final m in shown) {
    env.facts?.learnMessage(
      '${m['senderDisplayName'] ?? m['senderName'] ?? ''}',
      '${m['content'] ?? ''}',
      id: m['id'] is String ? m['id'] as String : null,
    );
  }
  return compact({
    'count': shown.length,
    'hasMore': page['hasMore'],
    'olderThanSeq': shown.isEmpty ? null : '${shown.first['seq']}',
    'messages': [for (final m in shown) messageRow(m)],
  });
}

BigInt? _before(Map<String, Object?> args) =>
    BigInt.tryParse('${args['beforeSeq'] ?? ''}');

final channelCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'channels.list',
    title: '列出我能看到的频道（可按名字搜、只看有未读的），带未读数',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels',
    keywords: const [
      '频道列表',
      '有哪些频道',
      '所有频道',
      '频道',
      'channels',
      '哪些群',
      '有哪些群',
      '有未读的频道',
      '未读频道',
      '找频道',
      '搜频道',
    ],
    paramsSchema: objectSchema({
      'query': strArg('频道名里的字，可省略'),
      'unreadOnly': boolArg('只列有未读消息的'),
      'includeArchived': boolArg('包含已归档的，默认不含'),
      'limit': intArg('最多几个，默认 30', min: 1, max: 50, dflt: 30),
    }),
    resultSummary:
        'channels[{id,name,type,description,unread,mention}]，按名字排序，total 是总数',
    run: (w, args, env) async {
      final q = (text(args['query']) ?? '').toLowerCase();
      final rows = [
        for (final c in w.channels)
          if (c.name.isNotEmpty &&
              (args['includeArchived'] == true || !c.archived) &&
              (q.isEmpty || c.name.toLowerCase().contains(q)) &&
              (args['unreadOnly'] != true || (w.unread[c.id] ?? 0) > 0))
            c,
      ]..sort((a, b) => a.name.compareTo(b.name));
      final limit = limitOf(args, dflt: 30, max: 50);
      return {
        'total': rows.length,
        'channels': [for (final c in rows.take(limit)) channelRow(w, c)],
      };
    },
  ),
  AgentCapability(
    id: 'dms.list',
    title: '列出我的私信（和谁的对话），带未读数',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/dm',
    keywords: const ['私信', '私聊', 'DM', '和谁聊过', '私信列表', '直接消息'],
    paramsSchema: objectSchema({
      'query': strArg('对方名字里的字，可省略'),
      'limit': intArg('最多几个，默认 20', min: 1, max: 50, dflt: 20),
    }),
    resultSummary: 'dms[{id,name,unread}]，name 是对方',
    run: (w, args, env) async {
      final q = (text(args['query']) ?? '').toLowerCase();
      final rows = [
        for (final c in w.dms)
          if (q.isEmpty || c.peerLabel.toLowerCase().contains(q)) c,
      ];
      return {
        'total': rows.length,
        'dms': [
          for (final c in rows.take(limitOf(args, dflt: 20, max: 50)))
            channelRow(w, c),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'channels.detail',
    title: '看一个频道的基本信息：简介、类型、未读数、是否加入',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/:id',
    keywords: const ['频道详情', '频道信息', '频道简介', '这个频道是干什么的', '频道介绍'],
    paramsSchema: objectSchema(
      {'channel': strArg('频道 id 或名字（不带 #）')},
      required: const ['channel'],
    ),
    resultSummary: 'channel{id,name,type,description,unread,mention,archived}',
    run: (w, args, env) async => {
      'channel': channelRow(w, channelByRef(w, '${args['channel']}')),
    },
  ),
  AgentCapability(
    id: 'channels.recent_messages',
    title: '读一个频道（或私信）最近的消息，可往前翻',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /messages/channel/:id',
    keywords: const [
      '最近的消息',
      '聊了什么',
      '最新消息',
      '频道里说了什么',
      '读消息',
      '看消息',
      '频道消息',
      '往前翻',
      '更早的消息',
      '历史消息',
      '私信消息',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('频道或私信的 id / 名字'),
        'limit': intArg('几条，默认 15', min: 1, max: 30, dflt: 15),
        'beforeSeq': strArg('往前翻：上一次结果里的 olderThanSeq', max: 24),
      },
      required: const ['channel'],
    ),
    resultSummary: 'messages[{id,from,senderId,time,text,threadId,replyCount,seq}] 旧到新；hasMore 与 olderThanSeq 用来继续往前翻',
    run: (w, args, env) async {
      final channel = channelByRef(w, '${args['channel']}');
      final limit = limitOf(args, dflt: 15);
      final page = await w.client.messagePage(
        channel.id,
        before: _before(args),
        limit: limit,
      );
      return {
        'channel': channelRow(w, channel),
        ..._messagePage(env, page, limit),
      };
    },
  ),
  AgentCapability(
    id: 'threads.messages',
    title: '按消息串 id 读一个消息串里的回复',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /messages/channel/:id',
    keywords: const [
      '消息串',
      '讨论串',
      '串里的回复',
      '回复',
      'thread',
      '线程',
      '这条消息下面的讨论',
      '讨论内容',
    ],
    paramsSchema: objectSchema(
      {
        'threadId': strArg(
          '消息串 id（消息或任务里的 threadId / threadChannelId）',
          max: 80,
        ),
        'limit': intArg('几条，默认 15', min: 1, max: 30, dflt: 15),
        'beforeSeq': strArg('往前翻：上一次结果里的 olderThanSeq', max: 24),
      },
      required: const ['threadId'],
    ),
    resultSummary:
        'messages[{id,from,time,text,seq}] 旧到新；hasMore 与 olderThanSeq 用来往前翻',
    run: (w, args, env) async {
      final limit = limitOf(args, dflt: 15);
      final page = await w.client.messagePage(
        '${args['threadId']}',
        before: _before(args),
        limit: limit,
      );
      return {'threadId': args['threadId'], ..._messagePage(env, page, limit)};
    },
  ),
  AgentCapability(
    id: 'channels.members',
    title: '看一个频道里有哪些人和 Agent',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/:id/members',
    keywords: const ['频道成员', '频道里有谁', '谁在这个频道', '成员名单', '频道里的人', '频道里的agent'],
    paramsSchema: objectSchema(
      {'channel': strArg('频道 id 或名字')},
      required: const ['channel'],
    ),
    resultSummary: 'humans[{id,name,role}], agents[{id,name}]',
    run: (w, args, env) async {
      final channel = channelByRef(w, '${args['channel']}');
      final roster = await w.query('/channels/${channel.id}/members');
      Map<String, Object?> member(Map<String, dynamic> m) => compact({
        'id': m['userId'] ?? m['id'],
        'name': m['displayName'] ?? m['name'],
        'role': m['role'],
      });
      final humans = rowsOf(roster, const ['humans']);
      final agents = rowsOf(
        roster is Map ? {'a': roster['agents']} : null,
        const ['a'],
      );
      return {
        'channel': channel.name,
        'humans': [for (final m in humans.take(40)) member(m)],
        'agents': [for (final m in agents.take(40)) member(m)],
        if (humans.length > 40 || agents.length > 40) 'truncated': true,
      };
    },
  ),
  AgentCapability(
    id: 'inbox.unread_summary',
    title: '未读概况：一共多少未读、哪些频道有未读、哪些有人提到我',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/unread',
    keywords: const [
      '未读',
      '有多少未读',
      '未读消息',
      '有没有新消息',
      '谁找过我',
      '有什么新消息',
      '新消息',
      '没看的消息',
      '未读概况',
      '哪些频道有未读',
    ],
    paramsSchema: objectSchema({
      'refresh': boolArg('先向服务器刷新一次，默认用 App 已有的计数'),
      'limit': intArg('列几个频道，默认 12', min: 1, max: 30, dflt: 12),
    }),
    resultSummary: 'totalUnread, channelsWithUnread, mentionChannels, channels[{id,name,unread,mention}] 按未读多少排序',
    run: (w, args, env) async {
      if (args['refresh'] == true) await w.refreshUnread();
      final byId = {
        for (final c in [...w.channels, ...w.dms]) c.id: c,
      };
      final rows = [
        for (final e in w.unread.entries)
          if (e.value > 0 && byId.containsKey(e.key)) (byId[e.key]!, e.value),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return {
        'totalUnread': rows.fold<int>(0, (a, r) => a + r.$2),
        'channelsWithUnread': rows.length,
        'mentionChannels': rows
            .where((r) => w.mentions.contains(r.$1.id))
            .length,
        'channels': [
          for (final r in rows.take(limitOf(args, dflt: 12)))
            channelRow(w, r.$1),
        ],
      };
    },
  ),
  AgentCapability(
    id: 'activity.inbox',
    title: '动态（Activity）列表：最近有动静的频道和消息串，可只看未读，可按频道或关键词搜',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/inbox',
    keywords: const [
      '动态',
      'activity',
      '最近的动静',
      '收件箱',
      'inbox',
      '最近有什么',
      '动态里有什么',
      '未读动态',
    ],
    paramsSchema: objectSchema({
      'filter': strArg('all 全部 / unread 未读', values: const ['all', 'unread']),
      'q': strArg('关键词，可省略'),
      'channel': strArg('只看这个频道（id 或名字）'),
      'limit': intArg('几条，默认 15', min: 1, max: 30, dflt: 15),
      'offset': intArg('跳过几条，翻页用', min: 0, max: 1000, dflt: 0),
    }),
    resultSummary: 'items[{kind,channelId,channel,threadId,from,text,time,unread,mention}], totalUnread, hasMore',
    run: (w, args, env) => _inbox(env, w, args, '${args['filter'] ?? 'all'}'),
  ),
  AgentCapability(
    id: 'activity.mentions',
    title: '提到我（@我）的消息：哪些频道、哪些消息串里有人 @ 了我',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/inbox',
    keywords: const [
      '@我',
      '提到我',
      '点名我',
      'at我',
      '谁@了我',
      'mention',
      '有人找我',
      '提到我的消息',
      '被提到',
    ],
    paramsSchema: objectSchema({
      'q': strArg('关键词，可省略'),
      'channel': strArg('只看这个频道（id 或名字）'),
      'limit': intArg('几条，默认 15', min: 1, max: 30, dflt: 15),
      'offset': intArg('跳过几条，翻页用', min: 0, max: 1000, dflt: 0),
    }),
    resultSummary: 'items[{kind,channelId,channel,threadId,from,text,time,unread,mention}], hasMore',
    run: (w, args, env) => _inbox(env, w, args, 'mentions'),
  ),
  AgentCapability(
    id: 'activity.done',
    title: '动态里已经处理完（标记为 Done）的会话',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/inbox/done',
    keywords: const ['已处理的动态', '处理完的', 'done', '已完成的动态', '处理过的会话', '标记完成的'],
    paramsSchema: objectSchema({
      'q': strArg('关键词，可省略'),
      'channel': strArg('只看这个频道（id 或名字）'),
      'limit': intArg('几条，默认 15', min: 1, max: 30, dflt: 15),
      'offset': intArg('跳过几条，翻页用', min: 0, max: 1000, dflt: 0),
    }),
    resultSummary:
        'items[{kind,channelId,channel,threadId,from,text,time}], hasMore',
    run: (w, args, env) =>
        _inbox(env, w, args, 'all', path: '/channels/inbox/done'),
  ),
  AgentCapability(
    id: 'channels.files',
    title: '一个频道里分享过的文件和图片（文件名、类型、大小、时间），可只看图片或其它文件、可只看某人发的',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/:id/files',
    keywords: const [
      '文件',
      '频道里的文件',
      '附件',
      '图片',
      '分享过的文件',
      '传过什么文件',
      'files',
      '文档',
      '上传的',
      '找图片',
      '某人发的图',
      '设计图',
      '发的文件',
      '谁发的文件',
      '截图',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('频道 id 或名字'),
        'kind': strArg(
          '只看哪一类：image 图片 / document 其它文件',
          values: const ['image', 'document'],
        ),
        'sender': strArg('只看这个人或 Agent 发的（名字）；会逐个去读消息核对，慢一点'),
        'limit': intArg('几个，默认 10', min: 1, max: 30, dflt: 10),
      },
      required: const ['channel'],
    ),
    resultSummary: 'files[{id,filename,mimeType,size,time,messageId,from}]，hasMore；from 只在按 sender 筛时有',
    run: (w, args, env) async {
      final channel = channelByRef(w, '${args['channel']}');
      final limit = limitOf(args, dflt: 10);
      final kind = text(args['kind']);
      final senderRef = text(args['sender']);
      final sender = senderRef == null
          ? null
          : await senderByRef(w, senderRef);
      final filtering = kind != null || sender != null;
      final body = await w.query(
        '/channels/${Uri.encodeComponent(channel.id)}/files',
        query: {'limit': filtering ? 50 : limit},
      );
      var rows = rowsOf(body, const ['files']);
      if (kind != null) {
        bool image(Map<String, dynamic> f) =>
            '${f['mimeType'] ?? f['contentType']}'.toLowerCase().startsWith('image/');
        rows = [
          for (final f in rows)
            if (kind == 'image' ? image(f) : !image(f)) f,
        ];
      }
      final from = <String, String>{};
      if (sender != null) {
        // File rows do not say who sent them; the messages do.
        final candidates = rows.take(25).toList();
        final kept = <Map<String, dynamic>>[];
        await Future.wait([
          for (final f in candidates)
            () async {
              try {
                final m = await messageById(
                  w,
                  '${f['messageId']}',
                  channelRef: channel.id,
                );
                if (m.senderId == sender.id) {
                  kept.add(f);
                  from['${f['id']}'] = m.author;
                }
              } on Object {
                // A message that cannot be read cannot be matched.
              }
            }(),
        ]);
        rows = [
          for (final f in candidates)
            if (kept.contains(f)) f,
        ];
      }
      return compact({
        'channel': channel.name,
        'count': rows.take(limit).length,
        'hasMore': body is Map && body['nextCursor'] != null ? true : null,
        'filteredBy': filtering
            ? [
                ?(kind == null ? null : kind == 'image' ? '图片' : '其它文件'),
                ?(sender == null ? null : '${sender.label} 发的（只查了最近 25 个文件）'),
              ].join('，')
            : null,
        'files': [
          for (final f in rows.take(limit))
            compact({
              'id': f['id'],
              'filename': f['filename'] ?? f['name'],
              'mimeType': f['mimeType'] ?? f['contentType'],
              'size': f['size'] ?? f['sizeBytes'],
              'time': stamp(f['createdAt']),
              'messageId': f['messageId'],
              'from': from['${f['id']}'],
            }),
        ],
      });
    },
  ),
  AgentCapability(
    id: 'threads.followed',
    title: '我关注的消息串（有新回复会通知我的那些）',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'GET /channels/threads/followed',
    keywords: const [
      '关注的消息串',
      '我关注的讨论',
      '关注的thread',
      '我跟进的讨论',
      'followed',
      '关注的话题',
    ],
    paramsSchema: objectSchema({
      'limit': intArg('几个，默认 10', min: 1, max: 30, dflt: 10),
    }),
    resultSummary: 'threads[{threadId,channelId,channel,parentMessageId,text,from,time}] 最近有动静的在前',
    run: (w, args, env) async {
      w.followedThreads.ensure();
      final rows = w.followedThreads.threads;
      return {
        'total': rows.length,
        'threads': [
          for (final r in rows.take(limitOf(args, dflt: 10)))
            compact({
              'threadId': r['threadChannelId'] ?? r['threadId'],
              'channelId': r['parentChannelId'] ?? r['channelId'],
              'channel': r['parentChannelName'],
              'parentMessageId': r['parentMessageId'],
              'text': clip(
                r['latestActivityPreview'] ?? r['parentMessagePreview'],
                160,
              ),
              'from': r['latestActivitySenderName'],
              'time': stamp(r['latestActivityAt'] ?? r['lastMessageAt']),
            }),
        ],
      };
    },
  ),
];
