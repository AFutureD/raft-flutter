import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_activity_feed.dart';
import 'package:raft_flutter/features/agent_mode/agent_attention.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_consent_tray.dart';
import 'package:raft_flutter/features/agent_mode/agent_conversation_view.dart';
import 'package:raft_flutter/features/agent_mode/agent_frame_view.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_screen_snapshot.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// Screen parity: the voice model must know everything the person can read on
/// the screen. Each test renders one layer of agent mode, collects every
/// string drawn under it (the way a person reads it) and asserts that each of
/// them is in what the model is given for that screen: the result of the tool
/// that shows (or shows again) the layer, plus the per-turn context line.
///
/// What is left out of the collected strings, and why:
///  - icon glyphs (private-use code points): pictures, not words;
///  - the letter inside an avatar ([HfAvatar]): a picture of the name that is
///    printed next to it;
///  - the number on a row's colour bar: it is the item's own number, which
///    the model has as `n` and as its handle (the test asserts every item of
///    the layer has both);
///  - the chrome around a layer (close, settings, "第 N 层", the voice dock)
///    and the strips of the layers behind it: they are outside the layer.

/// Stands in for the model: runs [script] against the page's own tools.
class _Probe extends AgentScriptedModel {
  _Probe(this.script);
  Future<void> Function(AgentToolHandler call) script;

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String line) say,
  ) async {
    await script(call);
    return true;
  }
}

AgentProgressLine _line(String who, String time, String text) =>
    AgentProgressLine(who: who, time: time, text: text);

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => worldNow);

  @override
  Future<AgentAttention> attention() async => AgentAttention(
    items: [
      AgentAttentionItem(
        id: 't94',
        taskId: 't94',
        taskNumber: 94,
        priority: AgentPriority.decision,
        headline: 'Cindy 完成了「选型」，等你验收',
        ask: '验收',
        askLine: '验收「选型」',
        action: AgentAction.approve,
        canApprove: true,
        reason: '你派的任务',
        waitValue: 3,
        waitUnit: '小时',
        at: worldNow,
        waiters: const ['Cindy'],
        doer: 'Cindy',
        channelId: 'ch-general',
        channelName: 'general',
        threadTitle: '选型讨论',
        progress: [
          _line('Zed', '09:10', '请看一下返回键'),
          _line('Cindy', '10:32', '已完成并补了测试，等你验收'),
        ],
      ),
      AgentAttentionItem(
        id: 't7',
        taskId: 't7',
        taskNumber: 7,
        priority: AgentPriority.blocked,
        headline: 'Grok 的「返回」5 小时没动，卡住了',
        ask: '解除阻塞',
        reason: '卡住了',
        idle: true,
        waitValue: 5,
        at: worldNow,
        doer: 'Grok',
        channelId: 'ch-design',
        channelName: 'design',
        progress: [_line('Grok', '05:02', '卡在登录态上')],
      ),
      AgentAttentionItem(
        id: 'mention:ch-design2',
        priority: AgentPriority.mention,
        headline: 'Zed 在评审里问你：这个配色可以上线吗',
        ask: '回答',
        action: AgentAction.reply,
        reason: '点名找你',
        waitValue: 40,
        waitUnit: '分钟',
        at: worldNow,
        doer: 'Zed',
        channelId: 'ch-design2',
        channelName: 'design-review',
        progress: [_line('Zed', '11:20', '@Kevin 这个配色可以上线吗')],
      ),
    ],
    team: const [
      AgentTeamItem(
        id: 'tm1',
        headline: 'Bo 在迁移数据',
        channelName: 'general',
        who: 'Bo',
      ),
      AgentTeamItem(
        id: 'tm2',
        headline: 'Aria 在补测试',
        channelName: 'design',
        who: 'Aria',
      ),
    ],
  );

  @override
  Future<List<AgentRuntimeInfo>> agents() async => const [
    AgentRuntimeInfo(
      id: 'a1',
      name: 'Aria',
      state: AgentWorkState.busy,
      activity: '在做 #102「历史上拉」',
      since: '12 分钟前有进展',
      channel: 'seed',
    ),
    AgentRuntimeInfo(
      id: 'a2',
      name: 'Bo',
      state: AgentWorkState.blocked,
      activity: '#7「旧任务」 超过 6 小时没动',
    ),
  ];

  @override
  Future<List<AgentTaskDetail>> tasksNumbered(
    int number, {
    String? channel,
  }) async => number != 98
      ? const []
      : [
          AgentTaskDetail(
            id: 't98',
            number: 98,
            title: '修复搜索打开频道后无法返回',
            status: 'in_review',
            description: '',
            updated: '2 小时前',
            claimer: 'Aria',
            channelName: 'seed',
            thread: [
              _line('Zed', '09:10', '请看一下返回键'),
              _line('Bo', '09:40', '我这边复现不了了'),
              _line('Aria', '10:32', '已修复并补了测试'),
            ],
          ),
        ];

  @override
  Future<AgentConversationRead> conversation(
    String id, {
    int limit = 50,
    bool withTasks = true,
    String? parentChannelId,
    String? parentMessageId,
  }) async => AgentConversationRead(
    hasMore: true,
    tasks: withTasks
        ? [
            taskRow(
              't11',
              11,
              'in_review',
              title: '补全搜索结果的高亮',
              claimedById: 'a-cody',
              claimedByName: 'Cody',
            ),
            taskRow(
              't12',
              12,
              'in_progress',
              title: '整理发布说明',
              claimedById: 'a-cindy',
              claimedByName: 'Cindy',
            ),
          ]
        : const [],
    // Every kind of message a channel holds: people and Agents, system
    // notes, a task event, files and a picture, code, a quote, a reaction,
    // a thread, an edited and a deleted message.
    rows: [
      _chat('m1', 1, 'Ada', '明天的发布我来盯着', 300, more: {'replyCount': 2}),
      _chat('m2', 2, 'Cody', '#11 已经提交，等验收', 290, agent: true),
      _system('s1', 3, 'Cody claimed #11 "补全搜索结果的高亮"', 288),
      _system('s2', 4, 'Cody moved #11 "补全搜索结果的高亮" to In Review', 287),
      _system('s3', 5, '系统：频道设置已更新', 286),
      _chat(
        'm3',
        6,
        'Zed',
        '看一下这个：\n```\nfinal a = 1;\n```\n> 先别合并',
        200,
        more: {
          'attachments': [
            {
              'id': 'f1',
              'filename': '日志.txt',
              'mimeType': 'text/plain',
              'sizeBytes': 2048,
            },
            {
              'id': 'f2',
              'filename': '截图.png',
              'mimeType': 'image/png',
              'sizeBytes': 90210,
            },
          ],
          'reactions': [
            {
              'emoji': '👍',
              'count': 2,
              'reactorIds': ['u1', 'u2'],
              'reactorNames': ['Ada', 'Bo'],
            },
          ],
        },
      ),
      _chat('m4', 7, 'Ada', '改了一下说法', 100, more: {'editedAt': hoursAgo(1)}),
      _chat('m5', 8, 'Bo', '删掉了', 90, more: {'deletedAt': hoursAgo(1)}),
      _chat('m6', 9, 'Cody', '好，我先停下', 60, agent: true),
    ],
  );

  static Map<String, dynamic> _chat(
    String id,
    int seq,
    String who,
    String text,
    int minutes, {
    bool agent = false,
    Map<String, dynamic> more = const {},
  }) => {
    'id': id,
    'seq': '$seq',
    'channelId': 'ch-general',
    'senderType': agent ? 'agent' : 'user',
    'senderId': agent ? 'a-${who.toLowerCase()}' : 'u-${who.toLowerCase()}',
    'senderName': who,
    'content': text,
    'messageType': 'chat',
    'createdAt': worldNow.subtract(Duration(minutes: minutes)).toIso8601String(),
    ...more,
  };

  static Map<String, dynamic> _system(
    String id,
    int seq,
    String text,
    int minutes,
  ) => {
    'id': id,
    'seq': '$seq',
    'channelId': 'ch-general',
    'senderType': 'system',
    'senderName': 'System',
    'content': text,
    'messageType': 'system',
    'createdAt': worldNow.subtract(Duration(minutes: minutes)).toIso8601String(),
  };

  @override
  Future<List<Map<String, dynamic>>> openTasks() async => [
    taskRow(
      't21',
      21,
      'in_review',
      title: '迁移旧数据',
      channel: 'design',
      claimedById: 'a-cody',
      claimedByName: 'Cody',
    ),
    taskRow(
      't22',
      22,
      'in_progress',
      title: '补一份回滚说明',
      channel: 'general',
      claimedById: 'a-cindy',
      claimedByName: 'Cindy',
    ),
  ];
}

/// The home as the App's Activity gives it: rows composed by the real code,
/// a decision among them, and tasks nobody touched for days apart.
class _HomeData extends _Data {
  _HomeData(super.w);

  List<Map<String, dynamic>> rows() => [
    {
      'kind': 'thread',
      'threadChannelId': 'th-m7',
      'parentChannelId': 'ch-general',
      'parentChannelName': 'general',
      'parentChannelType': 'channel',
      'parentMessageId': 'p-m7',
      'parentMessagePreview': '检测首片什么时候出？',
      'parentMessageSenderId': 'kevin',
      'latestActivityMessageId': 'l-m7',
      'latestActivityPreview': '@Kevin 首片 12 张里 2 张误检，继续跑全量吗？',
      'latestActivitySenderName': 'Cody',
      'latestActivitySenderId': 'a-cody',
      'latestActivitySenderType': 'agent',
      'firstUnreadMessageId': 'u-m7',
      'lastActivityAt': hoursAgo(0),
      'unreadCount': 2,
      'hasMention': true,
      'isFollowing': true,
    },
    {
      'kind': 'dm',
      'channelId': 'd1',
      'channelName': 'alice',
      'channelType': 'dm',
      'lastMessageId': 'l-d1',
      'lastMessagePreview': '周五的评审你能来吗？',
      'lastMessageSenderName': 'Alice Chen',
      'lastMessageSenderId': 'u-alice',
      'lastMessageSenderType': 'user',
      'lastMessageAt': hoursAgo(1),
      'unreadCount': 1,
    },
    {
      'kind': 'channel',
      'channelId': 'ch-design',
      'channelName': 'design',
      'channelType': 'channel',
      'lastMessageId': 'l-design',
      'lastMessagePreview': '暗色稿上传了',
      'lastMessageSenderName': 'Bo',
      'lastMessageSenderId': 'u-bo',
      'lastMessageSenderType': 'user',
      'lastMessageAt': hoursAgo(5),
      'unreadCount': 0,
    },
  ];

  @override
  Future<AgentConversationRead> conversation(
    String id, {
    int limit = 50,
    bool withTasks = true,
    String? parentChannelId,
    String? parentMessageId,
  }) async => id != 'th-m7'
      ? super.conversation(id, withTasks: withTasks)
      : AgentConversationRead(
          rows: [
            _Data._chat('p-m7', 1, 'Kevin', '检测首片什么时候出？', 300),
            _Data._chat('u-m7', 2, 'Cody', '首片出来了，两张误检。', 20, agent: true),
            _Data._chat(
              'l-m7',
              3,
              'Cody',
              '@Kevin 首片 12 张里 2 张误检，继续跑全量吗？',
              2,
              agent: true,
            ),
          ],
        );

  AgentAttentionItem stale(String id, int n, String text, int days) =>
      AgentAttentionItem(
        id: id,
        taskId: id,
        taskNumber: n,
        kind: AgentItemKind.stale,
        priority: AgentPriority.blocked,
        headline: '$text，$days 天没动',
        ask: '解除阻塞',
        reason: '很久没动了',
        idle: true,
        at: worldNow.subtract(Duration(days: days)),
        waitValue: days,
        waitUnit: '天',
        channelId: 'ch-general',
        channelName: 'general',
        progress: [_line('Grok', '10-0$days 09:00', text)],
      );

  @override
  Future<AgentAttention> attention() async => AgentAttention(
    items: AgentActivityFeed.compose(activityItems(rows()), const []),
    stale: [stale('s1', 77, '安装包签名', 4), stale('s2', 80, '迁移脚本', 9)],
    team: const [
      AgentTeamItem(
        id: 'tm1',
        headline: 'Bo 在迁移数据',
        channelName: 'general',
        who: 'Bo',
      ),
    ],
  );
}

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Every string of a tool result, nested ones included.
String _flatten(Object? v) {
  final out = <String>[];
  void walk(Object? x) {
    if (x is String) {
      out.add(x);
    } else if (x is Map) {
      for (final e in x.entries) {
        out.add('${e.key}');
        walk(e.value);
      }
    } else if (x is Iterable) {
      x.forEach(walk);
    } else if (x != null) {
      out.add('$x');
    }
  }

  walk(v);
  return _norm(out.join('\n'));
}

bool _isIcon(String s) =>
    s.runes.isNotEmpty && s.runes.every((r) => r >= 0xE000 && r <= 0xF8FF);

/// The window's own chrome, which a wide window draws in the header of the
/// front layer: its title and the layer count.
bool _isChrome(String s) => s == 'Agent 模式' || RegExp(r'^第 \d+ 层$').hasMatch(s);

/// The strings drawn under [roots], as a person reads them.
List<String> _shown(WidgetTester t, List<Finder> roots) {
  final out = <String>{};
  for (final root in roots) {
    for (final element
        in find
            .descendant(of: root, matching: find.byType(RichText))
            .evaluate()) {
      // Pictures, not words: see the header of this file.
      var skip = false;
      element.visitAncestorElements((a) {
        final w = a.widget;
        if (w is HfAvatar ||
            w.key == const ValueKey('hf-row-bar') ||
            w.key == const ValueKey('hf-detail-index')) {
          skip = true;
          return false;
        }
        return true;
      });
      if (skip) continue;
      final text = _norm((element.widget as RichText).text.toPlainText());
      if (text.isEmpty || _isIcon(text) || _isChrome(text)) continue;
      out.add(text);
    }
  }
  return out.toList();
}

/// The tokens of what the model was given, by scenario (printed at the end).
final _sizes = <String, int>{};

void _expectParity(List<String> shown, String seen, String what) {
  final tokens = agentTokenEstimate(seen);
  _sizes[what] = tokens;
  // Everything the person reads fits a bounded message.
  expect(tokens, lessThan(5000), reason: '$what is $tokens tokens');
  expect(shown, isNotEmpty, reason: '$what: nothing was drawn');
  final missing = [
    for (final s in shown)
      if (!seen.contains(s)) s,
  ];
  expect(
    missing,
    isEmpty,
    reason:
        '$what: drawn on the screen but not in what the model is given.\n'
        'model saw: $seen',
  );
}

void main() {
  tearDownAll(() => debugPrint('screen snapshot tokens: $_sizes'));
  late ActivityClient client;
  late CapabilityWorld w;

  final registry = AgentCapabilityRegistry([
    AgentCapability(
      id: 'tasks.finish',
      title: '把任务标成完成',
      kind: AgentCapabilityKind.action,
      risk: AgentCapabilityRisk.change,
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': '任务 id'},
        },
        'required': ['taskId'],
      },
      resultSummary: '任务',
      keywords: const ['完成'],
      preview: (w, args, env) async => AgentActionPreview(
        summary: '把任务 ${args['taskId']} 标记为已完成',
        changes: const ['状态: 等验收 → 已完成'],
      ),
      run: (w, args, env) async => {'status': 'done'},
    ),
    ...agentStandardCapabilities.all,
  ]);

  setUp(() {
    AgentModeData.clearSession();
    FlutterSecureStorage.setMockInitialValues({});
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          taskRow(
            't3',
            9,
            'in_progress',
            title: '丙',
            claimedById: 'a-cody',
            claimedByName: 'Cody',
          ),
      ],
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<_Probe> open(
    WidgetTester t, {
    Size size = const Size(390, 1400),
    AgentModeData Function(CapabilityWorld w)? data,
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final probe = _Probe((call) async {});
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: AgentModePage(
          controller: w,
          data: data == null ? _Data(w) : data(w),
          model: probe,
          registry: registry,
        ),
      ),
    );
    await t.pumpAndSettle();
    return probe;
  }

  /// One typed request whose "model" runs [script]; what its calls returned is
  /// what the model was given.
  Future<void> say(
    WidgetTester t,
    _Probe probe,
    Future<void> Function(AgentToolHandler) script,
  ) async {
    probe.script = script;
    if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
      await t.tap(find.byKey(const ValueKey('agent-keyboard')));
      await t.pumpAndSettle();
    }
    await t.enterText(find.byKey(const ValueKey('agent-input')), '随便');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pumpAndSettle();
  }

  /// What the model is given when it asks for the screen the way it does
  /// today: the answer of the tool that shows this layer again.
  Future<String> given(
    WidgetTester t,
    _Probe probe,
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    late Map<String, Object?> result;
    await say(t, probe, (call) async {
      result = await call(tool, args);
    });
    return _flatten(result);
  }

  List<Finder> conversationRoots() => [find.byType(AgentConversationView)];

  List<Finder> attentionRoots() => [
    find.byType(AgentAttentionView),
    find.byType(HfDetail),
  ];

  testWidgets('the home layer: channel, assignee, wait, every card', (t) async {
    final probe = await open(t);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'home layer');
    // Every item has its number and its handle.
    for (var n = 1; n <= 3; n++) {
      expect(seen, contains('①②③'.substring(n - 1, n)));
    }
  });

  testWidgets('the home layer with the current item open under its row', (
    t,
  ) async {
    final probe = await open(t);
    await t.tap(find.text('Cindy 完成了「选型」，等你验收'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'home layer + detail');
  });

  testWidgets('the home layer on a wide window: list beside the detail', (
    t,
  ) async {
    final probe = await open(t, size: const Size(1500, 900));
    expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'wide home layer');
  });

  testWidgets('the team row, closed and open', (t) async {
    final probe = await open(t);
    var seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'team row closed');
    await t.ensureVisible(find.byKey(const ValueKey('attention-team')));
    await t.tap(find.byKey(const ValueKey('attention-team')));
    await t.pumpAndSettle();
    expect(find.text('Bo 在迁移数据'), findsOneWidget);
    seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'team row open');
  });

  testWidgets('the Activity home: who, where, the words, how long, why', (
    t,
  ) async {
    final probe = await open(t, data: _HomeData.new);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'activity home');
    for (final word in ['Cody', '#general', '检测首片什么时候出？', '点名了你', '2 条未读', '@alice', 'Alice Chen', '私信你', '已读']) {
      expect(seen, contains(word), reason: word);
    }
    // The stale tasks are one collapsed row, and the model is told so.
    expect(seen, contains('可能需要收尾 2 件'));
    expect(seen, isNot(contains('安装包签名')));
  });

  testWidgets('the Activity home with its feedback actions open', (t) async {
    final probe = await open(t, data: _HomeData.new);
    await t.tap(
      find.byKey(const ValueKey('attention-card-activity:thread:th-m7')),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'activity home + actions');
    for (final action in ['看完整对话', '回复', '点赞', '标记已处理', '稍后', '交给 Agent']) {
      expect(seen, contains(action), reason: action);
    }
  });

  testWidgets('the Activity home on a wide window', (t) async {
    final probe = await open(
      t,
      size: const Size(1500, 900),
      data: _HomeData.new,
    );
    expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'wide activity home');
  });

  testWidgets('the stale group, closed and open', (t) async {
    final probe = await open(t, data: _HomeData.new);
    var seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'stale group closed');
    await t.ensureVisible(find.byKey(const ValueKey('attention-stale')));
    await t.tap(find.byKey(const ValueKey('attention-stale')));
    await t.pumpAndSettle();
    expect(find.textContaining('安装包签名'), findsWidgets);
    seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'stale group open');
    expect(seen, contains('安装包签名'));
    expect(seen, contains('迁移脚本'));
  });

  testWidgets('a conversation opened from an item of the home', (t) async {
    final probe = await open(t, data: _HomeData.new);
    await say(t, probe, (call) async {
      await call('open_item', {'number': 1});
    });
    expect(find.text('第 2 层'), findsOneWidget);
    final seen = await given(t, probe, 'read_screen');
    _expectParity(_shown(t, conversationRoots()), seen, 'opened conversation');
    expect(seen, contains('你是从这一条打开的'));
  });

  testWidgets('a channel layer: a chat of every kind of message', (t) async {
    final probe = await open(t);
    await say(t, probe, (call) async {
      await call('open_channel', {'name': 'general'});
    });
    final seen = await given(t, probe, 'open_channel', {'name': 'general'});
    _expectParity(
      _shown(t, conversationRoots()),
      seen,
      'channel layer',
    );
    // Who said it, what kind it is, and what it holds.
    expect(seen, contains('来自 Agent Cody'));
    expect(seen, contains('系统消息'));
    expect(seen, contains('任务事件'));
    expect(seen, contains('日志.txt'));
    expect(seen, contains('图片：截图.png'));
    expect(seen, contains('final a = 1;'));
    expect(seen, contains('👍 2'));
    expect(seen, contains('2 条回复'));
    expect(seen, contains('已编辑'));
    expect(seen, contains('此消息已删除'));
    // The tasks are behind a chip, not the first thing.
    expect(seen, contains('任务 2'));
    expect(seen, isNot(contains('整理发布说明')));
  });

  testWidgets('a channel layer with a message pointed at', (t) async {
    final probe = await open(t);
    await say(t, probe, (call) async {
      await call('open_channel', {'name': 'general'});
    });
    await t.tap(find.text('好，我先停下'));
    await t.pumpAndSettle();
    // A conversation is read: pointing at a message opens no stage.
    expect(find.byKey(const ValueKey('agent-frame-stage')), findsNothing);
    final seen = await given(t, probe, 'open_channel', {'name': 'general'});
    _expectParity(
      _shown(t, conversationRoots()),
      seen,
      'channel layer + message pointed at',
    );
  });

  testWidgets('the tasks of a channel are their own layer', (t) async {
    final probe = await open(t);
    await say(t, probe, (call) async {
      await call('open_channel', {'name': 'general'});
    });
    await t.tap(find.byKey(const ValueKey('conversation-tasks')));
    await t.pumpAndSettle();
    expect(find.text('第 2 层'), findsNothing);
    expect(find.text('第 3 层'), findsOneWidget);
    final seen = await given(t, probe, 'show_tasks');
    _expectParity(
      _shown(t, [find.byType(AgentFrameView), find.byType(HfDetail)]),
      seen,
      'channel tasks layer',
    );
    expect(seen, contains('补全搜索结果的高亮'));
  });

  testWidgets('the tasks layer', (t) async {
    final probe = await open(t);
    await say(t, probe, (call) async {
      await call('show_tasks', {});
    });
    await t.tap(find.text('迁移旧数据'));
    await t.pumpAndSettle();
    final seen = await given(t, probe, 'show_tasks');
    _expectParity(
      _shown(t, [find.byType(AgentFrameView), find.byType(HfDetail)]),
      seen,
      'tasks layer',
    );
  });

  testWidgets('the full detail of a home item', (t) async {
    final probe = await open(t);
    late Map<String, Object?> result;
    await say(t, probe, (call) async {
      result = await call('expand_item', {'index': 1});
    });
    expect(find.byType(AgentSurfaceView), findsOneWidget);
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      _flatten(result),
      'detail layer of a task',
    );
    // The same for a mention, which has no task card.
    await say(t, probe, (call) async {
      await call('go_back', {});
      result = await call('expand_item', {'index': 3});
    });
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      _flatten(result),
      'detail layer of a mention',
    );
  });

  String surface(List<Object> children) => _json({
    'title': '全景',
    'summary': '一屏看全',
    'root': {'component': 'Column', 'children': children},
  });

  Future<String> showSurface(
    WidgetTester t,
    _Probe probe,
    List<Object> children,
  ) async {
    late Map<String, Object?> result;
    await say(t, probe, (call) async {
      await call('list_agents', {});
      await call('get_task', {'number': 98});
      result = await call('show_surface', {'surface': surface(children)});
    });
    expect(result['error'], isNull, reason: '${result['problems']}');
    // Entity cards are read from the workspace after they are drawn.
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    late Map<String, Object?> again;
    await say(t, probe, (call) async {
      again = await call('show_surface', {'surface': surface(children)});
    });
    return _flatten(again);
  }

  const status = {
    'component': 'AgentStatusCard',
    'name': 'Aria',
    'state': 'busy',
    'activity': '在做 #102「历史上拉」',
    'since': '12 分钟前有进展',
    'channel': 'seed',
  };
  const taskCard = {
    'component': 'TaskCard',
    'number': 98,
    'title': '修复搜索打开频道后无法返回',
    'status': 'in_review',
    'assignee': 'Aria',
    'channel': 'seed',
    'quote': {'who': 'Aria', 'time': '10:32', 'text': '已修复并补了测试'},
    'ask': '验收这个任务',
  };
  const quote = {
    'component': 'MessageQuote',
    'author': 'Bo',
    'time': '09:40',
    'text': '我这边复现不了了',
    'channel': 'seed',
  };

  testWidgets('a surface: status cards, task cards, quotes, stats', (t) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {
        'component': 'StatRow',
        'stats': [
          {'label': '在忙', 'value': '1'},
          {'label': '卡住', 'value': '1'},
        ],
      },
      {
        'component': 'AgentStatusGroup',
        'title': '在忙',
        'state': 'busy',
        'density': 'detail',
        'children': [status],
      },
      {
        'component': 'Section',
        'title': '任务和消息',
        'density': 'detail',
        'children': [
          taskCard,
          {
            ...taskCard,
            'display': {'level': 'detail'},
          },
          quote,
        ],
      },
    ]);
    _expectParity(_shown(t, [find.byType(AgentSurfaceView)]), seen, 'surface');
  });

  testWidgets('a surface: folded groups on a phone', (t) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {
        'component': 'AgentStatusGroup',
        'title': '在忙',
        'state': 'busy',
        'children': [status],
      },
      {
        'component': 'Section',
        'title': '任务和消息',
        'children': [taskCard, quote],
      },
    ]);
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      seen,
      'folded surface',
    );
  });

  testWidgets('a surface: entity cards of every kind the world holds', (
    t,
  ) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {'component': 'EntityCard', 'entity': 'channel', 'id': 'ch-general'},
      {
        'component': 'EntityCard',
        'entity': 'agent',
        'id': 'a-cody',
        'display': {'level': 'detail'},
      },
      {'component': 'EntityCard', 'entity': 'member', 'id': 'ada'},
      {'component': 'EntityCard', 'entity': 'computer', 'id': 'm1'},
      {
        'component': 'EntityCard',
        'entity': 'task',
        'id': 't3',
        'emphasis': 'high',
      },
      {'component': 'EntityCard', 'entity': 'task', 'id': 'nope'},
    ]);
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      seen,
      'entity cards',
    );
  });

  testWidgets('a surface: table, timeline, code, callout', (t) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {
        'component': 'Table',
        'columns': ['任务', '负责人'],
        'rows': [
          [
            {'entity': 'task', 'id': 't3'},
            'Cody',
          ],
          ['#9 另一件事', 'Ada'],
        ],
      },
      {
        'component': 'Timeline',
        'items': [
          {'time': '09:10', 'title': '创建任务'},
          {
            'time': '10:32',
            'title': '进入验收',
            'entity': 'channel',
            'id': 'ch-general',
          },
        ],
      },
      {
        'component': 'CodeBlock',
        'format': 'diff',
        'title': 'lib/main.dart',
        'code': '-final a = 1;\n+final a = 2;',
      },
      {'component': 'Callout', 'tone': 'good', 'text': '全量检查通过，可以合。'},
    ]);
    _expectParity(_shown(t, [find.byType(AgentSurfaceView)]), seen, 'blocks');
  });

  testWidgets('a surface: confirm card, choice and toggle, before and after '
      'the person used them', (t) async {
    final probe = await open(t);
    final blocks = <Object>[
      {
        'component': 'ConfirmCard',
        'title': '把 #98 标记为已完成？',
        'changes': ['状态: 等验收 → 已完成'],
      },
      {
        'component': 'Choice',
        'prompt': '合到哪里？',
        'options': ['integration', 'main'],
      },
      {'component': 'Toggle', 'label': '完成后通知我', 'value': false},
    ];
    var seen = await showSurface(t, probe, blocks);
    _expectParity(_shown(t, [find.byType(AgentSurfaceView)]), seen, 'blocks');
    await t.tap(find.text('main'));
    await t.pumpAndSettle();
    await t.tap(find.text('完成后通知我'));
    await t.pumpAndSettle();
    // Showing the same screen again would draw it fresh; look at it instead.
    late Map<String, Object?> again;
    await say(t, probe, (call) async {
      again = await call('read_screen', {});
    });
    seen = _flatten(again);
    // What the person chose is told too.
    expect(seen, contains('2 main（已选）'));
    expect(seen, contains('完成后通知我 开'));
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      seen,
      'blocks after use',
    );
  });

  testWidgets('a confirm card waiting for the person', (t) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, home;
    // Same request: a new one would cancel the preview.
    await say(t, probe, (call) async {
      previewed = await call('act', {
        'capability': 'tasks.finish',
        'args': '{"taskId":"t3"}',
      });
      home = await call('go_home', {});
    });
    expect(previewed['status'], 'needs_confirmation');
    _expectParity(
      _shown(t, [...attentionRoots(), find.byType(AgentConsentTray)]),
      _flatten(home),
      'home layer + confirm card',
    );
  });
}

String _json(Object v) => jsonEncode(v);
