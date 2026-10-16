import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;
import 'package:raft_agent_ui/raft_agent_ui.dart' as ui show AgentEntityRef;
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_entities.dart';
import 'package:raft_ui/raft_ui.dart';

/// A group or section of entity cards folded to one summary row says what the
/// cards say ("#98 修复返回"), never `message <uuid>`; and it follows the data.
const _msgId = '3f2b9c1e-7d44-4c0a-9a53-1c2f8e6b7a10';
const _msgId2 = '8a1d5e60-2b3c-4f71-8d9e-0a4b6c7d8e91';

AgentSurfaceSpec _spec(String container, List<Object> cards) =>
    agentStandardCatalog
        .parse(
          jsonEncode({
            'title': '标题',
            'root': {
              'component': container,
              'title': '今天的事',
              'children': cards,
            },
          }),
        )
        .spec!;

Map<String, Object?> _card(String kind, String id) => {
  'component': 'EntityCard',
  'entity': kind,
  'id': id,
};

class _Resolver extends ChangeNotifier implements AgentEntityResolver {
  final rows = <String, AgentEntityData>{};
  @override
  AgentEntityResolution resolve(ui.AgentEntityRef ref) {
    final data = rows['${ref.kind.name}:${ref.id}'];
    return data == null ? const AgentEntityLoading() : AgentEntityFound(data);
  }

  void set(String key, AgentEntityData d) {
    rows[key] = d;
    notifyListeners();
  }
}

void main() {
  final cards = <Object>[
    _card('message', _msgId),
    _card('message', _msgId2),
    _card('task', 't98'),
    _card('agent', 'a1'),
  ];

  group('the folded row of cards', () {
    for (final container in ['Section']) {
      testWidgets('$container names each card by its label, live', (t) async {
        final resolver = _Resolver()
          ..rows.addAll({
            'message:$_msgId': const AgentMessageData(
              author: 'Cody',
              text: '这是一段很长很长的话，需要被截短之后再放进摘要行里面',
            ),
            'task:t98': const AgentTaskData(
              title: '修复返回',
              status: 'in_progress',
              number: 98,
            ),
          });
        addTearDown(resolver.dispose);
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(RaftFamily.elegant, dark: false),
            home: Scaffold(
              body: AgentEntityScope(
                resolver: resolver,
                child: AgentSurfaceView(
                  spec: _spec(container, cards),
                  focusPrefix: 's',
                  compact: true,
                ),
              ),
            ),
          ),
        );
        await t.pump();

        String row() => t
            .widgetList<Text>(find.byType(Text))
            .map((e) => e.data ?? e.textSpan?.toPlainText() ?? '')
            .where((s) => s.contains('#98') || s.contains('消息'))
            .join('|');

        // Resolved: author and the start of the text, "#N title". The ones
        // not read yet say their kind, never an id.
        final first = row();
        expect(first, contains('Cody：这是一段很长很长的话'));
        expect(first, contains('…'));
        expect(first, contains('#98 修复返回'));
        expect(first, isNot(contains(_msgId)));
        expect(first, isNot(contains(_msgId2)));
        expect(first, isNot(contains('message ')));
        expect(first, isNot(contains('agent a1')));
        expect(first, contains('消息'));

        // Live: the others arrive, the task is renamed.
        resolver
          ..set(
            'message:$_msgId2',
            const AgentMessageData(author: 'Aria', text: '好的'),
          )
          ..set(
            'agent:a1',
            const AgentAgentData(name: 'Cindy', state: AgentWorkState.busy),
          )
          ..set(
            'task:t98',
            const AgentTaskData(
              title: '修复返回键',
              status: 'done',
              number: 98,
            ),
          );
        await t.pump();
        final later = row();
        expect(later, contains('Aria：好的'));
        expect(later, contains('Cindy'));
        expect(later, contains('#98 修复返回键'));
        expect(later, isNot(contains('消息')));
      });
    }
  });

  test('the frame the voice model reads uses the same labels', () {
    final labels = {
      'message:$_msgId': 'Cody：你好',
      'task:t98': '#98 修复返回',
    };
    final frame = agentSurfaceFrame(
      _spec('Section', cards),
      compact: true,
      entityLabel: (kind, id) => labels['$kind:$id'],
      entityOf: (n) => surfaceEntity(
        n,
        AgentFacts(),
        labelOf: (kind, id) => labels['$kind:$id'],
      ),
    );
    final item = (frame['items'] as List).single as Map;
    final title = '${item['title']}';
    expect(title, contains('Cody：你好'));
    expect(title, contains('#98 修复返回'));
    expect(title, isNot(contains(_msgId)));
    expect(title, isNot(contains('message ')));
    // Not read yet: the kind, not the id.
    expect(title, contains('消息'));
  });
}
