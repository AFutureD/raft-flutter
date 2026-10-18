import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_run.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';
import 'package:raft_flutter/features/agent_orb/orb_controller.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_rows.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_surface.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:raft_flutter/features/agent_orb/orb_presenter.dart';
import 'package:raft_flutter/features/agent_orb/orb_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_orb_eval_golden_test.dart' show golden;
import 'support/orb_eval_scripted.dart';

/// The driving screen shows what was read: every read tool has a surface, the
/// model only reads, and what is spoken is on the screen. The scenarios H1-H7
/// (one for each kind of answer, and Kevin's own sequence) pass with the
/// presenter and fail without it (the old behaviour: the model had to ask for
/// a second tool to show anything).

Map<String, Object?> _tasks(int n) => {
  'tasks': [
    for (var i = 1; i <= n; i++)
      {
        'number': 100 + i,
        'title': const ['迁移旧的缓存', '整理发布说明', '补充设计评审', '清理旧的分支'][i - 1],
        'statusText': '进行中',
        'assignee': 'Cody',
        'channel': 'raft-flutter',
      },
  ],
};

Map<String, Object?> _conversation(int n, {String type = 'channel'}) => {
  'conversation': {'id': 'c1', 'name': '#raft-flutter', 'type': type},
  'messages': [
    for (var i = 1; i <= n; i++)
      {'id': 'm$i', 'from': 'Cody', 'text': '第 $i 条', 'time': '今天'},
  ],
};

void main() {
  group('what each read tool is shown as', () {
    test('tasks: a list; one task: its detail', () {
      final list = orbPresent('list_tasks', const {}, _tasks(3))!;
      expect(list.list.kind, OrbListKind.tasks);
      expect(list.list.total, 3);
      expect(list.openFirst, isFalse);
      expect(list.say, startsWith('3 个任务'));
      final one = orbPresent('task_detail', const {}, {
        'task': (_tasks(1)['tasks']! as List).single,
      })!;
      expect(one.openFirst, isTrue);
      expect(one.say, contains('任务 #101'));
      expect(orbPresent('list_tasks', const {}, {'tasks': []}), isNull);
    });

    test('messages: a list for two or more, a detail for one, nothing for '
        'a summary (it is shown with the answer)', () {
      expect(
        orbPresent('read_conversation', const {}, _conversation(3))!.list.kind,
        OrbListKind.channel,
      );
      expect(
        orbPresent('read_conversation', const {}, _conversation(1))!.openFirst,
        isTrue,
      );
      expect(
        orbPresent(
          'read_conversation',
          const {},
          _conversation(3),
          said: '大家意见是什么',
        ),
        isNull,
      );
      expect(
        orbPresent(
          'read_conversation',
          const {},
          _conversation(2, type: 'dm'),
        )!.list.kind,
        OrbListKind.person,
      );
    });

    test('places and query results are a results list', () {
      final p = orbPresent('list_targets', const {}, {
        'channels': [
          {'id': 'c1', 'name': 'design', 'unread': 2},
          {'id': 'c2', 'name': 'raft-flutter'},
        ],
        'dms': [
          {'id': 'd1', 'name': 'Alice'},
        ],
      })!;
      expect(p.list.kind, OrbListKind.results);
      expect(p.list.rows.map((r) => r.title), [
        'design',
        'raft-flutter',
        'Alice',
      ]);
      expect(p.list.rows.first.fact, '2 条未读');
      expect(p.list.rows.first.openArgs, {'channel_id': 'c1'});
      final q = orbPresent(
        'query',
        const {'capability': 'x'},
        {
          'items': [
            {'id': 1, 'title': '甲', 'statusText': '进行中'},
            {'id': 2, 'title': '乙'},
          ],
        },
      )!;
      expect(q.list.rows.map((r) => r.title), ['甲', '乙']);
      expect(orbPresent('list_targets', const {}, const {}), isNull);
    });

    test('the Activity page: its items as a list; other pages and errors: '
        'nothing', () {
      final p = orbPresent('describe_page', const {}, {
        'page': 'activity',
        'items': [
          {
            'id': 'activity:dm:d1',
            'who': 'Alice',
            'where': '@Alice',
            'preview': '周五能来评审吗？',
            'unread': 3,
          },
          {
            'id': 'activity:channel:c1',
            'who': 'Cody',
            'where': '#raft-flutter',
            'preview': '第 10 步可以合入吗？',
          },
        ],
      })!;
      expect(p.list.kind, OrbListKind.recent);
      expect(p.list.rows.first.fact, '3 条未读');
      expect(p.list.rows.first.openArgs, {'dm_id': 'd1'});
      expect(p.list.rows.last.openArgs, {'channel_id': 'c1'});
      expect(orbPresent('describe_page', const {}, {'page': 'task'}), isNull);
      expect(
        orbPresent('list_tasks', const {}, {'error': '读不到', ..._tasks(2)}),
        isNull,
      );
      expect(
        orbPresent('list_tasks', const {}, {'loading': true, ..._tasks(2)}),
        isNull,
      );
    });

    test(
      'tasks: each row says how it stands and how long it has sat, the '
      'heading how they stand: what the model says of them is on the card',
      () {
        final tasks = {
          'tasks': [
            {
              'number': 142,
              'title': '迁移旧的缓存',
              'statusText': '等验收',
              'assignee': 'Cody',
              'waitsFor': '等你验收',
              'idle': '5 天',
            },
            {
              'number': 141,
              'title': '整理发布说明',
              'statusText': '进行中',
              'assignee': '八戒',
              'idle': '4 天',
            },
            {
              'number': 143,
              'title': '补充设计评审记录',
              'statusText': '进行中',
              'assignee': 'Grok',
              'idle': '3 天',
            },
          ],
        };
        final list = orbPresent('list_tasks', const {}, tasks)!.list;
        expect(list.heading, '任务 3 · 等验收 1、进行中 2');
        expect(list.rows[0].fact, '等你验收 · 5 天没动');
        expect(list.rows[0].meta, '任务 #142 · Cody');
        expect(list.rows[1].fact, '进行中 · 4 天没动');
        // The line says who has it and how it stands, and how many are which.
        expect(list.say, contains('等验收 1、进行中 2'));
        expect(list.say, contains('任务 #142「迁移旧的缓存」，Cody 负责，等你验收'));
        // What the model said on the G100 ("5 天没动 … 4 天 … 3 天") is on it.
        final turn = OrbEvalTurn('看看那几个放了好几天的任务')
          ..addText(
            '共 3 个任务，其中 1 个在等你验收。迁移旧的缓存，Cody 负责，等你验收，5 天没动；'
            '整理发布说明，八戒 在做，4 天没动；补充设计评审记录，Grok 在做，3 天没动。',
          )
          ..after = OrbEvalSnapshot(
            location: '/s/fixture',
            layerOpen: true,
            driving: true,
            drivingIndex: 0,
            cards: const [],
            surface: 'list',
            listTitle: list.heading,
            listTotal: list.total,
            rows: [
              for (final r in list.rows)
                {
                  'id': r.id,
                  'who': r.who,
                  'meta': r.meta,
                  'title': r.title,
                  'fact': r.fact,
                },
            ],
          );
        final run = OrbEvalRun(ids: const {})..turns.add(turn);
        expect(OrbEvalCheck.spokenIsShown().test(run), isNull);
      },
    );

    test('a long message is cut at 60 characters and says so', () {
      final long = '很长的话' * 30;
      final p = orbPresent('read_conversation', const {}, {
        'conversation': {'id': 'c1', 'name': '#a', 'type': 'channel'},
        'messages': [
          {'id': 'm1', 'from': 'Cody', 'text': long, 'time': '今天'},
        ],
      })!;
      expect(p.list.rows.single.title.runes.length, lessThanOrEqualTo(61));
      expect(p.list.rows.single.clipped, isTrue);
      expect(p.say, contains('停车后看'));
    });

    test('a reply that names two rows reads the set out; one does not', () {
      final rows = orbPresent('list_tasks', const {}, _tasks(3))!.list.rows;
      expect(orbRowsNamed('迁移旧的缓存 和 整理发布说明 都在做', rows), 2);
      expect(orbRowsNamed('整理发布说明 在做', rows), 1);
      expect(orbRowsNamed('好的', rows), 0);
    });

    test('every read tool has a surface (or is shown by the controller)', () {
      const reads = [
        'describe_page',
        'read_conversation',
        'get_briefing',
        'list_tasks',
        'task_detail',
        'list_targets',
        'find',
        'query',
        'navigate',
        'open_item',
      ];
      for (final tool in reads) {
        expect(
          orbPresentedTools.containsKey(tool) ||
              orbPresentedElsewhere.containsKey(tool),
          isTrue,
          reason: '$tool has no place in the presentation table',
        );
        expect(orbToolModes.containsKey(tool), isTrue, reason: tool);
      }
    });
  });

  group('the surfaces', () {
    test('a summary card: the rows are the sentences, none opens, the one '
        'spoken is lifted', () {
      final list = orbListOfSummary(['一。', '二。', '三。', '四。']);
      expect(list.rows, hasLength(3));
      expect(list.say, '一。二。三。');
      final surface = OrbDrivingSurface()..showList(list);
      expect(surface.openRow(0), isFalse);
      surface.spotlight(2);
      expect(surface.speaking, 2);
      surface.spotlight(null);
      expect(surface.speaking, isNull);
    });

    test('a list kind has its own heading and count', () {
      expect(
        const OrbList(kind: OrbListKind.recent, rows: []).heading,
        '最近动态 0',
      );
      expect(
        const OrbList(kind: OrbListKind.results, rows: []).heading,
        '找到 0',
      );
      expect(
        const OrbList(
          kind: OrbListKind.summary,
          rows: [],
          target: '设计',
        ).heading,
        '摘要 · 设计',
      );
    });
  });

  group('the scenarios, with and without the presenter', () {
    const ids = ['H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'H7'];
    late Directory reports;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AgentOrbPreference.instance.resetForTest();
      reports = Directory.systemTemp.createTempSync('orb-presenter');
    });
    tearDown(() {
      OrbController.presenterEnabled = true;
      reports.deleteSync(recursive: true);
    });

    Future<List<String>> failed(WidgetTester t, String id) async {
      final scenario = orbEvalScenarios.firstWhere((s) => s.id == id);
      final script = golden[id]!;
      final sessions = Sessions();
      await mountEvalPage(
        t,
        reports: reports,
        scenarios: [scenario],
        runs: 1,
        sessionFactory: sessions.factory((s, text) => script[text]!(s)),
      );
      await finishEvalRun(t);
      final report = readEvalReport(reports);
      await t.pumpWidget(const SizedBox());
      reports.listSync().forEach((e) => e.deleteSync(recursive: true));
      return [
        for (final c
            in ((report['scenarios'] as List).single as Map)['failedChecks']
                as List)
          '${(c as Map)['check']}',
      ];
    }

    testWidgets(
      'driving while the Activity has not come: the turn is not held, '
      'the screen is grey placeholders, and the briefing is laid out when '
      'it lands',
      (t) async {
        final scenario = orbEvalScenarios.firstWhere((s) => s.id == 'H6');
        final sessions = Sessions();
        await mountEvalPage(
          t,
          reports: reports,
          scenarios: [scenario],
          runs: 1,
          sessionFactory: sessions.factory((s, text) async {
            // The model asks for the briefing, as it did on the G100.
            if (text == '开始驾驶模式') {
              await s.turn([
                ('set_driving_mode', {'on': true}),
                ('get_briefing', {'show': true}),
              ], '好，驾驶模式。');
            } else {
              await s.turn(const [('get_briefing', {})], '动态还在加载，稍等再看。');
            }
          }),
        );
        await finishEvalRun(t);
        final report = readEvalReport(reports);
        final turns =
            (((report['scenarios'] as List).single as Map)['results'] as List)
                    .first['turns']
                as List;
        for (final turn in turns.cast<Map>()) {
          expect(turn['error'], isNull);
          expect(turn['ms'] as int, lessThan(8000), reason: '${turn['line']}');
        }
        final last = (turns.last as Map)['after'] as Map;
        expect(last['surface'], 'list');
        expect(last['rows'], isEmpty, reason: 'grey placeholders, not "empty"');
        await t.pumpWidget(const SizedBox());
      },
    );

    for (final id in ids) {
      testWidgets('$id: green with the presenter, red without it', (t) async {
        OrbController.presenterEnabled = true;
        expect(await failed(t, id), isEmpty, reason: '$id with the presenter');
        OrbController.presenterEnabled = false;
        // Without it the model only read, and the screen showed nothing of it.
        final old = await failed(t, id);
        expect(old, isNotEmpty, reason: '$id without the presenter');
        // ignore: avoid_print
        print('BEFORE/AFTER $id: before ${old.length} red -> after 0: $old');
      });
    }
  });
}
