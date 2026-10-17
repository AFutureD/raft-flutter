import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/app_speech.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_result.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/orb_eval_scripted.dart';

/// The layered harness: the real LayeredVoiceSession with fakes for the two
/// models, typed to like Live is typed to; what it records, and the check that
/// the voice model says the agent's words.

/// Live, typed to: it asks the agent for the text (or answers itself) and
/// "speaks" [speak] of what came back.
class FakeLive implements VoiceSession {
  FakeLive(
    this.parts, {
    required this.ask,
    required this.speak,
    this.filler = false,
    this.midComplete = false,
  });
  final LiveParts parts;

  /// Whether it hands the text to the agent.
  final bool ask;

  /// What it says, given the agent's say.
  final String Function(String say) speak;

  /// It says "我看一下。" and ends that turn before it asks (what the real
  /// model did).
  final bool filler;

  /// It ends a turn while the ask is still out.
  final bool midComplete;

  @override
  bool get connected => true;
  @override
  String? get model => 'live-fake';
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
  void addContext(String text) {}
  @override
  Future<void> close() async {}

  @override
  void sendText(String text) => unawaited(_turn(text));

  Future<void> _turn(String text) async {
    var say = '我自己答的。';
    if (filler) {
      parts.onOutputText?.call('我看一下。');
      parts.onTurnComplete?.call();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (ask) {
      if (midComplete) {
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 100),
            () => parts.onTurnComplete?.call(),
          ),
        );
      }
      final r = await parts.onToolCall('ask_agent', {'request': text});
      say = '${r['say']}';
    }
    parts.onOutputText?.call(ask ? speak(say) : say);
    parts.onTurnComplete?.call();
  }
}

/// The agent behind Live: it opens the channel with the orb's own `navigate`
/// and says [words].
class FakeAgent implements VoiceSession {
  FakeAgent(
    this.parts,
    this.words, {
    this.delay = Duration.zero,
    this.hang = false,
  });
  final AgentParts parts;
  final String words;
  final Duration delay;

  /// It never answers.
  final bool hang;

  @override
  bool get connected => true;
  @override
  String? get model => 'agent-fake';
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
  void sendText(String text) => unawaited(() async {
    if (hang) await Completer<void>().future;
    await Future<void>.delayed(delay);
    await parts.onToolCall('navigate', {'channel_id': evalId('raft-flutter')});
    parts.onOutputText.call(words);
    parts.onTurnComplete.call();
  }());
}

void main() {
  late Directory reports;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentOrbPreference.instance.resetForTest();
    // This file is about the relay; the app speaking has its own file.
    AgentOrbPreference.instance.setLayeredVoiceMode(
      LayeredVoiceMode.liveRelays,
    );
    reports = Directory.systemTemp.createTempSync('orb-eval-layered');
  });
  tearDown(() => reports.deleteSync(recursive: true));

  const agentSays = 'Cody 在问第 10 步能不能合入，等了 20 分钟。';

  VoiceSessionFactory layered({
    bool ask = true,
    String Function(String)? speak,
    bool filler = false,
    bool midComplete = false,
    Duration agentDelay = Duration.zero,
    bool hang = false,
  }) =>
      ({
        required provider,
        required apiKey,
        required systemPrompt,
        required tools,
        required onToolCall,
        required voice,
        reasoning = AgentReasoning.low,
        onAudio,
        onInputText,
        onOutputText,
        onTurnComplete,
        onInterrupted,
        onClosed,
        playbackPending,
        steering,
      }) => LayeredVoiceSession(
        apiKey: apiKey,
        systemPrompt: systemPrompt,
        tools: tools,
        onToolCall: onToolCall,
        steering: steering!,
        voice: voice,
        onOutputText: onOutputText,
        onTurnComplete: onTurnComplete,
        onClosed: onClosed,
        liveBuilder: (p) => FakeLive(
          p,
          ask: ask,
          speak: speak ?? (say) => '我看一下。$say',
          filler: filler,
          midComplete: midComplete,
        ),
        agentBuilder: (p) =>
            FakeAgent(p, agentSays, delay: agentDelay, hang: hang),
      );

  OrbEvalScenario scenario({List<OrbEvalCheck> checks = const []}) =>
      OrbEvalScenario(
        id: 'A1',
        title: '去频道看谁找我',
        start: OrbEvalStart.home,
        data: () {
          final d = OrbEvalData.cast();
          d.say(
            'raft-flutter',
            evalCody,
            '@Sam 第 10 步可以合入吗？',
            mentions: [evalMe],
          );
          return d;
        },
        say: const ['去 raft-flutter 看看谁找我'],
        checks: [
          OrbEvalCheck.tool(
            'navigate',
            args: {'channel_id': evalId('raft-flutter')},
          ),
          ...checks,
        ],
      );

  Future<Map<String, dynamic>> run(
    WidgetTester t,
    VoiceSessionFactory factory, {
    Duration turnTimeout = const Duration(seconds: 45),
  }) async {
    await mountEvalPage(
      t,
      reports: reports,
      scenarios: [scenario()],
      sessionFactory: factory,
      runs: 1,
      turnTimeout: turnTimeout,
      harness: OrbEvalHarness.layered,
    );
    await finishEvalRun(t);
    final json = readEvalReport(reports);
    await t.pumpWidget(const SizedBox());
    return json;
  }

  testWidgets('Live asks the agent and says its words: passes, and the turn '
      'records the ask, the words and the time', (t) async {
    final json = await run(t, layered());

    expect(json['harness'], 'layered');
    expect(
      json['combination'],
      '语音模型 + 文字 Agent：语音模型 Gemini Live（live-fake） · Live 转述 · Agent 引擎 Genkit'
      ' 模型 agent-fake 推理 低',
    );
    expect(json['model'], 'live-fake', reason: 'the Live model');
    expect(json['agentModel'], 'agent-fake');
    expect(json['engine'], 'genkit');
    expect(json['latencyP50Ms'], greaterThan(0));
    final scenarioJson = (json['scenarios'] as List).single as Map;
    expect(scenarioJson['outcome'], 'passed');
    final turn =
        ((((scenarioJson['results'] as List).single as Map)['turns'] as List)
                .single
            as Map);
    expect(turn['text'], '我看一下。$agentSays');
    expect(turn['ms'], greaterThan(0));
    // What the person waits for: the first word after the agent's answer.
    expect(turn['firstAudioMs'], greaterThan(0));
    expect(turn['askMs'], isNotNull);
    for (final k in [
      'latencyP90Ms',
      'firstAudioP50Ms',
      'firstAudioP90Ms',
      'askP50Ms',
      'askP90Ms',
    ]) {
      expect(json[k], isNotNull, reason: k);
    }
    final ask = (turn['asks'] as List).single as Map;
    expect(ask['request'], '去 raft-flutter 看看谁找我');
    expect(ask['say'], agentSays);
    expect(ask['ms'], isNotNull);
    // The agent's own tool call is in the turn like in the other harnesses.
    expect((turn['tools'] as List).map((c) => (c as Map)['name']), [
      'navigate',
    ]);

    final md = File(
      '${reports.listSync().whereType<Directory>().single.path}/report.md',
    ).readAsStringSync();
    expect(md, contains('通道 layered'));
    expect(md, contains('组合：语音模型 + 文字 Agent'));
    expect(md, contains('模型 live-fake'));
    expect(md, contains('引擎 genkit'));
    expect(md, contains('Agent 模型 agent-fake'));
    expect(md, contains('时延 p50'));
    expect(md, contains('p90'));
    expect(md, contains('首声 p50'));
    expect(md, contains('Agent 耗时 p50'));
    expect(
      md,
      contains('ask_agent(request=去 raft-flutter 看看谁找我) → say：$agentSays'),
    );
    expect(md, contains('Live 说：我看一下。$agentSays'));
  });

  testWidgets('spaces and punctuation do not matter when Live says the words', (
    t,
  ) async {
    final json = await run(
      t,
      layered(speak: (say) => say.replaceAll('，', ' ').replaceAll('。', '')),
    );
    expect(((json['scenarios'] as List).single as Map)['outcome'], 'passed');
  });

  testWidgets('Live that answers by itself fails the check, with the line', (
    t,
  ) async {
    final json = await run(t, layered(ask: false));
    final s = (json['scenarios'] as List).single as Map;
    expect(s['outcome'], 'failed');
    final failed = (s['failedChecks'] as List).map((c) => (c as Map)['check']);
    expect(failed, anyElement(startsWith('说出了 Agent 那句话的关键信息')));
  });

  testWidgets('Live that puts the agent\'s words in its own fails the check', (
    t,
  ) async {
    final json = await run(t, layered(speak: (say) => 'Cody 找你，问能不能合入。'));
    final s = (json['scenarios'] as List).single as Map;
    expect(s['outcome'], 'failed');
    final result = (s['results'] as List).single as Map;
    final reason = ((result['failures'] as List).single as Map)['reason'];
    expect(reason, contains('漏了：数字 10'));
    expect(reason, contains(agentSays));
  });

  testWidgets('a filler and its turn end before the ask do not end the '
      'turn: the ask is waited for', (t) async {
    final json = await run(
      t,
      layered(filler: true, agentDelay: const Duration(seconds: 1)),
    );
    final s = (json['scenarios'] as List).single as Map;
    expect(s['outcome'], 'passed');
    final turn =
        (((s['results'] as List).single as Map)['turns'] as List).single as Map;
    expect((turn['asks'] as List), hasLength(1));
    expect(turn['text'], contains(agentSays));
    expect((turn['tools'] as List).map((c) => (c as Map)['name']), [
      'navigate',
    ]);
  });

  testWidgets('a turn end while the ask is out is not the end', (t) async {
    final json = await run(
      t,
      layered(midComplete: true, agentDelay: const Duration(seconds: 1)),
    );
    final s = (json['scenarios'] as List).single as Map;
    expect(s['outcome'], 'passed');
    final turn =
        (((s['results'] as List).single as Map)['turns'] as List).single as Map;
    expect(turn['text'], contains(agentSays));
  });

  testWidgets('an ask that never comes back: the turn fails with that '
      'reason, after the time', (t) async {
    final json = await run(
      t,
      layered(hang: true),
      turnTimeout: const Duration(seconds: 3),
    );
    final s = (json['scenarios'] as List).single as Map;
    expect(s['outcome'], 'failed');
    final result = (s['results'] as List).single as Map;
    expect(result['error'], contains('ask_agent 发起了 1 次，还有 1 个没回来'));
  });

  testWidgets('the header names Gemini and the Live model, not the voice '
      'settings', (t) async {
    final json = await run(t, layered());
    expect(json['provider'], 'gemini');
    expect(json['model'], 'live-fake');
  });

  testWidgets('a filler that is nothing like the say is recorded as one', (
    t,
  ) async {
    final json = await run(t, layered(speak: (say) => '我看一下。'));
    final s = (json['scenarios'] as List).single as Map;
    final turn =
        (((s['results'] as List).single as Map)['turns'] as List).single as Map;
    expect(turn['liveFiller'], isTrue);
    // (And the check fails it: the say was not spoken.)
    expect(s['outcome'], 'failed');
    final md = File(
      '${reports.listSync().whereType<Directory>().single.path}/report.md',
    ).readAsStringSync();
    expect(md, contains('Live 说了垫话'));
  });

  testWidgets('a turn that says the words is not a filler turn', (t) async {
    final json = await run(t, layered());
    final turn =
        ((((json['scenarios'] as List).single as Map)['results'] as List).single
                as Map)['turns']
            as List;
    expect((turn.single as Map).containsKey('liveFiller'), isFalse);
  });

  group('the app speaks', () {
    VoiceSessionFactory appSpeaks() =>
        ({
          required provider,
          required apiKey,
          required systemPrompt,
          required tools,
          required onToolCall,
          required voice,
          reasoning = AgentReasoning.low,
          onAudio,
          onInputText,
          onOutputText,
          onTurnComplete,
          onInterrupted,
          onClosed,
          playbackPending,
          steering,
        }) => LayeredVoiceSession(
          apiKey: apiKey,
          systemPrompt: systemPrompt,
          tools: tools,
          onToolCall: onToolCall,
          steering: steering!,
          voice: voice,
          mode: LayeredVoiceMode.appSpeaks,
          speech: RecordingSpeech(),
          listen: false,
          onInputText: onInputText,
          onOutputText: onOutputText,
          onTurnComplete: onTurnComplete,
          onInterrupted: onInterrupted,
          onClosed: onClosed,
          liveBuilder: (p) => throw StateError('Live is not built to listen'),
          agentBuilder: (p) => FakeAgent(p, agentSays),
        );

    setUp(
      () => AgentOrbPreference.instance.setLayeredVoiceMode(
        LayeredVoiceMode.appSpeaks,
      ),
    );

    testWidgets('the typed words reach the agent, the voice is asked for '
        'the say, and the record shows it', (t) async {
      final json = await run(t, appSpeaks());
      expect(json['voiceMode'], 'appSpeaks');
      final s = (json['scenarios'] as List).single as Map;
      expect(s['outcome'], 'passed', reason: '${s['failedChecks']}');
      final turn =
          (((s['results'] as List).single as Map)['turns'] as List).single
              as Map;
      expect(turn['spoken'], ['Cody 在问第 10 步能不能合入，等了 20 分钟。']);
      expect(turn['text'], agentSays);
      // Turn end to the start of the first sentence.
      expect(turn['firstAudioMs'], greaterThan(0));
      expect(turn['askMs'], isNotNull);
      final ask = (turn['asks'] as List).single as Map;
      expect(ask['request'], '去 raft-flutter 看看谁找我');
      final md = File(
        '${reports.listSync().whereType<Directory>().single.path}/report.md',
      ).readAsStringSync();
      expect(md, contains('语音 appSpeaks'));
      expect(md, contains('App 朗读：$agentSays'));
    });
  });

  group('filler and fast path in the record', () {
    OrbEvalTurn turn(String text, List<String> says) {
      final t = OrbEvalTurn('x')..addText(text);
      for (final say in says) {
        t.asks.add(OrbEvalAsk(request: 'x', say: say, millis: 1));
      }
      return t;
    }

    const say = 'Cody 在问第 10 步能不能合入，等了 20 分钟。';

    test('a known wait-word that is nothing like the say', () {
      for (final w in ['我看一下。', '稍等一下', 'Let me check.', '让我查一下', '马上']) {
        expect(orbEvalLiveFiller(turn(w, [say])), isTrue, reason: w);
      }
    });

    test(
      'not when it carries the say, or is something else, or asked nothing',
      () {
        expect(orbEvalLiveFiller(turn('我看一下。$say', [say])), isFalse);
        expect(orbEvalLiveFiller(turn('好的。', [say])), isFalse);
        expect(orbEvalLiveFiller(turn('', [say])), isFalse);
        expect(orbEvalLiveFiller(turn('我看一下。', [])), isFalse);
      },
    );

    test('a turn the app did by itself says so in the json', () {
      final t = turn('好', [])..fastPath = 'next';
      expect(t.toJson()['fastPath'], 'next');
      expect(turn('好', []).toJson().containsKey('fastPath'), isFalse);
    });
  });
}
