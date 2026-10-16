import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;
import 'package:raft_agent_ui/raft_agent_ui.dart' as ui show AgentEntityRef;
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_entities.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_handle_tag.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_reference_table.dart';
import 'package:raft_ui/raft_ui.dart';

/// The entity layer (cards, blocks) and the phase-1 reference table meeting
/// in one catalog: a card the model puts on screen gets a handle like any
/// other, and "第二个 / ③ / 这个" resolve to it.
String _surface(Object root) => jsonEncode({'title': '标题', 'root': root});

final catalog = agentStandardCatalog;

Map<String, Object?> _card(String kind, String id, [String? handle]) => {
  'component': 'EntityCard',
  'entity': kind,
  'id': id,
  'handle': ?handle,
};

AgentSurfaceSpec _spec(List<Object> children) => catalog
    .parse(_surface({'component': 'Column', 'children': children}))
    .spec!;

class _Resolver extends ChangeNotifier implements AgentEntityResolver {
  _Resolver(this.rows);
  final Map<String, AgentEntityData> rows;

  @override
  AgentEntityResolution resolve(ui.AgentEntityRef ref) {
    final data = rows['${ref.kind.name}:${ref.id}'];
    return data == null
        ? const AgentEntityMissing('没有这个')
        : AgentEntityFound(data);
  }
}

final _labels = {
  'task:t98': '#98 修复返回',
  'task:t99': '#99 迁移数据',
  'agent:a1': 'Aria',
};

AgentReferenceTable _table(AgentSurfaceSpec spec, {AgentFacts? facts}) {
  final frame = agentSurfaceFrame(
    spec,
    compact: true,
    entityOf: (n) => surfaceEntity(
      n,
      facts ?? AgentFacts(),
      labelOf: (kind, id) => _labels['$kind:$id'],
    ),
  );
  return AgentReferenceTable.fromFrame('surface:1', frame);
}

void main() {
  group('the merged catalog', () {
    test('has both the phase-1 and the entity components', () {
      for (final name in [
        'AgentStatusCard',
        'TaskCard',
        'MessageQuote',
        'StatRow',
        'EntityCard',
        'Table',
        'Timeline',
        'CodeBlock',
        'Callout',
        'ConfirmCard',
        'Choice',
        'Toggle',
      ]) {
        expect(catalog.item(name), isNotNull, reason: name);
        expect(catalog.describe(), contains('- $name（'));
      }
    });

    test('a surface may mix old cards with entity cards and blocks', () {
      final parsed = catalog.parse(
        _surface({
          'component': 'Column',
          'children': [
            {
              'component': 'TaskCard',
              'number': 7,
              'title': '返回',
              'status': 'in_progress',
            },
            _card('task', 't98'),
            {
              'component': 'Table',
              'columns': ['任务', '负责人'],
              'rows': [
                [
                  {'entity': 'task', 'id': 't99'},
                  'Aria',
                ],
              ],
            },
            {'component': 'Callout', 'text': '一件在忙'},
          ],
        }),
      );
      expect(parsed.problems, isEmpty);
      expect(parsed.spec!.root.children, hasLength(4));
    });

    test('validate hooks and oneOf cells are enforced after the merge', () {
      void rejects(Object child, String reason) {
        final parsed = catalog.parse(
          _surface({
            'component': 'Column',
            'children': [child],
          }),
        );
        expect(parsed.ok, isFalse, reason: '$child');
        expect(parsed.problems.join('\n'), contains(reason));
      }

      rejects(_card('task', '#98'), '不要带 # 或 @');
      rejects(_card('robot', 'x'), '只能是');
      rejects({
        'component': 'Table',
        'columns': ['a', 'b'],
        'rows': [
          ['只有一格'],
        ],
      }, '要和列数一样');
      rejects({
        'component': 'Table',
        'columns': ['a'],
        'rows': [
          [
            {'entity': 'task', 'id': 'a b'},
          ],
        ],
      }, '不是 id');
      rejects({
        'component': 'Table',
        'columns': ['a'],
        'rows': [
          [3],
        ],
      }, '或');
      rejects({
        'component': 'ConfirmCard',
        'title': '改',
        'changes': ['没有箭头'],
      }, '字段: 原值 → 新值');
      // The phase-1 components keep their own rules.
      rejects({
        'component': 'TaskCard',
        'number': 'x',
        'title': 't',
        'status': 'in_progress',
      }, 'number');
    });
  });

  group('entity cards in the reference table', () {
    test('they get handles in screen order, with the other cards', () {
      final spec = _spec([
        {
          'component': 'TaskCard',
          'number': 7,
          'title': '返回',
          'status': 'in_progress',
          'assignee': 'Cody',
        },
        _card('task', 't98'),
        _card('agent', 'a1'),
        {'component': 'Callout', 'text': '不占编号'},
      ]);
      final table = _table(spec);
      // The TaskCard keeps the handle of its place (①) with no id the model
      // read; the entity cards count on from it.
      expect(table.entries.map((e) => (e.handle, e.type, e.id)).toList(), [
        ('①', 'task', null),
        ('②', 'task', 't98'),
        ('③', 'agent', 'a1'),
      ]);
      final text = table.contextText();
      expect(text, contains('②任务(t98)「'));
      expect(text, contains('修复返回'));
      expect(text, contains('③Agent(a1)「Aria」'));
    });

    test('"第二个", "③" and names resolve to the card', () {
      final spec = _spec([
        _card('task', 't98'),
        _card('task', 't99'),
        _card('agent', 'a1'),
      ]);
      final table = _table(spec);
      expect(table.entries.map((e) => e.handle), ['①', '②', '③']);

      AgentEntityRef? entity(String phrase, {AgentEntityRef? pointed}) =>
          resolveAgentReference(phrase, table, pointed: pointed).entity;

      expect(entity('第二个')?.id, 't99');
      expect(entity('③')?.type, 'agent');
      expect(entity('第一个任务')?.id, 't98');
      expect(entity('第二个任务')?.id, 't99');
      expect(entity('最后一个')?.id, 'a1');
      expect(entity('#99 那个任务')?.id, 't99');
      expect(entity('Aria')?.id, 'a1');
      expect(entity('⑨'), isNull);
      // "这个" is the card that was tapped, else the only one of its kind.
      expect(entity('这个', pointed: table.entries[1])?.id, 't99');
      expect(entity('这个 agent')?.id, 'a1');
      final ambiguous = resolveAgentReference('这个任务', table);
      expect(ambiguous.isResolved, isFalse);
      expect(ambiguous.candidates.map((c) => c.id), ['t98', 't99']);
    });

    test('the model\'s own handle is not what numbers the card', () {
      final table = _table(
        _spec([_card('task', 't98', '⑨'), _card('task', 't99', '①')]),
      );
      expect(table.entries.map((e) => (e.handle, e.id)).toList(), [
        ('①', 't98'),
        ('②', 't99'),
      ]);
    });

    test('a card whose data is not read yet is still addressable by id', () {
      final table = _table(_spec([_card('message', 'm1')]));
      expect(table.entries.single.id, 'm1');
      expect(table.entries.single.label, '消息');
      expect(
        resolveAgentReference('这条消息', table).entity?.id,
        'm1',
      );
    });

    test('files are a kind of thing a screen can show', () {
      final table = _table(_spec([_card('file', 'f1')]));
      expect(table.entries.single.type, AgentEntityTypes.file);
      expect(resolveAgentReference('那个文件', table).entity?.id, 'f1');
    });
  });

  group('on screen', () {
    Widget host(AgentSurfaceSpec spec, AgentPointer pointer) {
      final table = _table(spec);
      final resolver = _Resolver({
        'task:t98': const AgentTaskData(
          title: '修复返回',
          status: 'in_progress',
          number: 98,
        ),
        'task:t99': const AgentTaskData(
          title: '迁移数据',
          status: 'todo',
          number: 99,
        ),
      });
      addTearDown(resolver.dispose);
      return MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: Scaffold(
          body: AgentReferenceScope(
            table: table,
            pointer: pointer,
            child: AgentEntityScope(
              resolver: resolver,
              child: AgentSurfaceView(
                spec: spec,
                focusPrefix: 'surface:1',
                compact: true,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the cards wear the screen\'s numbers, and a tap points', (
      t,
    ) async {
      t.view.physicalSize = const Size(800, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final pointer = AgentPointer();
      addTearDown(pointer.dispose);
      await t.pumpWidget(
        host(
          _spec([
            {
              'component': 'Callout',
              'text': '不占编号',
            },
            _card('task', 't98', '⑨'),
            _card('task', 't99'),
          ]),
          pointer,
        ),
      );
      await t.pumpAndSettle();

      // 1 and 2 on the bars, whatever handle the model wrote; no 9.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('9'), findsNothing);

      await t.tap(find.textContaining('迁移数据'));
      await t.pump();
      expect(pointer.entity?.id, 't99');
      expect(pointer.layerId, 'surface:1');
    });
  });

  group('the prompt', () {
    test('names the new components and the confirmation rule', () {
      final prompt = agentSystemPrompt(channels: 'general');
      for (final name in [
        'EntityCard',
        'Table',
        'Timeline',
        'CodeBlock',
        'Callout',
        'ConfirmCard',
        'Choice',
        'Toggle',
      ]) {
        expect(prompt, contains(name));
      }
      expect(prompt, contains('needs_user_confirmation'));
      expect(prompt, contains('你自己的话不算确认'));
    });
  });
}
