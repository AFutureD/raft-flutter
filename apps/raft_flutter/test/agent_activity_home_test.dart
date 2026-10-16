import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/resource_row_reconcile.dart'
    show activityItemKey;
import 'package:raft_flutter/data/source_activity_unread_store.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_activity_feed.dart';
import 'package:raft_flutter/features/agent_mode/agent_attention.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_snooze.dart';
import 'package:raft_flutter/features/resource_view.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart'
    show ActivityClient, ActivityWorkspace, activityFixture;

/// The home of agent mode is the App's Activity: the same rows, the same
/// order, live; the tasks that wait for a decision among them; the tasks
/// nobody touched for days apart; the whole conversation behind a row; the
/// feedback on a row through the tools every operation uses.
/// Fictional people, channels and tasks.
final _now = DateTime.utc(2026, 10, 17, 12);

String _ago(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toIso8601String();

Map<String, dynamic> _thread(
  String id, {
  int minutes = 5,
  int unread = 1,
  bool mention = false,
  String preview = '首片出了，两张误检',
  String who = 'Cody',
  int? task,
  String? status,
}) => {
  'kind': 'thread',
  'threadChannelId': id,
  'parentChannelId': 'c1',
  'parentChannelName': 'raft-flutter',
  'parentChannelType': 'channel',
  'parentMessageId': 'p-$id',
  'parentMessagePreview': '检测首片什么时候出？',
  'parentMessageSenderId': 'kevin',
  'latestActivityMessageId': 'l-$id',
  'latestActivityPreview': preview,
  'latestActivitySenderName': who,
  'latestActivitySenderId': 'a-cody',
  'latestActivitySenderType': 'agent',
  'firstUnreadMessageId': unread > 0 ? 'u-$id' : null,
  'lastActivityAt': _ago(minutes),
  'unreadCount': unread,
  'hasMention': mention,
  'isFollowing': true,
  'taskNumber': ?task,
  'taskStatus': ?status,
};

Map<String, dynamic> _dm(
  String id, {
  int minutes = 20,
  int unread = 1,
  String preview = '周五的评审你能来吗？',
}) => {
  'kind': 'dm',
  'channelId': id,
  'channelName': 'alice',
  'channelType': 'dm',
  'lastMessageId': 'l-$id',
  'lastMessagePreview': preview,
  'lastMessageSenderName': 'Alice Chen',
  'lastMessageSenderId': 'u-alice',
  'lastMessageSenderType': 'user',
  'firstUnreadMessageId': unread > 0 ? 'u-$id' : null,
  'lastMessageAt': _ago(minutes),
  'unreadCount': unread,
  'hasMention': false,
};

Map<String, dynamic> _channel(
  String id, {
  int minutes = 90,
  int unread = 0,
  bool mention = false,
  String preview = '托盘退出验证通过',
}) => {
  'kind': 'channel',
  'channelId': id,
  'channelName': 'ch-$id',
  'channelType': 'channel',
  'lastMessageId': 'l-$id',
  'lastMessagePreview': preview,
  'lastMessageSenderName': 'CodexWin',
  'lastMessageSenderId': 'a-codexwin',
  'lastMessageSenderType': 'agent',
  'firstUnreadMessageId': unread > 0 ? 'u-$id' : null,
  'lastMessageAt': _ago(minutes),
  'unreadCount': unread,
  'hasMention': mention,
};

Map<String, dynamic> _task(
  String id,
  int number,
  String status,
  int minutes,
  String title,
) => {
  'id': id,
  'taskNumber': number,
  'title': title,
  'status': status,
  'channelId': 'c1',
  'channelName': 'raft-flutter',
  'createdById': 'kevin',
  'createdByType': 'user',
  'createdByName': 'Kevin',
  'claimedById': 'a-cindy',
  'claimedByType': 'agent',
  'claimedByName': 'Cindy',
  'updatedAt': _ago(minutes),
};

/// The rows of the Activity the tests read, newest first.
List<Map<String, dynamic>> _rows() => [
  _thread('th1', minutes: 3, unread: 2, mention: true),
  _dm('d1', minutes: 14),
  _channel('c2', minutes: 40, unread: 4),
  {
    'kind': 'mention_action',
    'id': 'ma1',
    'unreadCount': 0,
    'channelId': 'c1',
    'channelName': 'raft-flutter',
    'channelType': 'channel',
    'messageId': 'ma1',
    'messagePreview': '@Dora 要加进来吗？',
    'lastMessageAt': _ago(60),
  },
  _thread(
    'th2',
    minutes: 90,
    unread: 0,
    who: 'Grok',
    preview: '回归测试补完了',
    task: 41,
    status: 'in_review',
  ),
  _channel('c3', minutes: 300, preview: '暗色稿上传了'),
];

void main() {
  late ActivityClient client;
  late ActivityWorkspace w;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    AgentModeData.clearSession();
    (client, w) = activityFixture();
    w.inbox = _rows();
    w.channels = [
      RaftChannel({'id': 'c1', 'name': 'raft-flutter', 'joined': true}),
      RaftChannel({'id': 'c2', 'name': 'ch-c2', 'joined': true}),
      RaftChannel({'id': 'c3', 'name': 'ch-c3', 'joined': true}),
    ];
    w.dms = [
      RaftChannel({
        'id': 'd1',
        'type': 'dm',
        'name': 'alice',
        'peerDisplayName': 'Alice Chen',
        'joined': true,
      }),
    ];
    client.user = RaftRecord({'id': 'kevin', 'displayName': 'Kevin'});
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  group('the same source as the App\'s Activity', () {
    testWidgets('the home lists the same items, in the same order, as the '
        'Activity page', (t) async {
      await t.runAsync(() => client.login('fixture', 'fixture'));
      // The Activity page, as the App mounts it.
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Scaffold(
            body: ResourceView(
              controller: w,
              section: 'activity',
              activitySidebarEnabled: true,
              onMessage: (_, _) async {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final dynamic state = t.state(find.byType(ResourceView));
      final page = [
        for (final row in state.rows as List) activityItemKey(row as Map)!,
      ];
      expect(page, hasLength(_rows().length));

      final home = (await t.runAsync(
        () => AgentModeData(w, now: () => _now).attention(),
      ))!;
      expect([for (final i in home.items) i.id], [
        for (final key in page) 'activity:$key',
      ]);
      // The unread state is the row's own.
      expect(
        [for (final i in home.items) i.unread],
        [for (final r in _rows()) r['unreadCount']],
      );
      expect(home.unreadCount, 3);
      expect(home.items.first.isActivity, isTrue);
    });

    testWidgets('the rows come from the window the Activity badge reads', (
      t,
    ) async {
      await t.runAsync(() => client.login('fixture', 'fixture'));
      final store = w.activityUnread;
      await t.runAsync(store.refresh);
      final queries = w.inboxQueries.length;
      final home = (await t.runAsync(
        () => AgentModeData(w, now: () => _now).attention(),
      ))!;
      // No second read of the inbox: the home took the store's window.
      expect(w.inboxQueries.length, queries);
      expect(home.items, hasLength(_rows().length));
    });

    test('each row says who, where, the words, how long ago and why', () {
      final feed = AgentActivityFeed(
        now: _now,
        myId: 'kevin',
        channels: w.channels,
        dms: w.dms,
      );
      final items = feed.itemsOf(_rows());
      final thread = items[0];
      expect(thread.doer, 'Cody');
      expect(thread.place, '#raft-flutter › 检测首片什么时候出？');
      expect(thread.excerpt, '首片出了，两张误检');
      expect(thread.agoLabel, '3 分钟前');
      expect(thread.reason, '点名了你');
      expect(thread.unread, 2);
      expect(thread.priority, AgentPriority.mention);
      expect(thread.tone, HfTone.mention);
      final dm = items[1];
      expect(dm.reason, '私信你');
      expect(dm.place, '私信 · Alice Chen');
      expect(dm.dm, isTrue);
      expect(dm.tone, HfTone.info);
      expect(items[2].reason, '频道有新消息');
      expect(items[2].place, '#ch-c2');
      expect(items[3].reason, '点名后等你处理');
      expect(items[3].rowKind, 'mention_action');
      // A thread under a message of mine, read: it replied to me.
      expect(items[4].reason, '回复了你的消息');
      expect(items[4].unread, 0);
      final mine = feed.itemOf({
        ..._thread('th9', unread: 0, who: 'Kevin'),
        'latestActivitySenderId': 'kevin',
        'latestActivitySenderType': 'user',
      })!;
      expect(mine.headline, startsWith('你：'));
      expect(mine.doer, isNull);
    });
  });

  group('live', () {
    testWidgets('a message that arrives while the home is open appears at '
        'the top, tagged', (t) async {
      SourceActivityUnreadStore.clock = t.binding.clock.now;
      addTearDown(() => SourceActivityUnreadStore.clock = DateTime.now);
      await t.runAsync(() => client.login('fixture', 'fixture'));
      t.view.physicalSize = const Size(430, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(
            controller: w,
            data: AgentModeData(w, now: () => _now),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-card-activity:thread:th1')), findsOneWidget);
      expect(find.text('刚到'), findsNothing);

      // The server lists the new message and the socket announces it: the
      // path of the App's own Activity.
      w.inbox = [
        _channel(
          'c9',
          minutes: 0,
          unread: 1,
          mention: true,
          preview: '暗色稿改好了，你看一眼可以就合',
        ),
        ...w.inbox,
      ];
      client.emit('message:new', {
        'id': 'l-c9',
        'channelId': 'c9',
        'seq': '8',
        'content': '暗色稿改好了',
      });
      await t.pump(const Duration(milliseconds: 200));
      await t.pumpAndSettle();
      final fresh = find.byKey(
        const ValueKey('attention-card-activity:channel:c9'),
      );
      expect(fresh, findsOneWidget);
      expect(find.text('刚到'), findsOneWidget);
      expect(find.text('CodexWin：暗色稿改好了，你看一眼可以就合'), findsOneWidget);
      // It is the first row; the one that was first is second.
      expect(t.getTopLeft(fresh).dy, lessThan(t.getTopLeft(find.byKey(const ValueKey('attention-card-activity:thread:th1'))).dy));
    });
  });

  group('stale tasks', () {
    testWidgets('are apart, collapsed, at the bottom; opening shows them', (
      t,
    ) async {
      final data = _HomeData(w);
      data.result = AgentAttention(
        items: data.feed(_rows()),
        stale: [
          data.staleTask('s1', 77, 6 * 24 * 60, '安装包签名'),
          data.staleTask('s2', 80, 9 * 24 * 60, '迁移脚本'),
        ],
      );
      t.view.physicalSize = const Size(430, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: w, data: data),
        ),
      );
      await t.pumpAndSettle();
      // The first row is an Activity row, never a stale task.
      expect(find.byKey(const ValueKey('attention-card-activity:thread:th1')), findsOneWidget);
      final group = find.byKey(const ValueKey('attention-stale'));
      expect(find.text('可能需要收尾 2 件'), findsOneWidget);
      expect(group, findsOneWidget);
      // Collapsed: its cards are not drawn, and it comes after every row.
      expect(find.byKey(const ValueKey('attention-card-s1')), findsNothing);
      expect(
        t.getTopLeft(group).dy,
        greaterThan(
          t.getBottomLeft(find.byKey(const ValueKey('attention-card-activity:channel:c3'))).dy,
        ),
      );
      // The count line does not count them as decisions.
      expect(find.byKey(const ValueKey('attention-count-decision')), findsNothing);

      await t.tap(group);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-card-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attention-card-s2')), findsOneWidget);
      // Numbered after the feed (6 rows).
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('attention-card-s1')),
          matching: find.text('7'),
        ),
        findsOneWidget,
      );
      await t.tap(group);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('attention-card-s1')), findsNothing);
    });
  });

  group('open', () {
    testWidgets('shows the whole conversation, the item highlighted, one '
        'page, the tasks behind a chip', (t) async {
      final data = _HomeData(w);
      data.result = AgentAttention(items: data.feed(_rows()));
      data.convos['th1'] = AgentConversationRead(
        rows: [
          for (var i = 1; i <= 12; i++)
            {
              'id': i == 1
                  ? 'p-th1'
                  : (i == 5 ? 'u-th1' : (i == 12 ? 'l-th1' : 'm$i')),
              'seq': '$i',
              'senderType': i.isEven ? 'agent' : 'user',
              'senderId': i.isEven ? 'a-cody' : 'kevin',
              'senderName': i.isEven ? 'Cody' : 'Kevin',
              'content': '第 $i 句话',
              'messageType': 'chat',
              'createdAt': _ago(200 - i * 10),
            },
          {
            'id': 'sys1',
            'seq': '13',
            'senderType': 'system',
            'content': 'Cody moved #98 "搜索" to In Review',
            'messageType': 'system',
            'createdAt': _ago(2),
          },
        ],
      );
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: w, data: data),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('attention-card-activity:thread:th1')));
      await t.pumpAndSettle();
      final openButton = find.byKey(
        const ValueKey('attention-open-activity:thread:th1'),
      );
      await t.ensureVisible(openButton);
      await t.tap(openButton);
      await t.pumpAndSettle();
      expect(data.reads, ['th1']);
      expect(find.text('第 2 层'), findsOneWidget);
      // A thread: its title, and where it is.
      expect(find.text('讨论 · 检测首片什么时候出？'), findsWidgets);
      // The page is the layer's one scroll.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('hf-page')),
          matching: find.byType(Scrollable),
        ),
        findsOneWidget,
      );
      // The message the Activity page opens at is the highlighted one (the
      // first unread of the thread): every message of the list is there.
      for (final id in ['p-th1', 'm2', 'u-th1', 'm7', 'l-th1']) {
        expect(
          find.byKey(ValueKey('hf-bubble-$id'), skipOffstage: false),
          findsOneWidget,
          reason: id,
        );
      }
      expect(find.text('第 12 句话', skipOffstage: false), findsOneWidget);
      // A system message is a note, not a bubble.
      expect(find.byKey(const ValueKey('hf-bubble-sys1'), skipOffstage: false), findsNothing);
      Color? fill(String id) =>
          (t
                      .widget<DecoratedBox>(
                        find.byKey(
                          ValueKey('hf-bubble-$id'),
                          skipOffstage: false,
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color;
      expect(fill('u-th1'), const Color(0xfffff7d6));
      expect(fill('m7'), isNot(const Color(0xfffff7d6)));
      // The chip of the tasks is in the header, the tasks are not on top.
      expect(find.byKey(const ValueKey('conversation-tasks')), findsNothing);
      expect(t.takeException(), isNull);
    }, skip: false);
  });

  group('feedback', () {
    final ran = <(String, Map<String, Object?>)>[];

    AgentCapability spy(
      String id,
      List<String> props, {
      List<String> required = const [],
    }) => AgentCapability(
      id: id,
      title: '测试：$id',
      kind: AgentCapabilityKind.action,
      risk: AgentCapabilityRisk.change,
      paramsSchema: {
        'type': 'object',
        'properties': {
          for (final p in props) p: {'type': 'string', 'description': p},
        },
        'required': required,
      },
      resultSummary: 'done',
      keywords: [id],
      preview: (w, args, env) async => AgentActionPreview(
        summary: '预览 $id',
        changes: [for (final e in args.entries) '${e.key}: → ${e.value}'],
      ),
      run: (w, args, env) async {
        ran.add((id, Map<String, Object?>.of(args)));
        return {'status': 'done'};
      },
    );

    final spied = {
      'messages.react',
      'messages.reply_thread',
      'messages.send',
      'activity.mark_done',
      'tasks.assign',
      'tasks.create',
    };
    final registry = AgentCapabilityRegistry([
      spy('messages.react', ['message', 'emoji', 'channel'], required: ['message', 'emoji']),
      spy('messages.reply_thread', ['message', 'text', 'channel'], required: ['message', 'text']),
      spy('messages.send', ['channel', 'text'], required: ['channel', 'text']),
      spy('activity.mark_done', ['channel', 'thread'], required: ['channel']),
      spy('tasks.assign', ['task', 'assignee', 'channel'], required: ['task', 'assignee']),
      spy('tasks.create', ['channel', 'title', 'description', 'assignee'], required: ['channel', 'title']),
      for (final c in agentStandardCapabilities.all)
        if (!spied.contains(c.id)) c,
    ]);

    late _HomeData data;

    Future<void> open(WidgetTester t) async {
      ran.clear();
      data = _HomeData(w);
      final decision = data.decisionTask('t1', 41, 'th2');
      data.result = AgentAttention(
        items: AgentActivityFeed.compose(data.feed(_rows()), [decision]),
        pool: [decision],
      );
      t.view.physicalSize = const Size(412, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(
            controller: w,
            data: data,
            registry: registry,
            model: const AgentScriptedModel(),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    Future<void> current(WidgetTester t, String id) async {
      final card = find.byKey(ValueKey('attention-card-$id'));
      await t.ensureVisible(card);
      await t.tap(card);
      await t.pumpAndSettle();
    }

    Future<void> press(WidgetTester t, String key) async {
      final f = find.byKey(ValueKey(key));
      await t.ensureVisible(f);
      await t.tap(f);
      await t.pumpAndSettle();
    }

    Future<void> confirm(WidgetTester t) async {
      expect(find.text('确认'), findsOneWidget);
      await t.tap(find.text('确认'));
      await t.pumpAndSettle();
    }

    Future<void> type(WidgetTester t, String text) async {
      if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
        await t.tap(find.byKey(const ValueKey('agent-keyboard')));
        await t.pumpAndSettle();
      }
      await t.enterText(find.byKey(const ValueKey('agent-input')), text);
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pumpAndSettle();
    }

    testWidgets('点赞 is react on the message, behind a confirm card', (t) async {
      await open(t);
      await current(t, 'activity:thread:th1');
      await press(t, 'attention-like-activity:thread:th1');
      // The preview of the tool, and nothing ran yet.
      expect(find.textContaining('预览 messages.react'), findsWidgets);
      expect(ran, isEmpty);
      await confirm(t);
      expect(_ran(ran), [
        _c('messages.react', {'message': 'l-th1', 'emoji': '👍', 'channel': 'th1'}),
      ]);
    });

    testWidgets('取消 on the card runs nothing', (t) async {
      await open(t);
      await current(t, 'activity:thread:th1');
      await press(t, 'attention-like-activity:thread:th1');
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(ran, isEmpty);
    });

    testWidgets('标记已处理 is mark_done: a thread with its thread, a '
        'private conversation by itself, and a mention action has none', (
      t,
    ) async {
      await open(t);
      await current(t, 'activity:thread:th1');
      await press(t, 'attention-done-activity:thread:th1');
      await confirm(t);
      await current(t, 'activity:dm:d1');
      await press(t, 'attention-done-activity:dm:d1');
      await confirm(t);
      expect(_ran(ran), [
        _c('activity.mark_done', {'channel': 'c1', 'thread': 'th1'}),
        _c('activity.mark_done', {'channel': 'd1'}),
      ]);
      await current(t, 'activity:mention_action:ma1');
      expect(
        find.byKey(const ValueKey('attention-done-activity:mention_action:ma1')),
        findsNothing,
      );
    });

    testWidgets('回复 waits for the words: a thread is answered in its '
        'thread, a private message in its conversation', (t) async {
      await open(t);
      await current(t, 'activity:thread:th1');
      await press(t, 'attention-reply-activity:thread:th1');
      expect(find.byKey(const ValueKey('agent-reply-note')), findsOneWidget);
      expect(ran, isEmpty);
      await type(t, '先跑全量');
      expect(find.byKey(const ValueKey('agent-reply-note')), findsNothing);
      await confirm(t);
      expect(_ran(ran), [
        _c(
          'messages.reply_thread',
          {'message': 'p-th1', 'text': '先跑全量', 'channel': 'c1'},
        ),
      ]);
      ran.clear();
      await current(t, 'activity:dm:d1');
      await press(t, 'attention-reply-activity:dm:d1');
      await type(t, '可以，周五见');
      await confirm(t);
      expect(_ran(ran), [
        _c('messages.send', {'channel': 'd1', 'text': '可以，周五见'}),
      ]);
    });

    testWidgets('回复 can be given up', (t) async {
      await open(t);
      await current(t, 'activity:thread:th1');
      await press(t, 'attention-reply-activity:thread:th1');
      await press(t, 'agent-reply-cancel');
      expect(find.byKey(const ValueKey('agent-reply-note')), findsNothing);
      await type(t, '随便说点什么');
      expect(ran, isEmpty);
    });

    testWidgets('稍后 sets the item aside, as it always did', (t) async {
      await open(t);
      await current(t, 'activity:channel:c2');
      await press(t, 'attention-later-activity:channel:c2');
      expect(
        AgentSnoozeStore.of(w).active.map((e) => e.id),
        contains('activity:channel:c2'),
      );
      expect(
        find.byKey(const ValueKey('attention-card-activity:channel:c2')),
        findsNothing,
      );
    });

    testWidgets('交给 Agent: a task is assigned, a message becomes a task '
        'for the Agent', (t) async {
      await open(t);
      // The Activity row of a task I decide: its own task is assigned.
      await current(t, 'activity:thread:th2');
      expect(find.byKey(const ValueKey('attention-approve-activity:thread:th2')), findsOneWidget);
      await press(t, 'attention-assign-activity:thread:th2');
      expect(find.byKey(const ValueKey('agent-assign-panel')), findsOneWidget);
      // Only an Agent that is online can be chosen.
      expect(find.byKey(const ValueKey('agent-assign-Cody')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-assign-Bo')), findsNothing);
      await press(t, 'agent-assign-Cody');
      expect(find.byKey(const ValueKey('agent-assign-panel')), findsNothing);
      await confirm(t);
      expect(_ran(ran), [
        _c('tasks.assign', {'task': 't1', 'assignee': 'Cody'}),
      ]);
      ran.clear();
      // A message that is no task yet.
      await current(t, 'activity:channel:c2');
      await press(t, 'attention-assign-activity:channel:c2');
      await press(t, 'agent-assign-Grok');
      await confirm(t);
      expect(ran.single.$1, 'tasks.create');
      expect(ran.single.$2['channel'], 'c2');
      expect(ran.single.$2['assignee'], 'Grok');
      expect(ran.single.$2['title'], '托盘退出验证通过');
      expect(ran.single.$2['description'], contains('#ch-c2'));
    });

    testWidgets('通过 on a row that is a task I decide asks first', (t) async {
      await open(t);
      await current(t, 'activity:thread:th2');
      await press(t, 'attention-approve-activity:thread:th2');
      expect(find.text('通过这件事？'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('attention-approve-confirm')));
      await t.pumpAndSettle();
      expect(data.approved, ['t1']);
    });

    testWidgets('看完整对话 opens the conversation of the row', (t) async {
      await open(t);
      await current(t, 'activity:dm:d1');
      await press(t, 'attention-open-activity:dm:d1');
      expect(data.reads, ['d1']);
      expect(find.text('@Alice Chen'), findsWidgets);
    });
  });
}

/// Stands in for reading the workspace: the feed is composed by the real
/// code from the Activity rows it is given.
class _HomeData extends AgentModeData {
  _HomeData(WorkspaceController w) : super(w, now: () => _now);

  late AgentAttention result;
  final convos = <String, AgentConversationRead>{};
  final reads = <String>[];
  final approved = <String>[];
  final signal = _Signal();

  /// A task of mine that waits for a decision, whose thread is [thread].
  AgentAttentionItem decisionTask(String id, int number, String thread) =>
      AgentAttentionItem(
        id: id,
        taskId: id,
        taskNumber: number,
        taskStatus: 'in_review',
        kind: AgentItemKind.decision,
        priority: AgentPriority.decision,
        headline: 'Grok 完成了「回归测试」，等你验收',
        ask: '验收',
        action: AgentAction.approve,
        canApprove: true,
        reason: '你派的任务',
        at: _now.subtract(const Duration(minutes: 90)),
        channelId: 'c1',
        channelName: 'raft-flutter',
      );

  @override
  Future<void> approve(String taskId) async => approved.add(taskId);

  @override
  Future<List<AgentRuntimeInfo>> agents() async => const [
    AgentRuntimeInfo(
      id: 'a-cody',
      name: 'Cody',
      state: AgentWorkState.busy,
      activity: '在做 #96',
    ),
    AgentRuntimeInfo(
      id: 'a-grok',
      name: 'Grok',
      state: AgentWorkState.idle,
      activity: '空闲',
    ),
    AgentRuntimeInfo(
      id: 'a-bo',
      name: 'Bo',
      state: AgentWorkState.offline,
      activity: '离线',
    ),
  ];

  List<AgentAttentionItem> feed(List<Map<String, dynamic>> rows) =>
      activityItems(rows);

  AgentAttentionItem staleTask(String id, int number, int minutes, String t) {
    final at = _now.subtract(Duration(minutes: minutes));
    return AgentAttentionItem(
      id: id,
      taskId: id,
      taskNumber: number,
      kind: AgentItemKind.stale,
      priority: AgentPriority.blocked,
      headline: '「$t」$number 天没动',
      ask: '解除阻塞',
      reason: '很久没动了',
      idle: true,
      at: at,
      waitValue: minutes ~/ (24 * 60),
      waitUnit: '天',
      channelId: 'c1',
      channelName: 'raft-flutter',
    );
  }

  @override
  Listenable get activityChanges => signal;

  @override
  List<Map<String, dynamic>>? storeRows() => null;

  @override
  Future<AgentAttention> attention() async => result;

  @override
  Future<AgentConversationRead> conversation(
    String id, {
    int limit = 50,
    bool withTasks = true,
    String? parentChannelId,
    String? parentMessageId,
  }) async {
    reads.add(id);
    return convos[id] ?? const AgentConversationRead(rows: []);
  }
}

class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// What ran, as text: the capability and the arguments it was given.
List<String> _ran(List<(String, Map<String, Object?>)> ran) => [
  for (final (id, args) in ran) _c(id, args),
];

String _c(String id, Map<String, Object?> args) => '$id ${jsonEncode(args)}';
