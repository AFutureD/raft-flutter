import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_engine.dart';
import 'package:raft_flutter/features/agent_mode/agent_thinking.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('the thinking level of the text agent', () {
    final control = find.byKey(const ValueKey('agent-orb-thinking'));

    test(
      'low by default; a change is kept on the device and read back',
      () async {
        SharedPreferences.setMockInitialValues({});
        AgentOrbPreference.instance.resetForTest();
        expect(AgentOrbPreference.instance.agentThinking, AgentThinking.low);
        AgentOrbPreference.instance.setAgentThinking(AgentThinking.high);
        expect(AgentOrbPreference.instance.agentThinking, AgentThinking.high);
        await pumpEventQueue();
        final stored = await SharedPreferences.getInstance();
        expect(stored.getString(AgentOrbPreference.thinkingKey), 'high');

        // A later launch reads it from the device.
        AgentOrbPreference.instance.resetForTest();
        DevicePreferences.adopt(stored);
        addTearDown(DevicePreferences.reset);
        expect(AgentOrbPreference.instance.agentThinking, AgentThinking.high);
        stored.setString(AgentOrbPreference.thinkingKey, 'nonsense');
        expect(AgentOrbPreference.instance.agentThinking, AgentThinking.low);
        AgentOrbPreference.instance.resetForTest();
      },
    );

    testWidgets('the Labs card shows it only while the agent layer is on, '
        'and a tap changes it', (t) async {
      await fixture(t);
      await f.pump(enabled: false);
      expect(AgentOrbPreference.instance.agentLayer, isTrue);
      expect(find.text('文本 Agent 推理强度'), findsOneWidget);
      expect(control, findsOneWidget);
      for (final v in AgentThinking.values) {
        expect(find.text(v.label), findsOneWidget);
      }
      expect(AgentOrbPreference.instance.agentThinking, AgentThinking.low);

      await t.tap(find.byKey(const ValueKey('agent-orb-thinking-high')));
      await t.pump();
      expect(AgentOrbPreference.instance.agentThinking, AgentThinking.high);
      await t.tap(find.byKey(const ValueKey('agent-orb-thinking-minimal')));
      await t.pump();
      expect(AgentOrbPreference.instance.agentThinking, AgentThinking.minimal);

      await t.tap(find.byKey(const ValueKey('agent-orb-layer-switch')));
      await t.pump();
      expect(control, findsNothing);
      await t.tap(find.byKey(const ValueKey('agent-orb-layer-switch')));
      await t.pump();
      expect(control, findsOneWidget);
    });

    testWidgets('changing it builds the orb again', (t) async {
      await fixture(t);
      await f.pump();
      expect(f.builds, 1);
      AgentOrbPreference.instance.setAgentThinking(AgentThinking.medium);
      await t.pump();
      await t.pump();
      expect(f.builds, 2);
      await t.pump(const Duration(seconds: 1));
      expect(f.builds, 2);
    });
  });

  group('the engine of the text agent', () {
    test('Genkit by default; a choice is kept and read back', () async {
      SharedPreferences.setMockInitialValues({});
      AgentOrbPreference.instance.resetForTest();
      expect(AgentOrbPreference.instance.agentEngine, AgentEngine.genkit);
      AgentOrbPreference.instance.setAgentEngine(AgentEngine.direct);
      expect(AgentOrbPreference.instance.agentEngine, AgentEngine.direct);
      await pumpEventQueue();
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(AgentOrbPreference.engineKey), 'direct');

      AgentOrbPreference.instance.resetForTest();
      DevicePreferences.adopt(stored);
      addTearDown(DevicePreferences.reset);
      expect(AgentOrbPreference.instance.agentEngine, AgentEngine.direct);
      stored.setString(AgentOrbPreference.engineKey, 'nonsense');
      expect(AgentOrbPreference.instance.agentEngine, AgentEngine.genkit);
      AgentOrbPreference.instance.resetForTest();
    });

    testWidgets('the Labs card offers it while the agent layer is on', (
      t,
    ) async {
      await fixture(t);
      await f.pump(enabled: false);
      final control = find.byKey(const ValueKey('agent-orb-engine'));
      expect(find.text('引擎'), findsOneWidget);
      expect(control, findsOneWidget);
      expect(find.text('Genkit'), findsOneWidget);
      expect(find.text('直连'), findsOneWidget);
      expect(AgentOrbPreference.instance.agentEngine, AgentEngine.genkit);

      await t.tap(find.byKey(const ValueKey('agent-orb-engine-direct')));
      await t.pump();
      expect(AgentOrbPreference.instance.agentEngine, AgentEngine.direct);

      await t.tap(find.byKey(const ValueKey('agent-orb-layer-switch')));
      await t.pump();
      expect(control, findsNothing);
    });

    testWidgets('changing it builds the orb again', (t) async {
      await fixture(t);
      await f.pump();
      expect(f.builds, 1);
      AgentOrbPreference.instance.setAgentEngine(AgentEngine.direct);
      await t.pump();
      await t.pump();
      expect(f.builds, 2);
      await t.pump(const Duration(seconds: 1));
      expect(f.builds, 2);
    });
  });

  group('how the voice of the agent layer speaks', () {
    test('the app reads by default; a choice is kept and read back', () async {
      SharedPreferences.setMockInitialValues({});
      AgentOrbPreference.instance.resetForTest();
      expect(
        AgentOrbPreference.instance.layeredVoiceMode,
        LayeredVoiceMode.appSpeaks,
      );
      AgentOrbPreference.instance.setLayeredVoiceMode(
        LayeredVoiceMode.liveRelays,
      );
      await pumpEventQueue();
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(AgentOrbPreference.voiceModeKey), 'liveRelays');

      AgentOrbPreference.instance.resetForTest();
      DevicePreferences.adopt(stored);
      addTearDown(DevicePreferences.reset);
      expect(
        AgentOrbPreference.instance.layeredVoiceMode,
        LayeredVoiceMode.liveRelays,
      );
      stored.setString(AgentOrbPreference.voiceModeKey, 'nonsense');
      expect(
        AgentOrbPreference.instance.layeredVoiceMode,
        LayeredVoiceMode.appSpeaks,
      );
      AgentOrbPreference.instance.resetForTest();
    });

    testWidgets('the Labs card offers both while the agent layer is on', (
      t,
    ) async {
      await fixture(t);
      await f.pump(enabled: false);
      final control = find.byKey(const ValueKey('agent-orb-voice-mode'));
      expect(find.text('语音'), findsOneWidget);
      expect(control, findsOneWidget);
      expect(find.text('App 朗读'), findsOneWidget);
      expect(find.text('Live 转述'), findsOneWidget);

      final relay = find.byKey(
        const ValueKey('agent-orb-voice-mode-liveRelays'),
      );
      await t.ensureVisible(relay);
      await t.pump();
      await t.tap(relay);
      await t.pump();
      expect(
        AgentOrbPreference.instance.layeredVoiceMode,
        LayeredVoiceMode.liveRelays,
      );
      final layer = find.byKey(const ValueKey('agent-orb-layer-switch'));
      await t.ensureVisible(layer);
      await t.pump();
      await t.tap(layer);
      await t.pump();
      expect(control, findsNothing);
    });

    testWidgets('changing it builds the orb again', (t) async {
      await fixture(t);
      await f.pump();
      expect(f.builds, 1);
      AgentOrbPreference.instance.setLayeredVoiceMode(
        LayeredVoiceMode.liveRelays,
      );
      await t.pump();
      await t.pump();
      expect(f.builds, 2);
    });
  });
}
