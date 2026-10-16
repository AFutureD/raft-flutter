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

class _DemoData extends AgentModeData {
  _DemoData(super.w);

  @override
  Future<AgentAttention> attention() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return AgentAttention(
      items: [
        AgentAttentionItem(
          id: 't94',
          taskId: 't94',
          taskNumber: 94,
          priority: AgentPriority.decision,
          headline: 'Cindy 完成了「Personal Agent 第一版选型」，等你验收',
          ask: '验收',
          askLine: '验收「Personal Agent 选型」',
          action: AgentAction.approve,
          canApprove: true,
          reason: '你派的任务',
          waitValue: 2,
          waitUnit: '小时',
          at: _now,
          waiters: const ['Cindy'],
          doer: 'Cindy',
          channelId: 'c1',
          channelName: 'raft-flutter',
          progress: [
            AgentProgressLine(
              who: 'Cindy',
              time: '今天 10:32',
              text: '五个问题的结论都写在文档里了，请看第 3 节。',
            ),
          ],
        ),
        AgentAttentionItem(
          id: 't98',
          taskId: 't98',
          taskNumber: 98,
          priority: AgentPriority.blocked,
          headline: 'Grok 的「iOS 从搜索进频道后无法返回」5 小时没动，卡住了',
          ask: '解除阻塞',
          reason: '卡住了',
          idle: true,
          waitValue: 5,
          waitUnit: '小时',
          at: _now,
          doer: 'Grok',
          channelId: 'c1',
          channelName: 'raft-flutter',
        ),
        AgentAttentionItem(
          id: 'mention:c1',
          priority: AgentPriority.mention,
          headline: 'Cody 在 raft-flutter @ 了你：M7 问题检测首片待审',
          ask: '回复',
          askLine: '回复 Cody',
          action: AgentAction.reply,
          reason: '点名找你',
          waitValue: 12,
          waitUnit: '分钟',
          at: _now,
          doer: 'Cody',
          channelId: 'c1',
          channelName: 'raft-flutter',
        ),
      ],
    );
  }

  @override
  Future<List<AgentRuntimeInfo>> agents() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return const [
      AgentRuntimeInfo(
        id: 'a-grok',
        name: 'Grok',
        state: AgentWorkState.blocked,
        activity: '#98「搜索打开另一个频道后没有返回」 超过 5 小时没动',
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
      AgentRuntimeInfo(
        id: 'a-codexmac',
        name: 'CodexMac',
        state: AgentWorkState.offline,
        activity: '离线',
        since: '离线 3 小时',
      ),
    ];
  }

  @override
  Future<List<AgentTaskDetail>> tasksNumbered(
    int number, {
    String? channel,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (number != 98) return const [];
    return const [
      AgentTaskDetail(
        id: 't98',
        number: 98,
        title: '搜索打开另一个频道后没有返回',
        status: 'in_progress',
        description: 'iOS 从搜索进入另一个频道后，左上角返回回不到搜索页。',
        updated: '5 小时前',
        creator: 'Kevin',
        claimer: 'Grok',
        channelName: 'raft-flutter',
        thread: [
          AgentProgressLine(
            who: 'CodexMac',
            time: '今天 07:40',
            text: 'iOS 验收：4 项未通过，M6 暂不默认开启。',
          ),
          AgentProgressLine(
            who: 'Grok',
            time: '今天 07:52',
            text: '搜索页撤销在 M5 之前就存在，不是 M5 引入的。',
          ),
          AgentProgressLine(
            who: 'Grok',
            time: '今天 08:10',
            text: '正在改路由栈，改完补回归测试。',
          ),
        ],
      ),
    ];
  }

  @override
  Future<AgentChannelBrief> channel(
    RaftChannel c, {
    int windowHours = 6,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    return AgentChannelBrief(
      channel: c,
      windowHours: windowHours,
      messages: [
        {
          'senderName': 'CodexMac',
          'content': 'iOS 验收：4 项未通过，M6 暂不默认开启。',
          'createdAt': _ago(150),
        },
        {
          'senderName': 'Grok',
          'content': '搜索页撤销在 M5 之前就存在，不是 M5 引入的。',
          'createdAt': _ago(120),
        },
        {
          'senderName': 'CodexWin',
          'content': '托盘退出已通过：进入退出回调，后台数据库关闭完成。',
          'createdAt': _ago(20),
        },
        {
          'senderName': 'Cindy',
          'content': 'PR #113 已合入，全量检查 790 秒，0 失败。',
          'createdAt': _ago(8),
        },
      ],
      tasks: const [
        {
          'taskNumber': 98,
          'title': '搜索打开另一个频道后没有返回',
          'status': 'in_review',
          'claimedByName': 'Grok',
        },
        {
          'taskNumber': 102,
          'title': '历史上拉停在第一页最早一条',
          'status': 'in_progress',
          'claimedByName': 'Grok',
        },
      ],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> openTasks() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return const [
      {
        'taskNumber': 98,
        'title': '搜索打开另一个频道后没有返回',
        'status': 'in_review',
        'claimedByName': 'Grok',
        'channelName': 'raft-flutter',
      },
      {
        'taskNumber': 96,
        'title': 'M7 profile 问题检测',
        'status': 'in_progress',
        'claimedByName': 'Cody',
        'channelName': 'raft-flutter',
      },
      {
        'taskNumber': 99,
        'title': 'Windows 退出关库验证',
        'status': 'in_progress',
        'claimedByName': 'CodexWin',
        'channelName': 'raft-flutter',
      },
    ];
  }
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
  final client = _OfflineClient();
  final w = WorkspaceController(client)
    ..server = RaftRecord({'id': 's1', 'role': 'owner', 'name': 'Raft'})
    ..channels = [
      RaftChannel({'id': 'c1', 'name': 'raft-flutter', 'joined': true}),
      RaftChannel({'id': 'c2', 'name': 'general', 'joined': true}),
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

/// What the demo can change, so a confirm card has something to ask about.
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
  ...agentStandardCapabilities.all,
]);

class _ScriptedPage extends StatefulWidget {
  const _ScriptedPage({required this.controller});
  final WorkspaceController controller;
  @override
  State<_ScriptedPage> createState() => _ScriptedPageState();
}

class _ScriptedPageState extends State<_ScriptedPage> {
  final _key = GlobalKey();

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
      File(
        file,
      ).writeAsStringSync('$name\n', mode: FileMode.append, flush: true);
    }
  }

  Future<void> _run() async {
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    // Leaves the screen alone while a harness takes its screenshot.
    Future<void> mark(String name) async {
      _mark(name);
      await wait(1500);
    }

    await wait(2500);
    await mark('attention');
    await _type('现在所有的 Agent 都在干什么？');
    await wait(9000);
    await mark('agents');
    await _type('展开卡住了');
    await wait(8000);
    await mark('agents-expanded');
    await _type('返回');
    await wait(2500);
    await _type('返回');
    await wait(2500);
    await _type('raft-flutter 现在什么情况？');
    await wait(5000);
    await mark('channel');
    await _type('返回');
    await wait(2500);
    await _type('任务 #98 现在怎么样？');
    await wait(7000);
    await mark('task');
    await _type('把 #98 标记为已完成');
    await wait(3500);
    await mark('confirm');
    await _type('算了');
    await wait(1500);
    await _type('回到提醒');
    await wait(3500);
    await _type('讲讲第一条');
    await wait(3500);
    await mark('detail');
    await _type('回到提醒');
    await wait(3500);
    await mark('attention-dock');
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: _key,
    child: AgentModePage(
      controller: widget.controller,
      data: _DemoData(widget.controller),
      registry: _registry,
      // No network: a scripted model answers through the same tools.
      model: const AgentScriptedModel(),
    ),
  );
}
