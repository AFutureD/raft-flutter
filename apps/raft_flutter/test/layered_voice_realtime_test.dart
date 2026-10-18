import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_language.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/app_speech.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/key_info.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/realtime_voice_out.dart';
import 'package:raft_flutter/features/agent_mode/voice_layer_text.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_key_info.dart';

/// The voice layer when the voice service is OpenAI Realtime or Grok Voice:
/// it listens and transcribes, never calls a tool or answers, and says only
/// what the app asks it to (a lead-in it phrases, the acknowledgment, the
/// agent's answer), one line at a time, with the person's voice able to cut
/// all of it.

/// One thing the voice was asked to say.
class Said {
  Said(this.kind, this.text, this.handle);
  final String kind; // say | lead
  final String text;
  final SpeechHandle handle;
  @override
  String toString() => '$kind:$text';
}

/// A realtime voice session that plays each line for [playFor] after it
/// starts to sound [startAfter] after it was asked for.
class FakeVoice implements VoiceSession, RealtimeVoiceOut {
  FakeVoice(
    this.parts, {
    required this.exact,
    this.startAfter = const Duration(milliseconds: 300),
    this.playFor = const Duration(seconds: 1),
    this.leadStarts = true,
    this.leadSays = '好嘞，翻一下未读。',
  });
  final LiveParts parts;
  final bool exact;
  final Duration startAfter, playFor;

  /// Whether a lead-in ever starts to sound (false: the service did not
  /// produce one).
  final bool leadStarts;

  /// What the voice made of a lead-in.
  final String leadSays;

  /// What the voice reads of a line (default: the line, as asked).
  String Function(String text)? reads;
  final lines = <Said>[];
  int cancels = 0;
  int drains = 0;
  final timers = <Timer>[];

  Iterable<Said> get said => lines.where((l) => l.kind == 'say');
  Iterable<Said> get leads => lines.where((l) => l.kind == 'lead');

  @override
  bool get speaksExactly => exact;

  void _play(SpeechHandle h, String transcript) {
    timers.add(
      Timer(startAfter, () {
        if (h.finished) return;
        h.markStarted();
        h.addTranscript(transcript);
        timers.add(
          Timer(playFor, () {
            h.complete();
          }),
        );
      }),
    );
  }

  SpeechHandle _handle(
    String text,
    void Function()? onStart,
    void Function(String)? onTranscript,
  ) => SpeechHandle(
    text: text,
    onStart: onStart,
    onTranscript: onTranscript,
    onCancel: (h) {
      h
        ..markCancelled()
        ..complete();
    },
  );

  @override
  SpeechHandle say(
    String text, {
    void Function()? onStart,
    void Function(String piece)? onTranscript,
  }) {
    final h = _handle(text, onStart, onTranscript);
    lines.add(Said('say', text, h));
    _play(h, reads?.call(text) ?? text);
    return h;
  }

  @override
  SpeechHandle lead(
    String request, {
    List<String> avoid = const [],
    void Function()? onStart,
    void Function(String piece)? onTranscript,
  }) {
    final h = _handle(request, onStart, onTranscript);
    lines.add(Said('lead', request, h));
    if (leadStarts) _play(h, leadSays);
    return h;
  }

  @override
  void cancelSpeech() {
    cancels++;
    for (final l in lines) {
      if (!l.handle.finished) {
        l.handle
          ..markCancelled()
          ..complete();
      }
    }
  }

  @override
  Future<void> drained() async {
    drains++;
  }

  // ---- VoiceSession ----
  @override
  bool get connected => true;
  @override
  String? get model => 'voice-model';
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
  Future<void> connect() async {}
  @override
  void sendAudio(Uint8List pcm16k) {}
  @override
  void endAudio() {}
  @override
  void sendText(String text) =>
      throw StateError('the app does not type to the relay voice');
  @override
  void addContext(String text) {}
  @override
  Future<void> close() async {}

  /// What the person says: speech stops, the transcript, the end of it.
  void person(String words) {
    parts.onSpeechStarted?.call();
    parts.onInputText!(words);
    parts.onSpeechStopped?.call();
    parts.onInputDone?.call();
  }
}

class Agent implements VoiceSession, CancellableTurn {
  Agent(this.parts);
  final AgentParts parts;
  final asked = <String>[];
  int cancels = 0;

  @override
  bool get connected => true;
  @override
  String? get model => 'agent-model';
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
  void sendText(String text) => asked.add(text);
  @override
  void addContext(String text) {}
  @override
  Future<void> close() async {}
  @override
  void cancelTurn() => cancels++;

  /// Words of the answer as they stream.
  void draft(String delta) => parts.onDraft?.call(delta);

  void answer(String say) {
    parts.onOutputText(say);
    parts.onTurnComplete();
  }
}

class Rig {
  Rig({
    this.provider = AgentVoiceProvider.openai,
    this.mode = LayeredVoiceMode.liveRelays,
    this.language = AgentLanguage.zh,
    bool? exact,
    Duration startAfter = const Duration(milliseconds: 300),
    Duration playFor = const Duration(seconds: 1),
    bool leadStarts = true,
    Duration ackAfter = const Duration(milliseconds: 350),
    this.confirm,
    bool deviceVoice = false,
    Duration devicePerSentence = Duration.zero,
    this.nowMs,
  }) {
    this.exact = exact ?? provider == AgentVoiceProvider.grok;
    device = deviceVoice || mode == LayeredVoiceMode.appSpeaks
        ? RecordingSpeech(perSentence: devicePerSentence)
        : null;
    session = LayeredVoiceSession(
      voiceProvider: provider,
      apiKey: 'voice-key',
      agentApiKey: 'gemini-key',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async {
        toolCalls.add(n);
        return {};
      },
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: '', tools: []),
        confirmation: confirm == null ? null : () => confirm,
      ),
      mode: mode,
      language: language,
      speech: device,
      voice: 'marin',
      liveModel: 'voice-model',
      ackAfter: ackAfter,
      random: math.Random(7),
      nowMs: nowMs,
      onAudio: (pcm) => audio++,
      onInputText: heard.add,
      onOutputText: captions.add,
      onTurnComplete: () => completes++,
      onInterrupted: () => interrupts++,
      liveBuilder: (p) => voice = FakeVoice(
        p,
        exact: this.exact,
        startAfter: startAfter,
        playFor: playFor,
        leadStarts: leadStarts,
      ),
      agentBuilder: (p) {
        agentParts = p;
        return agent = Agent(p);
      },
      log: logs.add,
    );
    session.addSpeakingListener(speaking.add);
    session.onTimed = (what, ms) => timings.add((what, ms));
    session.onSpoken = spoken.add;
    session.onFeedback = (kind, text) => feedback.add('$kind:$text');
  }

  final AgentVoiceProvider provider;
  final LayeredVoiceMode mode;
  final AgentLanguage language;
  final KeyInfo? confirm;
  final int Function()? nowMs;
  late final bool exact;
  late final RecordingSpeech? device;
  late final LayeredVoiceSession session;
  late FakeVoice voice;
  late Agent agent;
  late AgentParts agentParts;
  final toolCalls = <String>[];
  final heard = <String>[];
  final captions = <String>[];
  final spoken = <String>[];
  final speaking = <bool>[];
  final logs = <String>[];
  final feedback = <String>[];
  final timings = <(String, int)>[];
  int completes = 0;
  int interrupts = 0;
  int audio = 0;

  Iterable<String> get said => voice.said.map((l) => l.text);

  void connect(FakeAsync async) {
    session.connect();
    async.flushMicrotasks();
  }
}

const _providers = [AgentVoiceProvider.openai, AgentVoiceProvider.grok];

void main() {
  for (final provider in _providers) {
    group('${provider.name} as the voice of the layered brain', () {
      test('it is built as a relay: no tools, the relay instruction, the '
          'chosen model and language; the text agent has the Gemini key', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
            language: AgentLanguage.en,
          );
          final p = r.voice.parts;
          expect(p.provider, provider);
          expect(p.relay, isTrue);
          expect(p.tools, isEmpty);
          expect(p.systemPrompt, relayVoicePromptFor(AgentLanguage.en));
          expect(p.systemPrompt, contains(AgentLanguage.en.relayLine));
          expect(p.language, AgentLanguage.en);
          expect(p.liveModel, 'voice-model');
          expect(p.apiKey, 'voice-key');
          expect(r.agentParts.apiKey, 'gemini-key');
          expect(
            relayVoicePromptFor(AgentLanguage.zh),
            contains(AgentLanguage.zh.relayLine),
          );
        });
      });

      test('a tool call of the voice is never run: not the agent\'s tools, '
          'not an ask', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          Map<String, Object?>? answer;
          r.voice.parts
              .onToolCall('send_message', {'text': 'hi'})
              .then((v) => answer = v);
          r.voice.parts.onToolCall('ask_agent', {'request': 'x'});
          async.flushMicrotasks();
          expect(answer, containsPair('error', isA<String>()));
          expect(r.toolCalls, isEmpty);
          expect(r.agent.asked, isEmpty);
          expect(r.voice.lines, isEmpty);
        });
      });

      test('the person\'s words go to the agent as they were heard; the '
          'voice never answers by itself', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 100));
          expect(r.agent.asked, ['读一下动态']);
          expect(r.heard.join(), '读一下动态');
          expect(r.voice.lines, isEmpty, reason: 'nothing is said at once');
        });
      });

      test('a slow answer: a lead-in the voice phrases from the request, no '
          'canned acknowledgment on top, then the answer a sentence at a '
          'time, and the turn ends after it', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 120));
          expect(r.voice.leads, isEmpty, reason: 'a quick answer needs none');
          async.elapse(const Duration(milliseconds: 130));
          expect(r.voice.leads.map((l) => l.text), ['读一下动态']);
          async.elapse(const Duration(seconds: 3));
          expect(r.voice.said, isEmpty, reason: 'the lead-in is the cue');
          expect(r.feedback, ['lead:好嘞，翻一下未读。']);
          expect(r.spoken, isEmpty, reason: 'the lead-in is not the answer');
          expect(r.captions, isEmpty);
          expect(r.completes, 0);
          r.agent.answer('动态里有 3 条。Cody 在问第 10 步。');
          async.flushMicrotasks();
          expect(r.said, ['动态里有 3 条。']);
          async.elapse(const Duration(milliseconds: 1400));
          expect(r.said, ['动态里有 3 条。', 'Cody 在问第 10 步。']);
          expect(r.completes, 0);
          async.elapse(const Duration(seconds: 3));
          expect(r.spoken, ['动态里有 3 条。', 'Cody 在问第 10 步。']);
          expect(r.captions.join(), '动态里有 3 条。Cody 在问第 10 步。');
          expect(r.completes, 1);
          expect(r.speaking.last, isFalse);
          expect(r.voice.drains, greaterThan(0));
        });
      });

      test('when the voice produces no lead-in, one canned acknowledgment '
          'steps in, once, said by the same voice; then the answer', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
            leadStarts: false,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 700));
          expect(r.voice.said, isEmpty, reason: 'the lead-in is given time');
          async.elapse(const Duration(milliseconds: 400));
          final ack = r.voice.said.single.text;
          expect(ackPhrases(AgentLanguage.zh), contains(ack));
          async.elapse(const Duration(seconds: 5));
          expect(r.voice.said, hasLength(1), reason: 'once');
          expect(r.spoken, isEmpty);
          expect(r.captions, isEmpty);
          r.agent.answer('有 3 条。');
          async.elapse(const Duration(seconds: 3));
          expect(r.said.toList(), [ack, '有 3 条。']);
          expect(r.captions.join(), '有 3 条。');
          expect(r.completes, 1);
        });
      });

      test('an agent faster than the delay: no lead-in, no acknowledgment', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('下一件');
          async.elapse(const Duration(milliseconds: 100));
          r.agent.answer('第 10 步。');
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 3));
          expect(r.voice.leads, isEmpty);
          expect(r.said.toList(), ['第 10 步。']);
          expect(r.feedback, isEmpty);
          expect(r.completes, 1);
        });
      });

      test('an answer that comes before the lead-in sounds takes it back', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 250));
          final lead = r.voice.leads.single.handle;
          expect(lead.started, isFalse);
          r.agent.answer('有 3 条。');
          async.flushMicrotasks();
          expect(lead.cancelled, isTrue);
          async.elapse(const Duration(seconds: 3));
          expect(r.said.toList(), ['有 3 条。']);
          expect(r.feedback, isEmpty, reason: 'nothing was heard of it');
          expect(r.completes, 1);
        });
      });

      test('the person speaking over the voice cuts everything: what is '
          'being said, what is queued, and the turn goes on with their '
          'words', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 100));
          r.agent.answer('第一句。第二句。第三句。');
          async.elapse(const Duration(milliseconds: 500));
          expect(r.speaking.last, isTrue);
          expect(r.said.toList(), ['第一句。']);
          // The person speaks over it.
          r.voice.parts.onSpeechStarted!();
          expect(r.voice.cancels, greaterThan(0));
          expect(r.interrupts, 1, reason: 'the player is told to stop');
          expect(r.speaking.last, isFalse);
          async.elapse(const Duration(seconds: 5));
          expect(r.said.toList(), ['第一句。'], reason: 'the rest never sounds');
          expect(r.completes, 0, reason: 'a cut turn is not a finished one');
          // Their words are the next turn.
          r.voice.parts.onInputText!('算了，读第二条');
          r.voice.parts.onSpeechStopped!();
          r.voice.parts.onInputDone!();
          async.elapse(const Duration(milliseconds: 100));
          expect(r.agent.asked, ['读一下动态', '算了，读第二条']);
        });
      });

      test(
        'speaking over the lead-in while the agent works cuts the ask too',
        () {
          fakeAsync((async) {
            final r = Rig(
              nowMs: () => async.elapsed.inMilliseconds,
              provider: provider,
            );
            r.connect(async);
            r.voice.person('读一下动态');
            async.elapse(const Duration(milliseconds: 600));
            expect(r.speaking.last, isTrue, reason: 'the lead-in sounds');
            r.voice.parts.onSpeechStarted!();
            expect(r.agent.cancels, 1);
            expect(r.voice.cancels, greaterThan(0));
            // The cut ask says nothing more.
            async.elapse(const Duration(seconds: 3));
            expect(r.said, isEmpty);
            expect(r.completes, 0);
          });
        },
      );

      test('the voice\'s own lead-in coming back through the microphone is '
          'not a question', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 700));
          expect(r.speaking.last, isTrue);
          // The transcript of what the room carried back.
          r.voice.parts.onInputText!('好嘞翻一下未读');
          r.voice.parts.onInputDone!();
          async.elapse(const Duration(milliseconds: 300));
          expect(r.agent.asked, ['读一下动态'], reason: 'not forwarded');
          expect(r.agent.cancels, 0);
        });
      });

      test('typed text is a turn like a heard one; a note from the app is '
          'for the agent and its answer is said', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.session.sendText('去动态');
          async.elapse(const Duration(milliseconds: 50));
          expect(r.agent.asked, ['去动态']);
          r.agent.answer('好。');
          async.elapse(const Duration(seconds: 3));
          expect(r.said.toList(), ['好。']);
          r.session.sendText('（App 提示）有新消息');
          async.flushMicrotasks();
          expect(r.agent.asked.last, '（App 提示）有新消息');
          r.agent.answer('Cody 回你了。');
          async.elapse(const Duration(seconds: 3));
          expect(r.said.toList(), ['好。', 'Cody 回你了。']);
        });
      });

      test('the app\'s own words are said by the voice, as they are', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.session.speak('有新的任务。');
          async.elapse(const Duration(seconds: 3));
          expect(r.said.toList(), ['有新的任务。']);
        });
      });

      test('the answer\'s numbers lose the # for the ear', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.session.sendText('读任务');
          async.elapse(const Duration(milliseconds: 20));
          r.agent.answer('任务 #136 待验收。');
          async.elapse(const Duration(seconds: 3));
          expect(r.said.single, '任务 136 待验收。');
        });
      });

      test('streamed answer: the first sentence is said before the agent is '
          'done; the rest follow in order, once; the turn ends once', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 100));
          r.agent.draft('动态里有 3 条，');
          r.agent.draft('Cody 在问第 10 步。第二句还没');
          async.flushMicrotasks();
          expect(r.said.toList(), ['动态里有 3 条，Cody 在问第 10 步。']);
          expect(r.completes, 0);
          // The agent finishes: the rest of the answer, nothing twice.
          r.agent.answer('动态里有 3 条，Cody 在问第 10 步。第二句还没说完。');
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 4));
          expect(r.said.toList(), ['动态里有 3 条，Cody 在问第 10 步。', '第二句还没说完。']);
          expect(r.completes, 1);
          expect(r.spoken, hasLength(2));
          expect(r.logs.join('\n'), isNot(contains('stream-diverged')));
        });
      });

      test('streamed answer: narration the agent said before its tools is '
          'dropped, and a final text that does not hold the draft is said '
          'whole', () {
        expect(
          LayeredVoiceSession.afterDraft(
            ['让我查一下。', '有 3 条。', '要读吗？'],
            ['有 3 条。'],
          ),
          ['要读吗？'],
        );
        expect(LayeredVoiceSession.afterDraft(['完全不同。', '另一句。'], ['有 3 条。']), [
          '完全不同。',
          '另一句。',
        ]);
        expect(LayeredVoiceSession.afterDraft(['一。', '二。'], const []), [
          '一。',
          '二。',
        ]);
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.session.sendText('读');
          async.elapse(const Duration(milliseconds: 20));
          r.agent.draft('旧的说法。');
          r.agent.answer('改过的说法。再一句。');
          async.elapse(const Duration(seconds: 5));
          expect(r.said.toList(), ['旧的说法。', '改过的说法。', '再一句。']);
          expect(r.logs.join('\n'), contains('stream-diverged'));
        });
      });

      test('streamed answer: the person speaking over it cuts what is '
          'queued, and the later words of the agent are not said', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(milliseconds: 100));
          r.agent.draft('第一句。第二句。第三句。');
          async.elapse(const Duration(milliseconds: 400));
          r.voice.parts.onSpeechStarted!();
          async.elapse(const Duration(seconds: 4));
          r.agent.answer('第一句。第二句。第三句。');
          async.elapse(const Duration(seconds: 4));
          expect(r.said.toList(), ['第一句。']);
          expect(r.completes, 0);
        });
      });

      test('the first sound and the first sentence of the answer are timed '
          'from the end of the person\'s speech: under a second for the '
          'lead-in', () {
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
          );
          r.connect(async);
          r.voice.person('读一下动态');
          async.elapse(const Duration(seconds: 2));
          r.agent.answer('有 3 条。');
          async.elapse(const Duration(seconds: 3));
          final voice = r.timings.firstWhere((t) => t.$1 == 'voice').$2;
          final answer = r.timings.firstWhere((t) => t.$1 == 'answer').$2;
          // Lead-in asked at 150 ms, begins 300 ms later.
          expect(voice, inInclusiveRange(400, 600));
          expect(voice, lessThan(1000));
          expect(answer, greaterThan(2000));
          expect(r.timings.where((t) => t.$1 == 'voice'), hasLength(1));
          expect(
            r.logs.where((l) => l.contains('latency what=voice')),
            hasLength(1),
          );
        });
      });

      test(
        'the language setting reaches the voice: English acknowledgments',
        () {
          fakeAsync((async) {
            final r = Rig(
              nowMs: () => async.elapsed.inMilliseconds,
              provider: provider,
              language: AgentLanguage.en,
              leadStarts: false,
            );
            r.connect(async);
            r.voice.person('read the activity');
            async.elapse(const Duration(seconds: 2));
            expect(ackPhrases(AgentLanguage.en), contains(r.said.single));
            expect(
              ackPhrases(AgentLanguage.zh),
              isNot(contains(r.said.single)),
            );
          });
        },
      );

      test('a reading of a confirmation that leaves something out is '
          'corrected by the device\'s voice (only where the voice reads, '
          'not where it speaks the text)', () {
        const line = '回复 Cody：晚上看，要发吗？';
        final card = orbCardKeyInfoOfResult('reply_in_thread', const {}, {
          'status': 'needs_confirmation',
          'preview': {
            'summary': '回复 Cody 的消息：“晚上看”',
            'changes': [
              '回复: Cody：第 10 步可以合入吗 → Cody：第 10 步可以合入吗',
              '内容:  → 晚上看',
            ],
          },
        })!;
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
            confirm: card,
            deviceVoice: true,
          );
          r.voice.reads = (text) => '好的。';
          r.connect(async);
          r.session.sendText('回他晚上看');
          async.elapse(const Duration(milliseconds: 20));
          r.agent.answer(line);
          async.elapse(const Duration(seconds: 6));
          if (r.exact) {
            expect(r.device!.spoken, isEmpty, reason: 'exact speech');
          } else {
            expect(r.device!.spoken.join(), line);
          }
          expect(r.completes, 1);
        });
        fakeAsync((async) {
          final r = Rig(
            nowMs: () => async.elapsed.inMilliseconds,
            provider: provider,
            confirm: card,
            deviceVoice: true,
          );
          r.connect(async);
          r.session.sendText('回他晚上看');
          async.elapse(const Duration(milliseconds: 20));
          r.agent.answer(line);
          async.elapse(const Duration(seconds: 6));
          expect(r.device!.spoken, isEmpty, reason: 'the voice said it all');
          expect(r.completes, 1);
        });
      });
    });
  }

  group('the device\'s voice with a relay voice service', () {
    test('with 转述 off (App 朗读) the service only listens and the device '
        'speaks everything', () {
      fakeAsync((async) {
        final r = Rig(
          nowMs: () => async.elapsed.inMilliseconds,
          mode: LayeredVoiceMode.appSpeaks,
        );
        r.connect(async);
        r.voice.person('读一下动态');
        async.elapse(const Duration(seconds: 1));
        r.agent.answer('有 3 条。');
        async.elapse(const Duration(seconds: 2));
        expect(r.voice.lines, isEmpty);
        expect(r.device!.spoken.last, '有 3 条。');
        // The first is the acknowledgment (a slow ask), by the device.
        expect(r.device!.spoken, hasLength(2));
        expect(r.completes, 1);
      });
    });

    test('a speaking device is cut by the person speaking over it', () {
      fakeAsync((async) {
        final r = Rig(
          nowMs: () => async.elapsed.inMilliseconds,
          mode: LayeredVoiceMode.appSpeaks,
          devicePerSentence: const Duration(seconds: 1),
        );
        r.connect(async);
        r.session.sendText('读');
        async.elapse(const Duration(milliseconds: 20));
        r.agent.answer('第一句。第二句。');
        async.flushMicrotasks();
        expect(r.session.speaking, isTrue);
        r.voice.parts.onSpeechStarted!();
        expect(r.session.speaking, isFalse);
        expect(r.device!.stops, greaterThan(0));
      });
    });
  });
}
