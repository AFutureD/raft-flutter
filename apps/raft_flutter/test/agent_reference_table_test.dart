import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentWorkState;
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_entities.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_tools.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_handle_tag.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_reference_table.dart';

import 'support/agent_capability_world.dart';

Map<String, Object?> _e(
  String type,
  String? id,
  String label, [
  List<String> hints = const [],
]) => {'type': type, 'id': ?id, 'label': label, 'hints': hints};

/// A screen of mixed things, as `_frame` serializes one: a section label
/// (which has no handle), two tasks, an agent, a message and a stat row
/// that stands for nothing.
Map<String, Object?> _frame({String title = '任务'}) => {
  'title': title,
  'items': [
    {'kind': 'section', 'text': '进行中'},
    {
      'kind': 'priority',
      'entity': _e('task', 't94', '历史消息上拉', ['#94', 'Cody', 'raft-flutter']),
    },
    {
      'kind': 'priority',
      'entity': _e('task', 't95', '搜索返回', ['#95', 'Cindy', 'raft-flutter']),
    },
    {
      'kind': 'priority',
      'entity': _e('agent', 'a-cody', 'Cody', ['在做 #94']),
    },
    {'kind': 'priority', 'title': '数字 3'},
    {
      'kind': 'message',
      'entity': _e('message', 'm1', 'PR 已合入', ['Cindy']),
    },
  ],
};

void main() {
  group('handles', () {
    test('count ① ② ③ … and read back', () {
      expect([for (var n = 1; n <= 3; n++) agentHandle(n)], ['①', '②', '③']);
      expect(agentHandle(20), '⑳');
      expect(agentHandle(21), '㉑');
      expect(agentHandle(36), '㊱');
      expect(agentHandle(60), '(60)');
      for (final n in [1, 7, 20, 21, 35, 36, 50]) {
        expect(agentHandleNumber(agentHandle(n).runes.first), n);
      }
      expect(agentHandleNumber('a'.runes.first), isNull);
    });

    test(
      'the table numbers items as the voice tools do, and restarts per screen',
      () {
        final table = AgentReferenceTable.fromFrame('surface:1', _frame());
        // Sections do not count; the stat row counts but stands for nothing.
        expect(
          [for (final e in table.entries) (e.handle, e.type, e.id)],
          [
            ('①', 'task', 't94'),
            ('②', 'task', 't95'),
            ('③', 'agent', 'a-cody'),
            ('⑤', 'message', 'm1'),
          ],
        );
        final other = AgentReferenceTable.fromFrame(
          'surface:2',
          _frame(title: '另一屏'),
        );
        expect(other.entries.first.handle, '①');
        expect(table.byFocusId('surface:1#2')!.id, 't95');
        expect(table.byFocusId('surface:2#2'), isNull);
        expect(table.byFocusId('surface:1#4'), isNull);
      },
    );

    test('the model reads a compact line, with the tapped card marked', () {
      final table = AgentReferenceTable.fromFrame('surface:1', _frame());
      final text = table.contextText();
      expect(text, startsWith('【屏幕引用】「任务」'));
      expect(text, contains('①任务(t94)「历史消息上拉」'));
      expect(text, contains('③Agent(a-cody)「Cody」'));
      expect(text.length, lessThan(220));
      final pointed = table.contextText(pointed: table.byIndex(2));
      expect(pointed, contains('用户刚点了：②任务(t95)「搜索返回」'));
      expect(AgentReferenceTable.empty.contextText(), '');
    });
  });

  group('resolve', () {
    final table = AgentReferenceTable.fromFrame('surface:1', _frame());

    String? id(String phrase, {AgentEntityRef? pointed}) =>
        resolveAgentReference(phrase, table, pointed: pointed).entity?.id;

    test('a handle, with or without words around it', () {
      expect(id('③'), 'a-cody');
      expect(id('把 ② 指派给 Cody'), 't95');
      expect(resolveAgentReference('③', table).how, 'handle');
      // A handle that is not on the screen is not guessed.
      final miss = resolveAgentReference('⑨', table);
      expect(miss.isResolved, isFalse);
      expect(miss.candidates, isNotEmpty);
    });

    test('an ordinal counts the screen; with a type it counts that type', () {
      expect(id('第一个'), 't94');
      expect(id('第2条'), 't95');
      expect(id('第三个'), 'a-cody');
      expect(id('第二个任务'), 't95');
      expect(id('第一个消息'), 'm1');
      expect(id('最后一个'), 'm1');
      expect(id('最后一个任务'), 't95');
      expect(resolveAgentReference('第二个', table).how, 'ordinal');
      // There are only two tasks, and no seventh thing.
      expect(resolveAgentReference('第三个任务', table).isResolved, isFalse);
      expect(resolveAgentReference('第七个', table).isResolved, isFalse);
    });

    test('a name with a type, a task number, or a name alone', () {
      expect(id('Cody 那个任务'), 't94');
      expect(id('cindy的任务'), 't95');
      expect(id('#95'), 't95');
      expect(id('94 号任务'), 't94');
      expect(id('Cody 这个 Agent'), 'a-cody');
      expect(id('Cindy 说的那条消息'), 'm1');
      expect(resolveAgentReference('Cody 那个任务', table).how, 'name');
    });

    test('several fit: candidates to ask about, nothing guessed', () {
      final r = resolveAgentReference('raft-flutter 的任务', table);
      expect(r.isResolved, isFalse);
      expect(r.candidates.map((c) => c.id), ['t94', 't95']);
      final json = r.toJson();
      expect(json['status'], 'ambiguous');
      expect((json['candidates'] as List).length, 2);
      expect(json['message'], contains('不要自己猜'));
      // A bare type with two tasks, and no card tapped.
      expect(
        resolveAgentReference('那个任务', table).toJson()['status'],
        'ambiguous',
      );
    });

    test('nothing fits: the screen is offered, no id is made up', () {
      final r = resolveAgentReference('Zed 的任务', table);
      expect(r.isResolved, isFalse);
      expect(r.toJson()['status'], anyOf('none', 'ambiguous'));
      expect(r.candidates, isNotEmpty);
      expect(resolveAgentReference('', table).isResolved, isFalse);
      expect(
        resolveAgentReference('这个', AgentReferenceTable.empty).candidates,
        isEmpty,
      );
    });

    test('“这个” is the card the person tapped', () {
      final tapped = table.byIndex(2);
      for (final phrase in ['这个', '这条', '它', '这个怎么了', '刚才那个', '这个任务']) {
        final r = resolveAgentReference(phrase, table, pointed: tapped);
        expect(r.entity?.id, 't95', reason: phrase);
        expect(r.how, 'pointed');
      }
      // A tapped message is not “这个任务”.
      final message = table.byIndex(5);
      expect(
        resolveAgentReference('这个任务', table, pointed: message).isResolved,
        isFalse,
      );
      // Without a tap, “这个” resolves only when there is one thing.
      expect(
        resolveAgentReference('这个', table).toJson()['status'],
        'ambiguous',
      );
      final single = AgentReferenceTable('l', [
        AgentEntityRef.fromJson(_e('task', 't1', '唯一'))!.at(1),
      ]);
      final r = resolveAgentReference('这个', single);
      expect(r.entity?.id, 't1');
      expect(r.how, 'only');
    });
  });

  group('pointer', () {
    test('a tap is remembered for this screen, for a while', () {
      var now = DateTime(2026, 10, 15, 12);
      final pointer = AgentPointer(now: () => now);
      addTearDown(pointer.dispose);
      final table = AgentReferenceTable.fromFrame('surface:1', _frame());
      var notified = 0;
      pointer.addListener(() => notified++);
      pointer.point('surface:1', table.byIndex(1)!);
      expect(pointer.entity?.id, 't94');
      expect(pointer.layerId, 'surface:1');
      expect(notified, 1);
      pointer.point('surface:1', table.byIndex(1)!); // same card again
      expect(notified, 1);
      pointer.point('surface:1', table.byIndex(2)!);
      expect(pointer.entity?.id, 't95');

      pointer.screenChanged('surface:1');
      expect(pointer.entity, isNotNull);
      pointer.screenChanged('surface:2');
      expect(pointer.entity, isNull);

      pointer.point('surface:1', table.byIndex(1)!);
      now = now.add(const Duration(minutes: 3));
      expect(pointer.entity, isNull);
    });
  });

  group('resolve tool', () {
    testWidgets('answers from the front screen and the tapped card', (t) async {
      final world = capabilityWorld();
      final table = AgentReferenceTable.fromFrame('surface:1', _frame());
      AgentEntityRef? pointed;
      final tools = AgentCapabilityTools(
        workspace: world.$2,
        references: () => table,
        pointed: () => pointed,
      );
      var r = await tools.run('resolve', {'phrase': 'Cody 那个任务'});
      expect(r!['status'], 'resolved');
      expect((r['entity'] as Map)['id'], 't94');
      expect((r['entity'] as Map)['handle'], '①');
      r = await tools.run('resolve', {'phrase': '这个'});
      expect(r!['status'], 'ambiguous');
      pointed = table.byIndex(3);
      r = await tools.run('resolve', {'phrase': '这个'});
      expect((r!['entity'] as Map)['id'], 'a-cody');
      expect((await tools.run('resolve', {}))!['error'], isNotNull);
      world.$2.dispose();
      await world.$1.dispose();
    });
  });

  group('cards', () {
    Widget host(
      AgentReferenceTable table,
      AgentPointer pointer,
      Widget child,
    ) => MaterialApp(
      theme: raftTheme(RaftFamily.elegant, dark: false),
      home: AgentReferenceScope(
        table: table,
        pointer: pointer,
        child: Scaffold(body: Center(child: child)),
      ),
    );

    testWidgets(
      'a card shows its handle, and a tap points at it without eating the tap',
      (t) async {
        final table = AgentReferenceTable.fromFrame('surface:1', _frame());
        final pointer = AgentPointer();
        addTearDown(pointer.dispose);
        var cardTaps = 0;
        await t.pumpWidget(
          host(
            table,
            pointer,
            Column(
              children: [
                AgentHandleTag(
                  focusId: 'surface:1#2',
                  child: GestureDetector(
                    onTap: () => cardTaps++,
                    child: const SizedBox(
                      width: 200,
                      height: 60,
                      child: Text('搜索返回'),
                    ),
                  ),
                ),
                // Not on the front screen, or standing for nothing: no handle.
                const AgentHandleTag(focusId: 'other#1', child: Text('旧屏')),
                const AgentHandleTag(focusId: 'surface:1#4', child: Text('数字')),
              ],
            ),
          ),
        );
        expect(find.text('②'), findsOneWidget);
        expect(find.byKey(const ValueKey('agent-handle-2')), findsOneWidget);
        expect(find.text('①'), findsNothing);
        expect(pointer.entity, isNull);

        await t.tap(find.text('搜索返回'));
        await t.pump();
        expect(cardTaps, 1);
        expect(pointer.entity?.id, 't95');
        expect(pointer.layerId, 'surface:1');
      },
    );

    testWidgets('a drag across a card does not point at it', (t) async {
      final table = AgentReferenceTable.fromFrame('surface:1', _frame());
      final pointer = AgentPointer();
      addTearDown(pointer.dispose);
      await t.pumpWidget(
        host(
          table,
          pointer,
          const AgentHandleTag(
            focusId: 'surface:1#1',
            child: SizedBox(width: 200, height: 60, child: Text('历史')),
          ),
        ),
      );
      await t.drag(find.text('历史'), const Offset(0, 80));
      await t.pump();
      expect(pointer.entity, isNull);
    });
  });

  group('a generated screen', () {
    testWidgets('its cards carry handles that lead to the ids the model read', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final facts = AgentFacts()
        ..learnAgents(const [
          AgentRuntimeInfo(
            id: 'a-cody',
            name: 'Cody',
            state: AgentWorkState.busy,
            activity: '在做 #94',
          ),
        ])
        ..learnTaskRows([
          {
            'id': 't94',
            'taskNumber': 94,
            'title': '历史上拉',
            'status': 'in_progress',
            'channelName': 'raft-flutter',
            'claimedByName': 'Cody',
          },
        ]);
      final spec = agentStandardCatalog.parse({
        'title': '一屏',
        'root': {
          'component': 'Column',
          'density': 'detail',
          'children': [
            {
              'component': 'AgentStatusCard',
              'name': 'Cody',
              'state': 'busy',
              'activity': '在做 #94',
            },
            {
              'component': 'TaskCard',
              'title': '历史上拉',
              'status': 'in_progress',
              'number': 94,
              'assignee': 'Cody',
              'channel': 'raft-flutter',
            },
          ],
        },
      }).spec!;
      final frame = agentSurfaceFrame(
        spec,
        entityOf: (n) => surfaceEntity(n, facts),
      );
      final table = AgentReferenceTable.fromFrame('surface:1', frame);
      expect(
        [for (final e in table.entries) (e.handle, e.type, e.id)],
        [('①', 'agent', 'a-cody'), ('②', 'task', 't94')],
      );
      final pointer = AgentPointer();
      addTearDown(pointer.dispose);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant, dark: false),
          home: AgentReferenceScope(
            table: table,
            pointer: pointer,
            child: Scaffold(
              body: AgentSurfaceView(
                spec: spec,
                focusPrefix: 'surface:1',
                compact: false,
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('agent-handle-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('agent-handle-2')), findsOneWidget);
      await t.tap(find.textContaining('历史上拉').first);
      await t.pump();
      expect(pointer.entity?.id, 't94');
      expect(
        resolveAgentReference('这个', table, pointed: pointer.entity).entity?.id,
        't94',
      );
    });

    testWidgets('a card whose handle badge is hidden is still pointed at', (
      t,
    ) async {
      t.view.physicalSize = const Size(390, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final facts = AgentFacts()
        ..learnTaskRows([
          {
            'id': 't94',
            'taskNumber': 94,
            'title': '历史上拉',
            'status': 'in_progress',
            'channelName': 'raft-flutter',
            'claimedByName': 'Cody',
          },
        ]);
      Map<String, Object?> task(Map<String, Object?>? display) => {
        'component': 'TaskCard',
        'title': '历史上拉',
        'status': 'in_progress',
        'number': 94,
        'assignee': 'Cody',
        'channel': 'raft-flutter',
        'display': ?display,
      };
      final pointer = AgentPointer();
      addTearDown(pointer.dispose);
      for (final hidden in [false, true]) {
        final spec = agentStandardCatalog.parse({
          'title': '一屏',
          'root': {
            'component': 'Column',
            'children': [
              task(
                hidden
                    ? {
                        'show': {'handle': false},
                      }
                    : null,
              ),
            ],
          },
        }).spec!;
        final frame = agentSurfaceFrame(
          spec,
          entityOf: (n) => surfaceEntity(n, facts),
        );
        final table = AgentReferenceTable.fromFrame('surface:1', frame);
        // The card is numbered either way.
        expect(
          [for (final e in table.entries) (e.handle, e.id)],
          [('①', 't94')],
        );
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(RaftFamily.elegant, dark: false),
            home: AgentReferenceScope(
              table: table,
              pointer: pointer,
              child: Scaffold(
                body: AgentSurfaceView(
                  spec: spec,
                  focusPrefix: 'surface:1',
                  compact: false,
                ),
              ),
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('agent-handle-1')),
          hidden ? findsNothing : findsOneWidget,
        );
        pointer.clear();
        await t.tap(find.textContaining('历史上拉').first);
        await t.pump();
        expect(pointer.entity?.id, 't94', reason: 'hidden: $hidden');
      }
    });
  });
}
