import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';

import 'agent_orb_shell_test.dart' show OrbFixture;

/// The Labs switch "Agent 层": which brain the orb runs on.

void main() {
  late OrbFixture f;

  Future<void> fixture(WidgetTester t) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
  }

  test('on by default in a debug build, and a stored choice wins', () {
    AgentOrbPreference.instance.resetForTest();
    expect(AgentOrbPreference.instance.agentLayer, isTrue);
    AgentOrbPreference.instance.setAgentLayer(false);
    expect(AgentOrbPreference.instance.agentLayer, isFalse);
    AgentOrbPreference.instance.setAgentLayer(true);
    expect(AgentOrbPreference.instance.agentLayer, isTrue);
    AgentOrbPreference.instance.resetForTest();
  });

  testWidgets('the Labs card has the switch and it flips the setting', (
    t,
  ) async {
    await fixture(t);
    await f.pump(enabled: false);
    final switchFinder = find.byKey(const ValueKey('agent-orb-layer-switch'));
    expect(find.text('Agent 层'), findsOneWidget);
    expect(switchFinder, findsOneWidget);
    expect(AgentOrbPreference.instance.agentLayer, isTrue);

    await t.tap(switchFinder);
    await t.pump();
    expect(AgentOrbPreference.instance.agentLayer, isFalse);
    await t.tap(switchFinder);
    await t.pump();
    expect(AgentOrbPreference.instance.agentLayer, isTrue);
  });

  testWidgets('changing it builds the orb again, with the new setting', (
    t,
  ) async {
    await fixture(t);
    await f.pump();
    final first = f.controller;
    expect(f.builds, 1);

    AgentOrbPreference.instance.setAgentLayer(false);
    await t.pump();
    await t.pump();
    expect(f.builds, 2);
    expect(identical(f.controller, first), isFalse);

    // Nothing else rebuilds it.
    await t.pump(const Duration(seconds: 1));
    expect(f.builds, 2);
  });
}
