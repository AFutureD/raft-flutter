import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_launcher.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_result.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'layered_voice_realtime_test.dart' show FakeVoice;
import 'support/orb_eval_scripted.dart';

/// The layered harness with OpenAI Realtime or Grok Voice as the voice
/// service: the turn ends when the app has had the answer said (not at the
/// voice session's own response ends), the first sound and the first
/// sentence of the answer are timed, the lead-in is recorded, and the link
/// names the voice service.

const _says = 'Cody 在问第 10 步能不能合入，等了 20 分钟。';

/// The text agent: opens the channel with the orb's own tool, optionally
/// streams its words before it ends the turn.
class StreamingAgent implements VoiceSession {
  StreamingAgent(this.parts, {this.stream = false});
  final AgentParts parts;
  final bool stream;

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
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (stream) {
      parts.onDraft?.call('Cody 在问第 10 步能不能合入，');
      parts.onDraft?.call('等了 20 分钟。');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    parts.onOutputText.call(_says);
    parts.onTurnComplete.call();
  }());
}

void main() {
  late Directory reports;
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final stored = <String, String>{};

  setUp(() async {
    stored.clear();
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
    SharedPreferences.setMockInitialValues({});
    // The voice services' own keys (the Gemini one is the page's).
    await OpenAiVoiceKey.instance.save('sk-proj-abcdefghijklmnopqrstuvwxyz01');
    await GrokVoiceKey.instance.save('xai-abcdefghijklmnopqrstuvwxyz0123');
    AgentOrbPreference.instance.resetForTest();
    AgentOrbPreference.instance.setLayeredVoiceMode(
      LayeredVoiceMode.liveRelays,
    );
    reports = Directory.systemTemp.createTempSync('orb-eval-realtime');
  });
  tearDown(() async {
    await OpenAiVoiceKey.instance.clear();
    await GrokVoiceKey.instance.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secure, null);
    reports.deleteSync(recursive: true);
  });

  OrbEvalScenario scenario() => OrbEvalScenario(
    id: 'A1',
    title: '去频道看谁找我',
    start: OrbEvalStart.home,
    data: () {
      final d = OrbEvalData.cast();
      d.say('raft-flutter', evalCody, '@Sam 第 10 步可以合入吗？', mentions: [evalMe]);
      return d;
    },
    say: const ['去 raft-flutter 看看谁找我'],
    checks: [
      OrbEvalCheck.tool(
        'navigate',
        args: {'channel_id': evalId('raft-flutter')},
      ),
    ],
  );

  VoiceSessionFactory realtime(
    WidgetTester t, {
    bool stream = false,
    bool exact = false,
    bool leadStarts = true,
    List<FakeVoice>? made,
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
        // The service the orb resolved from the page (the link).
        voiceProvider: provider,
        apiKey: apiKey,
        agentApiKey: 'gemini',
        systemPrompt: systemPrompt,
        tools: tools,
        onToolCall: onToolCall,
        steering: steering!,
        voice: voice,
        nowMs: () => t.binding.clock.now().millisecondsSinceEpoch,
        onAudio: onAudio,
        onOutputText: onOutputText,
        onTurnComplete: onTurnComplete,
        onClosed: onClosed,
        liveBuilder: (p) {
          final v = FakeVoice(
            p,
            exact: exact,
            startAfter: const Duration(milliseconds: 200),
            playFor: const Duration(milliseconds: 300),
            leadStarts: leadStarts,
          );
          made?.add(v);
          return v;
        },
        agentBuilder: (p) => StreamingAgent(p, stream: stream),
      );

  Future<Map<String, dynamic>> run(
    WidgetTester t,
    VoiceSessionFactory factory,
    AgentVoiceProvider provider,
  ) async {
    await mountEvalPage(
      t,
      reports: reports,
      scenarios: [scenario()],
      sessionFactory: factory,
      runs: 1,
      harness: OrbEvalHarness.layered,
      voiceProvider: provider,
    );
    await finishEvalRun(t);
    final json = readEvalReport(reports);
    await t.pumpWidget(const SizedBox());
    return json;
  }

  for (final provider in [AgentVoiceProvider.openai, AgentVoiceProvider.grok]) {
    group('${provider.name} as the voice service of the harness', () {
      testWidgets('the turn ends after the app had the answer said; the '
          'report names the service, the lead-in and the timings', (t) async {
        final json = await run(
          t,
          realtime(t, exact: provider == AgentVoiceProvider.grok),
          provider,
        );
        expect(json['provider'], provider.name);
        expect(
          json['combination'],
          contains(
            provider == AgentVoiceProvider.openai
                ? 'OpenAI Realtime'
                : 'Grok Voice',
          ),
        );
        final s = (json['scenarios'] as List).single as Map;
        expect(
          s['outcome'],
          'passed',
          reason: '${s['failedChecks']} ${s['results']}',
        );
        final turn =
            (((s['results'] as List).single as Map)['turns'] as List).single
                as Map;
        expect(turn['completed'], isTrue);
        expect(turn['spoken'], isNotEmpty);
        expect(turn['text'], _says);
        expect(turn['firstVoiceMs'], isNotNull);
        expect(turn['firstAnswerMs'], isNotNull);
        expect(turn['firstAnswerMs'], greaterThan(turn['firstVoiceMs'] as num));
        expect(turn['feedback'], ['lead：好嘞，翻一下未读。']);
        for (final k in [
          'firstVoiceP50Ms',
          'firstVoiceP90Ms',
          'firstAnswerP50Ms',
          'firstAnswerP90Ms',
        ]) {
          expect(json[k], isNotNull, reason: k);
        }
        final md = File(
          '${reports.listSync().whereType<Directory>().single.path}/report.md',
        ).readAsStringSync();
        expect(md, contains('首次出声 p50'));
        expect(md, contains('答案首句 p50'));
        expect(md, contains('等待时说了：lead：好嘞，翻一下未读。'));
        expect(md, contains('从说完到出声'));
      });

      testWidgets('a streamed answer ends the turn too (the sentences were '
          'said before the agent was done)', (t) async {
        final json = await run(t, realtime(t, stream: true), provider);
        final s = (json['scenarios'] as List).single as Map;
        expect(
          s['outcome'],
          'passed',
          reason: '${s['failedChecks']} ${s['results']}',
        );
        final turn =
            (((s['results'] as List).single as Map)['turns'] as List).single
                as Map;
        expect(turn['completed'], isTrue);
        expect(turn['timedOut'], isNull);
        expect(turn['spoken'], hasLength(1));
      });
    });
  }

  group('the link names the voice service', () {
    OrbEvalRequest? link(String query) =>
        OrbEvalRequest.fromLink(Uri.parse('raft://orb-eval/run?$query'));

    test('voice= takes a service or how the voice speaks', () {
      expect(
        link('harness=layered&voice=openai')!.voiceProvider,
        AgentVoiceProvider.openai,
      );
      expect(link('harness=layered&voice=openai')!.voiceMode, isNull);
      expect(
        link('harness=layered&voice=grok')!.voiceProvider,
        AgentVoiceProvider.grok,
      );
      expect(
        link('harness=layered&voice=gemini')!.voiceProvider,
        AgentVoiceProvider.gemini,
      );
      expect(link('voice=app')!.voiceMode, LayeredVoiceMode.appSpeaks);
      expect(link('voice=app')!.voiceProvider, isNull);
      expect(link('voice=relay')!.voiceMode, LayeredVoiceMode.liveRelays);
      expect(link('harness=layered')!.voiceProvider, isNull);
    });

    test('both at once: speak= and provider=', () {
      final r = link('harness=layered&provider=grok&speak=app')!;
      expect(r.voiceProvider, AgentVoiceProvider.grok);
      expect(r.voiceMode, LayeredVoiceMode.appSpeaks);
      final x = link('harness=layered&voice=xai&speak=relay')!;
      expect(x.voiceProvider, AgentVoiceProvider.grok);
      expect(x.voiceMode, LayeredVoiceMode.liveRelays);
      expect(link('voice=nonsense')!.voiceProvider, isNull);
    });
  });

  group('a slow ask is not met with silence', () {
    OrbEvalRun runOf(OrbEvalTurn turn) =>
        (OrbEvalRun(ids: const {})..turns.add(turn));

    OrbEvalTurn turn({required int askMs, int firstVoiceMs = 0}) =>
        OrbEvalTurn('读')
          ..asks.add(OrbEvalAsk(request: '读', say: '好', millis: askMs))
          ..firstVoiceMs = firstVoiceMs;

    final check = OrbEvalCheck.feedbackWhenSlow();

    test('a quick ask needs no voice before the answer', () {
      expect(check.test(runOf(turn(askMs: 600))), isNull);
    });

    test('a slow ask with a voice before the answer passes', () {
      expect(check.test(runOf(turn(askMs: 4000, firstVoiceMs: 900))), isNull);
    });

    test('a slow ask with nothing said fails', () {
      expect(check.test(runOf(turn(askMs: 4000))), contains('没有出过声'));
    });

    test('a voice that came after the answer, or too late, fails', () {
      expect(
        check.test(runOf(turn(askMs: 2000, firstVoiceMs: 2600))),
        contains('第一声在 2600ms'),
      );
      expect(
        check.test(runOf(turn(askMs: 5000, firstVoiceMs: 1800))),
        contains('晚于'),
      );
    });
  });
}
