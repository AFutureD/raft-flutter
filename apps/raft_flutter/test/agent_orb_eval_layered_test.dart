import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
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
  FakeLive(this.parts, {required this.ask, required this.speak});
  final LiveParts parts;

  /// Whether it hands the text to the agent.
  final bool ask;

  /// What it says, given the agent's say.
  final String Function(String say) speak;

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
    if (ask) {
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
  FakeAgent(this.parts, this.words);
  final AgentParts parts;
  final String words;

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
    reports = Directory.systemTemp.createTempSync('orb-eval-layered');
  });
  tearDown(() => reports.deleteSync(recursive: true));

  const agentSays = 'Cody 在问第 10 步能不能合入，等了 20 分钟。';

  VoiceSessionFactory layered({
    bool ask = true,
    String Function(String)? speak,
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
        liveBuilder: (p) =>
            FakeLive(p, ask: ask, speak: speak ?? (say) => '我看一下。$say'),
        agentBuilder: (p) => FakeAgent(p, agentSays),
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
    VoiceSessionFactory factory,
  ) async {
    await mountEvalPage(
      t,
      reports: reports,
      scenarios: [scenario()],
      sessionFactory: factory,
      runs: 1,
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
    expect(md, contains('模型 live-fake'));
    expect(md, contains('引擎 genkit'));
    expect(md, contains('Agent 模型 agent-fake'));
    expect(md, contains('时延 p50'));
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
    expect(failed, anyElement(startsWith('Live 调用 ask_agent，并一字不差地说出 say')));
  });

  testWidgets('Live that puts the agent\'s words in its own fails the check', (
    t,
  ) async {
    final json = await run(t, layered(speak: (say) => 'Cody 找你，问能不能合入。'));
    final s = (json['scenarios'] as List).single as Map;
    expect(s['outcome'], 'failed');
    final result = (s['results'] as List).single as Map;
    final reason = ((result['failures'] as List).single as Map)['reason'];
    expect(reason, contains('没有原样说出'));
    expect(reason, contains(agentSays));
  });

  group('the check on its own', () {
    OrbEvalRun runOf(List<OrbEvalTurn> turns) =>
        OrbEvalRun(ids: {})..turns.addAll(turns);
    OrbEvalTurn turn(String line, String text, List<OrbEvalAsk> asks) {
      final t = OrbEvalTurn(line)..addText(text);
      t.asks.addAll(asks);
      return t;
    }

    final check = OrbEvalCheck.liveSpokeAgentWords();

    test('every user turn needs an ask whose say is in what Live said', () {
      expect(
        check.test(
          runOf([
            turn('开始驾驶模式', '好，驾驶模式。', [
              const OrbEvalAsk(request: '开始驾驶模式', say: '好，驾驶模式。', millis: 5),
            ]),
            turn('下一件', '稍等。Alice 问你周五。', [
              const OrbEvalAsk(request: '下一件', say: 'Alice 问你周五', millis: 5),
            ]),
          ]),
        ),
        isNull,
      );
    });

    test('an empty say needs no words; an event turn needs no ask', () {
      expect(
        check.test(
          runOf([
            turn('确认', '', [
              const OrbEvalAsk(request: '确认', say: '', millis: 5),
            ]),
            turn('（事件）', '', []),
          ]),
        ),
        isNull,
      );
    });

    test('no ask, or other words, fail with the line', () {
      expect(check.test(runOf([turn('下一件', 'Alice。', [])])), contains('下一件'));
      expect(
        check.test(
          runOf([
            turn('下一件', 'Alice 找你。', [
              const OrbEvalAsk(request: '下一件', say: 'Alice 问你周五', millis: 5),
            ]),
          ]),
        ),
        contains('没有原样说出'),
      );
    });

    test('every say of a turn with several asks must be spoken', () {
      expect(
        check.test(
          runOf([
            turn('x', '甲。乙。', [
              const OrbEvalAsk(request: 'x', say: '甲', millis: 1),
              const OrbEvalAsk(request: 'x', say: '丙', millis: 1),
            ]),
          ]),
        ),
        contains('丙'),
      );
    });
  });
}
