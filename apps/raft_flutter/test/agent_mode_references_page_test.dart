import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

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
        action: AgentAction.approve,
        canApprove: true,
        reason: '你派的任务',
        waitValue: 3,
        at: worldNow,
        waiters: const ['Cindy'],
        channelId: 'ch-general',
        channelName: 'general',
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
      ),
    ],
  );
}

void main() {
  late ActivityClient client;
  late CapabilityWorld w;

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

  testWidgets('cards carry handles, the tools see them, a tap points', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final probe = _Probe((call) async {});
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: AgentModePage(controller: w, data: _Data(w), model: probe),
      ),
    );
    await t.pumpAndSettle();

    // The home cards already wear their rank, which is their handle.
    expect(find.byKey(const ValueKey('agent-pointed-1')), findsNothing);

    Future<void> say(
      String text,
      Future<void> Function(AgentToolHandler) script,
    ) async {
      probe.script = script;
      if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
        await t.tap(find.byKey(const ValueKey('agent-keyboard')));
        await t.pumpAndSettle();
      }
      await t.enterText(find.byKey(const ValueKey('agent-input')), text);
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pumpAndSettle();
    }

    late Map<String, Object?> found, queried, second, deixis, screen;
    await say('随便', (call) async {
      found = await call('find', {'intent': '有哪些任务在等验收'});
      queried = await call('query', {
        'capability': 'tasks.board',
        'args': '{"status":"in_progress"}',
      });
      second = await call('resolve', {'phrase': '第二个'});
      deixis = await call('resolve', {'phrase': '这个'});
      screen = await call('go_home', {});
    });
    expect((found['matches'] as List).first['id'], 'tasks.board');
    expect((queried['result'] as Map)['total'], 1);
    expect((second['entity'] as Map)['id'], 't7');
    expect((second['entity'] as Map)['handle'], '②');
    // Nothing was tapped yet and two cards are there: ask back.
    expect(deixis['status'], 'ambiguous');
    expect(screen['refs'], contains('①任务(t94)'));
    expect(screen['refs'], contains('②任务(t7)'));
    final items = (screen['items'] as List).cast<Map>();
    expect(items.first['handle'], '①');
    expect(items.first['entity'], {'type': 'task', 'id': 't94'});

    // Tapping the first card makes it the current one (its detail opens
    // under it) and “这个” is that task; 展开 goes to the full page.
    await t.tap(find.text('Cindy 完成了「选型」，等你验收'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('hf-stage')), findsOneWidget);
    late Map<String, Object?> stage;
    await say('随便', (call) async {
      stage = await call('resolve', {'phrase': '这个'});
    });
    expect((stage['entity'] as Map)['id'], 't94');
    await t.tap(find.byKey(const ValueKey('hf-stage-expand')));
    await t.pumpAndSettle();
    expect(find.text('第 2 层'), findsOneWidget);
    // The detail's task card wears 1 on its bar and is the pointed one.
    expect(find.byKey(const ValueKey('agent-pointed-1')), findsOneWidget);
    late Map<String, Object?> there;
    await say('随便', (call) async {
      there = await call('resolve', {'phrase': '这个'});
    });
    expect((there['entity'] as Map)['id'], 't94');
    expect(there['how'], 'pointed');
  });

  test('the prompt explains the flow, the handles and the ask-back rule', () {
    final prompt = agentSystemPrompt(channels: 'general');
    for (final word in [
      'find',
      'query',
      'act',
      'confirm',
      'resolve',
      '①',
      'candidates',
      '不要自己猜',
      '不要编 id',
    ]) {
      expect(prompt, contains(word), reason: word);
    }
  });
}
