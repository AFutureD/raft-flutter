import 'dart:convert';

import 'package:raft_client/raft_client.dart';

import '../../../data/message_translation_store.dart';
import '../../../data/workspace_controller.dart';
import '../../attachment_view.dart' show attachmentIsInlineImage;
import '../../forward_composer_page.dart'
    show forwardRecentTargets, forwardTargetLabel;
import '../../forward_messages_dialog.dart'
    show ForwardAttempt, messageForwardable;
import '../../resource_filters.dart';
import '../../saved_sidebar_entry.dart' show SavedCountStore;
import 'action_support.dart';
import 'agent_capability.dart';
import 'capability_support.dart';

/// Messages: forward, send with a file that is already in Raft, translate,
/// save and unsave, follow and unfollow a thread. Each rides on what the
/// message menu and the forward composer do (same requests, same stores).

// ---- forward -----------------------------------------------------------

typedef _Target = ({
  String label,
  String? channelId,
  Map<String, dynamic>? search,
  bool joint,
});

String _targetLabel(RaftChannel c) => forwardTargetLabel(c);

/// A channel or DM the person may forward to, by id or name; a person or
/// Agent without a DM yet is found the way the composer finds them
/// (`/messages/forward/targets/search`).
Future<_Target> _forwardTarget(WorkspaceController w, String ref) async {
  final pool = forwardRecentTargets(w.channels, w.dms);
  RaftChannel? found;
  try {
    found = channelByRef(w, ref);
  } on AgentCapabilityError catch (e) {
    if (e.candidates != null) rethrow;
  }
  if (found != null) {
    if (!pool.any((c) => c.id == found!.id)) {
      throw AgentCapabilityError(
        found.archived
            ? '${channelWord(found)} 已归档，不能转发过去'
            : '你还没有加入 ${channelWord(found)}（或它是只读的），不能转发过去：先加入它（join_channel）',
      );
    }
    return (
      label: _targetLabel(found),
      channelId: found.id,
      search: null,
      joint: found.type == 'joint',
    );
  }
  final body = await w.query(
    '/messages/forward/targets/search',
    query: {'q': ref.trim(), 'limit': 20},
  );
  final rows = rowsOf(body, const ['targets']);
  String nameOf(Map<String, dynamic> r) =>
      '${r['displayName'] ?? r['name'] ?? r['label'] ?? ''}';
  final want = ref.trim().replaceAll(RegExp(r'^[@#]'), '').toLowerCase();
  var hits = [
    for (final r in rows)
      if (nameOf(r).toLowerCase() == want ||
          '${r['name']}'.toLowerCase() == want)
        r,
  ];
  if (hits.isEmpty && rows.length == 1) hits = rows;
  if (hits.length == 1) {
    final r = hits.single;
    return (
      label: r['type'] == 'channel' ? '#${nameOf(r)}' : '@${nameOf(r)}',
      channelId: r['channelId'] is String ? r['channelId'] as String : null,
      search: r,
      joint: false,
    );
  }
  if (hits.isEmpty) {
    throw AgentCapabilityError('没有叫“$ref”的频道、私信或人');
  }
  throw AgentCapabilityError(
    '“$ref”对得上多个去处，请问用户是哪一个',
    candidates: [
      for (final r in hits.take(6)) {'name': nameOf(r), 'type': r['type']},
    ],
  );
}

Future<List<_Target>> _forwardTargets(
  WorkspaceController w,
  Object? refs,
) async {
  final list = [
    for (final r in (refs as List? ?? const []))
      if ('$r'.trim().isNotEmpty) '$r'.trim(),
  ];
  if (list.isEmpty) throw const AgentCapabilityError('需要 targets：转给谁（至少一个）');
  if (list.length > 10) {
    throw const AgentCapabilityError('一次最多转发到 10 个去处');
  }
  final out = <_Target>[];
  for (final ref in list) {
    final t = await _forwardTarget(w, ref);
    if (!out.any((o) => o.label == t.label)) out.add(t);
  }
  return out;
}

/// A forward the person confirmed keeps its request id, so a retry of the
/// same card is the server's idempotent retry and never a second forward.
final _attempts = <String, ForwardAttempt>{};

Future<RaftMessage> _forwardable(
  WorkspaceController w,
  Map<String, Object?> args,
) async {
  if (w.server?.string('role') == 'guest') {
    throw const AgentCapabilityError('访客不能转发消息');
  }
  final m = await messageById(
    w,
    '${args['message']}',
    channelRef: text(args['channel']),
  );
  if (!messageForwardable(m)) {
    throw const AgentCapabilityError('只有普通的聊天消息能转发（系统消息、操作卡片、已转发的合集不行）');
  }
  return m;
}

// ---- attachments ---------------------------------------------------------

typedef _File = ({
  Map<String, dynamic> metadata,
  String channelId,
  String? author,
});

/// The attachments of the messages the app holds, newest message first.
Iterable<_File> _heldFiles(WorkspaceController w, {String? channelId}) sync* {
  final ids = [
    ?channelId,
    if (channelId == null) ...[
      ?w.channel?.id,
      for (final c in [...w.channels, ...w.dms]) c.id,
    ],
  ];
  final seen = <String>{};
  for (final id in ids) {
    final rows = w.ledger.messages(id).reversed;
    for (final m in rows) {
      final attachments = m['attachments'];
      if (attachments is! List) continue;
      for (final a in attachments.reversed) {
        if (a is Map && a['id'] is String && seen.add(a['id'] as String)) {
          yield (
            metadata: Map<String, dynamic>.from(a),
            channelId: id,
            author: (m['senderDisplayName'] ?? m['senderName']) as String?,
          );
        }
      }
    }
  }
}

_File _file(WorkspaceController w, Map<String, Object?> args) {
  final id = text(args['attachment']);
  final latest = text(args['latest']);
  if (id == null && latest == null) {
    throw const AgentCapabilityError(
      '需要 attachment（文件 id），或 latest=image/file（刚才那张图 / 那个文件）',
    );
  }
  final from = text(args['from']);
  final channelId = from == null ? null : channelByRef(w, from).id;
  final files = _heldFiles(w, channelId: channelId);
  if (id != null) {
    final hit = files.where((f) => f.metadata['id'] == id).firstOrNull;
    if (hit == null) {
      throw const AgentCapabilityError(
        '这个文件不在读到的消息里，或你没有权限：id 要取自读取工具或屏幕上的文件卡片',
      );
    }
    return hit;
  }
  final hit = files
      .where(
        (f) => latest == 'image' ? attachmentIsInlineImage(f.metadata) : true,
      )
      .firstOrNull;
  if (hit == null) {
    throw AgentCapabilityError(latest == 'image' ? '最近的消息里没有图片' : '最近的消息里没有文件');
  }
  return hit;
}

String _fileWord(Map<String, dynamic> m) =>
    '${m['filename'] ?? '文件'}${attachmentIsInlineImage(m) ? '（图片）' : ''}';

// ---- translation -----------------------------------------------------------

Future<void> _until(bool Function() ready, {int ms = 5000}) async {
  var waited = 0;
  while (!ready() && waited < ms) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    waited += 100;
  }
}

final messageActionCapabilities = <AgentCapability>[
  AgentCapability(
    id: 'messages.forward',
    title: '把一条消息转发到最多 10 个频道、私信或人那里，可附一句说明；转发后不能撤回',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /messages/forward',
    keywords: const [
      '转发',
      '转给',
      '把这条转给',
      '转发给',
      '转发到',
      '发给他看看',
      '分享这条',
      '转一下',
      'forward',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg('要转发的消息 id（取自读取工具，或先 resolve 屏幕上的“这条”）', max: 80),
        'targets': {
          'type': 'array',
          'description': '转到哪里：频道名、人 / Agent 的名字、私信对方的名字，最多 10 个',
          'items': {'type': 'string', 'maxLength': 80},
        },
        'note': strArg('附一句话说明，可省略', max: 500),
        'channel': strArg('消息所在频道，已知时带上'),
      },
      required: const ['message', 'targets'],
    ),
    resultSummary: 'done, entity=message, id（被转发的消息）',
    preview: (w, args, env) async {
      final m = await _forwardable(w, args);
      final targets = await _forwardTargets(w, args['targets']);
      final note = text(args['note']);
      final where = targets.map((t) => t.label).join('、');
      return AgentActionPreview(
        summary:
            '把 ${m.author} 的消息“${quote(m.content, 24)}”转发到 $where${note == null ? '' : '，附说明“${quote(note, 20)}”'}',
        changes: [
          change('消息', '', '${m.author}：${quote(m.content, 30)}'),
          change('转发到', '', where),
          if (note != null) change('说明', '', note),
          for (final t in targets)
            if (t.search?['requiredAction'] == 'create_dm')
              change('先建立私信', '', t.label),
          if (targets.any((t) => t.joint) ||
              w.channelById(m.channelId)?.type == 'joint')
            change('提醒', '', '涉及联合频道，内容会被其它服务器的人看到'),
        ],
        refs: [AgentPreviewRef('message', m.id)],
      );
    },
    run: (w, args, env) async {
      final m = await _forwardable(w, args);
      final targets = await _forwardTargets(w, args['targets']);
      final ids = <String>[];
      for (final t in targets) {
        final search = t.search;
        var channelId = t.channelId;
        if (search != null &&
            (channelId == null || search['requiredAction'] != null)) {
          if (search['requiredAction'] == 'create_dm') {
            final created = await w.command(
              'POST',
              '/channels/dm',
              data: {
                search['type'] == 'agent' ? 'agentId' : 'userId': search['id'],
              },
            );
            if (created is Map && created['id'] is String) {
              channelId = created['id'] as String;
            }
          } else if (search['requiredAction'] == 'join_channel' &&
              channelId != null) {
            await w.command('POST', '/channels/$channelId/join');
          }
        }
        if (channelId == null) {
          throw AgentCapabilityError('没能找到 ${t.label} 的会话，转发没有进行');
        }
        ids.add(channelId);
      }
      final note = text(args['note']) ?? '';
      final key = jsonEncode([m.id, ids, note]);
      final attempt = _attempts.putIfAbsent(
        key,
        () => ForwardAttempt(
          requestId: w.client.newRandomId(),
          sources: [m.id],
          destinations: ids,
          note: note,
        ),
      );
      while (_attempts.length > 10) {
        _attempts.remove(_attempts.keys.first);
      }
      final response = await w.command(
        'POST',
        '/messages/forward',
        data: attempt.payload,
      );
      attempt.apply(response);
      if (!attempt.completed) {
        final failed = [
          for (var i = 0; i < ids.length; i++)
            if (attempt.outcomes[ids[i]] != 'success') targets[i].label,
        ];
        throw AgentCapabilityError(
          '有 ${failed.length} 处没转成功：${failed.join('、')}。点重试只会补转这几处，已经转成功的不会重复',
        );
      }
      _attempts.remove(key);
      return actionResult(
        '已转发到 ${targets.map((t) => t.label).join('、')}',
        entity: 'message',
        id: m.id,
      );
    },
  ),
  AgentCapability(
    id: 'messages.send_with_attachment',
    title: '发一条带文件或图片的消息：附件是已经在 Raft 里的那个（文件卡片、刚才那张图）；发出后不能撤回',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /v2/messages',
    keywords: const [
      '带附件',
      '附上',
      '附上刚才那张',
      '附上截图',
      '发图片',
      '发文件',
      '把这个文件发给',
      '把这张图发到',
      '发条消息附上',
      'attach',
    ],
    paramsSchema: objectSchema(
      {
        'channel': strArg('发到哪个频道或私信：id、频道名（不带 #），或私信对方的名字'),
        'text': strArg('消息内容，可省略（只发文件）；要 @ 谁就写 @名字', max: 4000),
        'attachment': strArg('文件 id（取自文件卡片或读取结果里的 attachments）', max: 80),
        'latest': strArg(
          '不知道 id 时：image 最近的一张图片 / file 最近的一个文件（在 from 或当前会话里找）',
          values: const ['image', 'file'],
        ),
        'from': strArg('最近的文件在哪个频道里找；省略就是当前打开的会话'),
      },
      required: const ['channel'],
    ),
    resultSummary: 'done, entity=message, id（发出的消息）',
    preview: (w, args, env) async {
      final c = sendableChannel(w, '${args['channel']}');
      final f = _file(w, args);
      final m = await mentionsIn(w, text(args['text']) ?? '');
      return AgentActionPreview(
        summary:
            '发到${channelWord(c)}：${m.text.isEmpty ? '' : '“${quote(m.text, 24)}” '}附 ${_fileWord(f.metadata)}',
        changes: [
          change('发到', '', channelWord(c)),
          if (m.text.isNotEmpty) change('内容', '', m.text),
          change('附件', '', _fileWord(f.metadata)),
        ],
        refs: [AgentPreviewRef('channel', c.id)],
      );
    },
    run: (w, args, env) async {
      final c = sendableChannel(w, '${args['channel']}');
      final f = _file(w, args);
      final m = await mentionsIn(w, text(args['text']) ?? '');
      final sent = await w.client.sendWithReceipt(
        c.id,
        m.text.isEmpty ? '[1 attachment]' : m.text,
        attachments: ['${f.metadata['id']}'],
        mentions: m.mentions.isEmpty ? null : m.mentions,
        randomId: w.client.newRandomId(),
      );
      return actionResult(
        '已发送，附 ${_fileWord(f.metadata)}',
        entity: 'message',
        id: sent.message.id.isEmpty ? null : sent.message.id,
        extra: {'channel': channelWord(c)},
      );
    },
  ),
  AgentCapability(
    id: 'messages.translate',
    title: '把一条消息翻译成用户设置的语言并念出来（只读；服务器要开了翻译）',
    kind: AgentCapabilityKind.query,
    risk: AgentCapabilityRisk.read,
    parity: 'POST /message-translations:batch',
    keywords: const [
      '翻译',
      '翻译这条',
      '翻成中文',
      '翻成英文',
      '这条什么意思',
      '看不懂这条',
      '这句话是什么意思',
      'translate',
    ],
    paramsSchema: objectSchema(
      {'message': strArg('消息 id', max: 80), 'channel': strArg('消息所在频道，已知时带上')},
      required: const ['message'],
    ),
    resultSummary: 'original, translated, language（译成哪种语言）, sourceLanguage',
    run: (w, args, env) async {
      final m = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final store = w.translations..ensureSettings();
      await _until(() => store.settings.loaded, ms: 3000);
      final s = store.settings;
      if (!s.loaded) {
        throw const AgentCapabilityError('现在读不到翻译设置，稍后再试');
      }
      if (!s.serverEnabled || !s.providerAvailable) {
        throw const AgentCapabilityError('这个服务器没有开翻译（要管理员在服务器设置里打开）');
      }
      if (s.mode == MessageTranslationMode.off) {
        throw const AgentCapabilityError('你把翻译设成了“关闭”：在语言设置里改成自动或手动才能翻译');
      }
      if (m.content.trim().isEmpty) {
        throw const AgentCapabilityError('这条消息没有文字可翻译');
      }
      if (m.senderId == w.client.user?.id &&
          s.mode != MessageTranslationMode.manual) {
        throw const AgentCapabilityError('这是你自己发的消息，不用翻译');
      }
      await store.translate(m);
      await _until(
        () =>
            store.present(m).entry?.status != MessageTranslationStatus.pending,
        ms: 4000,
      );
      final entry = store.present(m).entry;
      if (entry == null || entry.status == MessageTranslationStatus.pending) {
        throw const AgentCapabilityError('翻译超时了，稍后再试');
      }
      if (entry.status == MessageTranslationStatus.skipped) {
        return {
          'original': clip(m.content, 600),
          'message': '这条已经是你的语言，不用翻译',
          'language': messageTranslationLanguages[s.effectiveLanguage],
        };
      }
      if (!entry.hasContent) {
        throw const AgentCapabilityError('翻译没有成功，稍后再试');
      }
      env.facts?.learnMessage(m.author, m.content, id: m.id);
      return compact({
        'from': m.author,
        'original': clip(m.content, 600),
        'translated': clip(entry.translatedContent, 1200),
        'language': messageTranslationLanguages[s.effectiveLanguage],
        'sourceLanguage': entry.sourceLanguage,
      });
    },
  ),
  AgentCapability(
    id: 'messages.set_saved',
    title: '收藏一条消息，或取消收藏（saved 默认 true）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels/saved',
    keywords: const [
      '收藏这条',
      '收藏',
      '存一下这条',
      '保存这条消息',
      '取消收藏',
      '不收藏了',
      '从收藏里去掉',
      'save',
      'unsave',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg('消息 id', max: 80),
        'saved': boolArg('true 收藏（默认）/ false 取消收藏'),
        'channel': strArg('消息所在频道，已知时带上'),
      },
      required: const ['message'],
    ),
    resultSummary: 'done, entity=message, id',
    prepareUndo: (w, args, env) async {
      final m = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final saved = args['saved'] != false;
      return AgentUndoPlan(
        label: saved ? '取消收藏' : '重新收藏',
        run: () async {
          await SavedCountStore.of(w).setSaved(m.id, !saved);
          return saved ? '已取消收藏' : '已重新收藏';
        },
      );
    },
    preview: (w, args, env) async {
      final m = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final saved = args['saved'] != false;
      final store = SavedCountStore.of(w);
      if (!saved && !await _knownSaved(w, store, m)) {
        throw const AgentCapabilityError('这条消息不在你的收藏里');
      }
      if (saved && store.isSaved(m.id)) {
        throw const AgentCapabilityError('这条消息已经收藏过了');
      }
      return AgentActionPreview(
        summary:
            '${saved ? '收藏' : '取消收藏'} ${m.author} 的消息“${quote(m.content, 24)}”',
        changes: [
          change('收藏', saved ? '未收藏' : '已收藏', saved ? '已收藏' : '未收藏'),
          change('消息', '', '${m.author}：${quote(m.content, 30)}'),
        ],
        reversible: true,
        refs: [AgentPreviewRef('message', m.id)],
      );
    },
    run: (w, args, env) async {
      final m = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final saved = args['saved'] != false;
      await SavedCountStore.of(w).setSaved(m.id, saved);
      return actionResult(saved ? '已收藏' : '已取消收藏', entity: 'message', id: m.id);
    },
  ),
  AgentCapability(
    id: 'threads.set_following',
    title: '关注一条消息的讨论串（有新回复会通知我），或取消关注（following 默认 true）',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    parity: 'POST /channels/threads/follow',
    keywords: const [
      '关注这个话题',
      '关注讨论',
      '关注这个串',
      '取消关注',
      '不再关注',
      '别通知我这个话题',
      'follow',
      'unfollow',
    ],
    paramsSchema: objectSchema(
      {
        'message': strArg('讨论串所属的那条消息 id（串的第一条）', max: 80),
        'following': boolArg('true 关注（默认）/ false 取消关注'),
        'channel': strArg('消息所在频道，已知时带上'),
      },
      required: const ['message'],
    ),
    resultSummary: 'done, entity=message, id',
    prepareUndo: (w, args, env) async {
      final m = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final following = args['following'] != false;
      final store = w.followedThreads;
      final threadId = store.threadChannelIdFor(m.id);
      return AgentUndoPlan(
        label: following ? '取消关注' : '重新关注',
        run: () async {
          if (following) {
            await store.unfollow(
              m.id,
              threadChannelId: store.threadChannelIdFor(m.id) ?? threadId,
            );
            return '已取消关注';
          }
          await store.follow(m.id);
          return '已重新关注';
        },
      );
    },
    preview: (w, args, env) async {
      final m = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final following = args['following'] != false;
      final now = await _isFollowing(w, m.id);
      if (following && now) throw const AgentCapabilityError('已经在关注这个讨论串了');
      if (!following && !now) throw const AgentCapabilityError('本来就没有关注这个讨论串');
      return AgentActionPreview(
        summary: '${following ? '关注' : '取消关注'} ${m.author} 那条消息的讨论串',
        changes: [
          change('关注', following ? '未关注' : '已关注', following ? '已关注' : '未关注'),
          change('消息', '', '${m.author}：${quote(m.content, 30)}'),
        ],
        reversible: true,
        refs: [AgentPreviewRef('message', m.id)],
      );
    },
    run: (w, args, env) async {
      final m = await messageById(
        w,
        '${args['message']}',
        channelRef: text(args['channel']),
      );
      final following = args['following'] != false;
      final store = w.followedThreads;
      if (following) {
        await store.follow(m.id);
      } else {
        await _isFollowing(w, m.id);
        final id =
            store.threadChannelIdFor(m.id) ?? m.string('threadChannelId');
        if (id.isEmpty) {
          throw const AgentCapabilityError('这个讨论串还没有读到，取消不了关注');
        }
        await store.unfollow(m.id, threadChannelId: id);
      }
      return actionResult(
        following ? '已关注这个讨论串' : '已取消关注',
        entity: 'message',
        id: m.id,
      );
    },
  ),
];

/// Whether [m] is among the saved messages, learning it from the Saved list
/// when the app has not yet (the same read the Saved page makes).
Future<bool> _knownSaved(
  WorkspaceController w,
  SavedCountStore store,
  RaftMessage m,
) async {
  if (store.isSaved(m.id)) return true;
  final filters = ResourceFilters()..channelId = m.channelId;
  try {
    final body = await w.query(
      '/channels/saved',
      query: filters.list('', limit: 50),
    );
    store.know([
      for (final r in rowsOf(body, const ['saved', 'items']))
        if (r['messageId'] is String) r['messageId'] as String,
    ]);
  } on Object {
    // Fall through to what is known.
  }
  return store.isSaved(m.id);
}

Future<bool> _isFollowing(WorkspaceController w, String parentMessageId) async {
  final store = w.followedThreads..ensure();
  await _until(() => store.settled, ms: 4000);
  if (!store.loaded) {
    throw const AgentCapabilityError('现在读不到你关注的讨论串，稍后再试');
  }
  return store.isFollowing(parentMessageId);
}
