import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_engine.dart';
import 'package:raft_flutter/features/agent_mode/agent_thinking.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
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

  group('the voice service of the agent layer', () {
    tearDown(() {
      AgentVoiceSettings.instance.layeredProvider = AgentVoiceProvider.openai;
    });

    testWidgets('changing it in the voice settings builds the orb again', (
      t,
    ) async {
      await fixture(t);
      await f.pump();
      expect(f.builds, 1);
      AgentVoiceSettings.instance.layeredProvider = AgentVoiceProvider.grok;
      await t.pump();
      await t.pump();
      expect(f.builds, 2);
      // A setting of the voice that is not the service does not.
      AgentVoiceSettings.instance.openAiVoice = 'cedar';
      AgentVoiceSettings.instance.language = AgentLanguage.en;
      await t.pump(const Duration(seconds: 1));
      expect(f.builds, 2);
      AgentVoiceSettings.instance.language = AgentLanguage.zh;
    });
  });

  group('how the voice of the agent layer speaks', () {
    test('Live relays by default; a choice is kept and read back', () async {
      SharedPreferences.setMockInitialValues({});
      AgentOrbPreference.instance.resetForTest();
      expect(
        AgentOrbPreference.instance.layeredVoiceMode,
        LayeredVoiceMode.liveRelays,
      );
      AgentOrbPreference.instance.setLayeredVoiceMode(
        LayeredVoiceMode.appSpeaks,
      );
      await pumpEventQueue();
      final stored = await SharedPreferences.getInstance();
      expect(stored.getString(AgentOrbPreference.voiceModeKey), 'appSpeaks');

      AgentOrbPreference.instance.resetForTest();
      DevicePreferences.adopt(stored);
      addTearDown(DevicePreferences.reset);
      expect(
        AgentOrbPreference.instance.layeredVoiceMode,
        LayeredVoiceMode.appSpeaks,
      );
      stored.setString(AgentOrbPreference.voiceModeKey, 'nonsense');
      expect(
        AgentOrbPreference.instance.layeredVoiceMode,
        LayeredVoiceMode.liveRelays,
      );
      AgentOrbPreference.instance.resetForTest();
    });

    testWidgets('changing it builds the orb again', (t) async {
      await fixture(t);
      await f.pump();
      expect(f.builds, 1);
      AgentOrbPreference.instance.setLayeredVoiceMode(
        LayeredVoiceMode.appSpeaks,
      );
      await t.pump();
      await t.pump();
      expect(f.builds, 2);
    });
  });
}
