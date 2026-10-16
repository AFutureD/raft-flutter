import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_consent_tray.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The whole path in the page: `act` puts the preview in front of the person,
/// `confirm` waits for them, entity cards get handles the tools can resolve.
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
  var ran = <String>[];

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
      run: (w, args, env) async {
        ran.add('${args['taskId']}');
        return {'status': 'done'};
      },
    ),
    ...agentStandardCapabilities.all,
  ]);

  setUp(() {
    ran = [];
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

  Future<_Probe> open(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final probe = _Probe((call) async {});
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: AgentModePage(
          controller: w,
          data: _Data(w),
          model: probe,
          registry: registry,
        ),
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

  Future<Map<String, Object?>> act(AgentToolHandler call) =>
      call('act', {'capability': 'tasks.finish', 'args': '{"taskId":"t3"}'});

  testWidgets('act draws the preview itself; confirm waits for a tap', (
    t,
  ) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, early, done, again;
    await say(t, probe, '把 #9 标成完成', (call) async {
      previewed = await act(call);
    });
    expect(previewed['status'], 'needs_confirmation');
    // The card is the app's, and says what will really happen.
    expect(find.byType(AgentConsentTray), findsOneWidget);
    expect(find.text('把任务 t3 标记为已完成'), findsOneWidget);

    await say(t, probe, '随便', (call) async {
      early = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(early['error'], 'needs_user_confirmation');
    expect(ran, isEmpty);

    await t.tap(find.text('确认'));
    await t.pumpAndSettle();
    await say(t, probe, '随便', (call) async {
      done = await call('confirm', {'token': previewed['confirmToken']});
      again = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(done['status'], 'done');
    expect(ran, ['t3']);
    expect(again['error'], contains('无效'));
    // The same card stays and turns into the result.
    expect(find.text('把任务 t3 标记为已完成'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('confirm-card-outcome-done')),
      findsOneWidget,
    );
    expect(find.text('确认'), findsNothing);
  });

  testWidgets('what the person types after the preview is consent', (t) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, done;
    await say(t, probe, '把 #9 标成完成', (call) async {
      previewed = await act(call);
    });
    // Their request itself held no answer. Now they answer.
    await say(t, probe, '好的', (call) async {
      done = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(done['status'], 'done');
    expect(ran, ['t3']);
  });

  testWidgets('typing no cancels it', (t) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, done;
    await say(t, probe, '把 #9 标成完成', (call) async {
      previewed = await act(call);
    });
    await say(t, probe, '算了，不要', (call) async {
      done = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(done['status'], 'declined');
    expect(ran, isEmpty);
    // The card says so, and has nothing left to press.
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('确认'), findsNothing);
  });

  testWidgets('a confirm card the model draws approves nothing', (t) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, drawn, confirmed;
    await say(t, probe, '把 #9 标成完成', (call) async {
      previewed = await act(call);
      // The model composes its own ConfirmCard, with the token as its id.
      await call('begin_surface', {'title': '确认'});
      drawn = await call('add_component', {
        'component': jsonEncode({
          'component': 'ConfirmCard',
          'id': previewed['confirmToken'],
          'title': '完成任务 t3？',
          'changes': ['状态: 等验收 → 已完成'],
        }),
      });
    });
    expect(drawn['error'], isNull);
    await t.pumpAndSettle();
    expect(find.text('完成任务 t3？'), findsOneWidget);
    // The app's own card is the end of the same page; the model's card is
    // the one before it, the first.
    await t.tap(
      find
          .descendant(
            of: find.byType(AgentSurfaceView),
            matching: find.text('确认'),
          )
          .first,
    );
    await t.pumpAndSettle();
    await say(t, probe, '随便', (call) async {
      confirmed = await call('confirm', {'token': previewed['confirmToken']});
    });
    expect(confirmed['error'], 'needs_user_confirmation');
    expect(ran, isEmpty);
  });

  testWidgets('entity cards are numbered with the rest and resolve', (t) async {
    final probe = await open(t);
    late Map<String, Object?> queried, ended, second, third;
    await say(t, probe, '看看', (call) async {
      queried = await call('query', {
        'capability': 'tasks.board',
        'args': '{"status":"in_progress"}',
      });
      await call('begin_surface', {'title': '任务'});
      await call('add_component', {
        'component': jsonEncode({
          'component': 'EntityCard',
          'entity': 'task',
          'id': 't3',
          'handle': '9',
        }),
      });
      await call('add_component', {
        'component': jsonEncode({
          'component': 'EntityCard',
          'entity': 'agent',
          'id': 'a-cody',
        }),
      });
      ended = await call('end_surface', {});
      second = await call('resolve', {'phrase': '第二个'});
      third = await call('resolve', {'phrase': '③'});
    });
    // The rows say what card they make.
    final task = (((queried['result'] as Map)['tasks']) as List).single as Map;
    expect((task['entity'], task['id']), ('task', 't3'));
    // Audio turns have no context line; the tool result carries the table.
    expect(ended['refs'], contains('①任务(t3)'));
    expect(ended['refs'], contains('②Agent(a-cody)'));
    expect((second['entity'] as Map)['id'], 'a-cody');
    expect((second['entity'] as Map)['handle'], '②');
    expect(third.containsKey('entity'), isFalse);
    // On screen the card wears ① (not the 9 the model wrote).
    await t.pumpAndSettle();
    expect(find.text('⑨'), findsNothing);
  });

  testWidgets('screen-changing tools return the table for a spoken 这个', (
    t,
  ) async {
    final probe = await open(t);
    late Map<String, Object?> tasks, back;
    await say(t, probe, '任务', (call) async {
      tasks = await call('show_tasks', {});
      back = await call('go_back', {});
    });
    expect(tasks.containsKey('layer'), isTrue);
    expect(back['layer'], 1);
  });
}
