import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/gemini_text.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_service.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_writer.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The briefing service on a fictional workspace: Activity rows are template
/// text, the content behind them is read, and nothing is marked read.

DateTime ago(int minutes) => worldNow.subtract(Duration(minutes: minutes));

Map<String, dynamic> msg(
  String id,
  int seq,
  String text, {
  String from = 'Cody',
  String fromId = 'cody',
  String type = 'agent',
  int minutes = 20,
  List<String> mentions = const [],
}) => {
  'id': id,
  'seq': '$seq',
  'content': text,
  'senderId': fromId,
  'senderName': from,
  'senderType': type,
  'createdAt': ago(minutes).toIso8601String(),
  'mentions': [
    for (final m in mentions) {'id': m, 'type': 'user'},
  ],
};

Map<String, dynamic> threadRow() => {
  'kind': 'thread',
  'threadChannelId': 'th1',
  'parentChannelId': 'ch-general',
  'parentChannelName': 'general',
  'parentMessageId': 'p1',
  'parentMessagePreview': '重构第 10 步',
  'latestActivityMessageId': 'th1-m2',
  'latestActivityPreview': '有 3 条新回复',
  'latestActivitySenderType': 'agent',
  'latestActivitySenderId': 'cody',
  'latestActivitySenderName': 'Cody',
  'lastActivityAt': ago(20).toIso8601String(),
  'latestActivitySeq': '12',
  'replyCount': 3,
  'isFollowing': true,
  'unreadCount': 2,
  'hasMention': true,
};

Map<String, dynamic> channelRow(
  String id,
  String name, {
  required String msgId,
  String preview = '有新消息',
  int unread = 1,
  int seq = 5,
}) => {
  'kind': 'channel',
  'channelId': id,
  'channelName': name,
  'lastMessageId': msgId,
  'lastMessagePreview': preview,
  'lastMessageSenderType': 'agent',
  'lastMessageSenderId': 'codexmac',
  'lastMessageSenderName': 'CodexMac',
  'lastMessageAt': ago(8).toIso8601String(),
  'latestActivitySeq': '$seq',
  'unreadCount': unread,
  'hasMention': false,
};

Map<String, dynamic> dmRow() => {
  'kind': 'dm',
  'channelId': 'dm-1',
  'channelName': 'dm',
  'peerName': 'Ada',
  'lastMessageId': 'dm-m1',
  'lastMessagePreview': '有新消息',
  'lastMessageSenderType': 'user',
  'lastMessageSenderId': 'ada',
  'lastMessageSenderName': 'Ada',
  'lastMessageAt': ago(47).toIso8601String(),
  'latestActivitySeq': '3',
  'unreadCount': 1,
  'hasMention': false,
};

/// A model that answers from the prompt it is given.
class FakeGemini implements GeminiText {
  @override
  bool get lite => false;

  FakeGemini([this.reply]);

  /// Builds the reply from the request (null: no key).
  String? Function(Map<String, dynamic> request)? reply;
  final prompts = <String>[];
  Object? error;

  @override
  Duration get timeout => const Duration(seconds: 1);

  int get calls => prompts.length;

  @override
  Future<String?> generate(String system, String prompt) async {
    prompts.add(prompt);
    if (error != null) throw error!;
    return reply?.call(jsonDecode(prompt) as Map<String, dynamic>);
  }

  /// A valid reply that titles every item "T:" plus its id; [asking] answers the
  /// ambiguous ones.
  static String Function(Map<String, dynamic>) echo({
    bool asking = false,
    String overview = '模型总览',
  }) =>
      (req) => jsonEncode({
        'overview': overview,
        'items': [
          for (final i in req['items'] as List)
            {
              'id': (i as Map)['id'],
              'title': 'T:${i['id']}',
              'ask': '看一下',
              if (i['ambiguous'] == true) 'askingMe': asking,
            },
        ],
      });
}

int _rank(OrbReason r) => switch (r) {
  OrbReason.buildFailure => 0,
  OrbReason.mentionAsk || OrbReason.replyAsk || OrbReason.dmAsk => 1,
  _ => 2,
};

void main() {
  late ActivityClient client;
  late CapabilityWorld w;
  late List<Map<String, dynamic>> inbox;
  late Map<String, List<Map<String, dynamic>>> channelMessages;

  setUp(() {
    AgentModeData.clearSession();
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    inbox = [
      threadRow(),
      channelRow('ch-general', 'general', msgId: 'cm2'),
      dmRow(),
      channelRow('ch-design', 'design', msgId: 'dz1', preview: '有新消息'),
      // Read already: not new.
      channelRow('ch-old', 'old', msgId: 'o1', unread: 0),
    ];
    channelMessages = {
      'th1': [
        msg('th1-m1', 11, '第 10 步的方案写好了。'),
        msg('th1-m2', 12, '@Kevin 第 10 步的方案已经写好，等你批准就开工。', mentions: ['kevin']),
      ],
      'ch-general': [
        msg(
          'cm1',
          4,
          '重构第 9 步合并了',
          from: 'Ada',
          fromId: 'ada',
          type: 'user',
          minutes: 90,
        ),
        msg(
          'cm2',
          5,
          'Mac 验证通过，截图已经放进 PR 描述。',
          from: 'CodexMac',
          fromId: 'codexmac',
          minutes: 8,
        ),
      ],
      'dm-1': [
        msg(
          'dm-m1',
          3,
          '周五的设计评审你能参加吗？',
          from: 'Ada',
          fromId: 'ada',
          type: 'user',
          minutes: 47,
        ),
      ],
      'ch-design': [
        msg(
          'dz1',
          5,
          '午饭吃什么',
          from: 'Ada',
          fromId: 'ada',
          type: 'user',
          minutes: 90,
        ),
      ],
    };
    w.routes['/channels/inbox'] = (_) => {
      'items': inbox,
      'totalUnreadCount': 4,
      'hasMore': false,
    };
    w.routes['/messages/context/p1'] = (_) => {
      'messages': [msg('p1', 9, '重构第 10 步：拆分 activity 数据层', minutes: 300)],
    };
    w.routes['/tasks/server'] = (_) => {'tasks': []};
    w.routes['/agents'] = (_) => [
      {
        'id': 'a-cody',
        'name': 'cody',
        'displayName': 'Cody',
        'status': 'active',
        'runtime': 'codex',
        'creatorType': 'user',
        'creatorId': 'kevin',
      },
    ];
    w.routes['/servers/s1/members'] = (_) => [
      {'userId': 'kevin', 'name': 'kevin', 'displayName': 'Kevin'},
      {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
    ];
    for (final id in ['th1', 'ch-general', 'dm-1', 'ch-design', 'ch-old']) {
      client.responses['GET /messages/channel/$id'] = {
        'messages': channelMessages[id] ?? const [],
        'hasMore': false,
      };
    }
  });

  OrbBriefingService service({GeminiText? model}) =>
      OrbBriefingService(w, model: model, now: () => worldNow);

  group('without a model', () {
    test(
      'reads the content behind the template rows and sorts the day',
      () async {
        final b = await service().brief(OrbBriefScope.activity);
        // Cody's thread row only says "有 3 条新回复"; the request is in the
        // fetched reply.
        final cody = b.needsYou.firstWhere((i) => i.who == 'Cody');
        expect(cody.reason, OrbReason.awaitingApproval);
        expect(cody.title, contains('Cody'));
        expect(cody.title, contains('批准'));
        expect(cody.title, isNot(contains('新回复')));
        expect(cody.since, '已等 20 分钟');
        expect(cody.where, contains('#general'));
        expect(cody.ask, '批准');
        expect(cody.suggestedAction!.label, '回复：批准');
        expect(cody.suggestedAction!.kind, 'reply');
        expect(cody.link, contains('/channel/ch-general'));
        expect(cody.link, contains('thread=ch-general%3Ap1'));
        expect(cody.sourceIds, contains('th1-m2'));

        // Ada asks in a private conversation.
        final ada = b.needsYou.firstWhere((i) => i.who == 'Ada');
        expect(ada.reason, OrbReason.dmAsk);
        expect(ada.since, '已等 47 分钟');
        expect(ada.link, contains('/dm/dm-1'));
        expect(b.needsYou.length, 2);

        // Asks before the rest (Ada's question before Cody's approval).
        expect(b.needsYou.first.who, 'Ada');

        expect(b.progress.single.who, 'CodexMac');
        expect(b.progress.single.title, contains('Mac 验证通过'));
        expect(b.progress.single.title, isNot(contains('CodexMac')));
        // Lunch chatter is routine; the read row is not counted.
        expect(b.routineCount, 1);
        expect(b.overview, '4 条新动态，2 件需要你处理');
        expect(b.writtenByModel, isFalse);

        // Each item says how many of its messages are unread (the Activity's
        // "N 条未读"), for "把没读的摘要拿出来".
        expect(cody.unread, 2);
        expect(ada.unread, 1);
        expect(b.toJson()['needsYou'], [
          containsPair('unread', 1),
          containsPair('unread', 2),
        ]);
      },
    );

    test('driving mode re-reads live: a new row shows, nothing is marked '
        'read, and what was told stays', () async {
      final s = service();
      final first = await s.brief(OrbBriefScope.activity);
      expect(first.needsYou, hasLength(2));
      // A new question arrives in a private conversation.
      inbox.add({
        ...dmRow(),
        'channelId': 'dm-2',
        'peerName': 'Bob',
        'lastMessageId': 'dm-n1',
        'lastMessageSenderId': 'bob',
        'lastMessageSenderName': 'Bob',
        'lastMessageAt': ago(2).toIso8601String(),
      });
      client.responses['GET /messages/channel/dm-2'] = {
        'messages': [
          msg(
            'dm-n1',
            3,
            '你能看一下这个吗？',
            from: 'Bob',
            fromId: 'bob',
            type: 'user',
            minutes: 2,
          ),
        ],
        'hasMore': false,
      };
      client.posts.clear();
      final unread = {...w.unread};
      final live = await s.brief(
        OrbBriefScope.activity,
        full: true,
        remember: false,
      );
      expect(live.needsYou.map((i) => i.who), contains('Bob'));
      expect(live.needsYou, hasLength(3));
      expect(client.posts.every((p) => p.startsWith('GET ')), isTrue);
      expect(w.commands, isEmpty);
      expect(w.readAcks, isEmpty);
      expect(w.unread, unread);
      // The person was not told it: the next ordinary briefing has it.
      final delta = await s.brief(OrbBriefScope.activity);
      expect(delta.isDelta, isTrue);
      expect(delta.needsYou.map((i) => i.who), ['Bob']);
    });

    test('reading does not mark anything read', () async {
      final unread = {...w.unread};
      await service().brief(OrbBriefScope.activity);
      expect(client.posts, isNotEmpty);
      expect(
        client.posts.every((p) => p.startsWith('GET ')),
        isTrue,
        reason: '${client.posts}',
      );
      expect(w.commands, isEmpty);
      expect(w.readAcks, isEmpty);
      expect(w.unread, unread);
    });

    test(
      'a real name is never 有人, and a system event names its actor',
      () async {
        channelMessages['ch-general'] = [
          msg(
            'cm9',
            9,
            '🔄 Cody moved #136 to in_review',
            from: '',
            fromId: 'system',
            type: 'system',
            minutes: 3,
          ),
        ];
        client.responses['GET /messages/channel/ch-general'] = {
          'messages': channelMessages['ch-general'],
        };
        inbox[1] = {
          ...channelRow('ch-general', 'general', msgId: 'cm9'),
          'lastMessageSenderType': 'system',
          'lastMessageSenderId': 'system',
          'lastMessageSenderName': null,
          'isFollowing': true,
        };
        final b = await service().brief(OrbBriefScope.activity);
        final all = [...b.needsYou, ...b.progress];
        expect(
          all.any((i) => i.who == '有人' || i.title.contains('有人')),
          isFalse,
        );
        expect(b.progress.map((i) => i.who), contains('Cody'));
      },
    );

    test(
      'content that cannot be read falls back to the row, not a crash',
      () async {
        client.responses.remove('GET /messages/channel/dm-1');
        w.routes['/messages/context/p1'] = (_) => throw StateError('offline');
        final b = await service().brief(OrbBriefScope.activity);
        expect(b.needsYou, isNotEmpty);
      },
    );
  });

  // Kevin: "驾驶模式怎么还是死盯着那些任务不放呢？这个任务不代表我们现在就要处理。
  // 我们通常最高优先级是处理动态里的消息". In the Activity a task (or a blocked
  // agent) is never a card: it is counted, and said at the end.
  group('tasks and agents', () {
    void inReviewTask({int hours = 2, String title = '选型'}) {
      w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'in_review')
            taskRow(
              't94',
              94,
              'in_review',
              title: title,
              claimedById: 'a-cody',
              claimedByName: 'Cody',
              updated: hours,
            )..['messageId'] = 'tm94',
        ],
      };
      w.routes['/tasks/channel/ch-general'] = w.routes['/tasks/server']!;
    }

    Map<String, dynamic> agentRow(String id, String name, String creator) => {
      'id': id,
      'name': name.toLowerCase(),
      'displayName': name,
      'status': 'active',
      'runtime': 'codex',
      'activity': 'error',
      'activityDetail': '{"message":"quota exceeded"}',
      'creatorType': 'user',
      'creatorId': creator,
    };

    test('a task I created that is in review, and a blocked agent I manage, '
        'are counted and not cards', () async {
      inbox = [];
      inReviewTask();
      w.routes['/agents'] = (_) => [
        agentRow('a-cody', 'Cody', 'kevin'),
        agentRow('a-other', 'Other', 'someone-else'),
      ];
      final b = await service().brief(OrbBriefScope.activity);
      expect(b.needsYou, isEmpty);
      expect(b.progress, isEmpty);
      expect(b.waitingTasks, 2);
      expect(b.waitingTaskTitles, contains(contains('选型')));
      expect(b.overview, contains('另外有 2 个任务在等你验收，不急'));
      expect(b.toJson()['waitingTasks'], 2);
      expect(b.toJson()['waitingTaskTitles'], contains(contains('选型')));
    });

    test('a task waiting four days never outranks a fresh message', () async {
      inbox = [dmRow()];
      inReviewTask(hours: 96);
      final b = await service().brief(OrbBriefScope.activity);
      expect(b.needsYou.map((i) => i.who), ['Ada']);
      expect(b.needsYou.single.reason, OrbReason.dmAsk);
      expect(b.waitingTasks, 1);
      expect(b.overview, contains('1 件需要你处理'));
      expect(b.overview, contains('不急'));
    });

    test('a blocked agent is not in needsYou', () async {
      inbox = [dmRow()];
      w.routes['/agents'] = (_) => [agentRow('a-cody', 'Cody', 'kevin')];
      final b = await service().brief(OrbBriefScope.activity);
      expect(
        b.needsYou.map((i) => i.reason),
        isNot(contains(OrbReason.agentBlocked)),
      );
      expect(b.needsYou.map((i) => i.who), ['Ada']);
      expect(b.waitingTasks, 1);
    });

    test('no waiting task: no tail and nothing in the JSON', () async {
      final b = await service().brief(OrbBriefScope.activity);
      expect(b.waitingTasks, 0);
      expect(b.overview, isNot(contains('不急')));
      expect(b.toJson().containsKey('waitingTasks'), isFalse);
    });

    test('the titles are at most three', () async {
      inbox = [];
      w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'in_review')
            for (var n = 1; n <= 5; n++)
              taskRow(
                't$n',
                n,
                'in_review',
                title: '任务$n',
                claimedById: 'a-cody',
                claimedByName: 'Cody',
                updated: n,
              )..['messageId'] = 'tm$n',
        ],
      };
      final b = await service().brief(OrbBriefScope.activity);
      expect(b.waitingTasks, 5);
      expect(b.waitingTaskTitles, hasLength(3));
      expect(b.overview, contains('5 个任务'));
    });

    test(
      'the model overview gets the tail too, and counts messages only',
      () async {
        inbox = [dmRow()];
        inReviewTask(hours: 96);
        final gemini = FakeGemini(FakeGemini.echo(overview: '模型总览。'));
        final b = await service(model: gemini).brief(OrbBriefScope.activity);
        expect(b.overview, startsWith('模型总览'));
        expect(b.overview, endsWith('另外有 1 个任务在等你验收，不急'));
        final req = jsonDecode(gemini.prompts.single) as Map<String, dynamic>;
        expect((req['counts'] as Map)['needsYou'], 1);
        expect(
          (req['items'] as List).map((i) => (i as Map)['id']),
          isNot(contains('t94')),
        );
      },
    );

    test('a repeated briefing says the waiting tasks once', () async {
      inbox = [];
      inReviewTask();
      final s = service();
      final first = await s.brief(OrbBriefScope.activity);
      expect(first.waitingTasks, 1);
      final second = await s.brief(OrbBriefScope.activity);
      expect(second.isDelta, isTrue);
      expect(second.waitingTasks, 0);
      expect(second.overview, isNot(contains('不急')));
      final full = await s.brief(OrbBriefScope.activity, full: true);
      expect(full.waitingTasks, 1);
    });

    test('a conversation briefing still lists its tasks', () async {
      inReviewTask();
      final b = await service().brief(
        const OrbBriefScope.conversation('ch-general'),
      );
      expect(b.waitingTasks, 0);
      expect(
        b.needsYou.where((i) => i.reason == OrbReason.awaitingApproval),
        isNotEmpty,
      );
    });
  });

  group('the order of the Activity', () {
    test(
      'a build failure, then asks, then the rest; the newest first',
      () async {
        channelMessages['ch-design'] = [
          msg(
            'dz1',
            5,
            '构建失败了：flutter test 红了',
            from: 'CI',
            fromId: 'ci',
            type: 'user',
            minutes: 200,
          ),
        ];
        client.responses['GET /messages/channel/ch-design'] = {
          'messages': channelMessages['ch-design'],
        };
        final b = await service().brief(OrbBriefScope.activity);
        final order = b.needsYou.map((i) => i.reason).toList();
        expect(order.first, OrbReason.buildFailure);
        final rank = {for (final r in OrbReason.values) r: _rank(r)};
        final ranks = order.map((r) => rank[r]!).toList();
        expect([...ranks]..sort(), ranks);
      },
    );

    test('newest first within a group', () async {
      inbox = [
        dmRow(),
        {
          ...dmRow(),
          'channelId': 'dm-2',
          'peerName': 'Bob',
          'lastMessageId': 'dm-n1',
          'lastMessageSenderId': 'bob',
          'lastMessageSenderName': 'Bob',
          'lastMessageAt': ago(5).toIso8601String(),
        },
      ];
      client.responses['GET /messages/channel/dm-2'] = {
        'messages': [
          msg(
            'dm-n1',
            3,
            '你能看一下这个吗？',
            from: 'Bob',
            fromId: 'bob',
            type: 'user',
            minutes: 5,
          ),
        ],
        'hasMore': false,
      };
      final b = await service().brief(OrbBriefScope.activity);
      final asks = b.needsYou.where((i) => i.reason == OrbReason.dmAsk);
      expect(asks.map((i) => i.who), ['Bob', 'Ada']);
    });
  });

  // Kevin: asked to read the Activity, it kept talking about tasks. Every
  // task he created that moved in a day was "progress" in the Activity
  // briefing, and he creates most of them.
  test('in the Activity a task that does not need me is not progress; in its '
      'channel it is', () async {
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          taskRow(
            't95',
            95,
            'in_progress',
            title: '重构第 11 步',
            claimedById: 'a-cody',
            claimedByName: 'Cody',
            updated: 1,
          ),
      ],
    };
    w.routes['/tasks/channel/ch-general'] = w.routes['/tasks/server']!;
    final activity = await service().brief(OrbBriefScope.activity);
    expect(
      [...activity.needsYou, ...activity.progress].map((i) => i.title),
      isNot(contains(contains('重构第 11 步'))),
    );
    final channel = await service().brief(
      const OrbBriefScope.conversation('ch-general'),
    );
    expect(
      channel.progress.map((i) => i.title),
      contains(contains('重构第 11 步')),
    );
  });

  group('the model', () {
    test('writes the titles and the overview; ambiguous items are decided '
        'by it', () async {
      final gemini = FakeGemini(FakeGemini.echo(asking: true));
      // Ada's private message says nothing that reads as a request.
      channelMessages['dm-1'] = [
        msg('dm-m1', 3, '新的颜色方案已更新', from: 'Ada', fromId: 'ada', type: 'user'),
      ];
      client.responses['GET /messages/channel/dm-1'] = {
        'messages': channelMessages['dm-1'],
      };
      final b = await service(model: gemini).brief(OrbBriefScope.activity);
      expect(gemini.calls, 1);
      expect(b.writtenByModel, isTrue);
      expect(b.overview, '模型总览');
      expect(b.needsYou.map((i) => i.title), everyElement(startsWith('T:')));
      // The model said Ada asks: needs you.
      expect(b.needsYou.any((i) => i.who == 'Ada'), isTrue);
      expect(b.needsYou.firstWhere((i) => i.who == 'Ada').askingMe, isTrue);
    });

    test(
      'the unread counts are the Activity\'s, whoever worded the titles',
      () async {
        final plain = await service().brief(OrbBriefScope.activity);
        final written = await service(
          model: FakeGemini(FakeGemini.echo(asking: true)),
        ).brief(OrbBriefScope.activity);
        expect(written.writtenByModel, isTrue);
        final counts = {
          for (final i in [...plain.needsYou, ...plain.progress])
            i.id: i.unread,
        };
        expect(counts.values.any((n) => n > 0), isTrue);
        for (final i in [...written.needsYou, ...written.progress]) {
          expect(i.unread, counts[i.id], reason: i.who);
        }
        expect(
          written.toJson()['needsYou'],
          contains(containsPair('unread', greaterThan(0))),
        );
      },
    );

    test('FYI from the model leaves an ambiguous item as progress', () async {
      final gemini = FakeGemini(FakeGemini.echo(asking: false));
      channelMessages['dm-1'] = [
        msg('dm-m1', 3, '新的颜色方案已更新', from: 'Ada', fromId: 'ada', type: 'user'),
      ];
      client.responses['GET /messages/channel/dm-1'] = {
        'messages': channelMessages['dm-1'],
      };
      final b = await service(model: gemini).brief(OrbBriefScope.activity);
      expect(b.needsYou.any((i) => i.who == 'Ada'), isFalse);
      expect(b.progress.any((i) => i.who == 'Ada'), isTrue);
    });

    test('the model cannot demote a definite request', () async {
      final gemini = FakeGemini(FakeGemini.echo(asking: false));
      final b = await service(model: gemini).brief(OrbBriefScope.activity);
      expect(
        b.needsYou.map((i) => i.reason),
        containsAll([OrbReason.awaitingApproval, OrbReason.dmAsk]),
      );
    });

    final invalid = <String, String Function(Map<String, dynamic>)>{
      'not json': (_) => '好的，简报如下',
      'an unknown id': (_) => jsonEncode({
        'overview': 'x',
        'items': [
          {'id': 'nope', 'title': 'x'},
        ],
      }),
      'an unknown key': (r) => jsonEncode({
        'overview': 'x',
        'items': [
          {'id': (r['items'] as List).first['id'], 'title': 'x', 'priority': 1},
        ],
      }),
      'a title that is not text': (r) => jsonEncode({
        'items': [
          {'id': (r['items'] as List).first['id'], 'title': 7},
        ],
      }),
      'a title over its cap': (r) => jsonEncode({
        'items': [
          {'id': (r['items'] as List).first['id'], 'title': '长' * 200},
        ],
      }),
      'an array': (_) => '[]',
    };
    invalid.forEach((name, reply) {
      test('a reply with $name falls back to the rules', () async {
        final gemini = FakeGemini(reply);
        final b = await service(model: gemini).brief(OrbBriefScope.activity);
        expect(gemini.calls, 1);
        expect(b.writtenByModel, isFalse);
        expect(b.overview, '4 条新动态，2 件需要你处理');
        expect(
          b.needsYou.map((i) => i.title),
          everyElement(isNot(startsWith('T:'))),
        );
        expect(b.needsYou, hasLength(2));
      });
    });

    test('an ambiguous item with no verdict makes the reply invalid', () async {
      channelMessages['dm-1'] = [
        msg('dm-m1', 3, '新的颜色方案已更新', from: 'Ada', fromId: 'ada', type: 'user'),
      ];
      client.responses['GET /messages/channel/dm-1'] = {
        'messages': channelMessages['dm-1'],
      };
      final gemini = FakeGemini(
        (req) => jsonEncode({
          'overview': 'x',
          'items': [
            for (final i in req['items'] as List)
              {'id': (i as Map)['id'], 'title': 'T'},
          ],
        }),
      );
      final b = await service(model: gemini).brief(OrbBriefScope.activity);
      expect(b.writtenByModel, isFalse);
    });

    test('a model that throws leaves the rules', () async {
      final gemini = FakeGemini()..error = const FormatException('boom');
      final b = await service(model: gemini).brief(OrbBriefScope.activity);
      expect(b.writtenByModel, isFalse);
      expect(b.needsYou, hasLength(2));
    });

    test('no key: the briefing works from the rules', () async {
      final b = await service(
        model: GeminiText(key: AgentVoiceKey.forTesting(null)),
      ).brief(OrbBriefScope.activity);
      expect(b.writtenByModel, isFalse);
      expect(b.needsYou, hasLength(2));
      expect(b.overview, contains('需要你处理'));
    });

    test(
      'the input is bounded: long messages are cut, items are capped',
      () async {
        channelMessages['th1'] = [
          msg(
            'th1-m2',
            12,
            '@Kevin 等你批准。${'很长的内容' * 400}',
            mentions: ['kevin'],
          ),
        ];
        client.responses['GET /messages/channel/th1'] = {
          'messages': channelMessages['th1'],
        };
        final gemini = FakeGemini(FakeGemini.echo());
        await service(model: gemini).brief(OrbBriefScope.activity);
        final req = jsonDecode(gemini.prompts.single) as Map<String, dynamic>;
        for (final i in req['items'] as List) {
          for (final m in (i as Map)['messages'] as List) {
            expect(
              ((m as Map)['text'] as String).length,
              lessThanOrEqualTo(OrbBriefingWriter.maxMessageChars + 1),
            );
          }
        }
        expect(gemini.prompts.single.length, lessThan(8000));
      },
    );

    test(
      'the cache: an unchanged item is not sent again, a changed one is',
      () async {
        final gemini = FakeGemini(FakeGemini.echo());
        final s = service(model: gemini);
        final first = await s.brief(OrbBriefScope.activity, full: true);
        expect(gemini.calls, 1);
        final second = await s.brief(OrbBriefScope.activity, full: true);
        expect(gemini.calls, 1, reason: 'nothing changed: no second call');
        expect(
          second.needsYou.map((i) => i.title),
          first.needsYou.map((i) => i.title),
        );
        expect(second.overview, first.overview);

        // A new message in Cody's thread changes that item only.
        channelMessages['th1'] = [
          ...channelMessages['th1']!,
          msg(
            'th1-m3',
            13,
            '@Kevin 另外，第 11 步也等你批准',
            mentions: ['kevin'],
            minutes: 1,
          ),
        ];
        client.responses['GET /messages/channel/th1'] = {
          'messages': channelMessages['th1'],
        };
        inbox[0] = {...threadRow(), 'latestActivityMessageId': 'th1-m3'};
        await s.brief(OrbBriefScope.activity, full: true);
        expect(gemini.calls, 2);
        final req = jsonDecode(gemini.prompts.last) as Map<String, dynamic>;
        expect((req['items'] as List), hasLength(1));
        expect((req['known'] as List), isNotEmpty);
      },
    );
  });

  // The orb warms the Activity briefing when it opens, so `navigate` finds
  // the model's words ready (8-9 s from request to first word on the G100).
  group('warming', () {
    test('a briefing after a warm-up asks the model nothing new', () async {
      final gemini = FakeGemini(FakeGemini.echo());
      final s = service(model: gemini);
      await s.warm(OrbBriefScope.activity);
      expect(gemini.calls, 1);
      final b = await s.brief(OrbBriefScope.activity, full: true);
      expect(gemini.calls, 1);
      expect(b.writtenByModel, isTrue);
    });

    test(
      'a briefing during a warm-up waits for it instead of asking twice',
      () async {
        final gemini = FakeGemini(FakeGemini.echo());
        final s = service(model: gemini);
        final warming = s.warm(OrbBriefScope.activity);
        final b = await s.brief(OrbBriefScope.activity, full: true);
        await warming;
        expect(gemini.calls, 1);
        expect(b.writtenByModel, isTrue);
      },
    );

    test(
      'a warm-up is not "told": the next briefing is the whole picture',
      () async {
        final s = service();
        await s.warm(OrbBriefScope.activity);
        final first = await s.brief(OrbBriefScope.activity);
        expect(first.isDelta, isFalse);
        expect(first.needsYou, hasLength(2));
      },
    );

    // The reading was the other half of the wait: a briefing right after a
    // warm-up reuses what it read while nothing changed.
    test('a briefing after a warm-up reads no conversation again', () async {
      final s = service();
      await s.warm(OrbBriefScope.activity);
      final read = [
        for (final p in client.posts)
          if (p.startsWith('GET /messages/channel/')) p,
      ];
      expect(read, isNotEmpty);
      client.posts.clear();
      final b = await s.brief(OrbBriefScope.activity, full: true);
      expect(b.needsYou, hasLength(2));
      expect(
        client.posts.where((p) => p.startsWith('GET /messages/channel/')),
        isEmpty,
      );
    });

    test(
      'a row with a newer message is read again, the rest are not',
      () async {
        final s = service();
        await s.warm(OrbBriefScope.activity);
        channelMessages['dm-1'] = [
          ...channelMessages['dm-1']!,
          msg(
            'dm-m2',
            4,
            '另外你有空吗？',
            from: 'Ada',
            fromId: 'ada',
            type: 'user',
            minutes: 1,
          ),
        ];
        client.responses['GET /messages/channel/dm-1'] = {
          'messages': channelMessages['dm-1'],
        };
        inbox[2] = {...dmRow(), 'lastMessageId': 'dm-m2'};
        client.posts.clear();
        final b = await s.brief(OrbBriefScope.activity, full: true);
        expect(
          client.posts.where((p) => p.startsWith('GET /messages/channel/')),
          ['GET /messages/channel/dm-1'],
        );
        expect(
          b.needsYou.where((i) => i.who == 'Ada').single.title,
          contains('有空'),
        );
      },
    );

    test('a failing warm-up is quiet', () async {
      final gemini = FakeGemini(FakeGemini.echo())..error = StateError('boom');
      final s = service(model: gemini);
      await s.warm(OrbBriefScope.activity);
      final b = await s.brief(OrbBriefScope.activity, full: true);
      expect(b.needsYou, hasLength(2));
    });
  });

  group('since last time', () {
    test('a repeat call says only what is new; full says everything', () async {
      final s = service();
      final first = await s.brief(OrbBriefScope.activity);
      expect(first.isDelta, isFalse);
      expect(first.needsYou, hasLength(2));

      final again = await s.brief(OrbBriefScope.activity);
      expect(again.isDelta, isTrue);
      expect(again.needsYou, isEmpty);
      expect(again.progress, isEmpty);
      expect(again.carriedOver, 3);
      expect(again.overview, contains('没有新的'));

      final full = await s.brief(OrbBriefScope.activity, full: true);
      expect(full.isDelta, isFalse);
      expect(full.needsYou, hasLength(2));
    });

    test('a newer message in something briefed is new again', () async {
      final s = service();
      await s.brief(OrbBriefScope.activity);
      channelMessages['dm-1'] = [
        ...channelMessages['dm-1']!,
        msg(
          'dm-m2',
          4,
          '另外你有空吗？',
          from: 'Ada',
          fromId: 'ada',
          type: 'user',
          minutes: 1,
        ),
      ];
      client.responses['GET /messages/channel/dm-1'] = {
        'messages': channelMessages['dm-1'],
      };
      inbox[2] = {...dmRow(), 'lastMessageId': 'dm-m2'};
      final again = await s.brief(OrbBriefScope.activity);
      expect(again.isDelta, isTrue);
      expect(again.needsYou.map((i) => i.who), ['Ada']);
      expect(again.overview, contains('新增'));
    });

    test('each scope is remembered on its own', () async {
      final s = service();
      await s.brief(OrbBriefScope.activity);
      final conversation = await s.brief(
        const OrbBriefScope.conversation('ch-general'),
      );
      expect(conversation.isDelta, isFalse);
    });
  });

  group('a conversation', () {
    test('the unread messages that concern me, and the progress', () async {
      w.unread = {'ch-general': 3};
      channelMessages['ch-general'] = [
        msg(
          'c1',
          1,
          '午饭吃什么',
          from: 'Ada',
          fromId: 'ada',
          type: 'user',
          minutes: 60,
        ),
        msg('c2', 2, '@Kevin 发布前你再确认一下版本号吧？', mentions: ['kevin'], minutes: 30),
        msg(
          'c3',
          3,
          'Mac 验证通过',
          from: 'CodexMac',
          fromId: 'codexmac',
          minutes: 8,
        ),
      ];
      client.responses['GET /messages/channel/ch-general'] = {
        'messages': channelMessages['ch-general'],
      };
      final b = await service().brief(
        const OrbBriefScope.conversation('ch-general'),
      );
      expect(b.needsYou.single.reason, OrbReason.mentionAsk);
      expect(b.needsYou.single.since, '已等 30 分钟');
      expect(b.needsYou.single.link, contains('msg=c2'));
      expect(b.progress.single.who, 'CodexMac');
      expect(b.routineCount, 1);
      expect(client.posts.every((p) => p.startsWith('GET ')), isTrue);
    });
  });
}
