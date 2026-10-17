import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_audio.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_result.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_runner.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/orb_eval_scripted.dart';

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
  }) => mountEvalPage(
    t,
    reports: reports,
    scenarios: scenarios,
    sessionFactory: sessionFactory,
    key: key,
    runs: runs,
    turnTimeout: turnTimeout,
  );

  Future<void> finish(WidgetTester t) => finishEvalRun(t);

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

  testWidgets('driving: the orb\'s layer opens over the page, the snapshot '
      'shows it, and it is closed when the run ends', (t) async {
    final sessions = Sessions();
    final scenario = OrbEvalScenario(
      id: 'D1',
      title: 'driving',
      start: OrbEvalStart.home,
      say: const ['开始驾驶模式'],
      checks: [
        OrbEvalCheck.tool('set_driving_mode', args: {'on': true}),
        OrbEvalCheck.screen('driving', (s, _) => s.driving && s.layerOpen),
      ],
    );
    await mountPage(
      t,
      runs: 1,
      scenarios: [scenario],
      sessionFactory: sessions.factory((s, text) async {
        await s.turn([
          ('set_driving_mode', {'on': true}),
        ], '好，驾驶模式。');
      }),
    );
    await finish(t);
    expect(find.text('评测通过'), findsOneWidget);
    expect(find.byKey(const ValueKey('orb-layer')), findsNothing);
    final folder = reports.listSync().whereType<Directory>().single;
    final json = File('${folder.path}/report.json').readAsStringSync();
    expect(json, contains('"driving": true'));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a page closed under a run ends it, says why and logs '
      '"page gone"', (t) async {
    final logged = <String>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logged.add('$message');
    final sessions = Sessions();
    await mountPage(
      t,
      runs: 1,
      scenarios: [simple()],
      // The model never answers: the run is waiting when the page goes.
      sessionFactory: sessions.factory((s, text) async {}),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(sessions.made, isNotEmpty, reason: 'the turn is under way');
    await t.pumpWidget(const SizedBox());
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(milliseconds: 100));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    debugPrint = original;
    expect(logged, contains('orb-eval: page gone'));
    final report = readEvalReport(reports);
    expect(report['cancelled'], isTrue);
    expect(report['abortReason'], 'page gone');
    final run =
        ((report['scenarios'] as List).single as Map)['results'] as List;
    expect((run.single as Map)['error'], 'page gone');
    expect(
      File('${reports.listSync().whereType<Directory>().single.path}/report.md')
          .readAsStringSync(),
      contains('page gone'),
    );
  });

  testWidgets('a fixture Navigator that never appears fails the run clearly, '
      'after a bounded wait', (t) async {
    final runner = OrbEvalRunner(
      stage: _NeverMounted(),
      runs: 1,
      voiceKey: AgentVoiceKey.forTesting('test-key'),
      sessionFactory: Sessions().factory((s, text) async {}),
    );
    OrbEvalReport? report;
    unawaited(runner.runAll([simple()]).then((r) => report = r));
    for (var i = 0; i < 80 && report == null; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final run = report!.results.single.runs.single;
    expect(run.error, contains('没有准备好'));
    expect(run.run.turns, isEmpty, reason: 'nothing was said to the model');
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
      if (const {'A2', 'A3', 'A4', 'A5'}.contains(id)) {
        expect(where, '/s/fixture/channel/$raft', reason: id);
      } else if (id.startsWith('B') && id != 'B1') {
        expect(where, '/s/fixture/activity', reason: id);
      } else if (id == 'C2') {
        expect(where, contains('/dm/'), reason: id);
      } else if (id == 'C4') {
        expect(where, contains('task'), reason: id);
      } else if (id == 'C5') {
        expect(where, contains('thread='), reason: id);
      } else {
        expect(where, '/s/fixture', reason: id);
      }
    }
    await t.pumpWidget(const SizedBox());
  });
}

class _NeverMounted implements OrbEvalStage {
  @override
  Future<OrbEvalSite> mount(WorkspaceController workspace) async =>
      _NoNavigator();
}

class _NoNavigator implements OrbEvalSite {
  @override
  BuildContext? navigatorContext() => null;
  @override
  Future<void> unmount() async {}
}
