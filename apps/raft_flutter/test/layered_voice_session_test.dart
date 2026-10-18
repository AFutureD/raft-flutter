import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_engine.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/genkit_agent.dart';
import 'package:raft_flutter/features/agent_mode/agent_thinking.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:raft_flutter/features/agent_mode/gemini_agent.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';

/// The voice layer: Gemini Live with one tool, the text agent behind it.

class FakeLive implements VoiceSession {
  FakeLive(this.parts);
  final LiveParts parts;
  final sent = <String>[];
  final audio = <int>[];
  final contexts = <String>[];
  var ended = 0;
  var closes = 0;
  bool open = false;

  @override
  bool get connected => open;
  @override
  String? get model => 'live-model';
  @override
  AgentToolHandler get onToolCall => parts.onToolCall;
  @override
  void Function(Uint8List)? get onAudio => parts.onAudio;
  @override
  void Function(String)? get onInputText => parts.onInputText;
  @override
  void Function(String)? get onOutputText => parts.onOutputText;
  @override
  void Function()? get onTurnComplete => parts.onTurnComplete;
  @override
  void Function()? get onInterrupted => parts.onInterrupted;
  @override
  void Function(String)? get onClosed => parts.onClosed;
  @override
  Future<void> connect() async => open = true;
  @override
  void sendAudio(Uint8List pcm16k) => audio.add(pcm16k.length);
  @override
  void endAudio() => ended++;
  @override
  void sendText(String text) => sent.add(text);
  @override
  void addContext(String text) => contexts.add(text);
  @override
  Future<void> close() async {
    closes++;
    open = false;
  }
}

Map<String, Object?> _say(String text) => {
  'candidates': [
    {
      'content': {
        'role': 'model',
        'parts': [
          {'text': text},
        ],
      },
    },
  ],
};

Map<String, Object?> _call(String name) => {
  'candidates': [
    {
      'content': {
        'role': 'model',
        'parts': [
          {
            'functionCall': {'name': name, 'args': <String, Object?>{}},
          },
        ],
      },
    },
  ],
};

/// An agent that takes [delay] to answer.
class SlowAgent implements VoiceSession {
  SlowAgent(this.parts, this.delay);
  final AgentParts parts;
  final Duration delay;

  @override
  bool get connected => true;
  @override
  String? get model => 'slow';
  @override
  AgentToolHandler get onToolCall => parts.onToolCall;
  @override
  void Function(Uint8List)? get onAudio => null;
  @override
  void Function(String)? get onInputText => null;
  @override
  void Function(String)? get onOutputText => parts.onOutputText;
  @override
  void Function()? get onTurnComplete => parts.onTurnComplete;
  @override
  void Function()? get onInterrupted => null;
  @override
  void Function(String)? get onClosed => parts.onClosed;
  @override
  Future<void> connect() async {}
  @override
  void sendAudio(Uint8List pcm16k) {}
  @override
  void endAudio() {}
  @override
  void addContext(String text) {}
  @override
  Future<void> close() async {}
  @override
  void sendText(String text) => Future<void>.delayed(delay, () {
    parts.onOutputText('好了。');
    parts.onTurnComplete();
  });
}

class FakeApi {
  final replies = <Object>[];
  final requests = <Map<String, Object?>>[];
  var agents = 0;

  Future<({int status, String body})> call(
    Uri uri,
    String key,
    Map<String, Object?>? body,
  ) async {
    if (body == null) {
      return (
        status: 200,
        body: jsonEncode({
          'models': [
            {
              'name': 'models/gemini-3-flash-lite-preview',
              'supportedGenerationMethods': ['generateContent'],
            },
          ],
        }),
      );
    }
    requests.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    final next = replies.removeAt(0);
    if (next is int) return (status: next, body: '{}');
    return (status: 200, body: jsonEncode(next));
  }
}

void main() {
  late FakeApi api;
  late FakeLive live;
  late List<String> appTools;
  late List<String> outText;
  var completes = 0;

  LayeredVoiceSession make({Map<String, Object?>? Function(String)? tool}) {
    api = FakeApi();
    appTools = [];
    outText = [];
    completes = 0;
    return LayeredVoiceSession(
      apiKey: 'test-key',
      systemPrompt: 'full prompt',
      tools: const [
        {'name': 'navigate'},
      ],
      steering: AgentSteering(
        scope: () => const AgentScope(
          systemPrompt: 'scoped',
          tools: [
            {'name': 'navigate'},
          ],
        ),
      ),
      onToolCall: (name, args) async {
        appTools.add(name);
        return tool?.call(name) ?? {'ok': true};
      },
      onOutputText: outText.add,
      onTurnComplete: () => completes++,
      liveBuilder: (parts) => live = FakeLive(parts),
      agentBuilder: (p) => GeminiAgentSession(
        apiKey: p.apiKey,
        systemPrompt: p.systemPrompt,
        tools: p.tools,
        steering: p.steering,
        transport: api.call,
        retryDelay: Duration.zero,
        onToolCall: p.onToolCall,
        onOutputText: p.onOutputText,
        onTurnComplete: p.onTurnComplete,
        onClosed: p.onClosed,
      ),
    );
  }

  test('the voice layer has one tool and a short instruction', () async {
    final s = make();
    expect(live.parts.tools, [askAgentDeclaration]);
    expect(live.parts.systemPrompt, layeredVoicePrompt);
    expect(layeredVoicePrompt, contains('ask_agent'));
    expect(layeredVoicePrompt, contains('如实、自然'));
    expect(layeredVoicePrompt, isNot(contains('一字不差')));
    // The voice model says nothing before or while the agent works.
    expect(layeredVoicePrompt, contains('不要先说话'));
    expect(layeredVoicePrompt, isNot(contains('可以先说一句')));
    expect(layeredVoicePrompt.length, lessThan(900));
    expect(s.connected, isFalse);
    await s.connect();
    expect(s.connected, isTrue);
    expect(s.model, 'live-model');
  });

  test('ask_agent runs a turn of the agent and returns what it said', () async {
    final s = make(tool: (_) => {'title': 'X'});
    await s.connect();
    api.replies.addAll([_call('navigate'), _say('到了动态，没有要你处理的。')]);

    final answer = await live.onToolCall('ask_agent', {'request': '去动态'});

    expect(answer, {'say': '到了动态，没有要你处理的。'});
    expect(appTools, ['navigate']);
    // The agent had its own instruction; Live's words are not its.
    final system =
        ((api.requests.first['systemInstruction'] as Map)['parts'] as List)
                .single['text']
            as String;
    expect(system, 'scoped');
    // Nothing the agent said reached the person except through Live.
    expect(outText, isEmpty);
    expect(completes, 0);
  });

  test('Live is given a task number without its "#"', () async {
    final s = make();
    await s.connect();
    api.replies.add(_say('任务 #136「重构第 10 步」在等你验收。'));
    expect(await live.onToolCall('ask_agent', {'request': '打开 136'}), {
      'say': '任务 136「重构第 10 步」在等你验收。',
    });
    expect(layeredForVoice('#raft-flutter 的 #12'), '#raft-flutter 的 12');
  });

  test('an agent that says nothing returns an empty say', () async {
    final s = make();
    await s.connect();
    api.replies.add(_say(''));
    expect(await live.onToolCall('ask_agent', {'request': 'x'}), {'say': ''});
  });

  test('audio goes to Live; context goes to the agent, not to Live', () async {
    final s = make();
    await s.connect();
    s.sendAudio(Uint8List(320));
    s.endAudio();
    s.addContext('（App 提示：用户在动态页。）');
    expect(live.audio, [320]);
    expect(live.ended, 1);
    expect(live.contexts, isEmpty);

    api.replies.add(_say('好'));
    await live.onToolCall('ask_agent', {'request': '这是什么'});
    final parts =
        (((api.requests.single['contents'] as List).first as Map)['parts']
                as List)
            .map((p) => (p as Map)['text'])
            .toList();
    expect(parts, ['（App 提示：用户在动态页。）', '这是什么']);
  });

  test('typed text is the person\'s: Live hears it', () async {
    final s = make();
    await s.connect();
    s.sendText('回他可以');
    expect(live.sent, ['回他可以']);
    expect(api.requests, isEmpty);
  });

  test(
    'a note from the app is a turn of the agent; Live speaks the answer',
    () async {
      final s = make();
      await s.connect();
      api.replies.add(_say('第 2 件：Alice 问你周五能不能来。'));
      s.sendText('（App 提示，不是用户的话：我点了下一件。）');
      await pumpEventQueue();
      expect(live.sent, [layeredVerbatim('第 2 件：Alice 问你周五能不能来。')]);

      // Nothing to say: Live is left quiet.
      api.replies.add(_say(''));
      s.sendText('（App 提示，不是用户的话：先别打断。）');
      await pumpEventQueue();
      expect(live.sent, hasLength(1));
    },
  );

  test(
    'speak has Live say the words, and the agent knows they were said',
    () async {
      final s = make();
      await s.connect();
      s.speak('已回复。');
      expect(live.sent, ['（App 请你说）已回复。']);
      api.replies.add(_say('嗯'));
      await live.onToolCall('ask_agent', {'request': '下一件'});
      final parts =
          (((api.requests.single['contents'] as List).first as Map)['parts']
                  as List)
              .map((p) => (p as Map)['text'])
              .toList();
      expect(parts.first, contains('已回复。'));
    },
  );

  test('an agent that fails gives Live a spoken apology; the next ask '
      'starts a new agent', () async {
    final s = make();
    await s.connect();
    api.replies.addAll([500, 500, 500]);
    final failed = await live.onToolCall('ask_agent', {'request': '去动态'});
    expect(failed['say'], contains('出了点问题'));

    api.replies.add(_say('好了'));
    final again = await live.onToolCall('ask_agent', {'request': '再来'});
    expect(again, {'say': '好了'});
  });

  test('close closes both layers, and a waiting ask is answered', () async {
    final s = make();
    await s.connect();
    api.replies.add(_say('x'));
    // An ask under way when the call is hung up still gets its answer.
    final waiting = live.onToolCall('ask_agent', {'request': '慢'});
    await s.close();
    expect((await waiting)['say'], isNotNull);
    expect(live.closes, 1);
    expect(s.connected, isFalse);
  });

  test('the voice layer says nothing before or while it waits: the app cues '
      'when the agent is slow, and says how many asks are out', () async {
    final inFlight = <int>[];
    var cues = 0;
    final s = LayeredVoiceSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
      slowAfter: const Duration(milliseconds: 30),
      liveBuilder: (parts) => live = FakeLive(parts),
      agentBuilder: (p) => SlowAgent(p, const Duration(milliseconds: 120)),
    )..onSlow = () => cues++;
    s.addAskingListener(inFlight.add);
    await s.connect();

    final answer = live.onToolCall('ask_agent', {'request': '去动态'});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(s.asking, 1);
    expect(cues, 1, reason: 'slow: the app cues once');
    expect(await answer, {'say': '好了。'});
    expect(s.asking, 0);
    expect(inFlight, [1, 0]);

    // A quick ask gives no cue.
    cues = 0;
    final quick = LayeredVoiceSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
      slowAfter: const Duration(milliseconds: 200),
      liveBuilder: (parts) => live = FakeLive(parts),
      agentBuilder: (p) => SlowAgent(p, const Duration(milliseconds: 5)),
    )..onSlow = () => cues++;
    await quick.connect();
    await live.onToolCall('ask_agent', {'request': '去动态'});
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(cues, 0);
  });

  test('the Live model: the app\'s pick as before; for the relaying voice '
      'layer the quickest without extended thinking', () {
    const models = [
      'models/gemini-3.8-live-extended-thinking',
      'models/gemini-3.8-live',
      'models/gemini-3.5-flash-live-preview',
      'models/gemini-2.5-flash-native-audio-preview-09-2025',
    ];
    // As before: what the device picked.
    expect(
      GeminiLiveSession.sortModels(models).first,
      'models/gemini-3.8-live-extended-thinking',
    );
    final fast = GeminiLiveSession.sortModels(models, fast: true);
    expect(fast.first, 'models/gemini-3.5-flash-live-preview');
    expect(fast, isNot(contains('models/gemini-3.8-live-extended-thinking')));
    // Nothing else to take: the thinking one is still better than none.
    expect(
      GeminiLiveSession.sortModels([
        'models/gemini-3.8-live-extended-thinking',
      ], fast: true),
      ['models/gemini-3.8-live-extended-thinking'],
    );
    // And the session says which it uses.
    expect(
      GeminiLiveSession(
        apiKey: 'k',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
        fast: true,
      ).fast,
      isTrue,
    );
  });

  test('the relaying voice asks for the least thinking, whatever the voice '
      'settings say, and steps down when the model refuses', () {
    GeminiLiveSession session({required bool fast, AgentReasoning? r}) =>
        GeminiLiveSession(
          apiKey: 'k',
          systemPrompt: 'p',
          tools: const [],
          onToolCall: (n, a) async => {},
          reasoning: r ?? AgentReasoning.medium,
          fast: fast,
        );
    Object? config(GeminiLiveSession s) =>
        (s.setupMessage('m', affective: false, nonBlocking: false)['setup']
            as Map)['generationConfig']['thinkingConfig'];

    // The Agent-mode setting does not reach it.
    for (final r in AgentReasoning.values) {
      final relay = session(fast: true, r: r);
      expect(config(relay), {'thinkingLevel': 'minimal'}, reason: '$r');
      expect(relay.thinkingUsed, 'minimal');
    }
    // A model that does not take one: the next, then a zero budget, then none.
    final relay = session(fast: true);
    expect(relay.lowerThinkingSetting(), isTrue);
    expect(config(relay), {'thinkingLevel': 'low'});
    expect(relay.lowerThinkingSetting(), isTrue);
    expect(config(relay), {'thinkingBudget': 0});
    expect(relay.thinkingUsed, 'budget 0');
    expect(relay.lowerThinkingSetting(), isTrue);
    expect(config(relay), isNull);
    expect(relay.thinkingUsed, 'none');
    expect(relay.lowerThinkingSetting(), isFalse);

    // The other sessions are as they were: the level of the settings.
    final normal = session(fast: false, r: AgentReasoning.high);
    expect(config(normal), {'thinkingLevel': 'high'});
    expect(normal.thinkingUsed, 'high');
    expect(normal.lowerThinkingSetting(), isTrue);
    expect(config(normal), {'thinkingLevel': 'medium'});
  });

  test('the layered voice builds a relaying Live session and reports its '
      'thinking', () {
    final s = LayeredVoiceSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      reasoning: AgentReasoning.high,
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
      agentBuilder: (p) => SlowAgent(p, Duration.zero),
    );
    expect(s.liveThinking, 'minimal', reason: 'not the settings\' high');
  });

  test('the agent behind the voice thinks as asked', () {
    final seen = <AgentThinking>[];
    LayeredVoiceSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      thinking: AgentThinking.high,
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
      liveBuilder: (parts) => FakeLive(parts),
      agentBuilder: (p) {
        seen.add(p.thinking);
        return GeminiAgentSession(
          apiKey: p.apiKey,
          systemPrompt: p.systemPrompt,
          tools: p.tools,
          thinking: p.thinking,
          onToolCall: p.onToolCall,
        );
      },
    );
    expect(seen, [AgentThinking.high]);
  });

  test('the agent runs on Genkit unless the direct calls are chosen', () {
    LayeredVoiceSession build({AgentEngine? engine}) => LayeredVoiceSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
      liveBuilder: (parts) => FakeLive(parts),
      engine: engine ?? AgentEngine.genkit,
    );
    expect(build().agent, isA<GenkitAgentSession>());
    expect(build(engine: AgentEngine.genkit).agent, isA<GenkitAgentSession>());
    expect(build(engine: AgentEngine.direct).agent, isA<GeminiAgentSession>());
  });

  test('the factory reads the engine of the setting', () {
    AgentOrbPreference.instance.resetForTest();
    addTearDown(AgentOrbPreference.instance.resetForTest);
    LayeredVoiceSession make() => createLayeredSession(
      provider: AgentVoiceProvider.gemini,
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      voice: 'v',
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
    ) as LayeredVoiceSession;
    expect(make().engine, AgentEngine.genkit);
    AgentOrbPreference.instance.setAgentEngine(AgentEngine.direct);
    expect(make().engine, AgentEngine.direct);
    expect(make().agent, isA<GeminiAgentSession>());
  });

  test('the factory reads the setting when it builds the session', () {
    AgentOrbPreference.instance.resetForTest();
    addTearDown(AgentOrbPreference.instance.resetForTest);
    AgentOrbPreference.instance.setAgentThinking(AgentThinking.medium);
    final s = createLayeredSession(
      provider: AgentVoiceProvider.gemini,
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      voice: 'v',
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
    ) as LayeredVoiceSession;
    expect(s.thinking, AgentThinking.medium);
  });

  test('the factory builds the layered voice whatever the provider', () {
    final s = createLayeredSession(
      provider: AgentVoiceProvider.openai,
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      voice: 'v',
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: 's', tools: []),
      ),
    );
    expect(s, isA<LayeredVoiceSession>());
    expect(s, isA<AppSpeaker>());
  });
}
