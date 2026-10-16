import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface.dart';
import 'package:raft_flutter/features/agent_mode/agent_tv.dart';
import 'package:raft_ui/raft_ui.dart';

/// The TV runs its own engine with no workspace: what it shows reaches it only
/// as a frame. It draws the same screens as a desktop window with the same
/// components (its buttons are voice hints), so a frame carries what those
/// need: the attention result, the screen the model composed and what its
/// cards point at, never just their ids.
void main() {
  const id = 'b9292630-7a6d-4659-b76a-31bf6ff3a455';
  final spec = agentStandardCatalog
      .parse(
        jsonEncode({
          'title': '现在所有 Agent 在做什么',
          'root': {
            'component': 'Column',
            'children': [
              {'component': 'EntityCard', 'entity': 'agent', 'id': id},
              {'component': 'EntityCard', 'entity': 'task', 'id': 't98'},
            ],
          },
        }),
      )
      .spec!;
  AgentEntityData? data(String kind, String id) => switch (kind) {
    'agent' => const AgentAgentData(
      name: 'Cindy',
      state: AgentWorkState.blocked,
      activity: '在做 #98',
      since: '5 小时没动',
    ),
    'task' => const AgentTaskData(
      title: '修复返回',
      status: 'in_review',
      number: 98,
      assignee: 'Cody',
    ),
    _ => null,
  };
  Map<String, Object?> frame() => {
    ...agentSurfaceFrame(
      spec,
      entityData: data,
      entityOf: (n) => {
        'kind': n.string('entity'),
        'id': n.string('id'),
        'label': data(n.string('entity')!, n.string('id')!)!.label,
      },
    ),
    'id': 'surface-1',
  };

  test('entity cards carry their status and facts, not their ids', () {
    final items = [for (final i in frame()['items']! as List) i as Map];
    expect(items[0]['title'], 'Cindy');
    expect(items[0]['label'], '卡住了');
    expect(items[0]['priority'], AgentPriority.blocked.name);
    expect(items[0]['detail'], '在做 #98 · 5 小时没动');
    expect(items[1]['label'], '等验收');
    expect(items[1]['priority'], AgentPriority.decision.name);
    // The id stays in the reference only, for "这个" to resolve.
    for (final i in items) {
      expect('${i['title']} ${i['label']} ${i['detail']}', isNot(contains(id)));
    }
    expect(frame()['meta'], isNull);
  });

  test('the frame carries the screen and what its cards say', () {
    final f = frame();
    expect(
      AgentSurfaceSpec.fromJson((f['spec']! as Map).cast()).title,
      spec.title,
    );
    final entities = (f['entities']! as Map).cast<String, Object?>();
    expect(entities.keys, containsAll(['agent:$id', 'task:t98']));
    final back = AgentStaticEntityResolver.fromJson(entities);
    final r = back.resolve(AgentEntityRef(AgentEntityKind.agent, id));
    expect((r as AgentEntityFound).data.label, 'Cindy');
    expect(
      back.resolve(const AgentEntityRef(AgentEntityKind.task, 'zz')),
      isA<AgentEntityMissing>(),
    );
  });

  Future<void> tv(WidgetTester t, Map<String, Object?> f) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final spotlight = AgentSpotlightController();
    final marks = AgentMarkController();
    addTearDown(spotlight.dispose);
    addTearDown(marks.dispose);
    // What AgentTvView does with the phone's frame.
    spotlight.sync(f['spotlight'] as String?);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: AgentTvScreen(frame: f, spotlight: spotlight, marks: marks),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  testWidgets('the TV draws a surface with the desktop components, numbered, '
      'with no ids', (t) async {
    await tv(t, {
      'caption': '一个卡住了。',
      'mood': '🤔',
      'layers': [frame()],
    });
    expect(find.textContaining('Cindy'), findsWidgets);
    expect(find.textContaining('修复返回'), findsWidgets);
    expect(find.textContaining(id), findsNothing);
    expect(find.text('GenUI'), findsNothing);
    // The entity cards are the numbered rows of a desktop window.
    expect(find.byType(HfEntityCard), findsNWidgets(2));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    // The caption strip carries the mood; there is no dock to press.
    expect(find.text('一个卡住了。'), findsOneWidget);
    expect(find.text('🤔'), findsOneWidget);
    expect(find.byType(HfDock), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    // The same dotted canvas as the phone.
    expect(find.byType(HfCanvas), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the TV draws the attention list beside the detail, with voice '
      'hints for the buttons', (t) async {
    final attention = AgentAttention(
      items: [
        AgentAttentionItem(
          id: 't1',
          taskId: 't1',
          taskNumber: 12,
          priority: AgentPriority.decision,
          headline: 'Bo 做完了「修复登录跳转」，等你验收',
          ask: '验收',
          askLine: '验收「修复登录跳转」',
          action: AgentAction.approve,
          canApprove: true,
          reason: '等你验收',
          waitValue: 3,
          waitUnit: '天',
          at: DateTime.utc(2026, 10, 15),
          doer: 'Bo',
          channelId: 'c1',
          channelName: 'app-dev',
          progress: const [
            AgentProgressLine(who: 'Bo', time: '10:32', text: '修复已提交'),
          ],
        ),
        AgentAttentionItem(
          id: 't2',
          priority: AgentPriority.blocked,
          headline: 'Dex 卡在「导出报表」',
          ask: '解除阻塞',
          reason: '卡住了',
          waitValue: 2,
          waitUnit: '天',
          idle: true,
          at: DateTime.utc(2026, 10, 15),
        ),
      ],
    );
    // What the TV gets is JSON: the same result comes back out of it.
    final json = jsonDecode(jsonEncode(attention.toJson()));
    final back = AgentAttention.fromJson((json as Map).cast());
    expect(back.items.map((i) => i.id), ['t1', 't2']);
    expect(back.items.first.progress.single.text, '修复已提交');
    expect(back.items.last.idle, isTrue);

    await tv(t, {
      'caption': '先看第一件',
      'mood': '🤔',
      'layers': [
        {'id': 'attention', 'title': '现在需要你', 'attention': json},
      ],
    });
    // The split layout of a desktop: rows left, the selected one's detail
    // right, numbered; the type is the same ramp scaled by s = 2.
    expect(find.byType(HfRow), findsNWidgets(2));
    expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
    expect(find.text(AgentAttentionView.layerTitle), findsOneWidget);
    expect(find.textContaining('修复已提交'), findsOneWidget);
    // Nothing to press: the buttons are pills that say what to say.
    expect(find.textContaining('「通过」'), findsOneWidget);
    expect(find.textContaining('「打开讨论」'), findsOneWidget);
    expect(find.textContaining('「稍后」'), findsOneWidget);
    expect(find.text('在手机上处理'), findsNothing);
    expect(find.byType(HfDock), findsNothing);
    final title = t.widget<Text>(find.text('Dex 卡在「导出报表」'));
    expect(title.style!.fontSize, 22 * 2);
  });

  testWidgets('a confirm card that waits for an answer shows what to say', (
    t,
  ) async {
    await tv(t, {
      'caption': '要改吗？',
      'layers': [frame()],
      'confirms': [
        {
          'title': '把 #98 标记为已完成？',
          'changes': ['状态: 等验收 → 已完成'],
        },
      ],
    });
    expect(find.text('把 #98 标记为已完成？'), findsOneWidget);
    expect(find.textContaining('「对」确认'), findsOneWidget);
    expect(find.text('确认'), findsNothing);
  });

  testWidgets('the page follows the row the agent points at', (t) async {
    final many = {
      'id': 'surface-2',
      'title': '任务',
      'items': [
        for (var n = 1; n <= 12; n++)
          {'kind': 'priority', 'priority': 'progress', 'title': '第 $n 项'},
      ],
    };
    await tv(t, {
      'spotlight': 'surface-2#12',
      'layers': [many],
    });
    // The page scrolled to the row the agent points at: it is whole inside the
    // page's window, and the first rows are above it. No pager.
    final view = t.getRect(find.byKey(const ValueKey('hf-page')));
    final row = t.getRect(find.byKey(const ValueKey('frame-row-12')));
    expect(row.top, greaterThanOrEqualTo(view.top - 1));
    expect(row.bottom, lessThanOrEqualTo(view.bottom + 1));
    expect(
      t.getRect(find.byKey(const ValueKey('frame-row-1'))).bottom,
      lessThan(view.top),
    );
    expect(find.textContaining('/ 12'), findsNothing);
  });

  testWidgets('the TV scrolls on by a screen when the phone does ("下一批")', (
    t,
  ) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final layer = {
      'id': 'surface-2',
      'title': '任务',
      'items': [
        for (var n = 1; n <= 12; n++)
          {'kind': 'priority', 'priority': 'progress', 'title': '第 $n 项'},
      ],
    };
    final frames = ValueNotifier<Map<String, Object?>?>({
      'screens': 0,
      'layers': [layer],
    });
    addTearDown(frames.dispose);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(body: AgentTvView(frames: frames)),
      ),
    );
    await t.pumpAndSettle();
    ScrollableState page() => t.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('hf-page')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(page().position.pixels, 0);
    // The same frame again: nothing moves. A new count: one screen on.
    frames.value = {
      'screens': 0,
      'layers': [layer],
    };
    await t.pumpAndSettle();
    expect(page().position.pixels, 0);
    frames.value = {
      'screens': 1,
      'layers': [layer],
    };
    await t.pumpAndSettle();
    expect(page().position.pixels, greaterThan(0));
    // A TV cannot be dragged.
    final at = page().position.pixels;
    await t.drag(find.byKey(const ValueKey('hf-page')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(page().position.pixels, at);
  });

  testWidgets('a row does not repeat its title or status', (t) async {
    await tv(t, {
      'layers': [
        {
          'id': 'surface-3',
          'title': 'Agent · 2',
          'items': [
            {'kind': 'section', 'text': 'Agent · 2'},
            {
              'kind': 'priority',
              'priority': 'mention',
              'label': '空闲',
              'title': 'Aria',
              'detail': '空闲',
            },
          ],
        },
      ],
    });
    expect(find.text('Agent · 2'), findsOneWidget);
    expect(find.text('空闲'), findsOneWidget);
  });
}
