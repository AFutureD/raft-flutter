import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_language.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/app_speech.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_listen.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/voice_layer_text.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';

/// The voice layer where the app speaks: Live only listens, the app forwards
/// what the person said to the agent and speaks the agent's words itself.

class ListenLive implements VoiceSession {
  ListenLive(this.parts);
  final LiveParts parts;
  var audio = 0;
  var closes = 0;

  /// Text the app typed to Live (only where Live relays and says what it is
  /// given); in the app-speaks mode that is an error.
  final typed = <String>[];
  var allowText = false;

  @override
  bool get connected => true;
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
  Future<void> connect() async {}
  @override
  void sendAudio(Uint8List pcm16k) => audio++;
  @override
  void endAudio() {}
  @override
  void sendText(String text) {
    if (!allowText) throw StateError('the app does not type to Live');
    typed.add(text);
  }

  @override
  void addContext(String text) {}
  @override
  Future<void> close() async => closes++;
}

class HeldAgent implements VoiceSession, CancellableTurn {
  HeldAgent(this.parts);
  final AgentParts parts;
  final asked = <String>[];
  final contexts = <String>[];
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
  void addContext(String text) => contexts.add(text);
  @override
  Future<void> close() async {}
  @override
  void cancelTurn() => cancels++;

  /// The agent's turn ends with [say].
  void answer(String say) {
    parts.onOutputText(say);
    parts.onTurnComplete();
  }
}

class Rig {
  Rig({
    this.perSentence = const Duration(seconds: 1),
    // Off unless a test is about it: an ask the test leaves unanswered would
    // be acknowledged.
    Duration ackAfter = const Duration(hours: 1),
  }) {
    speech = RecordingSpeech(perSentence: perSentence);
    session = LayeredVoiceSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      steering: const AgentSteering(scope: _scope),
      mode: LayeredVoiceMode.appSpeaks,
      speech: speech,
      ackAfter: ackAfter,
      random: math.Random(7),
      onInputText: heard.add,
      onOutputText: captions.add,
      onTurnComplete: () => completes++,
      onInterrupted: () => interrupts++,
      liveBuilder: (p) => live = ListenLive(p),
      agentBuilder: (p) => agent = HeldAgent(p),
    );
    session.addSpeakingListener(speaking.add);
  }

  static AgentScope _scope() => const AgentScope(systemPrompt: '', tools: []);

  final Duration perSentence;
  late final RecordingSpeech speech;
  late final LayeredVoiceSession session;
  late ListenLive live;
  late HeldAgent agent;
  final heard = <String>[];
  final captions = <String>[];
  final speaking = <bool>[];
  int completes = 0;
  int interrupts = 0;

  /// What the person says: transcript chunks, then Live starts to generate.
  void say(List<String> chunks, {bool endWith = true}) {
    for (final c in chunks) {
      live.parts.onInputText!(c);
    }
    if (endWith) live.parts.onGenerating!();
  }
}

void main() {
  test('sentences: split at the stops, nothing lost or changed', () {
    expect(orbSentences('好的。已经打开了！要我读吗？'), ['好的。', '已经打开了！', '要我读吗？']);
    expect(orbSentences('Alice 说：“周五能来评审吗？”我回她好吗'), [
      'Alice 说：“周五能来评审吗？”',
      '我回她好吗',
    ]);
    expect(orbSentences('把 #136 标成完成。\n再看 v1.2 和 3.5 版。'), [
      '把 #136 标成完成。',
      '再看 v1.2 和 3.5 版。',
    ]);
    expect(orbSentences('Done. Next one'), ['Done.', 'Next one']);
    expect(orbSentences('等一下……好了。'), ['等一下……', '好了。']);
    expect(orbSentences('  '), isEmpty);
    expect(orbSentences(''), isEmpty);
    // What is said, one after the other, is the text.
    const text = '第 10 步，合入；等了 20 分钟！Cody 在问：“可以吗？”';
    expect(orbSentences(text).join(), text);
  });

  test('the recorder notes sentences and a stop frees the one being said', () {
    fakeAsync((async) {
      final speech = RecordingSpeech(perSentence: const Duration(seconds: 2));
      var done = false;
      speech.speak('一句。').then((_) => done = true);
      async.elapse(const Duration(seconds: 1));
      expect(done, isFalse);
      speech.stop();
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(speech.spoken, ['一句。']);
      expect(speech.stops, 1);
    });
  });

  group('the end of the person\'s turn', () {
    late UserTurnForwarder f;
    late List<String> forwarded, chunks;
    late int barges;
    bool guarding = false;
    String recent = '';

    setUp(() {
      forwarded = [];
      chunks = [];
      barges = 0;
      guarding = false;
      recent = '';
      f = UserTurnForwarder(
        forward: forwarded.add,
        onChunk: chunks.add,
        onBargeIn: () => barges++,
        guarding: () => guarding,
        echoOf: (t) => recent.contains(t),
      );
    });

    test('the whole transcript goes when Live starts to generate', () {
      fakeAsync((async) {
        f.heard('把 #136 ');
        f.heard('标成完成');
        expect(forwarded, isEmpty);
        f.modelActed();
        async.elapse(const Duration(milliseconds: 79));
        expect(forwarded, isEmpty);
        async.elapse(const Duration(milliseconds: 2));
        expect(forwarded, ['把 #136 标成完成']);
        expect(chunks.join(), '把 #136 标成完成');
      });
    });

    test('a chunk that comes in the settling time is part of the turn', () {
      fakeAsync((async) {
        f.heard('读一下');
        f.modelActed();
        async.elapse(const Duration(milliseconds: 50));
        f.heard('动态');
        async.elapse(const Duration(milliseconds: 50));
        expect(forwarded, isEmpty);
        async.elapse(const Duration(milliseconds: 50));
        expect(forwarded, ['读一下动态']);
      });
    });

    test('a sign with nothing heard forwards nothing; marks alone neither', () {
      fakeAsync((async) {
        f.modelActed();
        async.elapse(const Duration(seconds: 1));
        f.heard('。');
        f.modelActed();
        async.elapse(const Duration(seconds: 1));
        expect(forwarded, isEmpty);
      });
    });

    test('with no sign at all, a transcript that stops is the turn', () {
      fakeAsync((async) {
        f.heard('确认');
        async.elapse(const Duration(seconds: 1));
        expect(forwarded, isEmpty);
        async.elapse(const Duration(seconds: 1, milliseconds: 1));
        expect(forwarded, ['确认']);
      });
    });

    test('one turn at a time: the next words are the next turn', () {
      fakeAsync((async) {
        f.heard('下一件');
        f.modelActed();
        async.elapse(const Duration(milliseconds: 100));
        f.heard('确认');
        f.modelActed();
        async.elapse(const Duration(milliseconds: 100));
        expect(forwarded, ['下一件', '确认']);
      });
    });

    test('speaking over the voice is a barge-in, once; the echo is not', () {
      fakeAsync((async) {
        guarding = true;
        recent = '回复cody晚上看要发吗';
        // The voice heard through the microphone: dropped, no barge-in.
        f.heard('回复 Cody');
        f.heard('：晚上看');
        f.modelActed();
        async.elapse(const Duration(milliseconds: 100));
        expect(barges, 0);
        expect(forwarded, isEmpty);
        expect(chunks, isEmpty);
        // The person: a barge-in as soon as it is known, then the turn.
        f.heard('不对');
        f.heard('发给八戒');
        expect(barges, 1);
        f.heard('吧');
        expect(barges, 1);
        f.modelActed();
        async.elapse(const Duration(milliseconds: 100));
        expect(forwarded, ['不对发给八戒吧']);
      });
    });

    test('a short word over the voice is the person\'s', () {
      fakeAsync((async) {
        guarding = true;
        recent = '要发吗';
        f.heard('停');
        expect(barges, 0, reason: 'waits for enough to tell the echo');
        f.modelActed();
        async.elapse(const Duration(milliseconds: 100));
        expect(barges, 1);
        expect(forwarded, ['停']);
      });
    });
  });

  group('forwarding', () {
    test('what Live heard is sent to the agent as it is, and the say is '
        'spoken exactly, a sentence at a time', () {
      fakeAsync((async) {
        final r = Rig();
        r.session.connect();
        async.flushMicrotasks();
        r.say(['把 #136 ', '标成完成']);
        async.elapse(const Duration(milliseconds: 100));
        expect(r.agent.asked, ['把 #136 标成完成']);
        expect(r.heard.join(), '把 #136 标成完成');

        r.agent.answer('已经把 #136 标成完成。下一件是第 10 步。');
        async.flushMicrotasks();
        // The first sentence starts at once; the rest follow.
        expect(r.speech.spoken, ['已经把 #136 标成完成。']);
        expect(r.captions, ['已经把 #136 标成完成。']);
        expect(r.speaking, [true]);
        async.elapse(const Duration(seconds: 1));
        expect(r.speech.spoken, ['已经把 #136 标成完成。', '下一件是第 10 步。']);
        expect(r.completes, 0);
        async.elapse(const Duration(seconds: 1));
        expect(r.completes, 1);
        expect(r.speaking, [true, false]);
        expect(r.captions.join(), '已经把 #136 标成完成。下一件是第 10 步。');
      });
    });

    test('typed words take the same path', () {
      fakeAsync((async) {
        final r = Rig(perSentence: Duration.zero);
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        expect(r.agent.asked, ['读一下动态']);
        r.agent.answer('没有要你处理的。');
        async.flushMicrotasks();
        expect(r.speech.spoken, ['没有要你处理的。']);
        expect(r.completes, 1);
      });
    });

    test('an empty say speaks nothing and ends the turn', () {
      fakeAsync((async) {
        final r = Rig();
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('嗯');
        async.flushMicrotasks();
        r.agent.answer('');
        async.flushMicrotasks();
        expect(r.speech.spoken, isEmpty);
        expect(r.completes, 1);
      });
    });

    test('what Live generates is thrown away', () {
      fakeAsync((async) {
        final r = Rig();
        r.session.connect();
        async.flushMicrotasks();
        r.live.parts.onOutputText!('好的，我来看看。');
        r.live.parts.onAudio?.call(Uint8List(4));
        r.live.parts.onTurnComplete!();
        async.elapse(const Duration(seconds: 1));
        expect(r.captions, isEmpty);
        expect(r.completes, 0);
        expect(r.agent.asked, isEmpty);
      });
    });

    test('a note from the app is answered and the answer is spoken', () {
      fakeAsync((async) {
        final r = Rig(perSentence: Duration.zero);
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('（App 提示）卡片被点了确认');
        async.flushMicrotasks();
        r.agent.answer('已发给 Cody。');
        async.flushMicrotasks();
        expect(r.speech.spoken, ['已发给 Cody。']);
      });
    });

    test('the app\'s own words are spoken and the agent is told', () {
      fakeAsync((async) {
        final r = Rig(perSentence: Duration.zero);
        r.session.connect();
        async.flushMicrotasks();
        r.session.speak('回复 Cody：晚上看。要发吗？');
        async.flushMicrotasks();
        expect(r.speech.spoken, ['回复 Cody：晚上看。', '要发吗？']);
        expect(r.agent.contexts.single, contains('回复 Cody：晚上看。要发吗？'));
      });
    });

    test('the slow cue comes after 800 ms of the agent, once', () {
      fakeAsync((async) {
        final r = Rig();
        var cues = 0;
        r.session.onSlow = () => cues++;
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 790));
        expect(cues, 0);
        async.elapse(const Duration(milliseconds: 20));
        expect(cues, 1);
        r.agent.answer('好。');
        async.elapse(const Duration(seconds: 3));
        expect(cues, 1);
      });
    });

    test('the ask is recorded with its words and the sentences spoken', () {
      fakeAsync((async) {
        final r = Rig(perSentence: Duration.zero);
        final asks = <(String, String)>[];
        final spoken = <String>[];
        r.session
          ..onAsk = ((q, a, ms) => asks.add((q, a)))
          ..onSpoken = spoken.add;
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        r.agent.answer('第一句。第二句。');
        async.flushMicrotasks();
        expect(asks, [('读一下动态', '第一句。第二句。')]);
        expect(spoken, ['第一句。', '第二句。']);
      });
    });
  });

  group('the acknowledgment while the agent works', () {
    // The first acknowledgment of a session with this seed.
    final ack = AckPicker(random: math.Random(7)).next(AgentLanguage.zh);

    test('a slow ask is acknowledged once, in the app\'s voice, before the '
        'answer; it is no click, no caption and not a spoken sentence', () {
      fakeAsync((async) {
        final r = Rig(ackAfter: const Duration(milliseconds: 350));
        var cues = 0;
        final spoken = <String>[];
        r.session
          ..onSlow = (() => cues++)
          ..onSpoken = spoken.add;
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 340));
        expect(r.speech.spoken, isEmpty);
        async.elapse(const Duration(milliseconds: 20));
        expect(r.speech.spoken, [ack]);
        expect(r.speaking, [true]);
        // Once, however long it takes; the click is not needed on top.
        async.elapse(const Duration(seconds: 6));
        expect(r.speech.spoken, [ack]);
        expect(cues, 0);
        expect(spoken, isEmpty);
        expect(r.captions, isEmpty);
        expect(r.completes, 0, reason: 'the turn is not over');
        expect(r.agent.contexts, isEmpty, reason: 'the agent is not told');
        r.agent.answer('动态里有 3 条。');
        async.flushMicrotasks();
        expect(r.speech.spoken, [ack, '动态里有 3 条。']);
        expect(spoken, ['动态里有 3 条。']);
      });
    });

    test('a quick answer gets no acknowledgment', () {
      fakeAsync((async) {
        final r = Rig(
          perSentence: Duration.zero,
          ackAfter: const Duration(milliseconds: 350),
        );
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 200));
        r.agent.answer('没有要你处理的。');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(r.speech.spoken, ['没有要你处理的。']);
      });
    });

    test('an ask cut short or a session closed before the delay gets none', () {
      fakeAsync((async) {
        final r = Rig(ackAfter: const Duration(milliseconds: 350));
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
        r.live.parts.onInputText!('算了');
        async.flushMicrotasks();
        expect(r.agent.cancels, 1);
        // Short of the stale time that would forward the new words.
        async.elapse(const Duration(seconds: 1));
        expect(r.speech.spoken, isEmpty);
      });
      fakeAsync((async) {
        final r = Rig(ackAfter: const Duration(milliseconds: 350));
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
        r.session.close();
        async.elapse(const Duration(seconds: 2));
        expect(r.speech.spoken, isEmpty);
      });
    });

    test('an answer that comes while it is said follows it, not over it', () {
      fakeAsync((async) {
        final r = Rig(ackAfter: const Duration(milliseconds: 350));
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 600));
        expect(r.speech.spoken, [ack]);
        r.agent.answer('好的。第二句。');
        async.flushMicrotasks();
        expect(r.speech.spoken, [ack], reason: 'queued behind it');
        // The acknowledgment is said from 350 ms to 1350 ms.
        async.elapse(const Duration(milliseconds: 740));
        expect(r.speech.spoken, [ack]);
        async.elapse(const Duration(milliseconds: 20));
        expect(r.speech.spoken, [ack, '好的。']);
        async.elapse(const Duration(seconds: 1));
        expect(r.speech.spoken, [ack, '好的。', '第二句。']);
        expect(r.speaking, [true], reason: 'the voice goes on, no gap');
        async.elapse(const Duration(seconds: 1));
        expect(r.speaking, [true, false]);
        expect(r.completes, 1);
        expect(r.captions.join(), '好的。第二句。');
      });
    });

    test('no immediate repeat: the next ask has the next one', () {
      fakeAsync((async) {
        final r = Rig(
          perSentence: Duration.zero,
          ackAfter: const Duration(milliseconds: 350),
        );
        r.session.connect();
        async.flushMicrotasks();
        for (var i = 0; i < 5; i++) {
          r.session.sendText('读$i');
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 400));
          r.agent.answer('好$i。');
          async.flushMicrotasks();
        }
        final acks = [
          for (var i = 0; i < r.speech.spoken.length; i += 2)
            r.speech.spoken[i],
        ];
        expect(acks, hasLength(5));
        for (var i = 1; i < acks.length; i++) {
          expect(acks[i], isNot(acks[i - 1]));
        }
        expect(acks.toSet().length, greaterThan(2));
        expect(r.speech.spoken[1], '好0。');
      });
    });

    test('its echo through the microphone is neither a barge-in nor a '
        'question', () {
      fakeAsync((async) {
        final r = Rig(ackAfter: const Duration(milliseconds: 350));
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 400));
        expect(r.speech.spoken, [ack]);
        r.live.parts.onInputText!(ack);
        r.live.parts.onGenerating!();
        async.elapse(const Duration(milliseconds: 300));
        expect(r.agent.cancels, 0);
        expect(r.interrupts, 0);
        expect(r.agent.asked, ['读一下动态']);
        // The ask is still alive and answered.
        r.agent.answer('好。');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(r.speech.spoken, [ack, '好。']);
      });
    });

    test('without a voice of the device, Live relaying says the '
        'acknowledgment itself, once; no click', () {
      fakeAsync((async) {
        var cues = 0;
        late HeldAgent agent;
        late ListenLive live;
        final s = LayeredVoiceSession(
          apiKey: 'k',
          systemPrompt: 'p',
          tools: const [],
          onToolCall: (n, a) async => {},
          steering: const AgentSteering(scope: Rig._scope),
          ackAfter: const Duration(milliseconds: 350),
          liveLeadGrace: Duration.zero,
          random: math.Random(7),
          liveBuilder: (p) => live = ListenLive(p),
          agentBuilder: (p) => agent = HeldAgent(p),
        )..onSlow = (() => cues++);
        s.connect();
        async.flushMicrotasks();
        live.allowText = true;
        final answer = live.parts.onToolCall('ask_agent', {'request': '读'});
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 340));
        expect(live.typed, isEmpty);
        async.elapse(const Duration(milliseconds: 20));
        expect(live.typed, [
          layeredVerbatim(
            AckPicker(random: math.Random(7)).next(AgentLanguage.zh),
          ),
        ]);
        async.elapse(const Duration(seconds: 2));
        expect(live.typed, hasLength(1));
        expect(cues, 0);
        agent.answer('好。');
        async.flushMicrotasks();
        answer.then((_) {});
        async.elapse(const Duration(seconds: 2));
        expect(cues, 0);
      });
    });
  });

  group('speaking over the app', () {
    test('the person speaking stops the voice and what is queued', () {
      fakeAsync((async) {
        final r = Rig();
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读');
        async.flushMicrotasks();
        r.agent.answer('一句。两句。三句。');
        async.flushMicrotasks();
        expect(r.speech.spoken, ['一句。']);
        // The person starts to speak (not the voice's echo).
        r.live.parts.onInputText!('等一下我');
        async.flushMicrotasks();
        expect(r.speech.stops, greaterThan(0));
        expect(r.speaking, [true, false]);
        async.elapse(const Duration(seconds: 5));
        expect(r.speech.spoken, ['一句。'], reason: 'the rest is not said');
        expect(r.completes, 0);
        expect(r.interrupts, 1);
        // And what they said is a turn of its own.
        r.live.parts.onGenerating!();
        async.elapse(const Duration(milliseconds: 100));
        expect(r.agent.asked.last, '等一下我');
      });
    });

    test('Live\'s own interruption does the same', () {
      fakeAsync((async) {
        final r = Rig();
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读');
        async.flushMicrotasks();
        r.agent.answer('一句。两句。');
        async.flushMicrotasks();
        r.live.parts.onInterrupted!();
        async.elapse(const Duration(seconds: 5));
        expect(r.speech.spoken, ['一句。']);
      });
    });

    test('an ask that has not answered is cut short and never spoken', () {
      fakeAsync((async) {
        final r = Rig();
        final asking = <int>[];
        r.session.addAskingListener(asking.add);
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读一下动态');
        async.flushMicrotasks();
        expect(asking, [1]);
        // The person speaks before the agent has said anything.
        r.live.parts.onInputText!('算了');
        async.flushMicrotasks();
        expect(r.agent.cancels, 1);
        expect(asking, [1, 0]);
        // The agent's answer (it was already on its way) is not spoken.
        r.agent.answer('动态里有 3 条。');
        async.elapse(const Duration(seconds: 3));
        expect(r.speech.spoken, isEmpty);
        // The new words are asked.
        r.live.parts.onGenerating!();
        async.elapse(const Duration(milliseconds: 100));
        expect(r.agent.asked, ['读一下动态', '算了']);
        r.agent.answer('好。');
        async.flushMicrotasks();
        expect(r.speech.spoken, ['好。']);
      });
    });

    test('the voice\'s own echo is neither a barge-in nor a question', () {
      fakeAsync((async) {
        final r = Rig();
        r.session.connect();
        async.flushMicrotasks();
        r.session.sendText('读');
        async.flushMicrotasks();
        r.agent.answer('回复八戒，晚上看。要发吗？');
        async.flushMicrotasks();
        // The microphone hears the voice, and Live transcribes it a little
        // differently.
        r.live.parts.onInputText!('回复八戒晚上看');
        r.live.parts.onGenerating!();
        async.elapse(const Duration(milliseconds: 200));
        expect(r.speech.stops, 0);
        expect(r.agent.cancels, 0);
        expect(r.agent.asked, ['读']);
        async.elapse(const Duration(seconds: 5));
        expect(r.speech.spoken, ['回复八戒，晚上看。', '要发吗？']);
        // Just after the voice, "确认" is the person's.
        r.live.parts.onInputText!('确认');
        r.live.parts.onGenerating!();
        async.elapse(const Duration(milliseconds: 200));
        expect(r.agent.asked, ['读', '确认']);
      });
    });

    test('closing stops the voice', () {
      fakeAsync((async) {
        final r = Rig();
        r.session.connect();
        async.flushMicrotasks();
        r.session.speak('一句。两句。');
        async.flushMicrotasks();
        r.session.close();
        async.elapse(const Duration(seconds: 5));
        expect(r.speech.spoken, ['一句。']);
        expect(r.live.closes, 1);
      });
    });
  });

  group('Live only listens', () {
    GeminiLiveSession live({bool listenOnly = true}) => GeminiLiveSession(
      apiKey: 'k',
      systemPrompt: layeredListenPrompt,
      tools: const [],
      onToolCall: (n, a) async => {},
      listenOnly: listenOnly,
      fast: true,
    );

    test(
      'the setup asks for text, no voice, no tools, still the transcript',
      () {
        final setup =
            live().setupMessage(
                  'm',
                  affective: true,
                  nonBlocking: false,
                )['setup']!
                as Map;
        final gen = setup['generationConfig']! as Map;
        expect(gen['responseModalities'], ['TEXT']);
        expect(gen.containsKey('speechConfig'), isFalse);
        expect(setup.containsKey('tools'), isFalse);
        expect(setup.containsKey('outputAudioTranscription'), isFalse);
        expect(setup.containsKey('enableAffectiveDialog'), isFalse);
        expect(setup['inputAudioTranscription'], isNotNull);
        expect(
          (setup['realtimeInputConfig']! as Map)['automaticActivityDetection'],
          isNotNull,
        );
      },
    );

    test('the relay\'s setup is as before', () {
      final setup =
          live(
                listenOnly: false,
              ).setupMessage('m', affective: true, nonBlocking: false)['setup']!
              as Map;
      expect((setup['generationConfig']! as Map)['responseModalities'], [
        'AUDIO',
      ]);
      expect(setup['enableAffectiveDialog'], isTrue);
    });
  });

  test('the mode names parse', () {
    expect(LayeredVoiceMode.parse('app'), LayeredVoiceMode.appSpeaks);
    expect(LayeredVoiceMode.parse('relay'), LayeredVoiceMode.liveRelays);
    expect(LayeredVoiceMode.parse('appSpeaks'), LayeredVoiceMode.appSpeaks);
    expect(LayeredVoiceMode.parse('x'), isNull);
    expect(UserTurnForwarder.hasWords('。！'), isFalse);
  });
}
