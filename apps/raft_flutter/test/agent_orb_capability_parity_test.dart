import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_direct_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_read_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart'
    show agentToolDeclarations, groundedToolDeclarations;
import 'package:raft_flutter/features/agent_mode/runtime/agent_tool_set.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_actions.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_nudge.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_task_tools.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// Everything Agent mode can do, the orb can do. The capability layer is one
/// registry; Agent mode reaches it through `find`, `query`, `act`, `confirm`,
/// `undo` and one tool per common operation, and the orb must have the same
/// tools with the same arguments. A tool Agent mode gets later fails here
/// until the orb has it, or until it is listed as one that only draws on
/// Agent mode's own screen.
void main() {
  late CapabilityWorld w;
  late ActivityClient client;
  late OrbActions actions;

  setUp(() {
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    actions = OrbActions(workspace: w);
  });
  tearDown(() async {
    actions.dispose();
    w.dispose();
    await client.dispose();
  });

  Set<String> names(Iterable<Map<String, Object?>> decls) => {
    for (final d in decls) d['name']! as String,
  };

  final agentNames = names(agentModeToolDeclarations());

  /// Tools that draw on Agent mode's own screen (the cards it lays out); the
  /// orb has no such screen: it reads the page it is on (`describe_page`) and
  /// takes the person there (`navigate`).
  final screenOnly = {
    ...names(agentToolDeclarations),
    ...names(agentReadToolDeclarations),
    ...names(groundedToolDeclarations(agentStandardCatalog)),
    // "the second one" resolves against the numbered cards of that screen.
    'resolve',
  };

  final shared = {
    ...names(capabilityToolDeclarations).difference({'resolve'}),
    ...agentDirectActionTools.keys,
  };

  test(
    'every tool of Agent mode is shared with the orb or is a screen tool',
    () {
      final unclassified = agentNames.difference({...screenOnly, ...shared});
      expect(
        unclassified,
        isEmpty,
        reason:
            'a new Agent mode tool: give it to the orb, or list it as one '
            'that only draws on Agent mode\'s screen',
      );
      expect(
        shared.intersection(screenOnly).difference({'resolve'}),
        isEmpty,
        reason: 'a tool is one or the other',
      );
    },
  );

  test('the orb has every shared tool, under the same name', () {
    final orb = names(actions.tools.map((t) => t.declaration));
    expect(shared.difference(orb), isEmpty);
  });

  test('with the same arguments (the orb may need fewer, never others)', () {
    final theirs = {
      for (final d in agentModeToolDeclarations()) d['name']! as String: d,
    };
    for (final d in actions.tools) {
      final name = d.name;
      if (!shared.contains(name)) continue;
      final a = theirs[name]!['parameters'] as Map?;
      final o = d.declaration['parameters'] as Map?;
      final ap = ((a?['properties'] as Map?) ?? const {}).cast<String, Map>();
      final op = ((o?['properties'] as Map?) ?? const {}).cast<String, Map>();
      expect(op.keys.toSet(), ap.keys.toSet(), reason: '$name arguments');
      for (final k in ap.keys) {
        expect(op[k]!['type'], ap[k]!['type'], reason: '$name.$k type');
        expect(op[k]!['enum'], ap[k]!['enum'], reason: '$name.$k values');
      }
      final ar = ((a?['required'] as List?) ?? const []).toSet();
      final or = ((o?['required'] as List?) ?? const []).toSet();
      expect(ar.containsAll(or), isTrue, reason: '$name requires more');
    }
  });

  test('the orb adds only its own: the nudge, cancel, and the task reads', () {
    final extra = names(actions.tools.map((t) => t.declaration))
        .difference(agentNames);
    expect(extra, {'nudge_task', 'cancel_action'});
    expect(names(orbTaskTools().map((t) => t.declaration)), {
      'list_tasks',
      'task_detail',
    });
  });

  test('every capability of the registry is in the orb\'s, and the nudge', () {
    final ours = {for (final c in actions.registry.all) c.id};
    final theirs = {for (final c in agentStandardCapabilities.all) c.id};
    expect(ours.difference(theirs), {orbNudgeCapability.id});
    expect(theirs.difference(ours), isEmpty);
  });

  test('find finds a capability for the orb whenever it does for Agent mode', () async {
    // The nudge is one more entry, so a ranking may differ at the margin: what
    // Agent mode finds by a capability's own words, the orb finds too.
    final agent = AgentCapabilityTools(workspace: w);
    for (final c in agentStandardCapabilities.all) {
      final intent = c.keywords.first;
      final theirs = await agent.run('find', {'intent': intent});
      final ours = await actions.call('find', {'intent': intent});
      List<Object?> ids(Map<String, Object?>? r) => [
        for (final m in r!['matches'] as List) (m as Map)['id'],
      ];
      if (ids(theirs).contains(c.id)) {
        expect(ids(ours), contains(c.id), reason: '$intent -> ${c.id}');
      }
    }
  });

  test('every query capability can be called from the orb', () async {
    for (final c in agentStandardCapabilities.all.where((c) => c.isQuery)) {
      final r = await actions.call('query', {'capability': c.id});
      expect(
        '${r['error']}',
        isNot(contains('没有叫 ${c.id}')),
        reason: '${c.id} is not known to the orb: $r',
      );
      expect(r['capability'] ?? r['error'], isNotNull, reason: c.id);
    }
  });

  test(
    'every action capability is known to act, and none runs unasked',
    () async {
      for (final c in agentStandardCapabilities.all.where((c) => !c.isQuery)) {
        final r = await actions.call('act', {'capability': c.id, 'args': '{}'});
        expect(
          '${r['error']}',
          isNot(contains('没有叫 ${c.id}')),
          reason: '${c.id} is not known to the orb: $r',
        );
        expect(r['status'], isNot('done'), reason: c.id);
      }
      expect(w.sent, isEmpty);
      expect(w.commands, isEmpty);
      await actions.cancel();
    },
  );
}
