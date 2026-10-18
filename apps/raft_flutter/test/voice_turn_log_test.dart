import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/app_speech.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_mode/voice_turn_log.dart';

import 'layered_voice_app_speaks_test.dart' show HeldAgent, ListenLive;

/// The `voice-turn` lines of the voice diagnostics, and what a Live model
/// refused at setup being remembered for the next session.
class _Speech extends RecordingSpeech implements SpeechVoiceInfo {
  _Speech() : super(perSentence: const Duration(seconds: 1));
  @override
  Map<String, Object?> get voiceInfo => {
    'engine': 'com.google.android.tts',
    'voice': 'cmn-cn-x-ccc-network',
    'lang': 'zh-CN',
  };
  @override
  Future<void> prepare() async {}
}

GeminiLiveSession _live({
  bool fast = false,
  bool listenOnly = false,
  AgentReasoning reasoning = AgentReasoning.high,
  VoiceLog? log,
}) => GeminiLiveSession(
  apiKey: 'secret-key',
  systemPrompt: 'p',
  tools: const [],
  onToolCall: (n, a) async => {},
  reasoning: reasoning,
  fast: fast,
  listenOnly: listenOnly,
  log: log,
);

void main() {
  setUp(GeminiLiveSession.forgetSetups);

  group('the line format', () {
    test('event, k=v, quotes only when needed, null left out', () {
      expect(
        voiceTurnLine('tool', {'name': 'navigate', 'ms': 12, 'x': null}),
        'voice-turn tool name=navigate ms=12',
      );
      expect(
        voiceTurnLine('user', {'src': 'voice', 'text': 'show me\nmy "unread"'}),
        'voice-turn user src=voice text="show me my \\"unread\\""',
      );
    });

    test('long text is clipped with its length', () {
      final line = voiceTurnLine('speak', {'text': '字' * 300});
      expect(line, contains('字' * voiceLogClip));
      expect(line, isNot(contains('字' * (voiceLogClip + 1))));
      expect(line, contains('(300)'));
    });
  });

  group('setup refusals are remembered per model', () {
    test(
      'a model that refused three features gets the accepted setup first',
      () {
        final first = _live()..useModel('models/gemini-9-live');
        expect(first.setupFlags.affective, isTrue);
        expect(
          first.dropRefused(
            'Unknown name "enableAffectiveDialog" at setup',
            nonBlocking: true,
          ),
          'affective',
        );
        expect(
          first.dropRefused(
            'Thinking level is not supported for this model',
            nonBlocking: true,
          ),
          startsWith('thinking'),
        );
        expect(
          first.dropRefused('Unknown name "behavior"', nonBlocking: true),
          'nonBlocking',
        );
        first.rememberSetup();

        final next = _live()..useModel('models/gemini-9-live');
        expect(next.setupFlags.affective, isFalse);
        expect(next.setupFlags.nonBlocking, isFalse);
        // High was refused, medium was too (one step down each refusal in the
        // session); the next session starts at what was accepted.
        expect(next.thinkingUsed, first.thinkingUsed);
        expect(
          (next.setupMessage(
                    'm',
                    affective: false,
                    nonBlocking: false,
                  )['setup']!
                  as Map)
              .containsKey('enableAffectiveDialog'),
          isFalse,
        );
      },
    );

    test('a named feature is dropped, whatever the order', () {
      final s = _live()..useModel('models/m');
      expect(
        s.dropRefused(
          'Unknown name "enableAffectiveDialog"',
          nonBlocking: true,
        ),
        'affective',
      );
      expect(s.setupFlags.nonBlocking, isTrue);
    });

    test('unknown models start with everything, other models are not '
        'affected', () {
      final a = _live()..useModel('models/a');
      a.dropRefused('x', nonBlocking: true);
      a.dropRefused('x', nonBlocking: true);
      a.rememberSetup();
      final b = _live()..useModel('models/b');
      expect(b.setupFlags.affective, isTrue);
      expect(b.setupFlags.nonBlocking, isTrue);
      expect(GeminiLiveSession.rememberedSetup('models/b'), isNull);
    });

    test('a setup that never succeeded is not remembered', () {
      final a = _live()..useModel('models/a');
      a.dropRefused('network down', nonBlocking: true);
      final again = _live()..useModel('models/a');
      expect(again.setupFlags.affective, isTrue);
    });

    test('the relaying session remembers the thinking step it was given', () {
      final first = _live(fast: true)..useModel('models/gemini-9-live');
      expect(first.thinkingUsed, 'minimal');
      first.dropRefused('thinking level not supported', nonBlocking: false);
      first.dropRefused('thinking level not supported', nonBlocking: false);
      expect(first.thinkingUsed, 'budget 0');
      first.rememberSetup();
      final next = _live(fast: true)..useModel('models/gemini-9-live');
      expect(next.thinkingUsed, 'budget 0');
      // A listening session is its own kind: not affected.
      final listen = _live(fast: true, listenOnly: true)
        ..useModel('models/gemini-9-live');
      expect(listen.thinkingUsed, 'minimal');
    });

    test('the level of the settings is capped by what was accepted, never '
        'raised', () {
      final first = _live(reasoning: AgentReasoning.high)..useModel('models/m');
      first.dropRefused('thinking not supported', nonBlocking: false);
      expect(first.thinkingUsed, 'medium');
      first.rememberSetup();
      expect(
        (_live(
          reasoning: AgentReasoning.high,
        )..useModel('models/m')).thinkingUsed,
        'medium',
      );
      expect(
        (_live(
          reasoning: AgentReasoning.low,
        )..useModel('models/m')).thinkingUsed,
        'low',
      );
    });

    test('nothing left to drop: null', () {
      final s = _live()..useModel('models/m');
      s.dropRefused('x', nonBlocking: true);
      s.dropRefused('x', nonBlocking: true);
      expect(s.dropRefused('x', nonBlocking: false), isNull);
    });
  });

  group('Live logs one line per turn', () {
    test('what was heard once, what Live said once, never the key', () {
      final lines = <String>[];
      final s = _live(log: lines.add);
      void content(Map<String, Object?> c) =>
          s.handleMessage({'serverContent': c});
      content({
        'inputTranscription': {'text': 'show me '},
      });
      content({
        'inputTranscription': {'text': 'my unread summaries'},
      });
      content({
        'outputTranscription': {'text': 'Sure, '},
      });
      content({
        'outputTranscription': {'text': 'here they are.'},
      });
      content({'turnComplete': true});
      expect(lines, [
        'voice-turn user src=voice text="show me my unread summaries"',
        'voice-turn speak who=live voice=Sulafat text="Sure, here they are."',
        'voice-turn turn-complete who=live',
      ]);
      expect(lines.join(), isNot(contains('secret-key')));
    });

    test('a barge-in is logged and cuts what was said', () {
      final lines = <String>[];
      final s = _live(log: lines.add);
      s.handleMessage({
        'serverContent': {
          'outputTranscription': {'text': 'One two'},
        },
      });
      s.handleMessage({
        'serverContent': {'interrupted': true},
      });
      expect(lines, [
        'voice-turn speak who=live voice=Sulafat text="One two" cut=true',
        'voice-turn interrupted by=person who=live',
      ]);
    });

    test('a listening session leaves the person\'s turn to its owner', () {
      final lines = <String>[];
      final s = _live(listenOnly: true, log: lines.add);
      s.handleMessage({
        'serverContent': {
          'inputTranscription': {'text': 'hello'},
        },
      });
      s.handleMessage({
        'serverContent': {'turnComplete': true},
      });
      expect(lines, isEmpty);
    });
  });

  test('a tool call leaves one line with name, args, status and ms', () async {
    final lines = <String>[];
    final r = AgentToolResponder(
      handler: (name, args) async =>
          name == 'bad' ? {'error': 'no such page'} : {'ok': true},
      send: (_) => true,
      log: (_) {},
      turnLog: lines.add,
    );
    await r.answer([
      {
        'id': '1',
        'name': 'navigate',
        'args': {'page': 'activity'},
      },
      {'id': '2', 'name': 'bad', 'args': <String, Object?>{}},
    ]);
    expect(lines[0], matches(r'^voice-turn tool name=navigate args='));
    expect(lines[0], contains('status=ok'));
    expect(lines[0], matches(r'ms=\d+'));
    expect(lines[1], contains('name=bad'));
    expect(lines[1], contains('status=error'));
    expect(lines[1], contains('err="no such page"'));
  });

  test('the layered voice logs session, user, ask, speech and the turn', () {
    fakeAsync((async) {
      final lines = <String>[];
      late ListenLive live;
      late HeldAgent agent;
      final session = LayeredVoiceSession(
        apiKey: 'secret-key',
        systemPrompt: 'p',
        tools: const [],
        onToolCall: (n, a) async => {},
        steering: const AgentSteering(scope: _scope),
        mode: LayeredVoiceMode.appSpeaks,
        speech: _Speech(),
        ackAfter: const Duration(hours: 1),
        log: lines.add,
        liveBuilder: (p) => live = ListenLive(p),
        agentBuilder: (p) => agent = HeldAgent(p),
      )..fastPathOf = () => 'open';
      session.connect();
      async.flushMicrotasks();
      live.parts.onInputText!('open activity');
      live.parts.onGenerating!();
      async.elapse(const Duration(milliseconds: 200));
      agent.answer('好，打开了。');
      async.elapse(const Duration(seconds: 3));
      expect(lines.first, startsWith('voice-turn session mode=layered'));
      expect(lines.first, contains('live=appSpeaks'));
      expect(lines.first, contains('agentModel=agent-model'));
      expect(lines, contains('voice-turn user src=voice text="open activity"'));
      expect(
        lines.any(
          (l) =>
              l.startsWith('voice-turn ask request="open activity"') &&
              l.contains('say=') &&
              l.contains('fastPath=open'),
        ),
        isTrue,
        reason: '$lines',
      );
      expect(
        lines,
        contains(
          'voice-turn speak who=app-tts kind=answer text=好，打开了。 '
          'engine=com.google.android.tts voice=cmn-cn-x-ccc-network '
          'lang=zh-CN',
        ),
      );
      expect(lines, contains('voice-turn turn-complete who=app-tts'));
      expect(lines.join(), isNot(contains('secret-key')));
    });
  });
}

AgentScope _scope() => const AgentScope(systemPrompt: '', tools: []);
