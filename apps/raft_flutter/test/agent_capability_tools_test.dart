import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_tools.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The `find`, `query`, `act`, `confirm` tools: validation, the 8 s limit,
/// and the preview/confirm contract of operations.
void main() {
  late CapabilityWorld w;
  late ActivityClient client;
  var clock = worldNow;

  setUp(() {
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    clock = worldNow;
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_review') ...[
          taskRow('t1', 7, 'in_review', title: '甲', channel: 'general'),
          taskRow('t2', 7, 'in_review', title: '乙', channel: 'design'),
        ],
        if (q?['status'] == 'in_progress')
          taskRow(
            't3',
            9,
            'in_progress',
            title: '丙',
            channel: 'general',
            claimedById: 'a-cody',
            claimedByName: 'Cody',
          ),
      ],
    };
    w.routes['/tasks/channel/ch-general/number/9'] = (_) => {
      'task': {
        'id': 't3',
        'taskNumber': 9,
        'title': '丙',
        'status': 'in_progress',
      },
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  AgentCapabilityTools tools({
    AgentCapabilityRegistry? registry,
    Set<AgentCapabilityRisk> risks = const {AgentCapabilityRisk.change},
    Future<bool> Function(AgentActionPreview)? consent,
    AgentFacts? facts,
  }) => AgentCapabilityTools(
    workspace: w,
    registry: registry,
    env: AgentCapabilityEnv(
      data: AgentModeData(w, now: () => worldNow),
      facts: facts,
    ),
    actionRisks: risks,
    userConsent: consent,
    now: () => clock,
    random: Random(1),
  );

  group('find', () {
    test('returns at most five capabilities with their schemas', () async {
      final r = await tools().run('find', {'intent': '任务'});
      final matches = (r!['matches'] as List).cast<Map>();
      expect(matches, isNotEmpty);
      expect(matches.length, lessThanOrEqualTo(5));
      for (final m in matches) {
        expect(
          m.keys,
          containsAll(['id', 'title', 'kind', 'risk', 'params', 'result']),
        );
        expect((m['params'] as Map)['type'], 'object');
      }
      expect(matches.first['id'], startsWith('tasks.'));
    });

    test('says so when nothing fits, and needs an intent', () async {
      expect(
        (await tools().run('find', {'intent': 'qqqq'}))!['matches'],
        isEmpty,
      );
      expect((await tools().run('find', {}))!['error'], isNotNull);
    });

    test('other tool names are not its business', () async {
      expect(await tools().run('list_agents', {}), isNull);
    });
  });

  group('query', () {
    test('runs a capability on the data layer and wraps the result', () async {
      final r = await tools().run('query', {
        'capability': 'tasks.board',
        'args': '{"status":"in_progress"}',
      });
      expect(r!['capability'], 'tasks.board');
      final tasks = ((r['result'] as Map)['tasks'] as List).cast<Map>();
      expect(tasks.single['id'], 't3');
      expect(w.reads, contains('/tasks/server'));
    });

    test('args may be fenced JSON, a map, or left out', () async {
      final t = tools();
      for (final args in <Object?>[
        '```json\n{"status":"todo"}\n```',
        {'status': 'todo'},
      ]) {
        final r = await t.run('query', {
          'capability': 'tasks.board',
          'args': args,
        });
        expect(r!['error'], isNull, reason: '$args');
      }
      expect(
        (await t.run('query', {'capability': 'server.info'}))!['result'],
        isNotNull,
      );
    });

    test('a wrong capability id is named, with suggestions', () async {
      final r = await tools().run('query', {'capability': 'task.board'});
      expect(r!['error'], contains('没有叫 task.board'));
      expect(r['suggestions'], isNotEmpty);
      expect(
        (await tools().run('query', {}))!['error'],
        contains('capability'),
      );
    });

    test('bad arguments are refused with the problem and the schema', () async {
      final t = tools();
      final unknown = await t.run('query', {
        'capability': 'tasks.board',
        'args': '{"state":"done"}',
      });
      expect(unknown!['error'], contains('未知参数 state'));
      expect(unknown['params'], isA<Map>());
      final badEnum = await t.run('query', {
        'capability': 'tasks.board',
        'args': {'status': 'finished'},
      });
      expect((badEnum!['problems'] as List).single, contains('in_progress'));
      final badLimit = await t.run('query', {
        'capability': 'channels.recent_messages',
        'args': {'channel': 'general', 'limit': 500},
      });
      expect(badLimit!['error'], contains('不能大于 30'));
      final missing = await t.run('query', {'capability': 'channels.detail'});
      expect(missing!['error'], contains('缺少参数 channel'));
      final notJson = await t.run('query', {
        'capability': 'tasks.board',
        'args': '{oops',
      });
      expect(notJson!['error'], contains('JSON'));
      // Nothing was read for any of them.
      expect(w.reads, isEmpty);
    });

    test(
      'a read that cannot be answered comes back as an error with candidates',
      () async {
        final r = await tools().run('query', {
          'capability': 'tasks.detail',
          'args': {'number': 7},
        });
        expect(r!['error'], contains('多个频道'));
        expect(r['channels'], containsAll(['general', 'design']));
        expect(r['candidates'], hasLength(2));
        final one = await tools().run('query', {
          'capability': 'tasks.detail',
          'args': {'number': '#9'},
        });
        final task = (one!['result'] as Map)['task'] as Map;
        expect(task['id'], 't3');
        expect(task['channelId'], 'ch-general');
      },
    );

    test('what it reads is remembered for the screens that quote it', () async {
      final facts = AgentFacts();
      await tools(facts: facts).run('query', {
        'capability': 'tasks.detail',
        'args': {'number': 9},
      });
      expect(facts.taskId(9), 't3');
    });

    test(
      'a query that never returns is answered once, with the 8 s error',
      () async {
        final never = Completer<Map<String, Object?>>();
        final registry = AgentCapabilityRegistry([
          AgentCapability(
            id: 'slow.read',
            title: '很慢的读取',
            kind: AgentCapabilityKind.query,
            risk: AgentCapabilityRisk.read,
            paramsSchema: const {'type': 'object', 'properties': {}},
            resultSummary: 'x',
            keywords: const ['慢'],
            run: (w, a, e) => never.future,
          ),
        ]);
        final t = tools(registry: registry);
        final sent = <Map<String, Object?>>[];
        final responder = AgentToolResponder(
          handler: (name, args) async => (await t.run(name, args))!,
          timeout: const Duration(milliseconds: 50),
          log: (_) {},
          send: (r) {
            sent.add(r);
            return true;
          },
        );
        await responder.answer([
          {
            'id': 'c1',
            'name': 'query',
            'args': {'capability': 'slow.read'},
          },
        ]);
        expect(sent, hasLength(1));
        expect((sent.single['response'] as Map)['error'], contains('query 超过'));
        // The real limit is the one every other tool has.
        expect(agentToolTimeout, const Duration(seconds: 8));
      },
    );
  });

  group('act and confirm', () {
    var ran = 0;
    List<String> ranWith = [];

    AgentCapability action(
      String id, {
      AgentCapabilityRisk risk = AgentCapabilityRisk.change,
      String? route,
    }) => AgentCapability(
      id: id,
      title: '测试操作',
      kind: AgentCapabilityKind.action,
      risk: risk,
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': '任务 id'},
        },
        'required': ['taskId'],
      },
      resultSummary: '改后的任务',
      keywords: const ['测试'],
      openRoute: route,
      preview: route != null
          ? null
          : (w, args, env) async => AgentActionPreview(
              summary: '把任务 ${args['taskId']} 标记为完成',
              changes: const ['状态：待验收 → 已完成'],
              reversible: true,
            ),
      run: (w, args, env) async {
        ran++;
        ranWith.add('${args['taskId']}');
        return {'task': args['taskId'], 'status': 'done'};
      },
    );

    late AgentCapabilityRegistry registry;
    setUp(() {
      ran = 0;
      ranWith = [];
      registry = AgentCapabilityRegistry([
        action('tasks.finish'),
        action('server.erase', risk: AgentCapabilityRisk.sensitive),
        action(
          'billing.cancel',
          risk: AgentCapabilityRisk.neverByVoice,
          route: '/settings/billing',
        ),
        ...tools().registry.queries,
      ]);
    });

    test('phase one registers no operation at all', () {
      expect(tools().registry.all.where((c) => !c.isQuery), isEmpty);
    });

    test('act only previews: nothing changes until confirm', () async {
      final t = tools(registry: registry);
      final r = await t.run('act', {
        'capability': 'tasks.finish',
        'args': {'taskId': 't1'},
      });
      expect(r!['status'], 'needs_confirmation');
      expect((r['preview'] as Map)['summary'], contains('t1'));
      expect((r['preview'] as Map)['changes'], isNotEmpty);
      expect(r['confirmToken'], startsWith('cf_'));
      expect(r['confirmation'], '1/1');
      expect(ran, 0);

      final done = await t.run('confirm', {'token': r['confirmToken']});
      expect(done!['status'], 'done');
      expect(ran, 1);
      expect(ranWith, ['t1']);
      expect(t.executions.single.capability, 'tasks.finish');

      // A token works once.
      final again = await t.run('confirm', {'token': r['confirmToken']});
      expect(again!['error'], contains('无效或已过期'));
      expect(ran, 1);
    });

    test('act checks the arguments before it previews anything', () async {
      final t = tools(registry: registry);
      final r = await t.run('act', {'capability': 'tasks.finish', 'args': {}});
      expect(r!['error'], contains('缺少参数 taskId'));
      expect(r.containsKey('confirmToken'), isFalse);
    });

    test(
      'a token that is guessed, or has waited too long, runs nothing',
      () async {
        final t = tools(registry: registry);
        expect(
          (await t.run('confirm', {'token': 'cf_nope'}))!['error'],
          isNotNull,
        );
        expect((await t.run('confirm', {}))!['error'], isNotNull);
        final r = await t.run('act', {
          'capability': 'tasks.finish',
          'args': {'taskId': 't1'},
        });
        clock = clock.add(
          AgentCapabilityTools.confirmWindow + const Duration(seconds: 1),
        );
        expect(
          (await t.run('confirm', {'token': r!['confirmToken']}))!['error'],
          contains('过期'),
        );
        expect(ran, 0);
      },
    );

    test('a person who says no (the consent gate) stops it', () async {
      final t = tools(registry: registry, consent: (_) async => false);
      final r = await t.run('act', {
        'capability': 'tasks.finish',
        'args': {'taskId': 't1'},
      });
      expect(
        (await t.run('confirm', {'token': r!['confirmToken']}))!['status'],
        'declined',
      );
      expect(ran, 0);
    });

    test(
      'a sensitive operation is not available until it is enabled',
      () async {
        final r = await tools(registry: registry).run('act', {
          'capability': 'server.erase',
          'args': {'taskId': 'x'},
        });
        expect(r!['status'], 'not_available');
        expect(r.containsKey('confirmToken'), isFalse);
        expect(ran, 0);
      },
    );

    test('a sensitive operation needs two confirmations', () async {
      final t = tools(
        registry: registry,
        risks: {AgentCapabilityRisk.change, AgentCapabilityRisk.sensitive},
      );
      final first = await t.run('act', {
        'capability': 'server.erase',
        'args': {'taskId': 'x'},
      });
      expect(first!['status'], 'needs_confirmation');
      expect(first['confirmation'], '1/2');

      final second = await t.run('confirm', {'token': first['confirmToken']});
      expect(second!['status'], 'needs_second_confirmation');
      expect(second['confirmation'], '2/2');
      expect(second['warning'], isNotNull);
      expect(second['confirmToken'], isNot(first['confirmToken']));
      expect(ran, 0);
      // The first token is spent.
      expect(
        (await t.run('confirm', {'token': first['confirmToken']}))!['error'],
        isNotNull,
      );

      final done = await t.run('confirm', {'token': second['confirmToken']});
      expect(done!['status'], 'done');
      expect(ran, 1);
    });

    test('a never-by-voice operation only opens its page', () async {
      // Even with every risk enabled, and whatever the arguments.
      final t = tools(
        registry: registry,
        risks: AgentCapabilityRisk.values.toSet(),
      );
      final r = await t.run('act', {'capability': 'billing.cancel'});
      expect(r!['status'], 'open_page');
      expect(r['openPage'], '/settings/billing');
      expect(r.containsKey('confirmToken'), isFalse);
      expect(ran, 0);
    });

    test('queries and actions are not mixed up', () async {
      final t = tools(registry: registry);
      expect(
        (await t.run('act', {'capability': 'tasks.board'}))!['error'],
        contains('查询'),
      );
      expect(
        (await t.run('query', {
          'capability': 'tasks.finish',
          'args': {'taskId': 't1'},
        }))!['error'],
        contains('操作'),
      );
      expect(ran, 0);
    });
  });
}
