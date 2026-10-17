import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_report.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_result.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_world.dart';

/// Scoring: what each check passes and fails, how a scenario's runs add up,
/// and the report written from them.

OrbEvalRun run({
  List<(String, Map<String, Object?>, Map<String, Object?>)> tools = const [],
  String text = '',
  Set<String> ids = const {},
  List<OrbEvalWrite> writes = const [],
  OrbEvalSnapshot? after,
  List<String> setupText = const [],
}) {
  final r = OrbEvalRun(ids: ids);
  for (final s in setupText) {
    r.turns.add(OrbEvalTurn('setup', scored: false)..addText(s));
  }
  final turn = OrbEvalTurn('go')..addText(text);
  for (final (name, args, result) in tools) {
    turn.tools.add(
      OrbEvalToolCall(name: name, args: args, result: result, millis: 1),
    );
  }
  turn.after = after;
  r.turns.add(turn);
  r.writes = writes;
  return r;
}

OrbEvalSnapshot snapshot({
  String location = '/s/fixture',
  bool driving = false,
  List<Map<String, String>> cards = const [],
}) => OrbEvalSnapshot(
  location: location,
  layerOpen: driving,
  driving: driving,
  drivingIndex: 0,
  cards: cards,
);

void main() {
  group('tool checks', () {
    test('name and arguments, by value or by predicate', () {
      final r = run(
        tools: [
          ('navigate', {'page': 'activity', 'show': true, 'n': 136}, {}),
        ],
      );
      expect(
        OrbEvalCheck.tool(
          'navigate',
          args: {'page': 'activity', 'show': true},
        ).test(r),
        isNull,
      );
      expect(
        OrbEvalCheck.tool('navigate', args: {'n': 136.0}).test(r),
        isNull,
        reason: 'a model may send 136 as a double',
      );
      expect(
        OrbEvalCheck.tool(
          'navigate',
          args: {'page': (Object? v) => '$v'.startsWith('act')},
        ).test(r),
        isNull,
      );
      expect(
        OrbEvalCheck.tool('navigate', args: {'show': false}).test(r),
        contains('参数不对'),
      );
      expect(
        OrbEvalCheck.tool('navigate', args: {'missing': 1}).test(r),
        contains('参数不对'),
      );
      expect(
        OrbEvalCheck.tool('describe_page').test(r),
        contains('没有调用 describe_page'),
      );
      expect(OrbEvalCheck.tool('describe_page').test(r), contains('navigate'));
    });

    test('a setup turn does not count; anyTool and noTool', () {
      final r = OrbEvalRun(ids: {})
        ..turns.add(
          OrbEvalTurn('开始驾驶模式', scored: false)
            ..tools.add(
              const OrbEvalToolCall(
                name: 'set_driving_mode',
                args: {'on': true},
                result: {},
                millis: 1,
              ),
            ),
        )
        ..turns.add(OrbEvalTurn('下一件')..addText('好。'));
      expect(OrbEvalCheck.tool('set_driving_mode').test(r), isNotNull);
      expect(OrbEvalCheck.noTool('set_driving_mode').test(r), isNull);
      final read = run(tools: [('read_conversation', {}, {})]);
      expect(
        OrbEvalCheck.anyTool(['navigate', 'read_conversation']).test(read),
        isNull,
      );
      expect(OrbEvalCheck.anyTool(['navigate']).test(read), isNotNull);
    });
  });

  group('text checks', () {
    test('says: every group, any alternative, spaces and case ignored', () {
      final r = run(text: 'Cody 在问第10步能不能合入。');
      expect(
        OrbEvalCheck.says([
          ['cody'],
          ['第 10 步'],
          ['合并', '合入'],
        ]).test(r),
        isNull,
      );
      final missing = OrbEvalCheck.says([
        ['Cody'],
        ['方案 B'],
      ]).test(r);
      expect(missing, '没有说到：方案 B');
    });

    test('avoids looks at every turn, setup included', () {
      final r = run(text: '好。', setupText: ['这里没有内容']);
      final check = OrbEvalCheck.avoids(RegExp('没有内容'), '“没有内容”');
      expect(check.test(r), contains('没有内容'));
      expect(check.test(run(text: '还在加载。')), isNull);
    });

    test('inOrder: the first of each group, in sequence', () {
      final check = OrbEvalCheck.inOrder([
        ['Grok'],
        ['验收'],
      ], label: 'order');
      expect(check.test(run(text: 'Grok 回复了。另外有个任务等你验收。')), isNull);
      expect(check.test(run(text: '有个任务等你验收。Grok 回复了。')), isNotNull);
      expect(check.test(run(text: 'Grok 回复了。')), isNotNull);
    });

    test('shortReply counts sentences', () {
      expect(orbEvalSentences('Cody 在等你。第 10 步。'), 2);
      expect(orbEvalSentences('发布 v1.4 在等你批准。好吗？'), 2);
      expect(orbEvalSentences('Cody is waiting. Approve it.'), 2);
      expect(orbEvalSentences(''), 0);
      expect(
        OrbEvalCheck.shortReply(2).test(run(text: '好的，驾驶模式。第一件，Cody 在等你。')),
        isNull,
      );
      expect(
        OrbEvalCheck.shortReply(2).test(run(text: '第一句话。第二句话。第三句话。')),
        '说了 3 句',
      );
    });

    test('noIds: a uuid, or any id the fixture holds', () {
      const id = '4340bf9f-cc06-4085-a00a-12547d9ad249';
      expect(OrbEvalCheck.noIds().test(run(text: '频道 $id')), contains('id'));
      expect(
        OrbEvalCheck.noIds().test(
          run(text: '频道 abc12345xyz', ids: {'abc12345xyz'}),
        ),
        contains('abc12345xyz'),
      );
      expect(
        OrbEvalCheck.noIds().test(run(text: '频道 raft-flutter', ids: {id})),
        isNull,
      );
    });
  });

  group('writes and screen', () {
    test('a read receipt is not a write; a message is', () {
      const receipt = OrbEvalWrite('POST', '/channels/c1/read', null);
      const send = OrbEvalWrite('POST', '/channels/c1/messages', {
        'content': 'x',
      });
      expect(OrbEvalCheck.noWrites().test(run(writes: [receipt])), isNull);
      expect(
        OrbEvalCheck.noWrites().test(run(writes: [receipt, send])),
        '发出了：POST /channels/c1/messages',
      );
    });

    test('screen reads the state after the last turn', () {
      final check = OrbEvalCheck.screen('driving', (s, _) => s.driving);
      expect(check.test(run()), contains('没有记录'));
      expect(check.test(run(after: snapshot(driving: true))), isNull);
      expect(check.test(run(after: snapshot())), isNotNull);
    });
  });

  group('outcomes', () {
    OrbEvalRunResult result(int i, {bool pass = true, String? error}) =>
        OrbEvalRunResult(
          index: i,
          run: run(text: '好'),
          failures: pass ? const [] : [const OrbEvalFailure('说到 X', '没有说到：X')],
          error: error,
        );

    OrbEvalScenario scenarioOf(OrbEvalStatus status) => OrbEvalScenario(
      id: 'A1',
      title: 't',
      start: OrbEvalStart.home,
      status: status,
    );

    test('all runs pass, some, none', () {
      final s = scenarioOf(OrbEvalStatus.run);
      expect(
        OrbEvalScenarioResult(s, [result(1), result(2)]).outcome,
        OrbEvalOutcome.passed,
      );
      final flaky = OrbEvalScenarioResult(s, [
        result(1),
        result(2, pass: false),
      ]);
      expect(flaky.outcome, OrbEvalOutcome.flaky);
      expect(flaky.passRate, 0.5);
      expect(flaky.failsTheRun, isTrue);
      expect(flaky.failedChecks, {
        '说到 X — 没有说到：X': [2],
      });
      final failed = OrbEvalScenarioResult(s, [
        result(1, pass: false),
        result(2, error: 'x'),
      ]);
      expect(failed.outcome, OrbEvalOutcome.failed);
      expect(failed.failedChecks.keys, contains('运行出错 — x'));
    });

    test('skipped and not-built scenarios never fail the run', () {
      final skipped = OrbEvalScenarioResult(
        scenarioOf(OrbEvalStatus.skipped),
        const [],
      );
      expect(skipped.outcome, OrbEvalOutcome.skipped);
      expect(skipped.failsTheRun, isFalse);
      final xfail = OrbEvalScenarioResult(
        scenarioOf(OrbEvalStatus.expectedFail),
        [result(1, pass: false)],
      );
      expect(xfail.outcome, OrbEvalOutcome.expectedFail);
      expect(xfail.failsTheRun, isFalse);
      final xpass = OrbEvalScenarioResult(
        scenarioOf(OrbEvalStatus.expectedFail),
        [result(1)],
      );
      expect(xpass.outcome, OrbEvalOutcome.unexpectedPass);
      expect(xpass.failsTheRun, isFalse);
    });
  });

  group('report files', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('orb-eval-report'));
    tearDown(() => root.deleteSync(recursive: true));

    OrbEvalReport sample({String? harness, String? model, String? thinking}) {
      final good = OrbEvalScenario(
        id: 'B2',
        title: '读一下动态',
        start: OrbEvalStart.activity,
        say: const ['读一下动态'],
      );
      final bad = OrbEvalScenario(
        id: 'A1',
        title: '去 | 频道',
        start: OrbEvalStart.home,
        say: const ['去 raft-flutter'],
      );
      final skipped = OrbEvalScenario(
        id: 'A3',
        title: '回复',
        start: OrbEvalStart.home,
        status: OrbEvalStatus.skipped,
        note: 'needs actions',
      );
      return OrbEvalReport(
        startedAt: DateTime(2026, 10, 17, 9, 30, 15),
        runsPerScenario: 2,
        provider: 'gemini',
        reasoning: 'low',
        harness: harness,
        model: model,
        thinking: thinking,
        results: [
          OrbEvalScenarioResult(bad, [
            OrbEvalRunResult(
              index: 1,
              run: run(
                tools: [
                  (
                    'navigate',
                    {'channel_id': '4340bf9f-cc06-4085-a00a-12547d9ad249'},
                    {'route': '/x'},
                  ),
                ],
                text: 'Cody 在等你。\n第二行',
                writes: const [
                  OrbEvalWrite('POST', '/m', {'a': 1}),
                ],
              ),
              failures: const [OrbEvalFailure('说到 方案 B', '没有说到：方案 B')],
            ),
            OrbEvalRunResult(
              index: 2,
              run: run(text: 'x'),
              failures: const [],
            ),
          ]),
          OrbEvalScenarioResult(good, [
            OrbEvalRunResult(
              index: 1,
              run: run(text: '好'),
              failures: const [],
            ),
            OrbEvalRunResult(
              index: 2,
              run: run(text: '好'),
              failures: const [],
            ),
          ]),
          OrbEvalScenarioResult(skipped, const []),
        ],
      );
    }

    test('the markdown is a table with checks, calls and words', () {
      final md = orbEvalMarkdown(sample());
      expect(md, contains('| 场景 | 说 | 结果 | 通过 | 失败的检查 | 工具调用 | Agent 说的话 |'));
      expect(md, contains('| A1 去 \\| 频道 | 去 raft-flutter | 不稳定 | 1/2 |'));
      expect(md, contains('说到 方案 B — 没有说到：方案 B（第 1 次）'));
      expect(
        md,
        contains('navigate(channel_id=4340bf9f…)'),
        reason: 'ids are shortened',
      );
      expect(md, contains('Cody 在等你。<br>第二行'));
      expect(md, contains('| A3 回复 |'));
      expect(md, contains('跳过：needs actions'));
      expect(md, contains('每个场景 2 次 · 服务 gemini · 推理 low'));
      expect(md, contains('写操作：POST /m'));
    });

    test(
      'the header and the json say the thinking level next to the model',
      () {
        final report = sample(
          harness: 'agent',
          model: 'models/gemini-3-flash',
          thinking: 'high',
        );
        expect(
          orbEvalMarkdown(report),
          contains('模型 models/gemini-3-flash · 推理强度 high'),
        );
        expect(report.toJson()['thinking'], 'high');
        expect(sample().toJson().containsKey('thinking'), isFalse);
        expect(orbEvalMarkdown(sample()), isNot(contains('推理强度')));
      },
    );

    test('the header and the json say which harness and model ran', () {
      final report = sample(harness: 'agent', model: 'models/gemini-3-flash');
      expect(
        orbEvalMarkdown(report),
        contains('通道 agent · 模型 models/gemini-3-flash'),
      );
      final json = report.toJson();
      expect(json['harness'], 'agent');
      expect(json['model'], 'models/gemini-3-flash');
      expect(sample().toJson().containsKey('harness'), isFalse);
    });

    test(
      'report.json, report.md and latest land in <root>/<timestamp>',
      () async {
        final folder = await writeOrbEvalReport(sample(), root);
        expect(folder.path, '${root.path}/20261017-093015');
        expect(
          File('${root.path}/latest').readAsStringSync(),
          '20261017-093015',
        );
        final json = jsonDecode(
          File('${folder.path}/report.json').readAsStringSync(),
        ) as Map;
        expect(json['ok'], isFalse);
        expect(json['runsPerScenario'], 2);
        expect(json['summary'], containsPair('flaky', 1));
        expect(json['summary'], containsPair('passed', 1));
        expect(json['summary'], containsPair('skipped', 1));
        final a1 = (json['scenarios'] as List).first as Map;
        expect(a1['id'], 'A1');
        expect(a1['passRate'], 0.5);
        expect(a1['failedChecks'], [
          {
            'check': '说到 方案 B — 没有说到：方案 B',
            'runs': [1],
          },
        ]);
        final first = (a1['results'] as List).first as Map;
        expect(first['turns'][0]['tools'][0]['name'], 'navigate');
        expect(first['turns'][0]['text'], contains('Cody 在等你'));
        expect(first['writes'][0]['path'], '/m');
        expect(
          File('${folder.path}/report.md').readAsStringSync(),
          contains('# Agent 评测'),
        );
      },
    );

    test('long tool results are trimmed in the report', () {
      final long = 'x' * 1000;
      final trimmed = orbEvalTrim({
        'text': long,
        'list': List.generate(30, (i) => i),
      }) as Map;
      expect((trimmed['text'] as String).length, lessThan(300));
      expect(trimmed['list'], hasLength(13));
    });
  });
}
