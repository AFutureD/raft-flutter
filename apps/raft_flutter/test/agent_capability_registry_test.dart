import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_args.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_search.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/pubspec.yaml').existsSync() ||
      !Directory('${dir.path}/packages/raft_ui').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('repository root not found');
    dir = parent;
  }
  return dir;
}

AgentCapability _fake(
  String id, {
  AgentCapabilityKind kind = AgentCapabilityKind.query,
  AgentCapabilityRisk risk = AgentCapabilityRisk.read,
  AgentCapabilityPreview? preview,
  String? openRoute,
}) => AgentCapability(
  id: id,
  title: '测试能力',
  kind: kind,
  risk: risk,
  paramsSchema: const {'type': 'object', 'properties': {}},
  resultSummary: 'x',
  keywords: const ['测试'],
  run: (w, a, e) async => {},
  preview: preview,
  openRoute: openRoute,
);

void main() {
  final registry = agentStandardCapabilities;

  group('registry integrity', () {
    test('about thirty read capabilities and the ordinary operations', () {
      expect(registry.queries.length, greaterThanOrEqualTo(30));
      for (final c in registry.all) {
        expect(
          AgentCapabilityRegistry.integrityProblems(c),
          isEmpty,
          reason: c.id,
        );
        if (c.isQuery) {
          expect(c.risk, AgentCapabilityRisk.read, reason: c.id);
        } else {
          // Phase 2: ordinary changes only, each previewed.
          expect(c.risk, AgentCapabilityRisk.change, reason: c.id);
          expect(c.preview, isNotNull, reason: c.id);
        }
      }
      expect(
        [
          for (final c in registry.all)
            if (!c.isQuery) c.id,
        ],
        unorderedEquals([
          'messages.send',
          'messages.reply_thread',
          'messages.react',
          'activity.mark_read',
          'activity.mark_done',
          'channels.join',
          'tasks.create',
          'tasks.set_status',
          'tasks.assign',
          'tasks.unassign',
        ]),
      );
    });

    test('ids are unique and domain.verb', () {
      final ids = [for (final c in registry.all) c.id];
      expect(ids.toSet().length, ids.length);
      expect(ids, everyElement(matches(AgentCapabilityRegistry.idPattern)));
    });

    test('a malformed or duplicated capability is refused on construction', () {
      expect(
        () => AgentCapabilityRegistry([_fake('Bad Id')]),
        throwsArgumentError,
      );
      expect(
        () => AgentCapabilityRegistry([_fake('a.b'), _fake('a.b')]),
        throwsArgumentError,
      );
      // A query cannot carry a risk, an action needs a preview.
      expect(
        () => AgentCapabilityRegistry([
          _fake('a.b', risk: AgentCapabilityRisk.change),
        ]),
        throwsArgumentError,
      );
      expect(
        () => AgentCapabilityRegistry([
          _fake(
            'a.c',
            kind: AgentCapabilityKind.action,
            risk: AgentCapabilityRisk.change,
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => AgentCapabilityRegistry([
          _fake(
            'a.d',
            kind: AgentCapabilityKind.action,
            risk: AgentCapabilityRisk.neverByVoice,
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('every parity key exists in docs/capability-parity.json', () {
      final file = File('${_repoRoot().path}/docs/capability-parity.json');
      final entries = {
        for (final e
            in (jsonDecode(file.readAsStringSync()) as Map)['entries'] as List)
          (e as Map)['id'] as String: e['status'] as String,
      };
      var withKey = 0;
      // The only capability that reads no server endpoint.
      const local = {'agent.audit_log'};
      for (final c in registry.all) {
        final key = c.parity;
        if (key == null) {
          expect(local, contains(c.id), reason: '${c.id} has no parity key');
          continue;
        }
        withKey++;
        expect(entries, contains(key), reason: '${c.id} -> $key');
        // The Flutter client has the call: the capability rides on it.
        expect(
          const {'covered', 'partial'},
          contains(entries[key]),
          reason: '${c.id} -> $key is ${entries[key]}',
        );
      }
      expect(withKey, registry.all.length - local.length);
    });
  });

  group('argument checking', () {
    final schema = {
      'type': 'object',
      'properties': {
        'status': {
          'type': 'string',
          'enum': ['todo', 'done'],
        },
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 30,
          'default': 12,
        },
        'mine': {'type': 'boolean'},
        'name': {'type': 'string', 'maxLength': 5},
      },
      'required': ['status'],
    };

    test(
      'defaults fill in, numbers and booleans sent as text are understood',
      () {
        final r = checkAgentArgs(schema, {
          'status': 'todo',
          'limit': '5',
          'mine': 'true',
        });
        expect(r.ok, isTrue);
        expect(r.args, {'status': 'todo', 'limit': 5, 'mine': true});
        expect(checkAgentArgs(schema, {'status': 'done'}).args['limit'], 12);
      },
    );

    test('unknown, missing, out of range and wrong values are named', () {
      String all(Object? given) =>
          checkAgentArgs(schema, given).problems.join('|');
      expect(all({'status': 'todo', 'colour': 'x'}), contains('未知参数 colour'));
      expect(all({}), contains('缺少参数 status'));
      expect(all({'status': 'later'}), contains('todo / done'));
      expect(all({'status': 'todo', 'limit': 99}), contains('不能大于 30'));
      expect(all({'status': 'todo', 'limit': 2.5}), contains('整数'));
      expect(all({'status': 'todo', 'name': 'toolong'}), contains('最长 5'));
      expect(all('nope'), contains('必须是对象'));
    });
  });

  group('find', () {
    final index = AgentCapabilityIndex(registry.all);

    // Ten things a person says, and the capability that should come first.
    const intents = {
      '现在所有的 Agent 都在干什么': 'agents.list',
      '任务 #94 现在怎么样了': 'tasks.detail',
      '有哪些任务在等验收': 'tasks.board',
      '帮我搜一下昨天谁说过上线': 'messages.search',
      '我有多少未读消息': 'inbox.unread_summary',
      '谁@了我': 'activity.mentions',
      'general 频道最近聊了什么': 'channels.recent_messages',
      '我收藏的消息': 'saved.list',
      '哪台电脑离线了': 'computers.list',
      'Cindy 刚才做了什么': 'agents.activity_log',
      '这个任务什么时候改的状态': 'tasks.history',
      '团队有哪些成员': 'members.list',
    };

    for (final e in intents.entries) {
      test('“${e.key}” finds ${e.value} first', () {
        final hits = index.find(e.key);
        expect(hits, isNotEmpty);
        expect(hits.length, lessThanOrEqualTo(5));
        expect(
          hits.first.id,
          e.value,
          reason: hits.map((c) => c.id).join(', '),
        );
      });
    }

    test('deterministic, and nothing relevant finds nothing', () {
      expect(
        [for (final c in index.find('任务看板')) c.id],
        [for (final c in index.find('任务看板')) c.id],
      );
      expect(index.find('zzzz qqqq'), isEmpty);
      expect(index.find(''), isEmpty);
    });
  });

  group('every read runs on the app data layer', () {
    late CapabilityWorld w;
    late ActivityClient client;
    final env = const AgentCapabilityEnv();

    setUp(() {
      final world = capabilityWorld();
      client = world.$1;
      w = world.$2;
      w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'in_review')
            taskRow(
              't94',
              94,
              'in_review',
              title: '选型',
              claimedById: 'a-cody',
              claimedByName: 'Cody',
            ),
          if (q?['status'] == 'in_progress')
            taskRow(
              't95',
              95,
              'in_progress',
              title: '修复',
              claimedById: 'a-cindy',
              claimedByName: 'Cindy',
            ),
        ],
      };
      w.routes['/tasks/channel/ch-general/number/94'] = (_) => {
        'task': {
          'id': 't94',
          'taskNumber': 94,
          'title': '选型',
          'status': 'in_review',
        },
      };
      w.routes['/tasks/t94/history'] = (_) => {
        'events': [
          {
            'eventType': 'created',
            'actorName': 'Kevin',
            'createdAt': hoursAgo(5),
            'payload': {'status': 'todo'},
          },
          {
            'eventType': 'status_changed',
            'actorName': 'Cody',
            'createdAt': hoursAgo(2),
            'payload': {'from': 'todo', 'to': 'in_review'},
          },
        ],
      };
      w.routes['/channels/inbox'] = (_) => {
        'items': [
          {
            'kind': 'channel',
            'channelId': 'ch-general',
            'channelName': 'general',
            'lastMessagePreview': 'hello',
            'lastMessageSenderName': 'Ada',
            'unreadCount': 3,
            'hasMention': true,
          },
        ],
        'totalUnreadCount': 3,
        'hasMore': false,
      };
      w.routes['/channels/inbox/done'] = (_) => {'items': []};
      w.routes['/channels/saved'] = (_) => {
        'saved': [
          {
            'messageId': 'm9',
            'channelId': 'ch-general',
            'channelName': 'general',
            'senderName': 'Ada',
            'content': 'keep this',
            'createdAt': hoursAgo(1),
          },
        ],
        'total': 1,
      };
      w.routes['/messages/search'] = (_) => {
        'results': [
          {
            'id': 'm1',
            'channelId': 'ch-general',
            'channelName': 'general',
            'senderName': 'Ada',
            'senderId': 'ada',
            'content': '上线了',
            'createdAt': hoursAgo(1),
          },
        ],
        'hasMore': false,
      };
      w.routes['/messages/context/m1'] = (_) => {};
      w.routes['/channels/ch-general/members'] = (_) => {
        'humans': [
          {'userId': 'ada', 'displayName': 'Ada', 'role': 'member'},
        ],
        'agents': [
          {'id': 'a-cody', 'name': 'cody'},
        ],
      };
      w.routes['/channels/ch-general/files'] = (_) => {
        'files': [
          {
            'id': 'f1',
            'filename': 'a.png',
            'mimeType': 'image/png',
            'size': 10,
            'createdAt': hoursAgo(1),
          },
        ],
      };
      w.routes['/agents/a-cody'] = (_) => {'description': 'Writes code'};
      w.routes['/agents/a-cody/activity-log'] = (_) => [
        {
          'timestamp': worldNow.millisecondsSinceEpoch - 60000,
          'entry': {'kind': 'tool_start', 'toolName': 'bash', 'detail': 'ls'},
        },
      ];
      w.routes['/agents/a-cody/channels'] = (_) => {
        'channels': [
          {'id': 'ch-general', 'name': 'general'},
        ],
      };
      w.routes['/reminders'] = (_) => {
        'reminders': [
          {'reminderId': 'r1', 'title': 'standup', 'fireAt': hoursAgo(-3)},
        ],
      };
      w.routes['/servers/s1/members/ada/profile'] = (_) => {
        'name': 'Ada',
        'role': 'member',
        'email': 'ada@example.test',
        'joinedAt': hoursAgo(900),
      };
      w.routes['/servers/s1/machines/m1/runtime-options'] = (_) => {
        'runtimes': [
          {'id': 'codex', 'name': 'Codex', 'available': true},
        ],
      };
      client.responses['GET /messages/channel/ch-general'] = {
        'messages': [
          {
            'id': 'm1',
            'seq': '10',
            'senderName': 'Ada',
            'content': '早',
            'createdAt': hoursAgo(2),
          },
          {
            'id': 'm2',
            'seq': '11',
            'senderName': 'Cody',
            'content': '好',
            'createdAt': hoursAgo(1),
          },
        ],
        'hasMore': true,
      };
      client.responses['GET /messages/channel/th-1'] = {
        'messages': [
          {
            'id': 'r1',
            'seq': '3',
            'senderName': 'Ada',
            'content': '回复',
            'createdAt': hoursAgo(1),
          },
        ],
      };
      client.responses['GET /messages/context/m1'] = {
        'targetMessageId': 'm1',
        'messages': [
          {
            'id': 'm0',
            'seq': '9',
            'senderName': 'Ada',
            'content': '前',
            'createdAt': hoursAgo(3),
          },
          {
            'id': 'm1',
            'seq': '10',
            'senderName': 'Ada',
            'content': '上线了',
            'createdAt': hoursAgo(2),
          },
        ],
      };
    });
    tearDown(() async {
      w.dispose();
      await client.dispose();
    });

    // capability id -> (args, a key the result must have)
    final cases = <String, (Map<String, Object?>, String)>{
      'channels.list': ({}, 'channels'),
      'dms.list': ({}, 'dms'),
      'channels.detail': ({'channel': 'general'}, 'channel'),
      'channels.recent_messages': ({'channel': '#general'}, 'messages'),
      'threads.messages': ({'threadId': 'th-1'}, 'messages'),
      'channels.members': ({'channel': 'general'}, 'humans'),
      'channels.files': ({'channel': 'general'}, 'files'),
      'inbox.unread_summary': ({}, 'totalUnread'),
      'activity.inbox': ({'filter': 'unread'}, 'items'),
      'activity.mentions': ({}, 'items'),
      'activity.done': ({}, 'items'),
      'threads.followed': ({}, 'threads'),
      'saved.list': ({}, 'saved'),
      'messages.search': ({'q': '上线'}, 'messages'),
      'messages.context': ({'messageId': 'm1'}, 'messages'),
      'tasks.board': ({}, 'tasks'),
      'tasks.mine': ({'role': 'created'}, 'tasks'),
      'tasks.search': ({'query': '选型'}, 'tasks'),
      'tasks.history': ({'taskId': 't94'}, 'events'),
      'agents.list': ({}, 'agents'),
      'agents.detail': ({'agent': 'Cody'}, 'agent'),
      'agents.activity_log': ({'agent': 'cody'}, 'entries'),
      'agents.reminders': ({'agent': 'Cody'}, 'reminders'),
      'agents.channels': ({'agent': 'Cody'}, 'channels'),
      'computers.list': ({}, 'computers'),
      'computers.detail': ({'computer': 'Studio'}, 'computer'),
      'members.list': ({}, 'members'),
      'members.profile': ({'member': 'Ada'}, 'member'),
      'server.info': ({}, 'current'),
      'agent.audit_log': ({}, 'entries'),
    };

    test('the smoke table covers every registered capability but one', () {
      // tasks.detail has its own tests below (ambiguity, ids).
      expect(
        {for (final c in registry.queries) c.id}.difference(cases.keys.toSet()),
        {'tasks.detail'},
      );
    });

    for (final entry in cases.entries) {
      test('${entry.key} answers from the data layer', () async {
        final c = registry[entry.key]!;
        final checked = checkAgentArgs(c.paramsSchema, entry.value.$1);
        expect(checked.problems, isEmpty);
        final result = await c.run(w, checked.args, env);
        expect(result, contains(entry.value.$2));
      });
    }

    test('channel names resolve, ambiguity comes back as candidates', () async {
      final c = registry['channels.detail']!;
      final hit = await c.run(w, {'channel': 'general'}, env);
      expect((hit['channel'] as Map)['id'], 'ch-general');
      expect(
        () => c.run(w, {'channel': 'design'}, env),
        returnsNormally, // exact name wins over the longer one
      );
      final partial = registry['channels.recent_messages']!;
      await expectLater(
        partial.run(w, {'channel': 'des'}, env),
        throwsA(
          isA<AgentCapabilityError>().having(
            (e) => e.candidates?.length,
            'candidates',
            2,
          ),
        ),
      );
      await expectLater(
        partial.run(w, {'channel': 'nowhere'}, env),
        throwsA(isA<AgentCapabilityError>()),
      );
    });

    test('messages page backwards and keep the ids', () async {
      final r = await registry['channels.recent_messages']!.run(w, {
        'channel': 'general',
        'limit': 15,
      }, env);
      expect(r['hasMore'], true);
      expect(r['olderThanSeq'], '10');
      final ids = [for (final m in r['messages'] as List) (m as Map)['id']];
      expect(ids, ['m1', 'm2']);
    });

    test('search sends the filters the search page sends', () async {
      await registry['messages.search']!.run(w, {
        'q': '上线',
        'channel': 'general',
        'sender': 'Ada Lee',
        'within': '7d',
        'limit': 5,
        'sort': 'recent',
      }, env);
      final q = w.queries['/messages/search']!;
      expect(q['q'], '上线');
      expect(q['channelId'], 'ch-general');
      expect(q['senderId'], 'ada2');
      expect(q['limit'], 5);
      expect(q['sort'], 'recent');
      expect(q, contains('after'));
      await expectLater(
        registry['messages.search']!.run(w, {}, env),
        throwsA(isA<AgentCapabilityError>()),
      );
      await expectLater(
        registry['messages.search']!.run(w, {'q': 'x', 'sender': 'ad'}, env),
        throwsA(
          isA<AgentCapabilityError>().having(
            (e) => e.candidates?.length,
            'candidates',
            2,
          ),
        ),
      );
    });

    test(
      'the board filters by assignee and reads each lane through its cursor',
      () async {
        final r = await registry['tasks.board']!.run(w, {
          'assignee': 'cody',
          'status': 'open',
        }, env);
        expect(r['total'], 1);
        final task = (r['tasks'] as List).single as Map;
        expect(task['id'], 't94');
        expect(task['number'], 94);
        expect(w.reads.where((p) => p == '/tasks/server').length, 3);
        final mine = await registry['tasks.mine']!.run(w, {
          'role': 'created',
        }, env);
        expect(mine['total'], 2); // both created by Kevin
      },
    );

    test('a task read teaches the facts and keeps its ids', () async {
      final facts = AgentFactsProbe();
      final r = await registry['tasks.board']!.run(
        w,
        {},
        AgentCapabilityEnv(facts: facts.facts),
      );
      expect(r['total'], 2);
      expect(facts.facts.taskId(94), 't94');
      final history = await registry['tasks.history']!.run(w, {
        'taskId': 't94',
      }, env);
      expect((history['events'] as List).last, containsPair('to', 'in_review'));
    });

    test('a profile leaves out contact details', () async {
      final r = await registry['members.profile']!.run(w, {
        'member': 'Ada',
      }, env);
      expect(jsonEncode(r), isNot(contains('example.test')));
    });
  });
}
