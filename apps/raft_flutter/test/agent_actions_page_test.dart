import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_consent_tray.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// In the page: a one-step tool puts the preview card on screen, the person
/// presses 确认, the model calls confirm, the same card turns into the result
/// with the task card in it and a 撤销 that works, and the audit log can be
/// read back.
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
  Future<AgentAttention> attention() async => AgentAttention(items: const []);
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
    w.routes['/tasks/channel/ch-general/number/9'] = (_) => {
      'task': taskRow('t3', 9, 'in_progress', title: '丙'),
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<_Probe> open(WidgetTester t) async {
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
    return probe;
  }

  Future<void> say(
    WidgetTester t,
    _Probe probe,
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

  testWidgets('the one-step tools are declared to the model', (t) async {
    final names = [
      for (final d in [...agentToolDeclarations]) d['name'],
    ];
    // The page adds the generic and the one-step tools to these; the
    // declarations themselves are checked in agent_actions_test.
    expect(names, isNot(contains('send_message')));
    final prompt = agentSystemPrompt(channels: 'general');
    for (final name in [
      'send_message',
      'reply_in_thread',
      'react',
      'mark_read',
      'mark_done',
      'create_task',
      'set_task_status',
      'assign_task',
      'unassign_task',
      'join_channel',
      'undo',
      'agent.audit_log',
    ]) {
      expect(prompt, contains(name));
    }
    expect(prompt, contains('永远不要自己调用 confirm'));
    expect(prompt, isNot(contains('还没有开放任何操作')));
    expect(prompt, isNot(contains('现在只能查看')));
  });

  testWidgets('preview card, tap, result card in place, undo, audit', (
    t,
  ) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, early, done, undone, audit;

    await say(t, probe, '把 #9 改成等验收', (call) async {
      previewed = await call('set_task_status', {
        'task': '9',
        'status': 'in_review',
      });
    });
    expect(previewed['status'], 'needs_confirmation');
    expect(find.byType(AgentConsentTray), findsOneWidget);
    expect(find.text('把 #9 丙 改为 等验收'), findsOneWidget);
    expect(find.text('确认'), findsOneWidget);
    // The task the change is about is on the card.
    expect(find.textContaining('丙'), findsWidgets);

    await say(t, probe, '随便', (call) async {
      early = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(early['error'], 'needs_user_confirmation');
    expect(w.commands, isEmpty);

    await t.tap(find.text('确认'));
    await t.pumpAndSettle();
    await say(t, probe, '随便', (call) async {
      done = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(done['status'], 'done');
    expect(w.commands.single.$2, '/tasks/t3/status');

    // The same card is now the result.
    expect(
      find.byKey(const ValueKey('confirm-card-outcome-done')),
      findsOneWidget,
    );
    expect(find.textContaining('已改为 等验收'), findsOneWidget);
    expect(find.text('确认'), findsNothing);
    expect(find.byKey(const ValueKey('confirm-card-undo')), findsOneWidget);

    // 撤销 on the card is the person's own press.
    await t.tap(find.byKey(const ValueKey('confirm-card-undo')));
    await t.pumpAndSettle();
    expect(w.commands.last.$3, {'status': 'in_progress'});
    expect(find.textContaining('已改回 进行中'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirm-card-undo')), findsNothing);

    await say(t, probe, '刚才做了什么', (call) async {
      audit = await call('query', {'capability': 'agent.audit_log'});
      undone = await call('undo', {});
    });
    final result = audit['result'] as Map;
    expect((result['entries'] as List), hasLength(2));
    expect((result['entries'] as List).last, containsPair('undo', true));
    expect(undone['error'], contains('没有能撤销'));
  });

  testWidgets('a failure turns the card into an error with retry', (t) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, failed, again;
    await say(t, probe, '加入 random', (call) async {
      w.channels = [
        ...w.channels,
        RaftChannel({'id': 'ch-random', 'name': 'random'}),
      ];
      previewed = await call('join_channel', {'channel': 'random'});
    });
    expect(previewed['status'], 'needs_confirmation');
    await t.tap(find.text('确认'));
    await t.pumpAndSettle();
    w.commandError = StateError('offline');
    await say(t, probe, '随便', (call) async {
      failed = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(failed['status'], 'failed');
    expect(
      find.byKey(const ValueKey('confirm-card-outcome-failed')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('confirm-card-retry')), findsOneWidget);

    w.commandError = null;
    await t.tap(find.byKey(const ValueKey('confirm-card-retry')));
    await t.pumpAndSettle();
    expect(w.commands.map((c) => c.$2), [
      '/channels/ch-random/join',
      '/channels/ch-random/join',
    ]);
    expect(
      find.byKey(const ValueKey('confirm-card-outcome-done')),
      findsOneWidget,
    );
    again = {};
    expect(again, isEmpty);
  });
}
