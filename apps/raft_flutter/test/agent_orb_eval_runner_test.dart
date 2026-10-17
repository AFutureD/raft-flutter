import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_page.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A session that answers by script instead of a model: when the person's
/// text arrives it calls tools through the orb's own dispatcher, says its
/// words and ends the turn.
class ScriptedSession implements VoiceSession {
  ScriptedSession({
    required this.onToolCall,
    required this.onOutputText,
    required this.onTurnComplete,
    required this.script,
  });

  final Future<void> Function(ScriptedSession s, String text) script;
  final sentTexts = <String>[];
  int closes = 0;
  bool _connected = false;

  @override
  final AgentToolHandler onToolCall;
  @override
  final void Function(String text)? onOutputText;
  @override
  final void Function()? onTurnComplete;

  @override
  bool get connected => _connected;
  @override
  String? get model => 'scripted';
  @override
  void Function(Uint8List pcm24k)? get onAudio => null;
  @override
  void Function(String text)? get onInputText => null;
  @override
  void Function()? get onInterrupted => null;
  @override
  void Function(String reason)? get onClosed => null;

  @override
  Future<void> connect() async => _connected = true;
  @override
  void sendAudio(Uint8List pcm16k) {}
  @override
  void endAudio() {}
  @override
  void sendText(String text) {
    sentTexts.add(text);
    unawaited(script(this, text));
  }

  /// The model's turn: the tools it calls, then its words.
  Future<void> turn(
    List<(String, Map<String, Object?>)> calls,
    String words,
  ) async {
    for (final (name, args) in calls) {
      await onToolCall(name, args);
    }
    onOutputText?.call(words);
    onTurnComplete?.call();
  }

  @override
  Future<void> close() async {
    closes++;
    _connected = false;
  }
}

class Sessions {
  final made = <ScriptedSession>[];

  VoiceSessionFactory factory(
    Future<void> Function(ScriptedSession s, String text) script,
  ) =>
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
      }) {
        final s = ScriptedSession(
          onToolCall: onToolCall,
          onOutputText: onOutputText,
          onTurnComplete: onTurnComplete,
          script: script,
        );
        made.add(s);
        return s;
      };
}

void main() {
  late Directory reports;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentOrbPreference.instance.resetForTest();
    reports = Directory.systemTemp.createTempSync('orb-eval-test');
  });
  tearDown(() => reports.deleteSync(recursive: true));

  Future<void> mountPage(
    WidgetTester t, {
    required List<OrbEvalScenario> scenarios,
    required VoiceSessionFactory sessionFactory,
    AgentVoiceKey? key,
    int runs = 2,
    Duration turnTimeout = const Duration(seconds: 45),
  }) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: OrbEvalPage(
          scenarios: scenarios,
          runs: runs,
          sessionFactory: sessionFactory,
          voiceKey: key ?? AgentVoiceKey.forTesting('test-key'),
          reportRoot: () async => reports,
          settle: const Duration(milliseconds: 50),
          turnTimeout: turnTimeout,
        ),
      ),
    );
  }

  /// Lets the run go: frames and timers on the fake clock, files on the real.
  Future<void> finish(WidgetTester t) async {
    final verdict = find.byKey(const ValueKey('orb-eval-verdict'));
    for (var i = 0; i < 600 && verdict.evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await t.pump();
  }

  OrbEvalScenario simple({
    List<OrbEvalCheck> checks = const [],
    OrbEvalStatus status = OrbEvalStatus.run,
    String id = 'A1',
  }) => OrbEvalScenario(
    id: id,
    title: 'scripted',
    start: OrbEvalStart.home,
    data: () {
      final d = OrbEvalData.cast();
      d.say('raft-flutter', evalCody, '@Sam 第 10 步可以合入吗？', mentions: [evalMe]);
      return d;
    },
    say: const ['去 raft-flutter 看看谁找我'],
    checks: checks,
    status: status,
  );

  testWidgets('a scripted session: tool calls, text and state are captured '
      'and scored, once per run, each in its own session', (t) async {
    final sessions = Sessions();
    final scenario = simple(
      checks: [
        OrbEvalCheck.tool(
          'navigate',
          args: {'channel_id': evalId('raft-flutter')},
        ),
        OrbEvalCheck.says([
          ['Cody'],
          ['合入'],
        ]),
        OrbEvalCheck.noIds(),
        OrbEvalCheck.noWrites(),
      ],
    );
    await mountPage(
      t,
      scenarios: [scenario],
      sessionFactory: sessions.factory((s, text) async {
        await s.turn([
          ('navigate', {'channel_id': evalId('raft-flutter')}),
        ], 'Cody 在问第 10 步能不能合入。');
      }),
    );
    await finish(t);

    expect(find.text('评测通过'), findsOneWidget);
    expect(sessions.made, hasLength(2), reason: 'two runs, two sessions');
    for (final s in sessions.made) {
      expect(s.sentTexts, ['去 raft-flutter 看看谁找我']);
      expect(s.closes, greaterThanOrEqualTo(1), reason: 'closed afterwards');
    }
    final folders = reports.listSync().whereType<Directory>().toList();
    expect(folders, hasLength(1));
    expect(File('${folders.single.path}/report.json').existsSync(), isTrue);
    expect(File('${folders.single.path}/report.md').existsSync(), isTrue);
    final md = File('${folders.single.path}/report.md').readAsStringSync();
    expect(md, contains('A1'));
    expect(md, contains('navigate('));
    expect(md, contains('Cody 在问第 10 步能不能合入。'));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('wrong tool, an id said aloud and a missing keyword fail '
      'their checks with reasons', (t) async {
    final sessions = Sessions();
    final scenario = simple(
      checks: [
        OrbEvalCheck.tool('navigate', args: {'page': 'activity'}),
        OrbEvalCheck.says([
          ['方案 B'],
        ]),
        OrbEvalCheck.noIds(),
      ],
    );
    await mountPage(
      t,
      runs: 1,
      scenarios: [scenario],
      sessionFactory: sessions.factory((s, text) async {
        await s.turn([
          ('describe_page', const {}),
        ], '这是 ${evalId('raft-flutter')}。');
      }),
    );
    await finish(t);

    expect(find.text('评测有失败'), findsOneWidget);
    final folder = reports.listSync().whereType<Directory>().single;
    final json = File('${folder.path}/report.json').readAsStringSync();
    expect(json, contains('"outcome": "failed"'));
    expect(json, contains('没有调用 navigate'));
    expect(json, contains('没有说到：方案 B'));
    expect(json, contains('说出了一个 id'));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a model turn that never ends is cut at the cap', (t) async {
    final sessions = Sessions();
    await mountPage(
      t,
      runs: 1,
      turnTimeout: const Duration(seconds: 3),
      scenarios: [simple()],
      sessionFactory: sessions.factory((s, text) async {}),
    );
    await finish(t);
    final folder = reports.listSync().whereType<Directory>().single;
    final json = File('${folder.path}/report.json').readAsStringSync();
    expect(json, contains('超过 3 秒'));
    expect(json, contains('"timedOut": true'));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no voice key stops the evaluation after the first run', (
    t,
  ) async {
    final sessions = Sessions();
    await mountPage(
      t,
      key: AgentVoiceKey.forTesting(null),
      scenarios: [
        simple(),
        simple(id: 'A2'),
      ],
      sessionFactory: sessions.factory((s, text) async {}),
    );
    await finish(t);
    expect(sessions.made, isEmpty);
    final folder = reports.listSync().whereType<Directory>().single;
    final json = File('${folder.path}/report.json').readAsStringSync();
    expect(json, contains('没有语音 Key'));
    expect('"id": "A2"'.allMatches(json), isEmpty, reason: 'it stopped');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('skipped scenarios are not run; expected-fail ones run once '
      'and do not fail the run', (t) async {
    final sessions = Sessions();
    await mountPage(
      t,
      scenarios: [
        simple(id: 'A3', status: OrbEvalStatus.skipped),
        simple(
          id: 'D5',
          status: OrbEvalStatus.expectedFail,
          checks: [
            OrbEvalCheck.says([
              ['不会说的话'],
            ]),
          ],
        ),
      ],
      sessionFactory: sessions.factory((s, text) async {
        await s.turn(const [], '好的。');
      }),
    );
    await finish(t);
    expect(find.text('评测通过'), findsOneWidget);
    expect(sessions.made, hasLength(1), reason: 'skipped: none; xfail: once');
    final folder = reports.listSync().whereType<Directory>().single;
    final json = File('${folder.path}/report.json').readAsStringSync();
    expect(json, contains('"outcome": "skipped"'));
    expect(json, contains('"outcome": "expectedFail"'));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('every scenario of scenarios-v1 mounts its data and starts on '
      'its page', (t) async {
    final sessions = Sessions();
    final all = orbEvalScenarios
        .where((s) => s.status != OrbEvalStatus.skipped)
        .toList();
    await mountPage(
      t,
      runs: 1,
      scenarios: all,
      sessionFactory: sessions.factory((s, text) async {
        await s.turn(const [], '好。');
      }),
    );
    await finish(t);
    final folder = reports.listSync().whereType<Directory>().single;
    final json = jsonDecode(
      File('${folder.path}/report.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final raft = evalId('raft-flutter');
    expect(json['scenarios'], hasLength(all.length));
    for (final s in json['scenarios'] as List) {
      final id = s['id'] as String;
      final run = (s['results'] as List).single as Map;
      expect(run['error'], isNull, reason: '$id did not start');
      final turns = (run['turns'] as List).cast<Map>();
      final where = turns.last['after']['location'] as String;
      if (const {'A2', 'A4', 'A5'}.contains(id)) {
        expect(where, '/s/fixture/channel/$raft', reason: id);
      } else if (id.startsWith('B') && id != 'B1') {
        expect(where, '/s/fixture/activity', reason: id);
      } else if (id == 'C5') {
        expect(where, contains('thread='), reason: id);
      } else {
        expect(where, '/s/fixture', reason: id);
      }
    }
    await t.pumpWidget(const SizedBox());
  });
}
