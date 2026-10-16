// Offline visual host for the agent mode demo: fixed sample data, no network.
//   tool/flutter run -d linux -t integration_test/agent_mode_demo_main.dart \
//     --dart-define=AGENT_DEMO_THEME=brutal|elegant-light|elegant-dark \
//     --dart-define=AGENT_DEMO_SCRIPT=true \
//     --dart-define=AGENT_DEMO_TV=true
// AGENT_DEMO_TV shows what the TV presentation shows (the frames the phone
// would send, drawn by AgentTvView) instead of the page; the page still runs,
// out of sight, and the script drives it.
// The script opens a card's detail, asks the generative UI questions ("现在所有的
// Agent 都在干什么？", "展开卡住了", a channel, "任务 #98 现在怎么样？") and goes back
// to the attention layer; a scripted model answers them with the real tools, so
// a recording needs no key. It prints `AGENT_DEMO_MARK <name>` at each moment
// worth a screenshot.
import 'dart:async';
import 'dart:io' show File, FileMode, Platform;

import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_activity_feed.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/agent_tv.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_ui/raft_ui.dart';

final _theme =
    Platform.environment['AGENT_DEMO_THEME'] ??
    const String.fromEnvironment('AGENT_DEMO_THEME', defaultValue: 'brutal');
final _tv =
    Platform.environment['AGENT_DEMO_TV'] == '1' ||
    const bool.fromEnvironment('AGENT_DEMO_TV');
final _script =
    Platform.environment['AGENT_DEMO_SCRIPT'] == '1' ||
    const bool.fromEnvironment('AGENT_DEMO_SCRIPT');

final _now = DateTime.now();
String _ago(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toUtc().toIso8601String();

/// The signed-in person of the demo.
const _me = 'u-kevin';

/// The App's Activity (`/channels/inbox`), newest first, as the server lists
/// it: a mention in a thread, a private message, a task thread being worked
/// on, a channel with unread messages, a task waiting for a review, a read
/// channel. The home is composed from these by the real code.
List<Map<String, dynamic>> _inbox() => [
  {
    'kind': 'thread',
    'threadChannelId': 'th-m7',
    'parentChannelId': 'c1',
    'parentChannelName': 'raft-flutter',
    'parentChannelType': 'channel',
    'parentMessageId': 'm-m7',
    'parentMessagePreview': 'M7 问题检测首片什么时候能出？',
    'parentMessageSenderId': _me,
    'parentMessageSenderType': 'user',
    'latestActivityMessageId': 'm-m7-4',
    'latestActivityPreview': '@Kevin 首片 12 张里 2 张误检，继续跑全量还是先调阈值？',
    'latestActivitySenderName': 'Cody',
    'latestActivitySenderId': 'a-cody',
    'latestActivitySenderType': 'agent',
    'firstMentionMessageId': 'm-m7-4',
    'firstUnreadMessageId': 'm-m7-3',
    'lastActivityAt': _ago(3),
    'replyCount': 4,
    'unreadCount': 2,
    'hasMention': true,
    'isFollowing': true,
  },
  {
    'kind': 'dm',
    'channelId': 'd1',
    'channelName': 'alice',
    'channelType': 'dm',
    'lastMessageId': 'm-dm-3',
    'lastMessagePreview': '周五的评审你能参加吗？我想把 M6 的验收放在评审之前。',
    'lastMessageSenderName': 'Alice Chen',
    'lastMessageSenderId': 'u-alice',
    'lastMessageSenderType': 'user',
    'firstUnreadMessageId': 'm-dm-3',
    'lastMessageAt': _ago(14),
    'unreadCount': 1,
    'hasMention': false,
  },
  {
    'kind': 'thread',
    'threadChannelId': 'th-98',
    'parentChannelId': 'c1',
    'parentChannelName': 'raft-flutter',
    'parentChannelType': 'channel',
    'parentMessageId': 'm-98',
    'parentMessagePreview': '搜索打开另一个频道后没有返回',
    'latestActivityMessageId': 'm-98-3',
    'latestActivityPreview': '路由栈改完了，正在补回归测试，预计 40 分钟。',
    'latestActivitySenderName': 'Grok',
    'latestActivitySenderId': 'a-grok',
    'latestActivitySenderType': 'agent',
    'lastActivityAt': _ago(31),
    'replyCount': 3,
    'unreadCount': 0,
    'hasMention': false,
    'isFollowing': true,
    'taskNumber': 98,
    'taskStatus': 'in_progress',
    'taskClaimedByName': 'Grok',
  },
  {
    'kind': 'channel',
    'channelId': 'c2',
    'channelName': 'general',
    'channelType': 'channel',
    'lastMessageId': 'm-gen-9',
    'lastMessagePreview': '托盘退出已通过：进入退出回调，后台数据库关闭完成。',
    'lastMessageSenderName': 'CodexWin',
    'lastMessageSenderId': 'a-codexwin',
    'lastMessageSenderType': 'agent',
    'firstUnreadMessageId': 'm-gen-6',
    'lastMessageAt': _ago(62),
    'unreadCount': 4,
    'hasMention': false,
  },
  {
    'kind': 'thread',
    'threadChannelId': 'th-94',
    'parentChannelId': 'c1',
    'parentChannelName': 'raft-flutter',
    'parentChannelType': 'channel',
    'parentMessageId': 'm-94',
    'parentMessagePreview': 'Personal Agent 第一版选型',
    'parentMessageSenderId': _me,
    'parentMessageSenderType': 'user',
    'latestActivityMessageId': 'm-94-5',
    'latestActivityPreview': '五个问题的结论都写在文档里了，请看第 3 节。',
    'latestActivitySenderName': 'Cindy',
    'latestActivitySenderId': 'a-cindy',
    'latestActivitySenderType': 'agent',
    'lastActivityAt': _ago(118),
    'replyCount': 5,
    'unreadCount': 1,
    'hasMention': false,
    'isFollowing': true,
    'taskNumber': 94,
    'taskStatus': 'in_review',
    'taskClaimedByName': 'Cindy',
  },
  {
    'kind': 'channel',
    'channelId': 'c1',
    'channelName': 'raft-flutter',
    'channelType': 'channel',
    'lastMessageId': 'm-c1-12',
    'lastMessagePreview': 'iOS 验收：4 项未通过，M6 暂不默认开启。',
    'lastMessageSenderName': 'CodexMac',
    'lastMessageSenderId': 'a-codexmac',
    'lastMessageSenderType': 'agent',
    'lastMessageAt': _ago(190),
    'unreadCount': 0,
    'hasMention': false,
  },
  {
    'kind': 'channel',
    'channelId': 'c3',
    'channelName': 'design',
    'channelType': 'channel',
    'lastMessageId': 'm-des-4',
    'lastMessagePreview': '新版首页的暗色稿上传了，大家看看对比度够不够。',
    'lastMessageSenderName': 'Bo',
    'lastMessageSenderId': 'u-bo',
    'lastMessageSenderType': 'user',
    'lastMessageAt': _ago(300),
    'unreadCount': 0,
    'hasMention': false,
  },
];

/// A message that arrives while the home is open.
Map<String, dynamic> _arrival() => {
  'kind': 'channel',
  'channelId': 'c3',
  'channelName': 'design',
  'channelType': 'channel',
  'lastMessageId': 'm-des-5',
  'lastMessagePreview': '@Kevin 暗色稿改好了，换了描边和阴影，你看一眼可以就合。',
  'lastMessageSenderName': 'Bo',
  'lastMessageSenderId': 'u-bo',
  'lastMessageSenderType': 'user',
  'firstUnreadMessageId': 'm-des-5',
  'firstMentionMessageId': 'm-des-5',
  'lastMessageAt': _now.toUtc().toIso8601String(),
  'unreadCount': 1,
  'hasMention': true,
};

Map<String, dynamic> _task(
  String id,
  int number,
  String status,
  int minutes,
  String title, {
  String claimer = 'Cindy',
  bool mine = true,
}) => {
  'id': id,
  'taskNumber': number,
  'title': title,
  'status': status,
  'channelId': 'c1',
  'channelName': 'raft-flutter',
  'createdById': mine ? _me : 'u-bo',
  'createdByType': 'user',
  'createdByName': mine ? 'Kevin' : 'Bo',
  'claimedById': 'a-${claimer.toLowerCase()}',
  'claimedByType': 'agent',
  'claimedByName': claimer,
  'updatedAt': _ago(minutes),
};

class _DemoData extends AgentModeData {
  _DemoData(super.w) : super(summarizer: null);

  /// The App's Activity as it is now; the script lets a message arrive.
  final _rows = _inbox();
  final _signal = _Signal();

  @override
  Listenable get activityChanges => _signal;

  @override
  List<Map<String, dynamic>>? storeRows() => [
    for (final r in _rows) Map<String, dynamic>.of(r),
  ];

  /// A message arrives in the Activity, as a live event would bring it.
  void arrive(Map<String, dynamic> row) {
    // The server lists a conversation once: a new message moves it up.
    _rows.removeWhere(
      (r) => r['kind'] == row['kind'] && r['channelId'] == row['channelId'],
    );
    _rows.insert(0, row);
    _signal.fire();
  }

  /// What waits for a decision (a task whose thread is in Activity gains the
  /// decision there), and the tasks nobody touched for days.
  List<AgentAttentionItem> _pool() => [
    _taskItem(
      _task('t94', 94, 'in_review', 118, 'Personal Agent 第一版选型'),
      'Cindy 完成了「Personal Agent 第一版选型」，等你验收',
      reason: '你派的任务',
    ),
    _taskItem(
      _task('t101', 101, 'in_review', 250, '发布说明初稿'),
      'Cindy 完成了「发布说明初稿」，等你验收',
      reason: '你派的任务',
    ),
  ];

  AgentAttentionItem _taskItem(
    Map<String, dynamic> t,
    String headline, {
    required String reason,
    bool stale = false,
    String? ask,
  }) {
    final at = DateTime.parse('${t['updatedAt']}').toLocal();
    final ago = _now.difference(at);
    final days = ago.inDays;
    return AgentAttentionItem(
      id: '${t['id']}',
      taskId: '${t['id']}',
      taskNumber: t['taskNumber'] as int,
      taskStatus: '${t['status']}',
      kind: stale ? AgentItemKind.stale : AgentItemKind.decision,
      priority: stale ? AgentPriority.blocked : AgentPriority.decision,
      headline: headline,
      ask: ask ?? '验收',
      askLine: ask ?? '验收「${t['title']}」',
      action: stale ? AgentAction.open : AgentAction.approve,
      canApprove: !stale,
      reason: reason,
      waitValue: stale ? days : (ago.inHours > 0 ? ago.inHours : ago.inMinutes),
      waitUnit: stale ? '天' : (ago.inHours > 0 ? '小时' : '分钟'),
      idle: stale,
      at: at,
      score: 3,
      waiters: ['${t['claimedByName']}'],
      doer: '${t['claimedByName']}',
      channelId: 'c1',
      channelName: 'raft-flutter',
      progress: [
        AgentProgressLine(
          who: '${t['claimedByName']}',
          time: '昨天 17:40',
          text: '${t['title']}',
        ),
      ],
    );
  }

  @override
  Future<AgentAttention> attention() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final pool = _pool();
    return AgentAttention(
      items: AgentActivityFeed.compose(activityItems(_rows), pool),
      stale: [
        _taskItem(
          _task(
            't77',
            77,
            'in_progress',
            6 * 24 * 60,
            'Windows 安装包签名',
            claimer: 'CodexWin',
          ),
          'CodexWin 的「Windows 安装包签名」6 天没动',
          reason: '很久没动了',
          stale: true,
          ask: '解除阻塞',
        ),
        _taskItem(
          _task('t80', 80, 'in_review', 9 * 24 * 60, '旧版迁移脚本', claimer: 'Grok'),
          'Grok 完成了「旧版迁移脚本」，9 天没人验收',
          reason: '很久没动了',
          stale: true,
          ask: '验收',
        ),
      ],
      team: const [
        AgentTeamItem(
          id: 'x1',
          headline: 'Cody 正在做「M7 profile 问题检测」',
          channelName: 'raft-flutter',
          who: 'Cody',
        ),
        AgentTeamItem(
          id: 'x2',
          headline: 'CodexWin 正在做「Windows 退出关库验证」',
          channelName: 'raft-flutter',
          who: 'CodexWin',
        ),
      ],
      pool: pool,
    );
  }

  Map<String, dynamic> _msg(
    String id,
    int seq,
    String name,
    String content,
    int minutes, {
    String type = 'agent',
    String? senderId,
    Map<String, dynamic> more = const {},
  }) => {
    'id': id,
    'seq': '$seq',
    'channelId': 'c1',
    'senderType': type,
    'senderId': senderId ?? 'a-${name.toLowerCase()}',
    'senderName': name,
    'content': content,
    'messageType': type == 'system' ? 'system' : 'chat',
    'createdAt': _ago(minutes),
    ...more,
  };

  Map<String, dynamic> _sys(String id, int seq, String content, int minutes) =>
      _msg(id, seq, 'System', content, minutes, type: 'system', senderId: '');

  @override
  Future<AgentConversationRead> conversation(
    String id, {
    int limit = 50,
    bool withTasks = true,
    String? parentChannelId,
    String? parentMessageId,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (id == 'th-m7') {
      return AgentConversationRead(
        rows: [
          _msg(
            'm-m7',
            1,
            'Kevin',
            'M7 问题检测首片什么时候能出？',
            190,
            type: 'user',
            senderId: _me,
            more: {'replyCount': 4},
          ),
          _msg('m-m7-1', 2, 'Cody', '开始跑了，先抽 12 张样本做首片，不动全量。', 175),
          _msg(
            'm-m7-2',
            3,
            'Cody',
            '首片结果出来了，误检的两张在这里：\n```\nprofile_07.json  nav.back  expected=pop  got=push\nprofile_11.json  tab.switch  expected=keep  got=reset\n```',
            40,
            more: {
              'attachments': [
                {
                  'id': 'a1',
                  'filename': 'm7-first-slice.png',
                  'mimeType': 'image/png',
                  'sizeBytes': 183000,
                },
              ],
            },
          ),
          _msg('m-m7-3', 4, 'Cindy', '07 号那张我之前也见过，应该是路由栈的问题，不是阈值。', 22),
          _msg('m-m7-4', 5, 'Cody', '@Kevin 首片 12 张里 2 张误检，继续跑全量还是先调阈值？', 3),
        ],
        hasMore: false,
        tasks: const [],
      );
    }
    if (id == 'c1') {
      return AgentConversationRead(
        rows: [
          _msg(
            'm-c1-1',
            1,
            'Kevin',
            '今天先把 M6 验收收掉，再开 M7。',
            330,
            type: 'user',
            senderId: _me,
          ),
          _msg(
            'm-c1-2',
            2,
            'Cindy',
            '收到。我先把 #94 的选型文档补完整，再提验收。',
            322,
            more: {
              'reactions': [
                {
                  'emoji': '👍',
                  'count': 2,
                  'reactorIds': [_me, 'u-bo'],
                  'reactorNames': ['Kevin', 'Bo'],
                },
              ],
            },
          ),
          _sys('s1', 3, 'Cindy claimed #98 "搜索打开另一个频道后没有返回"', 300),
          _sys('s2', 4, 'Cindy moved #98 "搜索打开另一个频道后没有返回" to In Progress', 299),
          _msg(
            'm-c1-5',
            5,
            'Grok',
            '路由栈的改法我写在这里了，改完补回归测试：\n```dart\nfinal stack = RouteStack.of(context);\nstack.popUntil((r) => r.isSearch);\n```',
            250,
            more: {'replyCount': 3},
          ),
          _msg(
            'm-c1-6',
            6,
            'Bo',
            '暗色稿的对比度我再看一下，晚点给结论。',
            205,
            type: 'user',
            senderId: 'u-bo',
            more: {'editedAt': _ago(200)},
          ),
          _msg(
            'm-c1-7',
            7,
            'CodexWin',
            '托盘退出验证的日志和截图，请看附件。',
            90,
            more: {
              'attachments': [
                {
                  'id': 'a2',
                  'filename': 'tray-exit.log',
                  'mimeType': 'text/plain',
                  'sizeBytes': 48200,
                },
                {
                  'id': 'a3',
                  'filename': 'tray-exit.png',
                  'mimeType': 'image/png',
                  'sizeBytes': 96100,
                },
              ],
            },
          ),
          _sys(
            's3',
            8,
            'Cindy moved #94 "Personal Agent 第一版选型" to In Review',
            119,
          ),
          _msg('m-c1-9', 9, 'CodexMac', 'iOS 验收：4 项未通过，M6 暂不默认开启。', 190),
          _msg(
            'm-c1-10',
            10,
            'Bo',
            '这条已经删了',
            185,
            type: 'user',
            senderId: 'u-bo',
            more: {'deletedAt': _ago(180)},
          ),
          _msg(
            'm-c1-11',
            11,
            'Kevin',
            '收到，M6 先不开。#98 修好之后再验一轮。',
            60,
            type: 'user',
            senderId: _me,
          ),
          _msg('m-c1-12', 12, 'Grok', '好的。预计 40 分钟后补完回归测试。', 31),
        ],
        hasMore: true,
        tasks: [
          _task(
            't98',
            98,
            'in_progress',
            31,
            '搜索打开另一个频道后没有返回',
            claimer: 'Grok',
          ),
          _task('t101', 101, 'in_review', 250, '发布说明初稿'),
          _task(
            't96',
            96,
            'in_progress',
            20,
            'M7 profile 问题检测',
            claimer: 'Cody',
          ),
        ],
      );
    }
    return const AgentConversationRead(rows: []);
  }

  @override
  Future<List<AgentRuntimeInfo>> agents() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const [
      AgentRuntimeInfo(
        id: 'a-grok',
        name: 'Grok',
        state: AgentWorkState.busy,
        activity: '在做 #98「搜索打开另一个频道后没有返回」',
        channel: 'raft-flutter',
        taskNumber: 98,
      ),
      AgentRuntimeInfo(
        id: 'a-cody',
        name: 'Cody',
        state: AgentWorkState.busy,
        activity: '在做 #96「M7 profile 问题检测」',
        since: '4 分钟前有进展',
        channel: 'raft-flutter',
        taskNumber: 96,
      ),
      AgentRuntimeInfo(
        id: 'a-codexwin',
        name: 'CodexWin',
        state: AgentWorkState.busy,
        activity: '在做 #99「Windows 退出关库验证」',
        since: '9 分钟前有进展',
        channel: 'raft-flutter',
        taskNumber: 99,
      ),
      AgentRuntimeInfo(
        id: 'a-cindy',
        name: 'Cindy',
        state: AgentWorkState.idle,
        activity: '空闲',
      ),
    ];
  }

  @override
  Future<List<AgentTaskDetail>> tasksNumbered(
    int number, {
    String? channel,
  }) async => const [];

  @override
  Future<List<Map<String, dynamic>>> openTasks() async => [
    _task('t98', 98, 'in_progress', 31, '搜索打开另一个频道后没有返回', claimer: 'Grok'),
    _task('t96', 96, 'in_progress', 20, 'M7 profile 问题检测', claimer: 'Cody'),
  ];
}

/// A [Listenable] the demo fires when a message arrives.
class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

class _OfflineClient extends RaftClient {
  _OfflineClient()
    : super(
        origin: 'https://example.invalid',
        sessionStore: MemorySessionStore(),
      );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final client = _OfflineClient()
    ..user = RaftRecord({'id': _me, 'displayName': 'Kevin', 'name': 'kevin'});
  final w = WorkspaceController(client)
    ..server = RaftRecord({'id': 's1', 'role': 'owner', 'name': 'Raft'})
    ..channels = [
      RaftChannel({'id': 'c1', 'name': 'raft-flutter', 'joined': true}),
      RaftChannel({'id': 'c2', 'name': 'general', 'joined': true}),
      RaftChannel({'id': 'c3', 'name': 'design', 'joined': true}),
    ]
    ..dms = [
      RaftChannel({
        'id': 'd1',
        'type': 'dm',
        'name': 'alice',
        'peerDisplayName': 'Alice Chen',
        'joined': true,
      }),
    ];
  final theme = switch (_theme) {
    'elegant-light' => raftTheme(RaftFamily.elegant),
    'elegant-dark' => raftTheme(RaftFamily.elegant, dark: true),
    _ => raftTheme(RaftFamily.brutal),
  };
  final page = _ScriptedPage(controller: w);
  if (_tv) {
    final frames = ValueNotifier<Map<String, Object?>?>(null);
    AgentPresentation.instance.debugSink = (f) => frames.value = f;
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Stack(
          children: [
            // The phone, out of sight: it composes what the TV shows.
            Offstage(child: page),
            Scaffold(body: AgentTvView(frames: frames)),
          ],
        ),
      ),
    );
    return;
  }
  runApp(
    MaterialApp(debugShowCheckedModeBanner: false, theme: theme, home: page),
  );
}

/// An operation of the demo: it previews what it would do and "runs" without
/// a server, so a confirm card has something to ask about. It has the id of
/// the real capability, so the app's own tools reach it.
AgentCapability _demoAction(
  String id,
  String title,
  Map<String, Object?> params, {
  required String Function(Map<String, Object?> args) summary,
  required List<String> Function(Map<String, Object?> args) changes,
  required String done,
  List<String> required = const [],
}) => AgentCapability(
  id: id,
  title: title,
  kind: AgentCapabilityKind.action,
  risk: AgentCapabilityRisk.change,
  paramsSchema: {
    'type': 'object',
    'properties': {
      for (final e in params.entries)
        e.key: {'type': 'string', 'description': '${e.value}'},
    },
    if (required.isNotEmpty) 'required': required,
  },
  resultSummary: 'done',
  keywords: [title],
  preview: (w, args, env) async =>
      AgentActionPreview(summary: summary(args), changes: changes(args)),
  run: (w, args, env) async => {'status': 'done', 'done': done},
);

final _demoIds = {
  'messages.react',
  'messages.reply_thread',
  'messages.send',
  'activity.mark_done',
  'tasks.assign',
  'tasks.create',
};

/// What the demo can change: the feedback actions of the home, with the
/// ids of the real capabilities.
final _registry = AgentCapabilityRegistry([
  AgentCapability(
    id: 'demo.finish',
    title: '把任务标成完成',
    kind: AgentCapabilityKind.action,
    risk: AgentCapabilityRisk.change,
    paramsSchema: const {
      'type': 'object',
      'properties': {
        'number': {'type': 'integer', 'description': '任务编号'},
      },
      'required': ['number'],
    },
    resultSummary: '任务',
    keywords: const ['完成'],
    preview: (w, args, env) async => AgentActionPreview(
      summary: '把 #${args['number']} 标记为已完成',
      changes: const ['状态: 等验收 → 已完成'],
    ),
    run: (w, args, env) async => {'status': 'done'},
  ),
  _demoAction(
    'messages.react',
    '给一条消息加表情反应',
    {'message': '消息 id', 'emoji': '表情', 'channel': '频道'},
    summary: (a) => '给 Cody 的消息加 ${a['emoji']}',
    changes: (a) => ['表情: → ${a['emoji']}', '消息: Cody：@Kevin 首片 12 张里 2 张误检…'],
    done: '已加 👍',
    required: const ['message', 'emoji'],
  ),
  _demoAction(
    'messages.reply_thread',
    '在讨论串里回复',
    {'message': '消息 id', 'text': '内容', 'channel': '频道'},
    summary: (a) => '回复 Cody 的消息：“${a['text']}”',
    changes: (a) => ['回复: Cody：@Kevin 首片 12 张里 2 张误检…', '内容: → ${a['text']}'],
    done: '已回复',
    required: const ['message', 'text'],
  ),
  _demoAction(
    'messages.send',
    '往频道或私信发消息',
    {'channel': '频道', 'text': '内容'},
    summary: (a) => '发到私信：“${a['text']}”',
    changes: (a) => ['发到: → 私信', '内容: → ${a['text']}'],
    done: '已发送',
    required: const ['channel', 'text'],
  ),
  _demoAction(
    'activity.mark_done',
    '把动态里的会话标为已处理',
    {'channel': '频道', 'thread': '讨论串'},
    summary: (a) => '把 #raft-flutter 里的讨论串在动态里标为已处理',
    changes: (a) => ['动态: 待处理 → 已处理', '未读: 2 条 → 0 条'],
    done: '已标为已处理',
    required: const ['channel'],
  ),
  _demoAction(
    'tasks.assign',
    '把任务指派给某人',
    {'task': '任务', 'assignee': '负责人'},
    summary: (a) => '把任务指派给 ${a['assignee']}',
    changes: (a) => ['负责人: Cindy → ${a['assignee']}'],
    done: '已指派',
    required: const ['task', 'assignee'],
  ),
  _demoAction(
    'tasks.create',
    '新建任务',
    {'channel': '频道', 'title': '标题', 'description': '描述', 'assignee': '负责人'},
    summary: (a) => '在 #design 新建任务“${a['title']}”，交给 ${a['assignee']}',
    changes: (a) => ['标题: → ${a['title']}', '负责人: → ${a['assignee']}'],
    done: '已新建',
    required: const ['channel', 'title'],
  ),
  for (final c in agentStandardCapabilities.all)
    if (!_demoIds.contains(c.id)) c,
]);

class _ScriptedPage extends StatefulWidget {
  const _ScriptedPage({required this.controller});
  final WorkspaceController controller;
  @override
  State<_ScriptedPage> createState() => _ScriptedPageState();
}

class _ScriptedPageState extends State<_ScriptedPage> {
  final _key = GlobalKey();
  late final _data = _DemoData(widget.controller);

  @override
  void initState() {
    super.initState();
    if (_script) unawaited(_run());
  }

  /// The input field only exists once the keyboard button was pressed.
  Future<void> _type(String text) async {
    var field = find(_key.currentContext!);
    if (field == null) {
      _tap(_key.currentContext!, const ValueKey('agent-keyboard'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      field = find(_key.currentContext!);
    }
    if (field == null) return;
    field.controller?.text = text;
    field.onSubmitted?.call(text);
  }

  /// Taps the first [GestureDetector] below the widget keyed [key].
  void _tap(BuildContext root, Key key) {
    var done = false;
    void inside(Element e) {
      if (done) return;
      final widget = e.widget;
      if (widget is GestureDetector && widget.onTap != null) {
        done = true;
        widget.onTap!();
        return;
      }
      e.visitChildren(inside);
    }

    void visit(Element e) {
      if (done) return;
      if (e.widget.key == key) {
        inside(e);
        return;
      }
      e.visitChildren(visit);
    }

    (root as Element).visitChildren(visit);
  }

  TextField? find(BuildContext root) {
    TextField? hit;
    void visit(Element e) {
      if (hit != null) return;
      final widget = e.widget;
      if (widget is TextField && widget.key == const ValueKey('agent-input')) {
        hit = widget;
        return;
      }
      e.visitChildren(visit);
    }

    (root as Element).visitChildren(visit);
    return hit;
  }

  /// A moment worth a screenshot: a recording harness waits for this line (in
  /// the file named by `AGENT_DEMO_MARKS` when set, else on stdout).
  void _mark(String name) {
    final file = Platform.environment['AGENT_DEMO_MARKS'];
    if (file == null) {
      debugPrint('AGENT_DEMO_MARK $name');
    } else {
      File(file)
          .writeAsStringSync('$name\n', mode: FileMode.append, flush: true);
    }
  }

  Future<void> _run() async {
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    // Leaves the screen alone while a harness takes its screenshot.
    final hold = int.tryParse(Platform.environment['AGENT_DEMO_HOLD_MS'] ?? '');
    // Puts the typing bar away, so the page has its whole room.
    Future<void> closeKeyboard() async {
      if (find(_key.currentContext!) != null) {
        _tap(_key.currentContext!, const ValueKey('agent-keyboard'));
        await wait(600);
      }
    }

    Future<void> mark(String name) async {
      await closeKeyboard();
      _mark(name);
      await wait(hold ?? 1500);
    }

    await wait(2500);
    await mark('home');
    // A message arrives in the Activity while the home is open.
    _data.arrive(_arrival());
    await wait(1800);
    await mark('live');
    // The newest row is the current one: its message in full and the
    // feedback actions (a wide window shows them beside the list).
    await _type('看看第一个');
    await wait(4500);
    await mark('actions');
    // 点赞: the preview and its confirm card, as for every operation.
    _tap(
      _key.currentContext!,
      const ValueKey('attention-like-activity:channel:c3'),
    );
    await wait(2500);
    await mark('confirm');
    await _type('算了');
    await wait(1500);
    // The whole conversation of a row, its message highlighted.
    await _type('打开第二条');
    await wait(3500);
    await mark('thread');
    await _type('返回');
    await wait(2500);
    // A channel: a chat of every kind of message.
    await _type('raft-flutter 现在什么情况？');
    await wait(4000);
    await mark('channel');
    await _type('下一批');
    await wait(2500);
    await mark('channel-next');
    await _type('返回');
    await wait(2500);
    // The group of tasks nobody touched for days, opened.
    _tap(_key.currentContext!, const ValueKey('attention-stale'));
    await wait(1500);
    await _type('看看第十个');
    await wait(4500);
    await mark('stale');
    await _type('回到首页');
    await wait(2500);
    await mark('attention-dock');
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: _key,
    child: AgentModePage(
      controller: widget.controller,
      data: _data,
      registry: _registry,
      // No network: a scripted model answers through the same tools.
      model: const AgentScriptedModel(),
    ),
  );
}
