import 'package:raft_client/raft_client.dart';

import '../../../data/reaction_toggle.dart';
import '../../../data/workspace_controller.dart';
import '../../resource_filters.dart';
import 'action_support.dart';
import 'agent_capability.dart';
import 'capability_support.dart';

/// The ordinary operations people ask for most: send, reply, react, mark
/// read, mark done, join. Each goes through the controller method the page
/// itself calls, so the optimistic UI, the sync and the unread counts behave
/// as if the person had done it by hand. All are `change` risk: previewed,
/// and run only after the person agrees.

const _emojiNames = {
  '点赞': '👍',
  '赞': '👍',
  '好': '👍',
  'thumbsup': '👍',
  'thumbs_up': '👍',
  '爱心': '❤️',
  '心': '❤️',
  'heart': '❤️',
  '笑': '😄',
  '哈哈': '😄',
  'smile': '😄',
  '庆祝': '🎉',
  '撒花': '🎉',
  'tada': '🎉',
  '收到': '👀',
  '看到了': '👀',
  'eyes': '👀',
  'ok': '👌',
  '完成': '✅',
  'check': '✅',
  '感谢': '🙏',
  '谢谢': '🙏',
  'pray': '🙏',
};

String _emoji(String raw) {
  final key = raw.trim().replaceAll(':', '').toLowerCase();
  return _emojiNames[key] ?? raw.trim();
}

final actionCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'messages.send',
    title: '往一个频道或私信发一条消息（可 @人或 Agent）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /v2/messages',
    keywords: const [
      '发消息',
      '发一条',
      '说一声',
      '告诉',
      '通知',
      '跟他说',
      '私信他',
      '发给',
      '在频道里说',
      '回一句',
      'send',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('频道或私信：id、频道名（不带 #），或私信对方的名字'),
        'text': strArg('消息内容，要 @ 谁就写 @名字', max: 4000),
      },
      required: const ['channel', 'text'],
    ),
    resultSummary: 'done, entity=message, id（发出的消息）',
    preview: (w, args, env) async {
      final c = sendableChannel(w, '${args['channel']}');
      final m = await mentionsIn(w, '${args['text']}');
      return AgentActionPreview(
        summary: '发到${channelWord(c)}：“${quote(m.text, 30)}”',
        changes: [
          change('发到', '', channelWord(c)),
          change('内容', '', m.text),
          if (m.mentions.isNotEmpty)
            change(
              '提到',
              '',
              [for (final x in m.mentions) '@${x['name']}'].join(' '),
            ),
        ],
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = sendableChannel(w, '${args['channel']}');
      final m = await mentionsIn(w, '${args['text']}');
      final randomId = w.client.newRandomId();
      // To the channel by id: what the person has open stays open.
      final ok = await w.sendToChannel(
        c,
        m.text,
        mentions: m.mentions,
        randomId: randomId,
      );
      if (!ok) {
        throw AgentCapabilityError(w.error ?? '消息没有发出去');
      }
      return actionResult(
        '已发送',
        entity: 'message',
        id: sentMessageId(w, c.id, randomId),
        extra: {'channel': channelWord(c)},
      );
    },
  ),
  AgentCapability(
    id: 'messages.reply_thread',
    title: '在某条消息的讨论串里回复（要消息 id）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels/:id/threads',
    keywords: const [
      '回复这条',
      '回复他',
      '回他',
      '在串里回',
      '在讨论串回复',
      '回一下这条消息',
      '接着这条说',
      'reply',
      'thread',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg('要回复的消息 id（取自读取工具，或先 resolve 屏幕上的“这条”）', max: 80),
        'text': strArg('回复内容，可 @ 人', max: 4000),
        'channel': strArg('消息所在频道，已知时带上'),
      },
      required: const ['message', 'text'],
    ),
    resultSummary: 'done, entity=message, id（发出的回复）',
    preview: (w, args, env) async {
      final parent = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final m = await mentionsIn(w, '${args['text']}');
      final where = w.channelById(parent.channelId);
      return AgentActionPreview(
        summary: '回复 ${parent.author} 的消息：“${quote(m.text, 30)}”',
        changes: [
          change('回复', '', '${parent.author}：${quote(parent.content, 30)}'),
          change('内容', '', m.text),
          if (where != null) change('所在', '', channelWord(where)),
        ],
        refs: [AgentPreviewRef('message', parent.id)],
      );
    },
    run: (w, args, env) async {
      final parent = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final where = w.channelById(parent.channelId);
      if (where == null) {
        throw const AgentCapabilityError('这条消息所在的频道你没有加入，不能回复');
      }
      final m = await mentionsIn(w, '${args['text']}');
      final randomId = w.client.newRandomId();
      String? threadId;
      // Into the thread by id: the open thread and channel stay as they are.
      final ok = await w.sendThreadReply(
        parent,
        m.text,
        mentions: m.mentions,
        randomId: randomId,
        resolved: (id) => threadId = id,
      );
      if (!ok) throw AgentCapabilityError(w.error ?? '回复没有发出去');
      return actionResult(
        '已回复',
        entity: 'message',
        id: threadId == null ? null : sentMessageId(w, threadId!, randomId),
        extra: {'parent': parent.id},
      );
    },
  ),
  AgentCapability(
    id: 'messages.react',
    title: '给一条消息加表情反应（👍 ❤️ 🎉 👀 …）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /messages/:id/reactions',
    keywords: const [
      '点赞',
      '表情',
      '加个表情',
      '给他赞',
      '反应',
      '👍',
      'react',
      '回个表情',
      '赞一下',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg('消息 id', max: 80),
        'emoji': strArg('表情，如 👍；也可以写“点赞”“爱心”“庆祝”', max: 16),
        'channel': strArg('消息所在频道，已知时带上'),
      },
      required: const ['message', 'emoji'],
    ),
    resultSummary: 'done, entity=message, id',
    prepareUndo: (w, args, env) async {
      final message = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final emoji = _emoji('${args['emoji']}');
      return AgentUndoPlan(
        label: '取消 $emoji',
        run: () async {
          await w.toggleReaction(message, emoji);
          return '已取消 $emoji';
        },
      );
    },
    preview: (w, args, env) async {
      final message = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final emoji = _emoji('${args['emoji']}');
      await w.hydrateReactionViewer(message);
      final mine =
          w.reactionViewer.reacted(message.id)?.contains(emoji) ??
          ownReactionFromRow(
            w.ledger.message(message.channelId, message.id)?['reactions'] ??
                message.json['reactions'],
            emoji,
            w.client.user?.id,
          );
      if (mine == true) {
        throw AgentCapabilityError('你已经对这条消息加过 $emoji 了');
      }
      if (mine == null) {
        throw const AgentCapabilityError('现在读不到你在这条消息上的表情状态，稍后再试');
      }
      return AgentActionPreview(
        summary: '给 ${message.author} 的消息加 $emoji',
        changes: [
          change('表情', '', emoji),
          change('消息', '', '${message.author}：${quote(message.content, 30)}'),
        ],
        reversible: true,
        refs: [AgentPreviewRef('message', message.id)],
      );
    },
    run: (w, args, env) async {
      final message = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final emoji = _emoji('${args['emoji']}');
      await w.toggleReaction(message, emoji);
      return actionResult('已加 $emoji', entity: 'message', id: message.id);
    },
  ),
  AgentCapability(
    id: 'activity.mark_read',
    title: '把一个频道或私信标为已读，或把动态全部标为已读',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels/:id/read-all',
    keywords: const [
      '标已读',
      '已读',
      '全部已读',
      '都标成已读',
      '清掉未读',
      '不用看了',
      '未读清零',
      'mark read',
    ],
    paramsSchema: objectSchema({
      'channel': strArg('频道或私信（id、名字）；全部已读时省略'),
      'all': boolArg('true 把动态里所有未读都标为已读（不能撤销）'),
    }),
    resultSummary: 'done, entity=channel, id（单个会话时）',
    prepareUndo: (w, args, env) async {
      if (args['all'] == true || text(args['channel']) == null) return null;
      final c = channelByRef(w, '${args['channel']}');
      return AgentUndoPlan(
        label: '改回未读',
        run: () async {
          w.markUnreadLocally(c.id);
          await w.command('POST', '/channels/${c.id}/unread');
          return '已把 ${channelWord(c)} 改回未读';
        },
      );
    },
    preview: (w, args, env) async {
      if (args['all'] == true || text(args['channel']) == null) {
        final total = w.unread.values.fold<int>(0, (a, b) => a + b);
        if (total == 0) throw const AgentCapabilityError('现在没有任何未读');
        return AgentActionPreview(
          summary: '把全部 $total 条未读标为已读',
          changes: [change('未读', '$total 条', '0 条')],
        );
      }
      final c = channelByRef(w, '${args['channel']}');
      final n = w.unread[c.id] ?? 0;
      if (n == 0) throw AgentCapabilityError('${channelWord(c)} 没有未读');
      return AgentActionPreview(
        summary: '把${channelWord(c)}的 $n 条未读标为已读',
        changes: [change('${channelWord(c)} 未读', '$n 条', '0 条')],
        reversible: true,
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      if (args['all'] == true || text(args['channel']) == null) {
        await w.command('POST', '/channels/inbox/read-all');
        await w.refreshUnread();
        return actionResult('已全部标为已读');
      }
      final c = channelByRef(w, '${args['channel']}');
      final receipt = await w.command('POST', '/channels/${c.id}/read-all');
      final principal = w.client.user?.id, serverId = w.client.serverId;
      if (principal != null && serverId != null) {
        w.acceptReadAllAck(
          c.id,
          receipt,
          serverId: serverId,
          principalId: principal,
        );
      }
      return actionResult(
        '已把 ${channelWord(c)} 标为已读',
        entity: 'channel',
        id: c.id,
      );
    },
  ),
  AgentCapability(
    id: 'activity.mark_done',
    title: '把动态（Activity）里的一个会话标为已处理（Done）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels/inbox/done',
    keywords: const [
      '处理完了',
      '标为已处理',
      'done',
      '这个动态处理好了',
      '从动态里去掉',
      '标完成',
      '动态里划掉',
    ],
    paramsSchema: objectSchema(
      {'channel': strArg('频道或私信（id、名字）')},
      required: const ['channel'],
    ),
    resultSummary: 'done, entity=channel, id',
    prepareUndo: (w, args, env) async {
      final c = channelByRef(w, '${args['channel']}');
      final row = await _inboxRow(w, c);
      final undone = row == null ? null : activityMutation(row, 'undone');
      if (undone == null) return null;
      return AgentUndoPlan(
        label: '放回动态',
        run: () async {
          await w.command('POST', undone.path, data: undone.data);
          await w.refreshUnread();
          return '已把 ${channelWord(c)} 放回动态';
        },
      );
    },
    preview: (w, args, env) async {
      final c = channelByRef(w, '${args['channel']}');
      final row = await _inboxRow(w, c);
      if (row == null || activityMutation(row, 'done') == null) {
        throw AgentCapabilityError('${channelWord(c)} 现在不在动态里，没有可以标为已处理的');
      }
      final n = ((row['unreadCount'] as num?) ?? 0).toInt();
      return AgentActionPreview(
        summary: '把${channelWord(c)}在动态里标为已处理',
        changes: [
          change('${channelWord(c)} 动态', '待处理', '已处理'),
          if (n > 0) change('未读', '$n 条', '0 条'),
        ],
        reversible: true,
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = channelByRef(w, '${args['channel']}');
      final row = await _inboxRow(w, c);
      final done = row == null ? null : activityMutation(row, 'done');
      if (done == null) {
        throw AgentCapabilityError('${channelWord(c)} 现在不在动态里');
      }
      await w.command('POST', done.path, data: done.data);
      await w.refreshUnread();
      return actionResult(
        '已把 ${channelWord(c)} 标为已处理',
        entity: 'channel',
        id: c.id,
      );
    },
  ),
  AgentCapability(
    id: 'channels.join',
    title: '加入一个公开频道',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels/:id/join',
    keywords: const ['加入频道', '进这个频道', '加入', 'join', '我想进', '进群'],
    paramsSchema: objectSchema(
      {'channel': strArg('公开频道的名字（不带 #）或 id')},
      required: const ['channel'],
    ),
    resultSummary: 'done, entity=channel, id',
    preview: (w, args, env) async {
      final c = _joinable(w, '${args['channel']}');
      return AgentActionPreview(
        summary: '加入 #${c.name}',
        changes: [change('#${c.name}', '未加入', '已加入')],
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = _joinable(w, '${args['channel']}');
      await w.command('POST', '/channels/${c.id}/join');
      await w.refreshChannels();
      return actionResult('已加入 #${c.name}', entity: 'channel', id: c.id);
    },
  ),
];

RaftChannel _joinable(WorkspaceController w, String ref) {
  final c = channelByRef(w, ref);
  if (c.type != 'channel') {
    throw AgentCapabilityError('${channelWord(c)} 不是公开频道，不能自己加入');
  }
  if (c.joined) throw AgentCapabilityError('你已经在 #${c.name} 里了');
  if (c.archived) throw AgentCapabilityError('#${c.name} 已归档');
  if (!w.can('joinPublicChannels')) {
    throw const AgentCapabilityError('你没有加入公开频道的权限');
  }
  return c;
}

/// The Activity row of [c], read the way the Activity page reads it.
Future<Map<String, dynamic>?> _inboxRow(
  WorkspaceController w,
  RaftChannel c,
) async {
  final filters = ResourceFilters()..channelId = c.id;
  final body = await w.sharedQuery(
    '/channels/inbox',
    query: filters.list('', limit: 30, filter: 'all'),
  );
  return rowsOf(body, const [
    'items',
  ]).where((r) => r['kind'] != 'thread' && r['channelId'] == c.id).firstOrNull;
}
