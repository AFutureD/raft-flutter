import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_mode/app_speech.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/key_info.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_key_info.dart';

/// Live relays the agent's answer in its own words. When the answer asks the
/// person to confirm a card, what Live said is checked for the card's key
/// information, and the app says the line itself when something is missing.
/// No other answer is ever spoken again.

class RelayLive implements VoiceSession {
  RelayLive(this.parts);
  final LiveParts parts;
  final sent = <String>[];

  @override
  bool get connected => true;
  @override
  String? get model => 'live';
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
  void sendText(String text) => sent.add(text);
  @override
  void addContext(String text) {}
  @override
  Future<void> close() async {}

  /// Live asks the agent, and the answer comes back.
  Future<Map<String, Object?>> ask(String request) =>
      parts.onToolCall('ask_agent', {'request': request});
  void says(String words) => parts.onOutputText!(words);
  void done() => parts.onTurnComplete!();
}

class SayingAgent implements VoiceSession {
  SayingAgent(this.parts, this.say, [this.delay = Duration.zero]);
  final AgentParts parts;
  final String say;

  /// How long it takes to answer.
  final Duration delay;

  @override
  bool get connected => true;
  @override
  String? get model => 'agent';
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
  void sendText(String text) {
    void answer() {
      parts.onOutputText(say);
      parts.onTurnComplete();
    }

    if (delay == Duration.zero) {
      answer();
    } else {
      Timer(delay, answer);
    }
  }
}

const _line = '回复 Cody：晚上看，要发吗？';

KeyInfo _card() => orbCardKeyInfoOfResult('reply_in_thread', const {}, {
  'status': 'needs_confirmation',
  'preview': {
    'summary': '回复 Cody 的消息：“晚上看”',
    'changes': ['回复: Cody：第 10 步可以合入吗 → Cody：第 10 步可以合入吗', '内容:  → 晚上看'],
  },
})!;

class Rig {
  Rig({
    this.card = true,
    bool withSpeech = true,
    String say = _line,
    Duration perSentence = Duration.zero,
    Duration delay = Duration.zero,
  }) {
    speech = withSpeech ? RecordingSpeech(perSentence: perSentence) : null;
    session = LayeredVoiceSession(
      apiKey: 'k',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      steering: AgentSteering(
        scope: () => const AgentScope(systemPrompt: '', tools: []),
        confirmation: () => card ? _card() : null,
      ),
      speech: speech,
      onAudio: (pcm) => audio++,
      onOutputText: captions.add,
      onTurnComplete: () => completes++,
      onInterrupted: () => interrupts++,
      liveBuilder: (p) => live = RelayLive(p),
      agentBuilder: (p) => SayingAgent(p, say, delay),
    )..onCorrection = ((say, missing) => corrections.add(missing));
    session.addSpeakingListener(speaking.add);
  }

  final bool card;
  late final RecordingSpeech? speech;
  late final LayeredVoiceSession session;
  late RelayLive live;
  final captions = <String>[];
  final corrections = <List<String>>[];
  final speaking = <bool>[];
  int completes = 0;
  int interrupts = 0;
  int audio = 0;

  /// Live asks and tells [words] after the answer, then ends its turn.
  Future<void> relay(FakeAsync async, String? words) async {
    session.connect();
    async.flushMicrotasks();
    final answer = live.ask('回他晚上看');
    async.flushMicrotasks();
    await answer;
    if (words != null) live.says(words);
    live.done();
  }
}

void main() {
  test('Live\'s words carry the card: nothing is said again', () {
    fakeAsync((async) {
      final r = Rig();
      r.relay(async, '我准备回复 Cody，说晚上看，要发吗？');
      async.elapse(const Duration(seconds: 2));
      expect(r.corrections, isEmpty);
      expect(r.speech!.spoken, isEmpty);
      expect(r.completes, 1, reason: 'the turn is over after the check');
      expect(r.interrupts, 0);
    });
  });

  test('a missing question, name or content: the app says the line itself', () {
    for (final words in [
      '我准备回复 Cody，说晚上看。',
      '我准备回复他，说晚上看，要发吗？',
      '我准备回复 Cody，要发吗？',
      '好的。',
    ]) {
      fakeAsync((async) {
        final r = Rig();
        r.relay(async, words);
        // Not before Live's late words could have come.
        async.elapse(const Duration(milliseconds: 600));
        expect(r.speech!.spoken, isEmpty, reason: words);
        expect(r.completes, 0, reason: words);
        async.elapse(const Duration(seconds: 1));
        expect(r.corrections, hasLength(1), reason: words);
        expect(r.speech!.spoken.join(), _line, reason: words);
        expect(r.interrupts, 1, reason: 'Live\'s own voice is cut');
        expect(r.completes, 1);
      });
    }
  });

  test('the correction names what was missing', () {
    fakeAsync((async) {
      final r = Rig();
      r.relay(async, '我准备回复 Cody，说晚上看。');
      async.elapse(const Duration(seconds: 2));
      expect(r.corrections.single, ['问他要不要做（等他确认）']);
    });
  });

  test('an answer that is no card is never said again, whatever Live said', () {
    fakeAsync((async) {
      final r = Rig(card: false, say: 'Cody 问第 10 步能不能合入。');
      r.relay(async, '嗯嗯。');
      async.elapse(const Duration(seconds: 5));
      expect(r.corrections, isEmpty);
      expect(r.speech!.spoken, isEmpty);
      expect(r.completes, 1);
    });
  });

  test('without a voice of its own, Live is asked to say it once more', () {
    fakeAsync((async) {
      final r = Rig(withSpeech: false);
      r.relay(async, '好的。');
      async.elapse(const Duration(seconds: 2));
      expect(r.corrections, hasLength(1));
      expect(r.live.sent, [layeredVerbatim(_line)]);
      expect(r.completes, 1);
      // That second telling is Live\'s turn, and not checked again.
      r.live.says('回复 Cody，晚上看，要发吗？');
      r.live.done();
      async.elapse(const Duration(seconds: 2));
      expect(r.live.sent, hasLength(1));
    });
  });

  test('the person speaking over Live cancels the check', () {
    fakeAsync((async) {
      final r = Rig();
      r.relay(async, '好的。');
      async.elapse(const Duration(milliseconds: 300));
      r.live.parts.onInterrupted!();
      async.elapse(const Duration(seconds: 5));
      expect(r.corrections, isEmpty);
      expect(r.speech!.spoken, isEmpty);
      expect(r.completes, 1, reason: 'the turn that was waiting is over');
    });
  });

  test('a turn end before Live has said anything is waited out; the words '
      'that come later count', () {
    fakeAsync((async) {
      final r = Rig();
      r.relay(async, null);
      async.elapse(const Duration(seconds: 2));
      expect(r.corrections, isEmpty, reason: 'not yet: it may still speak');
      r.live.says('我准备回复 Cody，说晚上看，要发吗？');
      r.live.done();
      async.elapse(const Duration(seconds: 2));
      expect(r.corrections, isEmpty);
      expect(r.completes, 1);
    });
  });

  test('Live that says nothing at all is corrected in the end', () {
    fakeAsync((async) {
      final r = Rig();
      r.relay(async, null);
      async.elapse(const Duration(seconds: 6));
      expect(r.corrections, hasLength(1));
      expect(r.speech!.spoken.join(), _line);
    });
  });
  group('the acknowledgment while the agent works', () {
    const ack = '我看一下。';

    test('a slow ask is acknowledged by the app once, before Live speaks; '
        'a quick one is not', () {
      fakeAsync((async) {
        final r = Rig(
          card: false,
          say: '有 3 条。',
          delay: const Duration(seconds: 3),
        );
        r.session.connect();
        async.flushMicrotasks();
        r.live.ask('读一下动态');
        async.elapse(const Duration(milliseconds: 340));
        expect(r.speech!.spoken, isEmpty);
        async.elapse(const Duration(milliseconds: 20));
        expect(r.speech!.spoken, [ack]);
        async.elapse(const Duration(seconds: 1));
        expect(r.speech!.spoken, [ack], reason: 'once');
        expect(r.captions, isEmpty);
        expect(r.completes, 0);
      });
      fakeAsync((async) {
        final r = Rig(
          card: false,
          say: '有 3 条。',
          delay: const Duration(milliseconds: 200),
        );
        r.session.connect();
        async.flushMicrotasks();
        r.live.ask('读一下动态');
        async.elapse(const Duration(seconds: 2));
        expect(r.speech!.spoken, isEmpty);
      });
    });

    test('Live starting to answer cuts the acknowledgment: no overlap', () {
      for (final byAudio in [false, true]) {
        fakeAsync((async) {
          final r = Rig(
            card: false,
            say: '有 3 条。',
            perSentence: const Duration(seconds: 2),
            delay: const Duration(milliseconds: 800),
          );
          r.session.connect();
          async.flushMicrotasks();
          r.live.ask('读一下动态');
          async.elapse(const Duration(milliseconds: 900));
          // The answer is back; the acknowledgment is still being said.
          expect(r.speech!.spoken, [ack]);
          expect(r.speaking, [true]);
          expect(r.speech!.stops, 0);
          if (byAudio) {
            r.live.parts.onAudio!(Uint8List(4));
          } else {
            r.live.says('有三条。');
          }
          expect(r.speech!.stops, 1, reason: 'byAudio: $byAudio');
          expect(r.speaking, [true, false]);
          expect(byAudio ? r.audio : r.captions.length, 1);
          async.elapse(const Duration(seconds: 5));
          expect(r.speech!.spoken, [ack]);
        });
      }
    });

    test('Live answering after the acknowledgment was said stops nothing', () {
      fakeAsync((async) {
        final r = Rig(
          card: false,
          say: '有 3 条。',
          delay: const Duration(seconds: 3),
        );
        r.session.connect();
        async.flushMicrotasks();
        r.live.ask('读一下动态');
        async.elapse(const Duration(seconds: 3, milliseconds: 100));
        expect(r.speaking, [true, false]);
        r.live.says('有三条。');
        expect(r.speech!.stops, 0);
        expect(r.captions, ['有三条。']);
      });
    });

    test('the person speaking over Live cuts it too', () {
      fakeAsync((async) {
        final r = Rig(
          card: false,
          perSentence: const Duration(seconds: 2),
          delay: const Duration(seconds: 5),
        );
        r.session.connect();
        async.flushMicrotasks();
        r.live.ask('读一下动态');
        async.elapse(const Duration(milliseconds: 500));
        expect(r.speaking, [true]);
        r.live.parts.onInterrupted!();
        expect(r.speech!.stops, 1);
        expect(r.speaking, [true, false]);
      });
    });

    test('without a voice of its own, the click cue is all there is', () {
      fakeAsync((async) {
        final r = Rig(
          card: false,
          withSpeech: false,
          delay: const Duration(seconds: 3),
        );
        var cues = 0;
        r.session.onSlow = (() => cues++);
        r.session.connect();
        async.flushMicrotasks();
        r.live.ask('读一下动态');
        async.elapse(const Duration(milliseconds: 700));
        expect(cues, 0);
        async.elapse(const Duration(milliseconds: 200));
        expect(cues, 1);
        async.elapse(const Duration(seconds: 1));
        expect(cues, 1);
      });
    });

    test('with a voice, the acknowledgment is the cue: no click as well', () {
      fakeAsync((async) {
        final r = Rig(card: false, delay: const Duration(seconds: 3));
        var cues = 0;
        r.session.onSlow = (() => cues++);
        r.session.connect();
        async.flushMicrotasks();
        r.live.ask('读一下动态');
        async.elapse(const Duration(seconds: 2));
        expect(r.speech!.spoken, [ack]);
        expect(cues, 0);
      });
    });
  });
}
