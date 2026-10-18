import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Gemini Live model is chosen in the voice settings (automatic, 3.8 Live
/// or 3.1 Flash Live) for both voice modes.
void main() {
  const keyOf = 'raft.agentDemo.liveModel';
  const k38 = 'models/gemini-3.8-live';
  const k31 = 'models/gemini-3.1-flash-live-preview';
  const available = [
    'models/gemini-2.5-flash-native-audio-preview',
    'models/gemini-3.8-live',
    'models/gemini-3.8-live-thinking',
    'models/gemini-3.1-flash-live-preview',
  ];

  final realLister = GeminiLiveSession.modelLister;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    AgentVoiceSettings.instance.liveModelChoice =
        AgentVoiceSettings.liveModelAuto;
    AgentOrbPreference.instance.resetForTest();
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.gemini;
    GeminiLiveSession.forgetModels();
  });
  tearDown(() {
    GeminiLiveSession.modelLister = realLister;
    GeminiLiveSession.forgetModels();
    AgentOrbPreference.instance.resetForTest();
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.gemini;
  });

  group('choosing the model', () {
    test('a model the key has is used, with or without the prefix', () {
      expect(GeminiLiveSession.selectModel(available, wanted: k31), (
        model: k31,
        missing: null,
      ));
      expect(
        GeminiLiveSession.selectModel(
          available,
          wanted: 'gemini-3.1-flash-live-preview',
        ).model,
        k31,
      );
      expect(
        GeminiLiveSession.selectModel([
          'gemini-3.8-live',
          'gemini-3.1-flash-live-preview',
        ], wanted: k31).model,
        'gemini-3.1-flash-live-preview',
      );
    });

    test('a model the key lacks falls back to the automatic pick', () {
      final r = GeminiLiveSession.selectModel([
        'models/gemini-3.8-live',
        'models/gemini-2.5-flash-live',
      ], wanted: k31);
      expect(r.model, k38);
      expect(r.missing, k31);
    });

    test('automatic is the sorted pick: 3.8 Live, never thinking', () {
      final r = GeminiLiveSession.selectModel(available);
      expect(r, (model: k38, missing: null));
      expect(r.model, GeminiLiveSession.sortModels(available).first);
      expect(
        GeminiLiveSession.selectModel(available, wanted: '').missing,
        null,
      );
    });

    test('the cache never gives the model of another choice', () async {
      var listed = 0;
      GeminiLiveSession.modelLister = (key) async {
        listed++;
        return available;
      };
      expect(await GeminiLiveSession.pick('k'), k38);
      expect(await GeminiLiveSession.pick('k', wanted: k31), k31);
      expect(await GeminiLiveSession.pick('k'), k38);
      expect(await GeminiLiveSession.pick('k', wanted: k31), k31);
      expect(await GeminiLiveSession.pick('k', wanted: k38), k38);
      // The relaying session is cached on its own, too.
      expect(await GeminiLiveSession.pick('k', fast: true, wanted: k31), k31);
      expect(listed, 4, reason: 'each (choice, fast) is listed once');
      expect(GeminiLiveSession.pickedModel, k38);
    });

    test('an unavailable choice is remembered as its fallback only', () async {
      GeminiLiveSession.modelLister = (key) async => [k38];
      expect(await GeminiLiveSession.pick('k', wanted: k31), k38);
      GeminiLiveSession.modelLister = (key) async => [k38, k31];
      // Same choice, cached; another choice is not affected by it.
      expect(await GeminiLiveSession.pick('k', wanted: k31), k38);
      GeminiLiveSession.forgetModels();
      expect(await GeminiLiveSession.pick('k', wanted: k31), k31);
    });
  });

  group('the setting', () {
    test('is automatic until chosen, and kept per device', () async {
      final s = AgentVoiceSettings.instance;
      expect(s.liveModelChoice, AgentVoiceSettings.liveModelAuto);
      expect(s.liveModel, isNull);
      s.liveModelChoice = k31;
      expect(s.liveModel, k31);
      await pumpEventQueue();
      expect(DevicePreferences.current!.getString(keyOf), k31);
      s.liveModelChoice = AgentVoiceSettings.liveModelAuto;
      expect(s.liveModel, isNull);
    });

    test('an unknown stored value is automatic; labels are one map', () {
      final s = AgentVoiceSettings.instance;
      s.liveModelChoice = 'models/gone';
      expect(s.liveModel, isNull);
      expect(AgentVoiceSettings.liveModelLabels.values, [
        '自动（gemini-3.8-live）',
        'Gemini 3.8 Live',
        'Gemini 3.1 Flash Live',
      ]);
    });

    test('changing it notifies listeners', () {
      var n = 0;
      void count() => n++;
      AgentVoiceSettings.instance.addListener(count);
      addTearDown(() => AgentVoiceSettings.instance.removeListener(count));
      AgentVoiceSettings.instance.liveModelChoice = k38;
      expect(n, 1);
    });

    test('both voice modes hand it to Live', () {
      AgentVoiceSettings.instance.liveModelChoice = k31;
      final voiceOnly = createVoiceSession(
        provider: AgentVoiceProvider.gemini,
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
        voice: 'Sulafat',
      ) as GeminiLiveSession;
      expect(voiceOnly.preferredModel, k31);
      // The layered factory reads the setting; its Live relays or listens.
      final lives = <GeminiLiveSession>[];
      for (final mode in LayeredVoiceMode.values) {
        final layered = createLayeredSession(
          provider: AgentVoiceProvider.gemini,
          apiKey: 'k',
          systemPrompt: 'p',
          tools: const [],
          onToolCall: (n, a) async => {},
          voice: 'Sulafat',
          steering: AgentSteering(
            scope: () => const AgentScope(systemPrompt: '', tools: []),
          ),
        ) as LayeredVoiceSession;
        expect(layered.liveModel, k31, reason: '$mode');
      }
      LayeredVoiceSession(
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
        steering: AgentSteering(
          scope: () => const AgentScope(systemPrompt: '', tools: []),
        ),
        liveModel: k38,
        liveBuilder: (parts) {
          final live = LayeredVoiceSession.geminiLive(parts);
          lives.add(live as GeminiLiveSession);
          return live;
        },
      );
      expect(lives.single.preferredModel, k38);
      expect(lives.single.fast, isTrue);
    });
  });

  group('the settings page', () {
    Future<void> open(WidgetTester t, {bool orb = false}) async {
      t.view.physicalSize = const Size(420, 3600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentVoiceSettingsPage(showOrb: orb),
        ),
      );
    }

    final auto = find.byKey(const ValueKey('agent-setting-auto'));
    final m31 = find.byKey(const ValueKey('agent-setting-$k31'));

    testWidgets('voice-only mode with Gemini offers it, and changes it', (
      t,
    ) async {
      await open(t, orb: true);
      AgentOrbPreference.instance.setBrainMode(AgentBrainMode.voiceOnly);
      await t.pump();
      expect(find.text('语音模型'), findsOneWidget);
      expect(find.text('自动（gemini-3.8-live）'), findsOneWidget);
      await t.tap(m31);
      await t.pump();
      expect(AgentVoiceSettings.instance.liveModel, k31);
      await t.tap(auto);
      await t.pump();
      expect(AgentVoiceSettings.instance.liveModel, isNull);
    });

    testWidgets('other voice services do not show it', (t) async {
      await open(t);
      AgentVoiceSettings.instance.provider = AgentVoiceProvider.openai;
      await t.pump();
      expect(m31, findsNothing);
      expect(find.text('语音模型'), findsNothing);
    });

    testWidgets('the layered mode always offers it', (t) async {
      AgentVoiceSettings.instance.provider = AgentVoiceProvider.openai;
      AgentOrbPreference.instance.setBrainMode(AgentBrainMode.layered);
      await open(t, orb: true);
      expect(find.text('语音模型版本'), findsOneWidget);
      await t.tap(m31);
      await t.pump();
      expect(AgentVoiceSettings.instance.liveModel, k31);
    });
  });
}
