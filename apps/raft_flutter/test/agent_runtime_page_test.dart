import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

class _Probe extends AgentScriptedModel {
  _Probe();
  Future<void> Function(AgentToolHandler call)? script;
  var asked = <String>[];

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String line) say,
  ) async {
    asked.add(text);
    await script?.call(call);
    return true;
  }
}

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => worldNow);

  @override
  Future<AgentAttention> attention() async => AgentAttention(items: const []);
}

/// The page is a view of the runtime: what a direct read draws (full, not
/// folded), a new request stopping a screen, and "算了" that never reaches
/// the model.
void main() {
  late ActivityClient client;
  late CapabilityWorld w;

  setUp(() {
    AgentModeData.clearSession();
    FlutterSecureStorage.setMockInitialValues({});
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          taskRow('t3', 9, 'in_progress', title: '丙', claimedByName: 'Cody'),
        if (q?['status'] == 'in_review')
          taskRow('t4', 10, 'in_review', title: '丁', claimedByName: 'Cindy'),
        if (q?['status'] == 'todo') taskRow('t5', 11, 'todo', title: '戊'),
      ],
    };
    w.routes['/tasks/channel/ch-general/number/9'] = (_) => {
      'task': {...taskRow('t3', 9, 'in_progress', title: '丙'), 'revision': 4},
    };
    w.routes['/channels/ch-general/members'] = (_) => {
      'humans': [
        {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
      ],
      'agents': [
        {'id': 'a-cody', 'name': 'cody', 'displayName': 'Cody'},
      ],
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<_Probe> open(
    WidgetTester t, {
    Size size = const Size(390, 844),
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final probe = _Probe();
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
    Future<void> Function(AgentToolHandler)? script,
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

  testWidgets('看所有任务: one call, every task a full card, nothing folded', (
    t,
  ) async {
    final probe = await open(t);
    late Map<String, Object?> shown;
    var calls = 0;
    await say(t, probe, '看所有任务', (call) async {
      calls++;
      shown = await call('show_list', {'kind': 'tasks'});
    });
    expect(calls, 1);
    expect(shown['shown'], 3);
    // Three entity cards on a phone, in full: the task titles are drawn, and
    // no summary row ("点开") stands in for them.
    expect(find.byType(AgentEntityCard), findsNWidgets(3));
    expect(find.byType(AgentSummaryRow), findsNothing);
    for (final title in ['丙', '丁', '戊']) {
      expect(find.textContaining(title), findsWidgets, reason: title);
    }
    // The numbers are the person's handles: "第二个" can be said.
    expect(find.text('②'), findsWidgets);
  });

  testWidgets('a phone shows at least four task cards above the dock, '
      'in the order the model was told', (t) async {
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        for (var i = 1; i <= 8; i++)
          if (q?['status'] == (i.isEven ? 'in_progress' : 'in_review'))
            taskRow(
              't$i',
              i * 10,
              i.isEven ? 'in_progress' : 'in_review',
              title: '任务 $i',
              claimedByName: 'Cody',
              updated: 9 - i,
            ),
      ],
    };
    final probe = await open(t, size: const Size(360, 800));
    late Map<String, Object?> shown;
    await say(t, probe, '看所有任务', (call) async {
      shown = await call('show_list', {'kind': 'tasks'});
    });
    expect(shown['order'], 'updated desc');
    final told = [
      for (final i in shown['items'] as List) (i as Map)['label'] as String,
    ];
    // The newest (#80, the smallest age) is first and ① on screen.
    expect(told.first, startsWith('#80'));

    await t.tap(find.byKey(const ValueKey('agent-keyboard')));
    await t.pumpAndSettle();
    final dock = t.getRect(find.byType(AgentVoiceDock));
    final visible = [
      for (final e in find.byType(AgentEntityCard).evaluate())
        if (t.getRect(find.byWidget(e.widget)).bottom <= dock.top) e.widget,
    ];
    // Four cards, with the transcript's two lines above the mic.
    expect(visible.length, greaterThanOrEqualTo(4));

    // Drawn top to bottom exactly as told: the cards' titles in the order of
    // the result, and the badges ①, ②, ③ going down.
    final tops = <double>[];
    for (final glyph in ['①', '②', '③', '④']) {
      tops.add(t.getTopLeft(find.text(glyph).first).dy);
    }
    expect(tops, [...tops]..sort());
    final y = [
      for (final label in told.take(4))
        t.getTopLeft(find.textContaining(label.split(' ').last).first).dy,
    ];
    expect(y, [...y]..sort(), reason: told.take(4).join(', '));
  });

  testWidgets('a new request stops the screen being composed, marked 已停止', (
    t,
  ) async {
    final probe = await open(t);
    // The model is still composing (the script waits) when the person speaks.
    final composing = Completer<void>();
    addTearDown(() {
      if (!composing.isCompleted) composing.complete();
    });
    await say(t, probe, 'Agent 们在干什么', (call) async {
      await call('begin_surface', {
        'surface_id': 'agents',
        'title': 'Agent 们',
        'layout': '{"component":"Column","id":"root","children":[{"component":"Section","id":"busy","title":"在忙","density":"detail"}]}',
      });
      await call('add_component', {
        'surface_id': 'agents',
        'parent_id': 'busy',
        'component': '{"component":"Callout","text":"Cody 在做 #9"}',
      });
      await composing.future;
    });
    expect(find.text('Cody 在做 #9'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-surface-stopped')), findsNothing);

    late Map<String, Object?> late_, shown;
    await say(t, probe, '看所有频道', (call) async {
      shown = await call('show_list', {'kind': 'channels'});
      late_ = await call('add_component', {
        'surface_id': 'agents',
        'parent_id': 'busy',
        'component': '{"component":"Callout","text":"Bo 在做 #10"}',
      });
      // Back to the old screen: as it was, and saying it was stopped.
      await call('go_back', {});
    });
    expect(shown['ok'], isTrue);
    expect(late_['stopped'], isTrue);
    expect(find.text('Cody 在做 #9'), findsOneWidget);
    expect(find.text('Bo 在做 #10'), findsNothing);
    expect(find.byKey(const ValueKey('agent-surface-stopped')), findsOneWidget);
    expect(find.text('已停止'), findsOneWidget);
  });

  testWidgets('算了 typed: nothing goes to the model, the card says 已取消', (
    t,
  ) async {
    final probe = await open(t);
    late Map<String, Object?> previewed;
    await say(t, probe, '把 #9 改成等验收', (call) async {
      previewed = await call('set_task_status', {
        'task': '9',
        'status': 'in_review',
      });
    });
    expect(previewed['status'], 'needs_confirmation');
    expect(find.text('确认'), findsOneWidget);
    expect(probe.asked, ['把 #9 改成等验收']);

    await say(t, probe, '算了', null);
    // The scripted model, which stands for the real one, was not asked.
    expect(probe.asked, ['把 #9 改成等验收']);
    expect(find.text('已取消'), findsOneWidget);
    expect(find.text('确认'), findsNothing);
    expect(find.text('已停止'), findsWidgets, reason: 'the caption');
    expect(w.commands, isEmpty);
  });

  testWidgets('a new, unrelated request cancels the old confirmation', (
    t,
  ) async {
    final probe = await open(t);
    late Map<String, Object?> previewed;
    await say(t, probe, '把 #9 改成等验收', (call) async {
      previewed = await call('set_task_status', {
        'task': '9',
        'status': 'in_review',
      });
    });
    expect(find.text('确认'), findsOneWidget);
    await say(t, probe, '看所有频道', (call) async {
      await call('show_list', {'kind': 'channels'});
    });
    expect(find.text('确认'), findsNothing);
    expect(find.text('已取消'), findsOneWidget);
    expect(previewed['confirmToken'], isNotNull);
  });
}
