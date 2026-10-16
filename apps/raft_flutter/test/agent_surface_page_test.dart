import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

final _now = DateTime.utc(2026, 10, 15, 12);

/// Fictional agents and tasks: no real names or data.
class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => _now);

  @override
  Future<AgentAttention> attention() async => const AgentAttention(items: []);

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
    AgentRuntimeInfo(
      id: 'a3',
      name: 'Cy',
      state: AgentWorkState.idle,
      activity: '空闲',
    ),
  ];

  @override
  Future<List<AgentTaskDetail>> tasksNumbered(
    int number, {
    String? channel,
  }) async => number != 98
      ? const []
      : const [
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
              AgentProgressLine(who: 'Zed', time: '09:10', text: '请看一下返回键'),
              AgentProgressLine(who: 'Bo', time: '09:40', text: '我这边复现不了了'),
              AgentProgressLine(who: 'Aria', time: '10:32', text: '已修复并补了测试'),
            ],
          ),
        ];
}

/// A model that sends a surface straight to the tool, whatever it says.
class _Wrong extends AgentScriptedModel {
  const _Wrong(this.surface);
  final String surface;
  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String) say,
  ) async {
    final r = await call('show_surface', {'surface': surface});
    say('${r['error'] ?? 'ok'}');
    return true;
  }
}

void main() {
  late ActivityClient client;
  late WorkspaceController w;
  setUp(() {
    AgentModeData.clearSession();
    FlutterSecureStorage.setMockInitialValues({});
    client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
    client.selectServer('s1');
    w = WorkspaceController(client)
      ..server = RaftRecord({'id': 's1', 'role': 'owner'});
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<void> ask(WidgetTester t, String text) async {
    await t.enterText(find.byKey(const ValueKey('agent-input')), text);
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t, {AgentScriptedModel? model}) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentModePage(
          controller: w,
          data: _Data(w),
          model: model ?? const AgentScriptedModel(),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('agent-keyboard')));
    await t.pumpAndSettle();
  }

  testWidgets('"现在所有的 Agent 都在干什么？" composes statuses by state', (t) async {
    await open(t);
    await ask(t, '现在所有的 Agent 都在干什么？');
    expect(find.text('第 2 层'), findsOneWidget);
    expect(find.text('现在所有 Agent 在做什么'), findsWidgets);
    // Groups by state, only the non-empty ones.
    expect(find.text('在忙'), findsWidgets);
    expect(find.text('卡住了'), findsWidgets);
    expect(find.text('空闲'), findsWidgets);
    expect(find.text('离线'), findsNothing);
    for (final name in ['Aria', 'Bo', 'Cy']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('在做 #102「历史上拉」'), findsOneWidget);
    expect(find.text('#seed'), findsOneWidget);
    // One spoken sentence, built from the counts that were read.
    expect(find.textContaining('3 个 Agent：1 个在忙，1 个卡住了，1 个空闲'), findsWidgets);
    expect(find.byKey(const ValueKey('agent-surface-error')), findsNothing);

    await ask(t, '返回');
    expect(find.text('第 1 层'), findsOneWidget);
  });

  testWidgets('"任务 #98 现在怎么样？" shows the task card and its quotes', (t) async {
    await open(t);
    await ask(t, '任务 #98 现在怎么样？');
    expect(find.text('第 2 层'), findsOneWidget);
    expect(find.text('修复搜索打开频道后无法返回'), findsOneWidget);
    expect(find.text('等验收'), findsOneWidget);
    expect(find.text('负责人 Aria'), findsOneWidget);
    expect(find.text('验收这个任务'), findsOneWidget);
    expect(find.text('Aria · 10:32  已修复并补了测试'), findsOneWidget);
    // The earlier lines of the thread are quoted below.
    expect(find.text('最近讨论'), findsOneWidget);
    expect(find.text('请看一下返回键'), findsOneWidget);
    expect(find.text('我这边复现不了了'), findsOneWidget);
    expect(find.textContaining('任务 #98 现在等验收，由 Aria 负责'), findsWidgets);
  });

  testWidgets('a task that does not exist says so and shows nothing', (
    t,
  ) async {
    await open(t);
    await ask(t, '任务 #5 现在怎么样？');
    expect(find.text('第 1 层'), findsOneWidget);
    expect(find.textContaining('没有找到任务 #5'), findsOneWidget);
  });

  testWidgets('a refused surface leaves the screen and shows a small caption', (
    t,
  ) async {
    await open(
      t,
      model: const _Wrong('{"title":"x","root":{"component":"Carousel"}}'),
    );
    await ask(t, '随便');
    expect(find.text('第 1 层'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-surface-error')), findsOneWidget);
    expect(find.textContaining('Carousel'), findsWidgets);
  });

  testWidgets('an invented agent is refused even though the surface is valid', (
    t,
  ) async {
    await open(
      t,
      model: const _Wrong(
        '{"title":"x","root":{"component":"AgentStatusCard","name":"Zoe","state":"busy"}}',
      ),
    );
    await ask(t, '随便');
    expect(find.text('第 1 层'), findsOneWidget);
    expect(find.textContaining('list_agents'), findsWidgets);
    expect(find.text('Zoe'), findsNothing);
  });
}
