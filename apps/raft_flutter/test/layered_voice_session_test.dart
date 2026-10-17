import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
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
    expect(layeredVoicePrompt, contains('一字不差'));
    expect(layeredVoicePrompt, contains('我看一下'));
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
