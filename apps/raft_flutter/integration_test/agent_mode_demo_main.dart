// Offline visual host for the agent mode demo: fixed sample data, no network.
//   tool/flutter run -d linux -t integration_test/agent_mode_demo_main.dart \
//     --dart-define=AGENT_DEMO_THEME=brutal|elegant-light|elegant-dark \
//     --dart-define=AGENT_DEMO_SCRIPT=true
// The script types a channel request, goes back and opens tasks so a recording
// shows each Z-axis transition.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_ui/raft_ui.dart';

final _theme =
    Platform.environment['AGENT_DEMO_THEME'] ??
    const String.fromEnvironment('AGENT_DEMO_THEME', defaultValue: 'brutal');
final _script =
    Platform.environment['AGENT_DEMO_SCRIPT'] == '1' ||
    const bool.fromEnvironment('AGENT_DEMO_SCRIPT');

final _now = DateTime.now();
String _ago(int minutes) =>
    _now.subtract(Duration(minutes: minutes)).toUtc().toIso8601String();

class _DemoData extends AgentModeData {
  _DemoData(super.w);

  @override
  Future<List<AgentAttentionItem>> attention() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return [
      AgentAttentionItem(
        priority: AgentPriority.decision,
        weight: 5,
        title: 'Personal Agent 第一版选型（5 个问题）',
        detail: '#94 等你验收 · Cindy',
        chips: const ['等了 2 小时', '#raft-flutter'],
        hot: true,
        at: _now,
        channelId: 'c1',
      ),
      AgentAttentionItem(
        priority: AgentPriority.blocked,
        weight: 4,
        title: 'iOS：从搜索进频道后无法返回',
        detail: '#98 · Grok · 5 小时没有进展',
        chips: const ['#raft-flutter'],
        at: _now,
        channelId: 'c1',
      ),
      AgentAttentionItem(
        priority: AgentPriority.mention,
        weight: 3,
        title: 'Cody：M7 问题检测首片待审',
        detail: '#raft-flutter 的讨论',
        chips: const ['未读', '12 分钟'],
        at: _now,
        channelId: 'c1',
      ),
      AgentAttentionItem(
        priority: AgentPriority.progress,
        weight: 1,
        title: '修复并行发送后的排序 已完成',
        detail: '#97 · Cody',
        at: _now,
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
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: _ScriptedPage(controller: w),
    ),
  );
}

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

  Future<void> _type(String text) async {
    final field = find(_key.currentContext!);
    if (field == null) return;
    field.controller?.text = text;
    field.onSubmitted?.call(text);
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

  Future<void> _run() async {
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    await wait(2500);
    await _type('raft-flutter 现在什么情况？');
    await wait(3200);
    await _type('返回');
    await wait(2200);
    await _type('看看任务');
    await wait(3000);
    await _type('回到提醒');
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: _key,
    child: AgentModePage(
      controller: widget.controller,
      data: _DemoData(widget.controller),
    ),
  );
}
