import 'dart:convert';

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_tools.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/orb_scope.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool_docs.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool_intents.dart';

import 'support/orb_action_world.dart';

/// The words of the orb's tools stay in shape: every description follows the
/// template (what it does, 用于, 不用于, ...), is under its cap, names no tool
/// the state does not have, and says nothing the prompt or another tool says.

/// The names a text may not use when the state lacks them.
final _toolNames = {...orbToolModes.keys, 'reply', 'ask_agent'};

Set<String> _named(String text) => {
  for (final n in _toolNames)
    if (RegExp('(?<![A-Za-z_])$n(?![A-Za-z_])').hasMatch(text)) n,
};

/// Every text of a declaration the model reads: the description and the
/// description of each parameter.
List<String> _texts(Map<String, Object?> d) => [
  '${d['description'] ?? ''}',
  for (final p
      in ((d['parameters'] as Map?)?['properties'] as Map? ?? {}).values)
    '${(p as Map)['description'] ?? ''}',
];

/// [text] without what is in “quotes” (the person's words).
String _unquoted(String text) => text.replaceAll(RegExp('“[^”]*”'), '');

Set<String> _sentences(String text) => {
  for (final s in text.split(RegExp(r'[。；\n]')))
    if (s.trim().length >= 20) s.trim(),
};

class _State {
  const _State(this.label, this.tools, this.prompt);
  final String label;
  final List<Map<String, Object?>> tools;
  final String prompt;
  Set<String> get names => {for (final d in tools) '${d['name']}'};
}

void main() {
  late ActionOrbFixture f;
  late List<_State> states;

  Future<List<_State>> build(WidgetTester t) async {
    final out = <_State>[];
    // The agent layer: the three states (and driving).
    f = ActionOrbFixture(t)..agentLayer = true;
    await f.setUp();
    await f.pump(tools: [...orbNavigationTools(), ...orbBriefingTools()]);
    final decls = [
      for (final tool in f.controller.tools.values) tool.declaration,
    ];
    for (final (mode, driving) in [
      (OrbMode.normal, false),
      (OrbMode.driving, true),
      (OrbMode.confirming, false),
      (OrbMode.confirming, true),
    ]) {
      final scope = orbAgentScope(
        mode: mode,
        driving: driving,
        declarations: decls,
        channels: 'a [1]',
        pending: '回复 Cody：“可以”',
      );
      out.add(
        _State('agent $mode driving=$driving', scope.tools, scope.systemPrompt),
      );
    }
    await t.pumpWidget(const SizedBox());
    await f.tearDown();
    // The realtime session: every tool of its own, and the whole prompt.
    f = ActionOrbFixture(t)..agentLayer = false;
    await f.setUp();
    await f.pump(tools: [...orbNavigationTools(), ...orbBriefingTools()]);
    await f.startCall();
    final s = f.sessions.single;
    out.add(_State('realtime', s.tools, s.systemPrompt));
    await t.pumpWidget(const SizedBox());
    await f.tearDown();
    return out;
  }

  testWidgets('every declared tool follows the template, in every state', (
    t,
  ) async {
    states = await build(t);
    for (final state in states) {
      expect(state.tools, isNotEmpty, reason: state.label);
      for (final d in state.tools) {
        final name = '${d['name']}';
        final text = '${d['description']}';
        final at = '${state.label} / $name';
        expect(orbToolDocs, contains(name), reason: '$at has no OrbToolDoc');
        final lines = text.split('\n');
        expect(lines.first.length, greaterThan(8), reason: at);
        expect(
          lines.where((l) => l.startsWith('用于：')),
          hasLength(1),
          reason: '$at: 用于',
        );
        // A tool with nothing to be mistaken for in this state may have no
        // 不用于; all but the ones whose only neighbours are absent do.
        final hasNot = lines.any((l) => l.startsWith('不用于：'));
        final doc = orbToolDocs[name]!;
        final mayLose = doc.notFor.every((n) => n.tool != null);
        expect(hasNot || mayLose, isTrue, reason: '$at: 不用于');
        // The sections come in the order of the template.
        const order = ['用于：', '不用于：', '限制：', '参数：', '返回：', '怎么说：'];
        var last = -1;
        for (final l in lines.skip(1)) {
          final i = order.indexWhere(l.startsWith);
          expect(i, greaterThan(last), reason: '$at: order of "$l"');
          last = i;
        }
        expect(
          text.length,
          lessThanOrEqualTo(orbDescriptionCap(name)),
          reason: '$at is ${text.length} long',
        );
        for (final e
            in ((d['parameters'] as Map?)?['properties'] as Map? ?? {})
                .entries) {
          final words = '${(e.value as Map)['description'] ?? ''}';
          if (name == 'navigate' && e.key == 'page')
            continue; // The page table.
          expect(
            words.length,
            lessThanOrEqualTo(100),
            reason: '$at.${e.key} is ${words.length} long',
          );
        }
      }
    }
  });

  testWidgets('no text names a tool that the state does not have', (t) async {
    states = await build(t);
    for (final state in states) {
      final names = state.names;
      for (final d in state.tools) {
        for (final text in _texts(d)) {
          final strange = _named(text).difference(names);
          expect(
            strange,
            isEmpty,
            reason: '${state.label} / ${d['name']} names $strange',
          );
        }
      }
      final strange = _named(state.prompt).difference(names);
      expect(
        strange,
        isEmpty,
        reason: 'the prompt of ${state.label} names $strange',
      );
    }
  });

  testWidgets('what the prompt says, the descriptions do not say again', (
    t,
  ) async {
    states = await build(t);
    for (final state in states) {
      final prompt = _sentences(state.prompt);
      final seen = <String, String>{};
      for (final d in state.tools) {
        final name = '${d['name']}';
        for (final text in _texts(d)) {
          for (final s in _sentences(text.replaceAll(orbCardLimit, ''))) {
            expect(
              prompt,
              isNot(contains(s)),
              reason: '${state.label}: "$s" of $name is in the prompt too',
            );
            // And a sentence is in one description only.
            final other = seen[s];
            expect(
              other == null || other == name,
              isTrue,
              reason: '${state.label}: "$s" is in $other and $name',
            );
            seen[s] = name;
          }
        }
      }
      // The ways of saying things are written once, in the intent table.
      for (final i in orbIntents) {
        for (final p in i.phrasings.where((p) => p.length >= 6)) {
          expect(
            state.prompt,
            isNot(contains(p)),
            reason: '${state.label}: the prompt repeats "$p" of ${i.id}',
          );
        }
      }
    }
  });

  testWidgets('every way of saying a thing is in the tool that owns it', (
    t,
  ) async {
    states = await build(t);
    final realtime = states.last;
    final text = {
      for (final d in realtime.tools) '${d['name']}': '${d['description']}',
    };
    for (final i in orbIntents) {
      final owner = text[i.owner];
      if (owner == null) continue; // The agent layer's tools are not here.
      for (final p in i.phrasings) {
        expect(owner, contains('“$p”'), reason: '${i.id}: $p');
      }
    }
    // Each intent has an owner that is a tool of the orb.
    final all = {...states.expand((s) => s.names)};
    for (final i in orbIntents) {
      expect(all, contains(i.owner), reason: '${i.id} has no tool');
    }
  });

  testWidgets('tools that can be mistaken for each other say so, both ways', (
    t,
  ) async {
    states = await build(t);
    const pairs = [
      ('navigate', 'get_briefing'),
      ('navigate', 'describe_page'),
      ('navigate', 'open_item'),
      ('navigate', 'read_conversation'),
      ('get_briefing', 'read_conversation'),
      ('describe_page', 'read_conversation'),
      ('list_tasks', 'task_detail'),
      ('set_task_status', 'reject_task'),
      ('set_task_status', 'assign_task'),
      ('assign_task', 'unassign_task'),
      ('mark_read', 'mark_done'),
      ('mark_done', 'snooze_item'),
      ('driving_next', 'next_task'),
    ];
    for (final state in states) {
      final text = {
        for (final d in state.tools) '${d['name']}': '${d['description']}',
      };
      for (final (a, b) in pairs) {
        if (!text.containsKey(a) || !text.containsKey(b)) continue;
        expect(
          text[a],
          contains(b),
          reason: '${state.label}: $a does not name $b',
        );
        expect(
          text[b],
          contains(a),
          reason: '${state.label}: $b does not name $a',
        );
      }
    }
  });

  testWidgets('the words are the same everywhere, and each tool has some', (
    t,
  ) async {
    states = await build(t);
    for (final state in states) {
      for (final d in state.tools) {
        for (final text in _texts(d)) {
          final plain = _unquoted(text);
          for (final bad in const ['待验收', '面板']) {
            expect(plain, isNot(contains(bad)), reason: '${d['name']}: $bad');
          }
        }
      }
      expect(
        _unquoted(state.prompt),
        isNot(contains('待验收')),
        reason: state.label,
      );
    }
    // The tools of the orb are all worded here.
    final realtime = states.last;
    for (final d in realtime.tools) {
      expect(orbToolDocs, contains('${d['name']}'));
    }
    // The tools a state offers: counts hold under the guide of 20 for the
    // text agent.
    for (final state in states.where((s) => s.label.startsWith('agent'))) {
      expect(state.tools.length, lessThanOrEqualTo(27), reason: state.label);
    }
    expect(jsonEncode(realtime.tools), isNotEmpty);
  });
}
