import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/openai_realtime.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The voice service is chosen in the voice settings (Gemini or OpenAI), each
/// with its own key and voices.
void main() {
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final stored = <String, String>{};

  setUp(() async {
    stored.clear();
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, (call) async {
          final args = (call.arguments as Map).cast<String, Object?>();
          switch (call.method) {
            case 'write':
              stored['${args['key']}'] = '${args['value']}';
              return null;
            case 'read':
              return stored['${args['key']}'];
            case 'delete':
              stored.remove('${args['key']}');
              return null;
          }
          return null;
        });
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.gemini;
  });
  tearDown(() {
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.gemini;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
  });

  test('Gemini is the default, the choice is kept per device', () {
    final s = AgentVoiceSettings.instance;
    expect(s.provider, AgentVoiceProvider.gemini);
    expect(s.voiceOf(AgentVoiceProvider.gemini), 'Sulafat');
    expect(s.voiceOf(AgentVoiceProvider.openai), 'marin');
    s.provider = AgentVoiceProvider.openai;
    expect(
      DevicePreferences.current!.getString('raft.agentDemo.provider'),
      'openai',
    );
    s.openAiVoice = 'cedar';
    expect(s.voiceOf(AgentVoiceProvider.openai), 'cedar');
    // The Gemini voice is its own setting.
    expect(s.voiceOf(AgentVoiceProvider.gemini), s.voice);
    s.openAiVoice = 'marin';
  });

  test('the reasoning effort is low until chosen, and kept per device', () {
    final s = AgentVoiceSettings.instance;
    addTearDown(() => s.reasoning = AgentReasoning.low);
    expect(s.reasoning, AgentReasoning.low);
    s.reasoning = AgentReasoning.high;
    expect(
      DevicePreferences.current!.getString('raft.agentDemo.reasoning'),
      'high',
    );
    expect(s.reasoning, AgentReasoning.high);
    expect(AgentVoiceSettings.reasoningLabels.values, ['低', '中', '高']);
  });

  testWidgets('the settings page offers the effort, except for Grok', (
    t,
  ) async {
    t.view.physicalSize = const Size(420, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = AgentVoiceSettings.instance;
    addTearDown(() => s.reasoning = AgentReasoning.low);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: const AgentVoiceSettingsPage(),
      ),
    );
    expect(find.text('推理强度'), findsOneWidget);
    await t.tap(
      find.byKey(const ValueKey('agent-setting-AgentReasoning.high')),
    );
    await t.pump();
    expect(s.reasoning, AgentReasoning.high);
    // OpenAI has the same scale.
    s.provider = AgentVoiceProvider.openai;
    await t.pump();
    expect(find.byKey(const ValueKey('agent-reasoning-note')), findsOneWidget);
    // Grok has a switch, not a scale: nothing to choose, and it says so.
    s.provider = AgentVoiceProvider.grok;
    await t.pump();
    expect(
      find.byKey(const ValueKey('agent-setting-AgentReasoning.high')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('agent-reasoning-grok-note')),
      findsOneWidget,
    );
  });

  test('the conversation passes the chosen effort to the session', () {
    // createVoiceSession hands it to the services that have a scale.
    final gemini = createVoiceSession(
      provider: AgentVoiceProvider.gemini,
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      voice: 'Sulafat',
      reasoning: AgentReasoning.medium,
    );
    expect(
      (gemini as GeminiLiveSession).setupMessage(
        'm',
        affective: false,
        nonBlocking: false,
      )['setup'],
      containsPair(
        'generationConfig',
        containsPair('thinkingConfig', {'thinkingLevel': 'medium'}),
      ),
    );
    final openai = createVoiceSession(
      provider: AgentVoiceProvider.openai,
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      voice: 'marin',
      reasoning: AgentReasoning.high,
    );
    expect((openai as OpenAiRealtimeSession).sessionConfig()['reasoning'], {
      'effort': 'high',
    });
  });

  test('Gemini steps a refused thinking level down, then drops it', () {
    expect(
      GeminiLiveSession.lowerThinking(AgentReasoning.high),
      AgentReasoning.medium,
    );
    expect(
      GeminiLiveSession.lowerThinking(AgentReasoning.medium),
      AgentReasoning.low,
    );
    expect(GeminiLiveSession.lowerThinking(AgentReasoning.low), isNull);
  });

  test('each provider has its own stored key', () async {
    const openai = 'sk-proj-abcdefghijklmnopqrstuvwxyz0123456789';
    final saved = await saveScannedKey(
      'OPENAI_API_KEY=$openai',
      preferred: AgentVoiceProvider.gemini,
    );
    expect(saved, AgentVoiceProvider.openai);
    expect(await OpenAiVoiceKey.instance.read(), openai);
    expect(OpenAiVoiceKey.instance.suffix, '6789');
    expect(stored.keys.single, 'raft.agentDemo.openaiKey');
    // The Gemini key is untouched.
    expect(stored.containsKey('raft.agentDemo.geminiKey'), isFalse);
    await OpenAiVoiceKey.instance.clear();
    expect(stored, isEmpty);
    expect(OpenAiVoiceKey.instance.suffix, isNull);
  });

  testWidgets('the settings page switches the service, its key and voices', (
    t,
  ) async {
    t.view.physicalSize = const Size(420, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    String? previewed;
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: AgentVoiceSettingsPage(onPreview: (v) => previewed = v),
      ),
    );
    final s = AgentVoiceSettings.instance;
    expect(find.text('语音服务'), findsOneWidget);
    expect(find.text('还没有 Gemini Key'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-voice-Sulafat')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-voice-marin')), findsNothing);

    await t.tap(
      find.byKey(ValueKey('agent-setting-${AgentVoiceProvider.openai}')),
    );
    await t.pump();
    expect(s.provider, AgentVoiceProvider.openai);
    expect(find.text('还没有 OpenAI Key'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-voice-Sulafat')), findsNothing);
    expect(find.byKey(const ValueKey('agent-voice-marin')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('agent-voice-cedar')));
    await t.pump();
    expect(s.openAiVoice, 'cedar');
    // Choosing an OpenAI voice leaves the Gemini voice alone.
    expect(s.voice, 'Sulafat');
    await t.tap(find.byTooltip('试听').first);
    await t.pump();
    expect(previewed, 'marin');
    s.openAiVoice = 'marin';

    await t.tap(
      find.byKey(ValueKey('agent-setting-${AgentVoiceProvider.gemini}')),
    );
    await t.pump();
    expect(find.text('还没有 Gemini Key'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-voice-Sulafat')), findsOneWidget);
  });

  testWidgets('Grok has its own key row and voices', (t) async {
    t.view.physicalSize = const Size(420, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: const AgentVoiceSettingsPage(),
      ),
    );
    final s = AgentVoiceSettings.instance;
    addTearDown(() => s.grokVoice = 'eve');
    await t.tap(
      find.byKey(ValueKey('agent-setting-${AgentVoiceProvider.grok}')),
    );
    await t.pump();
    expect(s.provider, AgentVoiceProvider.grok);
    expect(find.text('还没有 Grok Key'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-voice-eve')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-voice-marin')), findsNothing);
    expect(s.voiceOf(AgentVoiceProvider.grok), 'eve');
    await t.tap(find.byKey(const ValueKey('agent-voice-rex')));
    await t.pump();
    expect(s.grokVoice, 'rex');
    expect(s.voice, 'Sulafat');
  });

  test('a Grok key is stored under its own name', () async {
    const grok = 'xai-abcdefghijklmnopqrstuvwxyz0123456789ABCDEF';
    final saved = await saveScannedKey(
      'XAI_API_KEY=$grok',
      preferred: AgentVoiceProvider.gemini,
    );
    expect(saved, AgentVoiceProvider.grok);
    expect(await GrokVoiceKey.instance.read(), grok);
    expect(stored.keys.single, 'raft.agentDemo.grokKey');
    expect(GrokVoiceKey.instance.suffix, 'CDEF');
    await GrokVoiceKey.instance.clear();
    expect(stored, isEmpty);
  });

  testWidgets('a stored key shows only its last four characters', (t) async {
    await OpenAiVoiceKey.instance.save(
      'sk-proj-abcdefghijklmnopqrstuvwxyz0123456789',
    );
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.openai;
    t.view.physicalSize = const Size(420, 2600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.brutal),
        home: const AgentVoiceSettingsPage(),
      ),
    );
    await t.pump();
    expect(find.text('OpenAI Key ····6789'), findsOneWidget);
    expect(find.textContaining('sk-proj'), findsNothing);
    expect(
      find.byKey(const ValueKey('agent-provider-key-clear')),
      findsOneWidget,
    );
    await t.tap(find.byKey(const ValueKey('agent-provider-key-clear')));
    await t.pump();
    expect(find.text('还没有 OpenAI Key'), findsOneWidget);
    expect(AgentAudio.instance.supported, isFalse);
  });

  test('the conversation uses the key of the chosen service', () async {
    final voice = AgentVoiceController(
      tools: const [],
      onToolCall: (n, a) async => {},
      systemPrompt: () => 'p',
    );
    addTearDown(voice.dispose);
    // No key anywhere: no voice, whatever the service.
    expect(await voice.hasKey, isFalse);
    await OpenAiVoiceKey.instance.save('sk-proj-abcdefghijklmnopqrstuvwxyz01');
    addTearDown(OpenAiVoiceKey.instance.clear);
    // An OpenAI key does not serve the Gemini service, and the other way.
    expect(await voice.hasKey, isFalse);
    AgentVoiceSettings.instance.provider = AgentVoiceProvider.openai;
    expect(await voice.hasKey, isTrue);
  });

  test('the prompt says to ask again on a garbled transcript, not to act', () {
    final prompt = agentSystemPrompt(channels: 'general');
    expect(prompt, contains('【没听清就问】'));
    expect(prompt, contains('不要猜着回答'));
    expect(prompt, contains('绝对不要调用任何工具'));
  });
}
