import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_engine.dart';
import 'package:raft_flutter/features/agent_mode/agent_thinking.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_orb_shell_test.dart' show OrbFixture;

/// What the orb runs on is chosen in the Agent settings: the realtime voice
/// model alone, or a voice model with the text Agent.

void main() {
  final pref = AgentOrbPreference.instance;

  setUp(() async {
    // These tests are about Gemini Live as the voice layer.
    AgentVoiceSettings.instance.layeredProvider = AgentVoiceProvider.gemini;
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    pref.resetForTest();
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.gemini;
  });
  tearDown(() {
    pref.resetForTest();
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.gemini;
  });

  group('the preferences', () {
    test('the old "Agent 层" setting is the layered brain: same key', () async {
      // A device that had the switch off is on the voice model alone.
      SharedPreferences.setMockInitialValues({
        AgentOrbPreference.layerKey: false,
      });
      await DevicePreferences.load();
      pref.resetForTest();
      expect(pref.brainMode, AgentBrainMode.voiceOnly);
      expect(pref.agentLayer, isFalse);
      // And one that had it on is layered.
      SharedPreferences.setMockInitialValues({
        AgentOrbPreference.layerKey: true,
      });
      await DevicePreferences.load();
      pref.resetForTest();
      expect(pref.brainMode, AgentBrainMode.layered);
      expect(pref.agentLayer, isTrue);
    });

    test('a choice is written under that key and read back', () async {
      pref.setBrainMode(AgentBrainMode.voiceOnly);
      await pumpEventQueue();
      final stored = DevicePreferences.current!;
      expect(stored.getBool(AgentOrbPreference.layerKey), isFalse);
      pref.setBrainMode(AgentBrainMode.layered);
      await pumpEventQueue();
      expect(stored.getBool(AgentOrbPreference.layerKey), isTrue);
      pref.resetForTest();
      expect(pref.brainMode, AgentBrainMode.layered);
    });

    test('the Agent model: none until set, trimmed, kept, cleared', () async {
      expect(pref.agentModel, isNull);
      pref.setAgentModel('  gemini-3.5-flash-lite ');
      expect(pref.agentModel, 'gemini-3.5-flash-lite');
      await pumpEventQueue();
      final stored = DevicePreferences.current!;
      expect(
        stored.getString(AgentOrbPreference.agentModelKey),
        'gemini-3.5-flash-lite',
      );
      pref.resetForTest();
      expect(pref.agentModel, 'gemini-3.5-flash-lite', reason: 'read back');
      pref.setAgentModel('   ');
      expect(pref.agentModel, isNull);
      await pumpEventQueue();
      expect(stored.getString(AgentOrbPreference.agentModelKey), isNull);
    });
  });

  group('the settings page', () {
    Future<void> open(WidgetTester t, {bool showOrb = true}) async {
      t.view.physicalSize = const Size(420, 4200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentVoiceSettingsPage(showOrb: showOrb),
        ),
      );
    }

    Finder key(String k) => find.byKey(ValueKey(k));

    testWidgets('the voice model alone: its service, voice and reasoning; '
        'nothing of the Agent', (t) async {
      pref.setBrainMode(AgentBrainMode.voiceOnly);
      await open(t);
      expect(find.text('纯语音模型'), findsOneWidget);
      expect(find.text('语音模型 + 文字 Agent'), findsOneWidget);
      expect(find.text('语音服务'), findsOneWidget);
      for (final label in agentVoiceProviderLabels.values) {
        expect(find.text(label), findsWidgets);
      }
      expect(find.text('推理强度'), findsOneWidget);
      expect(find.text('说话方式'), findsNothing);
      expect(find.text('文字 Agent'), findsNothing);
      expect(key('agent-orb-agent-model'), findsNothing);
    });

    testWidgets('the layered brain: Gemini Live for listening and speaking, '
        'how it speaks, the Agent\'s engine, model and reasoning', (t) async {
      pref.setBrainMode(AgentBrainMode.layered);
      await open(t);
      expect(find.text('语音模型（听和说）'), findsOneWidget);
      expect(find.text('Gemini Live'), findsOneWidget);
      expect(find.text('OpenAI'), findsNothing);
      expect(find.text('推理强度'), findsNothing, reason: 'the Agent\'s is below');
      expect(find.text('说话方式'), findsOneWidget);
      for (final m in LayeredVoiceMode.values) {
        expect(find.text(m.label), findsOneWidget);
      }
      expect(find.text('文字 Agent'), findsOneWidget);
      for (final e in AgentEngine.values) {
        expect(find.text(e.label), findsOneWidget);
      }
      expect(key('agent-orb-agent-model'), findsOneWidget);
      expect(find.text('Agent 推理强度'), findsOneWidget);
      for (final v in AgentThinking.values) {
        expect(find.text(v.label), findsWidgets);
      }
    });

    testWidgets('a tap on the brain swaps what is offered and is kept', (
      t,
    ) async {
      pref.setBrainMode(AgentBrainMode.voiceOnly);
      await open(t);
      await t.tap(key('agent-setting-AgentBrainMode.layered'));
      await t.pump();
      expect(pref.brainMode, AgentBrainMode.layered);
      expect(find.text('文字 Agent'), findsOneWidget);
      expect(find.text('语音服务'), findsNothing);
      await t.tap(key('agent-setting-AgentBrainMode.voiceOnly'));
      await t.pump();
      expect(pref.brainMode, AgentBrainMode.voiceOnly);
      expect(find.text('文字 Agent'), findsNothing);
      expect(find.text('语音服务'), findsOneWidget);
    });

    testWidgets('speaking, engine and reasoning are chosen here and kept', (
      t,
    ) async {
      pref.setBrainMode(AgentBrainMode.layered);
      await open(t);
      expect(pref.layeredVoiceMode, LayeredVoiceMode.liveRelays);
      await t.tap(key('agent-setting-LayeredVoiceMode.appSpeaks'));
      await t.pump();
      expect(pref.layeredVoiceMode, LayeredVoiceMode.appSpeaks);
      await t.tap(key('agent-setting-AgentEngine.direct'));
      await t.pump();
      expect(pref.agentEngine, AgentEngine.direct);
      await t.tap(key('agent-setting-AgentThinking.high'));
      await t.pump();
      expect(pref.agentThinking, AgentThinking.high);
    });

    testWidgets('the Agent model is typed and kept; emptied it is automatic', (
      t,
    ) async {
      pref.setBrainMode(AgentBrainMode.layered);
      await open(t);
      await t.enterText(key('agent-orb-agent-model'), 'gemini-3.5-flash-lite');
      await t.pump();
      expect(pref.agentModel, 'gemini-3.5-flash-lite');
      await t.enterText(key('agent-orb-agent-model'), '');
      await t.pump();
      expect(pref.agentModel, isNull);
    });

    testWidgets('the key row and the voices follow the model that listens', (
      t,
    ) async {
      AgentVoiceSettings.instance.provider = AgentVoiceProvider.openai;
      pref.setBrainMode(AgentBrainMode.layered);
      await open(t);
      // OpenAI is chosen for the voice model alone; the layered brain listens
      // with Gemini whatever that says: Gemini's key and Gemini's voices.
      expect(key('agent-provider-key-gemini'), findsOneWidget);
      expect(key('agent-voice-Sulafat'), findsOneWidget);
      expect(key('agent-voice-marin'), findsNothing);
      await t.tap(key('agent-setting-AgentBrainMode.voiceOnly'));
      await t.pump();
      expect(key('agent-provider-key-openai'), findsOneWidget);
      expect(key('agent-voice-marin'), findsOneWidget);
    });

    testWidgets('without showOrb (Agent mode) there is no orb choice', (
      t,
    ) async {
      await open(t, showOrb: false);
      expect(find.text('纯语音模型'), findsNothing);
      expect(find.text('语音服务'), findsOneWidget);
      expect(find.text('推理强度'), findsOneWidget);
    });
  });

  group('the Labs card', () {
    testWidgets('has the orb switch and, when it is on, the way to the '
        'settings; no brain controls of its own', (t) async {
      final f = OrbFixture(t);
      await f.setUp();
      addTearDown(f.tearDown);
      await f.pump(enabled: false);
      expect(find.byKey(const ValueKey('agent-orb-switch')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-orb-layer-switch')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('agent-orb-engine')), findsNothing);
      expect(find.byKey(const ValueKey('agent-orb-thinking')), findsNothing);
      expect(find.byKey(const ValueKey('agent-orb-voice-mode')), findsNothing);
    });
  });

  testWidgets('the Labs card opens the settings once the orb is on', (t) async {
    final f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump();
    final open = find.byKey(const ValueKey('agent-orb-settings-open'));
    expect(open, findsOneWidget);
    expect(
      find.byKey(const ValueKey('agent-orb-brain-summary')),
      findsOneWidget,
    );
    await t.ensureVisible(open);
    await t.pump();
    await t.tap(open);
    await t.pumpAndSettle();
    expect(find.text('纯语音模型'), findsOneWidget);
    expect(find.text('语音模型 + 文字 Agent'), findsOneWidget);
  });

  group('a change builds the orb again', () {
    testWidgets('of the brain, and of the Agent model', (t) async {
      final f = OrbFixture(t);
      await f.setUp();
      addTearDown(f.tearDown);
      await f.pump();
      expect(f.builds, 1);
      pref.setBrainMode(AgentBrainMode.voiceOnly);
      await t.pump();
      await t.pump();
      expect(f.builds, 2);
      pref.setAgentModel('gemini-3.5-flash-lite');
      await t.pump();
      await t.pump();
      expect(f.builds, 3);
    });
  });
}
