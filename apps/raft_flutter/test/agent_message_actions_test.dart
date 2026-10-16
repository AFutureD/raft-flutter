import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/message_translation_store.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';

import 'support/agent_action_harness.dart';
import 'support/agent_capability_world.dart' show hoursAgo;

/// Forward, send with a file, translate, save, follow a thread, and the tasks
/// made from messages.
void main() {
  late ActionHarness h;

  Map<String, dynamic> msg(
    String id, {
    String channel = 'ch-general',
    String text = '周五上线可以吗？',
    String from = 'ada',
    String name = 'Ada',
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic> extra = const {},
    int seq = 10,
  }) => {
    'id': id,
    'channelId': channel,
    'content': text,
    'senderId': from,
    'senderName': name,
    'senderType': 'user',
    'seq': '$seq',
    'createdAt': hoursAgo(1),
    'attachments': ?attachments,
    ...extra,
  };

  void put(List<Map<String, dynamic>> rows) => h.w.ledger.ingest(
    rows,
    expectedGeneration: h.w.ledger.generation,
  );

  setUp(() {
    h = ActionHarness();
    put([msg('m-1')]);
    h.w.channels = [
      ...h.w.channels,
      RaftChannel({'id': 'ch-random', 'name': 'random'}),
      RaftChannel({
        'id': 'ch-old',
        'name': 'old',
        'joined': true,
        'archivedAt': '2026-10-01T00:00:00Z',
      }),
      RaftChannel({'id': 'ch-joint', 'name': 'bridge', 'type': 'joint', 'joined': true}),
    ];
  });
  tearDown(() => h.dispose());

  group('messages.forward', () {
    Map<String, Object?> args([Map<String, Object?> more = const {}]) => {
      'message': 'm-1',
      'targets': ['design', 'Ada'],
      ...more,
    };

    test('previews the message, the places and the note', () async {
      final r = await h.act('messages.forward', args({'note': '你看下'}));
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(h.summary(r), contains('Ada 的消息“周五上线可以吗？”'));
      expect(h.summary(r), contains('转发到 #design、@Ada'));
      expect(h.summary(r), contains('附说明“你看下”'));
      final lines = h.changes(r);
      expect(lines, contains('转发到:  → #design、@Ada'));
      expect(lines, contains('说明:  → 你看下'));
      for (final l in lines) {
        expect(ActionHarness.lineOk(l), isTrue, reason: l);
      }
      expect((r['preview'] as Map)['reversible'], isFalse);
      expect(h.w.commands, isEmpty);
    });

    test('forwards with the composer\'s own payload', () async {
      h.w.commandRoutes['POST /messages/forward'] = (data) => {
        'results': [
          for (final id in (data as Map)['destinationChannelIds'] as List)
            {
              'destinationChannelId': id,
              'status': 'success',
              'message': {'id': 'fwd-$id'},
            },
        ],
      };
      final done = await h.run('messages.forward', args({'note': '你看下'}));
      expect(done['status'], 'done', reason: '$done');
      final call = h.w.commands.single;
      expect(call.$1, 'POST');
      expect(call.$2, '/messages/forward');
      final payload = call.$3 as Map;
      expect(payload['sourceMessageIds'], ['m-1']);
      expect(payload['destinationChannelIds'], ['ch-design', 'dm-1']);
      expect(payload['note'], '你看下');
      expect(payload['requestId'], isNotEmpty);
      expect((done['result'] as Map)['entity'], 'message');
      expect(done.containsKey('undo'), isFalse);
    });

    test('a partial failure is said, and the retry is the same request', () async {
      var round = 0;
      h.w.commandRoutes['POST /messages/forward'] = (data) {
        round++;
        final ids = (data as Map)['destinationChannelIds'] as List;
        return {
          'results': [
            for (final id in ids)
              {
                'destinationChannelId': id,
                'status': id == 'dm-1' && round == 1 ? 'failed' : 'success',
                'error': 'blocked',
                'message': {'id': 'fwd-$id'},
              },
          ],
        };
      };
      final failed = await h.run('messages.forward', args());
      expect(failed['status'], 'failed');
      expect('${failed['error']}', contains('@Ada'));
      expect('${failed['error']}', contains('不会重复'));
      // The card's 重试: same request id, so the server does not forward twice.
      final retried = await h.tools.retryAction(
        h.board.records.single.id,
      );
      expect(retried['status'], 'done', reason: '$retried');
      final ids = {for (final c in h.w.commands) (c.$3 as Map)['requestId']};
      expect(ids, hasLength(1));
    });

    test('a person without a private chat gets one first', () async {
      h.w.routes['/messages/forward/targets/search'] = (q) => {
        'targets': [
          {
            'type': 'user',
            'id': 'u-lee',
            'name': 'ada.lee',
            'displayName': 'Ada Lee',
            'requiredAction': 'create_dm',
          },
        ],
      };
      h.w.commandRoutes['POST /channels/dm'] = (_) => {'id': 'dm-new'};
      h.w.commandRoutes['POST /messages/forward'] = (data) => {
        'results': [
          for (final id in (data as Map)['destinationChannelIds'] as List)
            {
              'destinationChannelId': id,
              'status': 'success',
              'message': {'id': 'f'},
            },
        ],
      };
      final r = await h.act('messages.forward', {
        'message': 'm-1',
        'targets': ['Ada Lee'],
      });
      expect(h.changes(r), contains('先建立私信:  → @Ada Lee'));
      await h.approve(r);
      expect(h.w.commands.map((c) => '${c.$1} ${c.$2}'), [
        'POST /channels/dm',
        'POST /messages/forward',
      ]);
      expect(h.w.commands.first.$3, {'userId': 'u-lee'});
      expect((h.w.commands.last.$3 as Map)['destinationChannelIds'], ['dm-new']);
    });

    test('a joint channel is warned about', () async {
      final r = await h.act('messages.forward', args({'targets': ['bridge']}));
      expect(h.changes(r).any((l) => l.startsWith('提醒:')), isTrue);
    });

    test('refused at the preview', () async {
      Future<void> refused(Map<String, Object?> a, String message) async {
        final r = await h.act('messages.forward', a);
        expect('${r['error']}', contains(message), reason: '$a $r');
        expect(r.containsKey('confirmToken'), isFalse);
      }

      await refused(args({'targets': <String>[]}), '需要 targets');
      await refused(
        args({'targets': [for (var i = 0; i < 11; i++) 'design$i']}),
        '最多转发到 10',
      );
      await refused(args({'targets': ['random']}), '还没有加入');
      await refused(args({'targets': ['old']}), '已归档');
      await refused(args({'targets': ['nowhere-at-all']}), '没有叫');
      await refused(args({'message': 'm-404'}), '没有找到消息');
      await refused({'message': 'm-1'}, '缺少参数 targets');
      put([msg('m-sys', extra: {'messageType': 'system'})]);
      await refused(args({'message': 'm-sys'}), '普通的聊天消息');
      put([
        msg('m-card', extra: {
          'actionMetadata': {'kind': 'action-card'},
        }),
      ]);
      await refused(args({'message': 'm-card'}), '普通的聊天消息');
      h.w.server = RaftRecord({'id': 's1', 'role': 'guest'});
      await refused(args(), '访客');
      expect(h.w.commands, isEmpty);
    });

    test('ten places is the limit and is allowed', () async {
      h.w.channels = [
        ...h.w.channels,
        for (var i = 0; i < 9; i++)
          RaftChannel({'id': 'ch-x$i', 'name': 'x$i', 'joined': true}),
      ];
      final r = await h.act('messages.forward', {
        'message': 'm-1',
        'targets': [for (var i = 0; i < 9; i++) 'x$i', 'design'],
      });
      expect(r['status'], 'needs_confirmation', reason: '$r');
    });
  });

  group('messages.send_with_attachment', () {
    final shot = {
      'id': 'att-1',
      'filename': 'shot.png',
      'mimeType': 'image/png',
      'sizeBytes': 2048,
    };
    final doc = {
      'id': 'att-2',
      'filename': 'plan.pdf',
      'mimeType': 'application/pdf',
      'sizeBytes': 9000,
    };
    setUp(() {
      put([
        msg('m-doc', channel: 'ch-design', attachments: [doc], seq: 20),
        msg('m-shot', channel: 'ch-design', attachments: [shot], seq: 21),
        msg('m-late', channel: 'ch-design', text: '看到了', seq: 22),
      ]);
    });

    test('"刚才那张图": the latest image of the conversation', () async {
      final r = await h.act('messages.send_with_attachment', {
        'channel': 'general',
        'text': '截图在这',
        'latest': 'image',
        'from': 'design',
      });
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(h.summary(r), '发到#general：“截图在这” 附 shot.png（图片）');
      expect(h.changes(r), [
        '发到:  → #general',
        '内容:  → 截图在这',
        '附件:  → shot.png（图片）',
      ]);
      expect(h.client.posts, isEmpty);
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.client.posts, ['POST /v2/messages']);
      final body = h.client.bodies.single as Map;
      expect(body['channelId'], 'ch-general');
      expect(body['content'], '截图在这');
      expect(body['attachmentIds'], ['att-1']);
    });

    test('a file card: by id, and the file alone needs no words', () async {
      final r = await h.act('messages.send_with_attachment', {
        'channel': 'general',
        'attachment': 'att-2',
      });
      expect(h.summary(r), '发到#general：附 plan.pdf');
      await h.approve(r);
      expect((h.client.bodies.single as Map)['attachmentIds'], ['att-2']);
      expect((h.client.bodies.single as Map)['content'], isNotEmpty);
    });

    test('refused at the preview', () async {
      Future<void> refused(Map<String, Object?> a, String message) async {
        final r = await h.act('messages.send_with_attachment', a);
        expect('${r['error']}', contains(message), reason: '$a $r');
      }

      await refused({'channel': 'general'}, '需要 attachment');
      await refused({'channel': 'general', 'attachment': 'nope'}, '不在读到的消息里');
      await refused(
        {'channel': 'general', 'latest': 'image', 'from': 'general'},
        '没有图片',
      );
      await refused({'channel': 'old', 'attachment': 'att-1'}, '已归档');
      await refused({'channel': 'random', 'attachment': 'att-1'}, '还没有加入');
      expect(h.client.posts, isEmpty);
    });
  });

  group('messages.translate', () {
    setUp(() {
      h.client.user = RaftRecord({
        'id': 'kevin',
        'displayName': 'Kevin',
        'preferredLanguage': 'zh-cn',
        'preferredTranslationMode': 'auto',
      });
      h.client.responses['GET /servers/s1/translation-settings'] = {
        'translationEnabled': true,
        'translationAvailable': true,
      };
      put([msg('m-en', text: 'Can we ship on Friday?', seq: 30)]);
    });

    Future<Map<String, Object?>> translate(String id) async {
      final r = await h.tools.run('query', {
        'capability': 'messages.translate',
        'args': {'message': id},
      });
      return r!;
    }

    test('reads the translation the App\'s own store makes', () async {
      h.client.responses['POST /message-translations:batch'] = {
        'results': [
          {
            'messageId': 'm-en',
            'status': 'translated',
            'translatedContent': '我们周五能上线吗？',
            'sourceLanguage': 'en',
            'targetLanguage': 'zh-cn',
          },
        ],
      };
      final r = await translate('m-en');
      final result = r['result'] as Map;
      expect(result['translated'], '我们周五能上线吗？');
      expect(result['original'], 'Can we ship on Friday?');
      expect(result['language'], 'Simplified Chinese');
      expect(h.client.posts, contains('POST /message-translations:batch'));
      final body = h.client.bodies.last as Map;
      expect(body['messageIds'], ['m-en']);
      expect(body['targetLanguage'], 'zh-cn');
    });

    test('says so when the server has translation off', () async {
      h.client.responses['GET /servers/s1/translation-settings'] = {
        'translationEnabled': false,
        'translationAvailable': true,
      };
      expect('${(await translate('m-en'))['error']}', contains('没有开翻译'));
      expect(h.client.posts, isNot(contains('POST /message-translations:batch')));
    });

    test('says so when the person turned translation off', () async {
      h.client.user = RaftRecord({
        'id': 'kevin',
        'preferredLanguage': 'zh-cn',
        'preferredTranslationMode': 'off',
      });
      expect('${(await translate('m-en'))['error']}', contains('关闭'));
    });

    test('a failed translation and your own message are said', () async {
      h.client.responses['POST /message-translations:batch'] = {
        'results': [
          {
            'messageId': 'm-en',
            'status': 'failed',
            'reason': 'provider',
            'targetLanguage': 'zh-cn',
          },
        ],
      };
      expect('${(await translate('m-en'))['error']}', contains('没有成功'));
      put([msg('m-mine', from: 'kevin', name: 'Kevin', seq: 31)]);
      expect('${(await translate('m-mine'))['error']}', contains('自己发的'));
    });

    test('is a read: no confirmation', () {
      final c = h.tools.registry['messages.translate']!;
      expect(c.isQuery, isTrue);
      expect(c.risk, AgentCapabilityRisk.read);
      expect(MessageTranslationMode.values, contains(MessageTranslationMode.off));
    });
  });

  group('messages.set_saved', () {
    test('saves, and undo takes it back', () async {
      final r = await h.act('messages.set_saved', {'message': 'm-1'});
      expect(h.summary(r), '收藏 Ada 的消息“周五上线可以吗？”');
      expect(h.changes(r).first, '收藏: 未收藏 → 已收藏');
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.commands.single.$1, 'POST');
      expect(h.w.commands.single.$2, '/channels/saved');
      expect(h.w.commands.single.$3, {'messageId': 'm-1'});
      expect((done['undo'] as Map)['label'], '取消收藏');
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect(h.w.commands.last.$1, 'DELETE');
      expect(h.w.commands.last.$2, '/channels/saved/m-1');
    });

    test('unsave needs it to be saved, and says if it is not', () async {
      h.w.routes['/channels/saved'] = (_) => {'saved': <Object>[]};
      var r = await h.act('messages.set_saved', {'message': 'm-1', 'saved': false});
      expect('${r['error']}', contains('不在你的收藏里'));
      h.w.routes['/channels/saved'] = (_) => {
        'saved': [
          {'messageId': 'm-1', 'channelId': 'ch-general'},
        ],
      };
      r = await h.act('messages.set_saved', {'message': 'm-1', 'saved': false});
      expect(h.changes(r).first, '收藏: 已收藏 → 未收藏');
      final done = await h.approve(r);
      expect(done['status'], 'done');
      expect(h.w.commands.single.$1, 'DELETE');
    });

    test('saving twice is said', () async {
      await h.run('messages.set_saved', {'message': 'm-1'});
      final again = await h.act('messages.set_saved', {'message': 'm-1'});
      expect('${again['error']}', contains('已经收藏过'));
    });
  });

  group('threads.set_following', () {
    setUp(() {
      h.w.routes['/channels/threads/followed'] = (_) => {
        'threads': [
          {
            'parentMessageId': 'm-followed',
            'threadChannelId': 'thr-f',
            'parentChannelId': 'ch-general',
          },
        ],
      };
      put([msg('m-followed', seq: 40)]);
    });

    test('follows with the follow request the menu sends', () async {
      final r = await h.act('threads.set_following', {'message': 'm-1'});
      expect(h.changes(r).first, '关注: 未关注 → 已关注');
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.commands.single.$2, '/channels/threads/follow');
      expect(h.w.commands.single.$3, {'parentMessageId': 'm-1'});
      expect((done['undo'] as Map)['label'], '取消关注');
    });

    test('unfollows the thread it knows', () async {
      final r = await h.act('threads.set_following', {
        'message': 'm-followed',
        'following': false,
      });
      expect(h.changes(r).first, '关注: 已关注 → 未关注');
      await h.approve(r);
      expect(h.w.commands.single.$2, '/channels/threads/unfollow');
      expect(h.w.commands.single.$3, {'threadChannelId': 'thr-f'});
    });

    test('already the way it should be is said', () async {
      var r = await h.act('threads.set_following', {'message': 'm-followed'});
      expect('${r['error']}', contains('已经在关注'));
      r = await h.act('threads.set_following', {
        'message': 'm-1',
        'following': false,
      });
      expect('${r['error']}', contains('本来就没有关注'));
    });

    test('a list that cannot be read stops it', () async {
      h.w.routes['/channels/threads/followed'] = (_) =>
          throw const RaftApiException('offline');
      final r = await h.act('threads.set_following', {'message': 'm-1'});
      expect('${r['error']}', contains('读不到'));
    });
  });

  group('tasks from messages', () {
    test('create_from_message links the task to the message', () async {
      h.w.commandRoutes['POST /tasks/convert-message'] = (_) => {
        'task': {'id': 't-new', 'taskNumber': 12, 'messageId': 'm-1'},
      };
      final r = await h.act('tasks.create_from_message', {'message': 'm-1'});
      expect(h.summary(r), '把 Ada 的消息“周五上线可以吗？”变成任务');
      expect(h.changes(r).last, contains('连着这条消息'));
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.commands.single.$2, '/tasks/convert-message');
      expect(h.w.commands.single.$3, {'messageId': 'm-1'});
      final result = done['result'] as Map;
      expect(result['entity'], 'task');
      expect(result['id'], 't-new');
      expect(result['done'], '已变成任务 #12');
    });

    test('refused: DMs, system messages, left channels, guests', () async {
      h.w.dms = [...h.w.dms];
      put([
        msg('m-dm', channel: 'dm-1', seq: 50),
        msg('m-sys', extra: {'messageType': 'system'}, seq: 51),
        msg('m-old', channel: 'ch-old', seq: 52),
      ]);
      for (final (id, message) in [
        ('m-dm', '私信'),
        ('m-sys', '不能变成任务'),
        ('m-old', '没有加入或已归档'),
      ]) {
        final r = await h.act('tasks.create_from_message', {'message': id});
        expect('${r['error']}', contains(message), reason: id);
      }
      h.w.server = RaftRecord({'id': 's1', 'role': 'guest'});
      final r = await h.act('tasks.create_from_message', {'message': 'm-1'});
      expect('${r['error']}', contains('访客'));
      expect(h.w.commands, isEmpty);
    });

    test('create_batch makes several in one request', () async {
      h.w.routes['/channels/ch-general/members'] = (_) => {
        'humans': [
          {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
        ],
        'agents': [
          {'id': 'a-cody', 'name': 'cody', 'displayName': 'Cody'},
        ],
      };
      h.w.commandRoutes['POST /tasks/channel/ch-general'] = (data) => {
        'tasks': [
          for (final (i, _) in ((data as Map)['tasks'] as List).indexed)
            {'id': 't-b$i', 'taskNumber': 20 + i, 'revision': 1},
        ],
      };
      final r = await h.act('tasks.create_batch', {
        'channel': 'general',
        'titles': ['改登录页', '补测试', '写文档'],
        'assignee': 'Cody',
      });
      expect(h.summary(r), '在 #general 新建 3 个任务');
      expect(h.changes(r), [
        '频道:  → #general',
        '任务 1:  → 改登录页',
        '任务 2:  → 补测试',
        '任务 3:  → 写文档',
        '状态:  → 待办',
        '负责人:  → Cody',
      ]);
      final done = await h.approve(r);
      expect(done['status'], 'done', reason: '$done');
      final first = h.w.commands.first;
      expect(first.$2, '/tasks/channel/ch-general');
      expect(
        ((first.$3 as Map)['tasks'] as List).map((t) => (t as Map)['title']),
        ['改登录页', '补测试', '写文档'],
      );
      final patches = h.w.commands.where((c) => c.$1 == 'PATCH').toList();
      expect(patches.map((c) => c.$2), [
        '/tasks/t-b0/assignee',
        '/tasks/t-b1/assignee',
        '/tasks/t-b2/assignee',
      ]);
      expect((patches.first.$3 as Map)['assignee'], {'type': 'agent', 'id': 'a-cody'});
      expect((done['result'] as Map)['count'], 3);
    });

    test('create_batch validation', () async {
      Future<void> refused(Map<String, Object?> a, String message) async {
        final r = await h.act('tasks.create_batch', a);
        expect('${r['error']}', contains(message), reason: '$a');
      }

      await refused({'channel': 'general', 'titles': <String>[]}, '至少一个');
      await refused({'channel': 'general', 'titles': ['', ' ']}, '至少一个');
      await refused(
        {'channel': 'general', 'titles': [for (var i = 0; i < 21; i++) 't$i']},
        '最多建 20',
      );
      await refused({'titles': ['a']}, '缺少参数 channel');
      await refused({'channel': 'dm-1', 'titles': ['a']}, '不能建在私信');
      await refused({'channel': 'old', 'titles': ['a']}, '已归档');
      expect(h.w.commands, isEmpty);
    });
  });

  test('messages carry their files in what the model reads', () async {
    put([
      msg('m-img', attachments: [
        {'id': 'att-9', 'filename': 'a.png', 'mimeType': 'image/png'},
      ], seq: 60),
    ]);
    h.client.responses['GET /messages/channel/ch-general'] = {
      'messages': [
        msg('m-img', attachments: [
          {'id': 'att-9', 'filename': 'a.png', 'mimeType': 'image/png'},
        ], seq: 60),
      ],
    };
    final r = await h.tools.run('query', {
      'capability': 'channels.recent_messages',
      'args': {'channel': 'general'},
    });
    final rows = ((r!['result'] as Map)['messages'] as List).cast<Map>();
    expect(rows.single['attachments'], [
      {'id': 'att-9', 'filename': 'a.png', 'mimeType': 'image/png'},
    ]);
  });
}
