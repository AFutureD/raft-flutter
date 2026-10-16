import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_tv.dart';
import 'package:raft_ui/raft_ui.dart';

/// The TV runs its own engine with no workspace: a generated surface reaches
/// it only as a frame, so entity cards must carry what the phone read for
/// them, never just their ids.
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

  testWidgets(
    'the TV draws a surface on the phone canvas, numbered, with no ids',
    (t) async {
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(
            body: AgentTvLayer(
              frame: frame(),
              caption: '一个卡住了。',
              mood: '🤔',
              focused: 'surface-1#2',
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining('Cindy'), findsWidgets);
      expect(find.textContaining('#98 修复返回'), findsWidgets);
      expect(find.textContaining(id), findsNothing);
      expect(find.text('GenUI'), findsNothing);
      expect(find.text('一个卡住了。'), findsOneWidget);
      // The same dotted canvas as the phone.
      expect(
        find.descendant(
          of: find.byType(AgentTvLayer),
          matching: find.byType(AgentCanvas),
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('the row the agent points at stays on screen', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final many = {
      'id': 'surface-2',
      'title': '任务',
      'items': [
        for (var n = 1; n <= 12; n++)
          {'kind': 'priority', 'priority': 'progress', 'title': '第 $n 项'},
      ],
    };
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: AgentTvLayer(
            frame: many,
            caption: '',
            mood: '',
            focused: 'surface-2#8',
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('第 8 项'), findsOneWidget);
    expect(find.text('第 1 项'), findsNothing);
    expect(find.text('6–10 / 12'), findsOneWidget);
  });

  testWidgets('a row does not repeat its title or status', (t) async {
    t.view.physicalSize = const Size(1920, 1080);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: Scaffold(
          body: AgentTvLayer(
            frame: {
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
            caption: '',
            mood: '',
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Agent · 2'), findsOneWidget);
    expect(find.text('空闲'), findsOneWidget);
  });
}
