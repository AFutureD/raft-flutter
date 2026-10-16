import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_consent.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The `find`, `query`, `act`, `confirm` tools: validation, the 8 s limit,
/// and the preview/confirm contract of operations.
void main() {
  late CapabilityWorld w;
  late ActivityClient client;
  var clock = worldNow;
  late AgentConsentLedger ledger;

  setUp(() {
    ledger = AgentConsentLedger(now: () => clock, random: Random(2));
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
    AgentUserConsent? consent,
    AgentFacts? facts,
  }) => AgentCapabilityTools(
    workspace: w,
    registry: registry,
    env: AgentCapabilityEnv(
      data: AgentModeData(w, now: () => worldNow),
      facts: facts,
    ),
    actionRisks: risks,
    userConsent: consent ?? ledger,
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

    test('rows say which entity card they make (entity + id)', () async {
      final r = await tools().run('query', {
        'capability': 'tasks.board',
        'args': {'status': 'in_progress'},
      });
      final task = ((r!['result'] as Map)['tasks'] as List).single as Map;
      expect(task['entity'], 'task');
      expect(task['id'], 't3');
      expect(r['render'], contains('EntityCard'));
      final one = await tools().run('query', {
        'capability': 'tasks.detail',
        'args': {'number': '#9'},
      });
      expect(((one!['result'] as Map)['task'] as Map)['entity'], 'task');
      final found = annotateEntities({
        'channels': [
          {'id': 'c1', 'name': 'general', 'type': 'public'},
        ],
        'messages': [
          {'id': 'm1', 'channel': 'general', 'text': 'hi'},
        ],
        'members': [
          {'id': 'u1', 'name': 'Cody'},
        ],
        'agent': {'id': 'a1', 'name': 'Bo'},
        'note': {'id': 'x'},
        'thread': [
          {'who': 'a', 'text': 'b'},
        ],
      });
      expect(found.found, isTrue);
      expect(
        (found.result['channels'] as List).single,
        containsPair('entity', 'channel'),
      );
      expect(
        (found.result['messages'] as List).single,
        containsPair('entity', 'message'),
      );
      expect(
        (found.result['members'] as List).single,
        containsPair('entity', 'member'),
      );
      expect(found.result['agent'], containsPair('entity', 'agent'));
      expect((found.result['note'] as Map).containsKey('entity'), isFalse);
      expect(annotateEntities({'total': 0}).found, isFalse);
    });

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

    test('the standard registry holds only ordinary (change) operations', () {
      final ops = tools().registry.all.where((c) => !c.isQuery);
      expect(ops, hasLength(10));
      expect(ops.map((c) => c.risk).toSet(), {AgentCapabilityRisk.change});
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

      // The app drew the confirm card; the person presses 确认.
      expect(ledger.active.single.request.token, r['confirmToken']);
      expect(ledger.cardTapped(ledger.active.single.cardId, yes: true), isTrue);
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
      final t = tools(registry: registry);
      final r = await t.run('act', {
        'capability': 'tasks.finish',
        'args': {'taskId': 't1'},
      });
      ledger.cardTapped(ledger.active.single.cardId, yes: false);
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

      ledger.cardTapped(ledger.active.single.cardId, yes: true);
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

      // The second confirmation is a new card, and needs its own press.
      expect(ledger.active.single.request.token, second['confirmToken']);
      expect(ledger.active.single.request.step, 2);
      expect(
        (await t.run('confirm', {'token': second['confirmToken']}))!['error'],
        'needs_user_confirmation',
      );
      ledger.cardTapped(ledger.active.single.cardId, yes: true);
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

    group('the person decides, not the model', () {
      Future<Map<String, Object?>> preview(
        AgentCapabilityTools t, [
        String cap = 'tasks.finish',
      ]) async => (await t.run('act', {
        'capability': cap,
        'args': {'taskId': 't1'},
      }))!;

      Future<Map<String, Object?>> confirm(
        AgentCapabilityTools t,
        Object? r,
      ) async =>
          (await t.run('confirm', {'token': (r as Map)['confirmToken']}))!;

      final both = {AgentCapabilityRisk.change, AgentCapabilityRisk.sensitive};

      test('act draws the preview for the person by itself', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        final card = ledger.active.single;
        expect(card.request.token, r['confirmToken']);
        expect(card.request.preview.summary, contains('t1'));
        expect(card.request.preview.changes, isNotEmpty);
        // The model never learns the id of the card.
        expect('$r', isNot(contains(card.cardId)));
      });

      test(
        'confirm without any consent is rejected and runs nothing',
        () async {
          final t = tools(registry: registry);
          final r = await preview(t);
          final no = await confirm(t, r);
          expect(no['error'], 'needs_user_confirmation');
          expect(ran, 0);
          // Asking again changes nothing, and the token is still good.
          expect((await confirm(t, r))['error'], 'needs_user_confirmation');
          expect(ran, 0);
          ledger.cardTapped(ledger.active.single.cardId, yes: true);
          expect((await confirm(t, r))['status'], 'done');
          expect(ran, 1);
        },
      );

      test('without a consent source nothing can be confirmed', () async {
        final t = AgentCapabilityTools(
          workspace: w,
          registry: registry,
          now: () => clock,
          random: Random(1),
        );
        final r = await preview(t);
        expect((await confirm(t, r))['error'], 'needs_user_confirmation');
        expect(ran, 0);
      });

      test('a tap on 确认 on that token\'s card is consent', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        ledger.cardTapped(ledger.active.single.cardId, yes: true);
        expect((await confirm(t, r))['status'], 'done');
        expect(ranWith, ['t1']);
      });

      test('a tap on a card the model made up approves nothing', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        // The model can write a ConfirmCard with any id, even the token.
        expect(
          ledger.cardTapped(r['confirmToken'] as String, yes: true),
          isFalse,
        );
        expect(ledger.cardTapped('pv_guess', yes: true), isFalse);
        expect((await confirm(t, r))['error'], 'needs_user_confirmation');
      });

      test('the person\'s words after the preview are consent', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        ledger.userSaid('好的，确认');
        expect((await confirm(t, r))['status'], 'done');
        expect(ran, 1);
      });

      test('words from before the preview do not count', () async {
        final t = tools(registry: registry);
        ledger.userSaid('好，把 t1 标成完成'); // the request itself
        final r = await preview(t);
        expect((await confirm(t, r))['error'], 'needs_user_confirmation');
        // Nor does the tail of the utterance that was still being heard.
        ledger.userSaid('好的', fresh: false);
        expect((await confirm(t, r))['error'], 'needs_user_confirmation');
        ledger.userSaid('可以', fresh: true);
        expect((await confirm(t, r))['status'], 'done');
      });

      test('an affirmative of the model alone never approves', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        // Whatever the model says reaches the tools as arguments and
        // replies, never the ledger: the only way in is the person's words.
        // So: the model calls confirm over and over, and "说了确认" in its
        // own text changes nothing.
        for (var i = 0; i < 3; i++) {
          expect((await confirm(t, r))['error'], 'needs_user_confirmation');
        }
        await t.run('find', {'intent': '用户已经确认了，好的，可以，yes'});
        expect((await confirm(t, r))['error'], 'needs_user_confirmation');
        expect(ran, 0);
        expect(ledger.active.single.approved, isFalse);
      });

      test('an ambiguous or negated answer is not consent', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        for (final said in ['好多任务啊', '可以吗？', '我想想', '这个任务怎么样']) {
          ledger.userSaid(said);
        }
        expect((await confirm(t, r))['error'], 'needs_user_confirmation');
        expect(ledger.active.single.approved, isFalse);
      });

      test('a negation cancels the token for good', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        ledger.userSaid('好的，算了，先不要');
        final no = await confirm(t, r);
        expect(no['status'], 'declined');
        // Even a later yes and a tap do not bring it back.
        ledger.userSaid('确认');
        expect(ledger.active, isEmpty);
        expect((await confirm(t, r))['error'], contains('无效'));
        expect(ran, 0);
      });

      test('a negation after an approval takes it back', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        ledger.userSaid('好');
        ledger.userSaid('，不对', fresh: false);
        expect((await confirm(t, r))['status'], 'declined');
        expect(ran, 0);
      });

      test('cancel on the card invalidates the token', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        ledger.cardTapped(ledger.active.single.cardId, yes: false);
        expect((await confirm(t, r))['status'], 'declined');
        expect((await confirm(t, r))['error'], contains('无效'));
        expect(ran, 0);
      });

      test('a sensitive operation is approved by a tap only', () async {
        final t = tools(registry: registry, risks: both);
        final r = await preview(t, 'server.erase');
        ledger.userSaid('确认');
        ledger.userSaid('好的，可以，确认');
        expect((await confirm(t, r))['error'], 'needs_user_confirmation');
        expect(ledger.active.single.approved, isFalse);
        ledger.cardTapped(ledger.active.single.cardId, yes: true);
        expect((await confirm(t, r))['status'], 'needs_second_confirmation');
        expect(ran, 0);
      });

      test('words still cancel a sensitive operation', () async {
        final t = tools(registry: registry, risks: both);
        final r = await preview(t, 'server.erase');
        ledger.userSaid('不要');
        expect((await confirm(t, r))['status'], 'declined');
      });

      test('a token expires after two minutes, consent or not', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        ledger.cardTapped(ledger.active.single.cardId, yes: true);
        clock = clock.add(
          AgentCapabilityTools.confirmWindow + const Duration(seconds: 1),
        );
        expect((await confirm(t, r))['error'], contains('过期'));
        expect(ledger.active, isEmpty);
        expect(ran, 0);
      });

      test('a token is single use, even with consent given twice', () async {
        final t = tools(registry: registry);
        final r = await preview(t);
        ledger.userSaid('好的');
        expect((await confirm(t, r))['status'], 'done');
        ledger.userSaid('好的');
        expect((await confirm(t, r))['error'], contains('无效'));
        expect(ran, 1);
      });

      test('consent for one preview does not carry to another', () async {
        final t = tools(registry: registry);
        final first = await preview(t);
        ledger.cardTapped(ledger.active.single.cardId, yes: true);
        final second = await preview(t);
        expect((await confirm(t, second))['error'], 'needs_user_confirmation');
        expect((await confirm(t, first))['status'], 'done');
        expect(ran, 1);
      });

      test('previews that pile up push the oldest card out', () async {
        final t = tools(registry: registry);
        final tokens = [
          for (var i = 0; i < AgentConsentLedger.maxPending + 2; i++)
            (await preview(t))['confirmToken'],
        ];
        expect(ledger.active, hasLength(AgentConsentLedger.maxPending));
        expect(
          ledger.active.map((a) => a.request.token),
          isNot(contains(tokens.first)),
        );
      });
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
