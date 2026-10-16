import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' hide AgentEntityRef;
import 'package:raft_agent_ui/raft_agent_ui.dart' as ui show AgentEntityRef;
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_entity_binding.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_stream.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_read_tools.dart';
import 'package:raft_flutter/features/agent_mode/references/agent_reference_table.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_runtime.dart';
import 'package:raft_flutter/features/agent_mode/runtime/agent_tool_set.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The direct read tools: one call, the app draws the cards, the model has
/// one sentence left to say.
void main() {
  late ActivityClient client;
  late CapabilityWorld w;
  late AgentRuntime rt;
  final begun = <AgentSurfaceDraft>[];
  var refs = AgentReferenceTable.empty;
  var phone = false;

  setUp(() {
    begun.clear();
    phone = false;
    refs = AgentReferenceTable.empty;
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_review')
          taskRow('t94', 94, 'in_review', title: '选型', claimedByName: 'Cody'),
        if (q?['status'] == 'in_progress')
          taskRow(
            't95',
            95,
            'in_progress',
            title: '修复',
            claimedByName: 'Cindy',
          ),
        if (q?['status'] == 'todo')
          taskRow('t96', 96, 'todo', title: '文档', channel: 'design'),
      ],
    };
    w.routes['/channels/inbox'] = (q) => {
      'items': [
        {
          'kind': 'channel',
          'channelId': 'ch-general',
          'channelName': 'general',
          'lastMessagePreview': 'hello',
          'lastMessageSenderName': 'Ada',
          'unreadCount': 3,
          'hasMention': q?['filter'] == 'mentions',
        },
        {
          'kind': 'thread',
          'parentChannelId': 'ch-design',
          'parentChannelName': 'design',
          'threadChannelId': 'th-1',
          'parentMessageId': 'm-parent',
          'latestActivityPreview': '回复',
          'latestActivitySenderName': 'Cody',
        },
      ],
      'totalUnreadCount': 3,
      'hasMore': false,
    };
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
        for (final id in ['m1', 'm2'])
          {
            'id': id,
            'channelId': 'ch-general',
            'channelName': 'general',
            'senderName': 'Ada',
            'senderId': 'ada',
            'content': '上线了 $id',
            'createdAt': hoursAgo(1),
          },
      ],
      'hasMore': false,
    };
    w.routes['/agents/a-cody'] = (_) => {'description': 'Writes code'};
    w.routes['/agents/a-cody/activity-log'] = (_) => [
      {
        'timestamp': worldNow.millisecondsSinceEpoch - 120000,
        'entry': {'kind': 'tool_start', 'toolName': 'bash', 'detail': 'ls'},
      },
      {
        'timestamp': worldNow.millisecondsSinceEpoch - 60000,
        'entry': {'kind': 'tool_start', 'toolName': 'git', 'detail': 'status'},
      },
    ];
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
    w.routes['/tasks/channel/ch-general/number/94'] = (_) => {
      'task': taskRow('t94', 94, 'in_review', title: '选型'),
    };
    w.routes['/messages/context/m-1'] = (_) => {
      'messages': [
        {
          'id': 'm-1',
          'channelId': 'ch-general',
          'content': '周五上线？',
          'senderName': 'Cody',
          'createdAt': hoursAgo(3),
          'seq': '10',
        },
      ],
    };
    w.routes['/channels/ch-general/threads/m-1'] = (_) => {
      'threadChannelId': 'th-1',
    };
    client.responses['GET /messages/channel/th-1'] = {
      'messages': [
        for (final (i, id) in ['r1', 'r2', 'r3'].indexed)
          {
            'id': id,
            'seq': '${20 + i}',
            'senderName': 'Ada',
            'content': '回复 $id',
            'createdAt': hoursAgo(2),
          },
      ],
    };
    rt = AgentRuntime(
      workspace: w,
      data: AgentModeData(w, now: () => worldNow),
      surfaces: AgentSurfaceHost(
        begin: (d) {
          begun.add(d);
          return const {};
        },
        changed: (d, {added}) => const {},
        isOpen: begun.contains,
      ),
      references: () => refs,
      compact: () => phone,
    );
  });
  tearDown(() async {
    rt.dispose();
    w.dispose();
    await client.dispose();
  });

  List<SurfaceNode> cards(AgentSurfaceDraft d) => [
    for (final n in d.root.walk())
      if (n.component == AgentEntityComponents.entity) n,
  ];

  /// Whatever the phone would fold into one row.
  Set<String> folded(AgentSurfaceDraft d) =>
      foldedPaths(agentStandardCatalog, d.root, compact: true);

  group('show_list: one call, the whole list as cards', () {
    // kind, the cards it draws as (entity, id).
    final expected = <String, List<(String, String)>>{
      'channels': [
        ('channel', 'ch-design'),
        ('channel', 'ch-design2'),
        ('channel', 'ch-general'),
      ],
      'dms': [('channel', 'dm-1')],
      'tasks': [('task', 't94'), ('task', 't95'), ('task', 't96')],
      'agents': [('agent', 'a-cody'), ('agent', 'a-cindy')],
      'computers': [('computer', 'm1'), ('computer', 'm2')],
      'members': [('member', 'kevin'), ('member', 'ada'), ('member', 'ada2')],
      'saved': [('message', 'm9')],
      'inbox': [('channel', 'ch-general'), ('message', 'm-parent')],
      'mentions': [('channel', 'ch-general'), ('message', 'm-parent')],
    };

    for (final kind in agentListKinds) {
      test(kind, () async {
        final r = await rt.runTool('show_list', {'kind': kind});
        expect(r['ok'], isTrue, reason: '$r');
        // One layer, built in this one call.
        expect(begun, hasLength(1));
        final draft = begun.single;
        expect(draft.ended, isTrue);
        final shown = [
          for (final n in cards(draft)) (n.string('entity')!, n.string('id')!),
        ];
        expect(shown, unorderedEquals(expected[kind]!));
        expect(r['shown'], shown.length);
        // Full: the cards inherit detail from the screen and none of them
        // says less; nothing is folded on a phone.
        expect(draft.root.props['childDisplay'], {'level': 'detail'});
        expect([
          for (final n in cards(draft)) n.props['display'],
        ], everyElement(isNull));
        expect(folded(draft), isEmpty);
        // The model has one sentence to say, and nothing to read out.
        expect(r['say'], contains('一句话'));
        expect(r.containsKey('cards'), isFalse);
      });
    }

    test('a task list is one group, in the order of the result', () async {
      await rt.runTool('show_list', {'kind': 'tasks'});
      final sections = [
        for (final n in begun.single.root.walk())
          if (n.component == AgentComponents.section) n.string('title'),
      ];
      expect(sections, ['任务 · 3']);
    });

    test(
      'filters reach the capability; what a kind cannot filter is said',
      () async {
        final r = await rt.runTool('show_list', {
          'kind': 'tasks',
          'status': 'in_review',
          'assignee': 'cody',
          'unread_only': true,
        });
        expect(w.queries['/tasks/server']!['status'], 'in_review');
        expect(r['ignoredFilters'], ['unread_only']);
        final channels = await rt.runTool('show_list', {
          'kind': 'channels',
          'unread_only': true,
        });
        expect(channels['shown'], 2);
        expect([
          for (final n in cards(begun.last)) n.string('id'),
        ], unorderedEquals(['ch-general', 'ch-design']));
      },
    );

    test('a lighter list is only given when asked for', () async {
      await rt.runTool('show_list', {
        'kind': 'agents',
        'childDisplay': {'level': 'minimum'},
      });
      final draft = begun.single;
      expect(draft.root.props['childDisplay'], {'level': 'minimum'});
      // The list itself is still shown whole, not folded into one row.
      expect(folded(draft), isEmpty);
    });

    test('nothing to list is said on screen too', () async {
      final r = await rt.runTool('show_list', {'kind': 'saved', 'query': 'x'});
      w.routes['/channels/saved'] = (_) => {'saved': [], 'total': 0};
      final none = await rt.runTool('show_list', {'kind': 'saved'});
      expect(r['ok'], isTrue);
      expect(none['shown'], 0);
      expect(
        begun.last.root.walk().any(
          (n) => n.component == AgentEntityComponents.callout,
        ),
        isTrue,
      );
    });

    test(
      'a wrong argument is refused with the reason, nothing is shown',
      () async {
        final r = await rt.runTool('show_list', {'kind': 'tickets'});
        expect(r['error'], contains('kind'));
        expect(begun, isEmpty);
        expect((await rt.runTool('show_list', {}))['error'], contains('kind'));
      },
    );
  });

  group('how dense a list is', () {
    Future<Map<String, Object?>?> childDisplay(
      Map<String, Object?> args, {
      String tool = 'show_list',
    }) async {
      await rt.runTool(tool, {'kind': 'tasks', ...args});
      return begun.last.root.props['childDisplay'] as Map<String, Object?>?;
    }

    test('medium on a phone, detail on a wide screen', () async {
      phone = true;
      expect(await childDisplay({}), {'level': 'medium'});
      phone = false;
      expect(await childDisplay({}), {'level': 'detail'});
    });

    test('every list kind and a search follow the width', () async {
      phone = true;
      for (final kind in agentListKinds) {
        await rt.runTool('show_list', {'kind': kind});
        expect(begun.last.root.props['childDisplay'], {'level': 'medium'});
      }
      await rt.runTool('search_messages', {'q': '上线'});
      expect(begun.last.root.props['childDisplay'], {'level': 'medium'});
      // One thing asked for by name is not a list: it is shown whole.
      await rt.runTool('show_item', {'kind': 'agent', 'id': 'a-cody'});
      expect(begun.last.root.props['childDisplay'], {'level': 'detail'});
    });

    test('what the model says is honored, on a phone too', () async {
      phone = true;
      expect(
        await childDisplay({
          'childDisplay': {'level': 'detail'},
        }),
        {'level': 'detail'},
      );
      expect(
        await childDisplay({
          'childDisplay': {'level': 'minimum'},
        }),
        {'level': 'minimum'},
      );
      // A look without a level keeps the width's level.
      expect(
        await childDisplay({
          'childDisplay': {
            'show': {'avatar': false},
          },
        }),
        {
          'level': 'medium',
          'show': {'avatar': false},
        },
      );
    });

    test('"详细一点" is one update on the screen\'s root', () async {
      phone = true;
      final r = await rt.runTool('show_list', {'kind': 'tasks'});
      final out = await rt.runTool('update_component', {
        'surface_id': r['surface_id'],
        'id': r['root'],
        'props': jsonEncode({
          'childDisplay': {'level': 'detail'},
        }),
      });
      expect(out['error'], isNull, reason: '$out');
      expect(begun.single.root.props['childDisplay'], {'level': 'detail'});
    });
  });

  group('"my tasks" are the ones that concern the person', () {
    Map<String, dynamic> row(
      String id,
      int number, {
      String createdById = 'ada',
      String? claimedById,
      String? claimedByType,
      String title = '任务',
    }) => {
      ...taskRow(
        id,
        number,
        'in_progress',
        title: title,
        createdById: createdById,
        createdByName: createdById,
        claimedById: claimedById,
        claimedByName: claimedById,
      ),
      'claimedByType': ?claimedByType,
    };

    setUp(() {
      w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'in_progress') ...[
            // Kevin created it and gave it to an agent.
            row('made', 1, createdById: 'kevin', claimedById: 'a-cody'),
            // Somebody else's, assigned to Kevin.
            row('given', 2, claimedById: 'kevin', claimedByType: 'user'),
            // Somebody else's, assigned to an agent, that names him.
            row('named', 3, claimedById: 'a-cody', title: '请 @Kevin 看一下'),
            // Nothing to do with him.
            row('other', 4, claimedById: 'a-cindy'),
          ],
        ],
      };
    });

    Future<List<String?>> ids(Map<String, Object?> args) async {
      final r = await rt.runTool('show_list', {'kind': 'tasks', ...args});
      expect(r['ok'], isTrue, reason: '$r');
      return [for (final n in cards(begun.last)) n.string('id')];
    }

    test('mine is created by me, assigned to me or mentioning me', () async {
      expect(await ids({'mine': true}), unorderedEquals(['made', 'given', 'named']));
      expect(
        await ids({'relation': 'any_mine'}),
        unorderedEquals(['made', 'given', 'named']),
      );
    });

    test('an explicit relation narrows it', () async {
      expect(await ids({'relation': 'assigned'}), ['given']);
      expect(await ids({'relation': 'created'}), ['made']);
      // The older way to ask, a literal assignee, still means just that.
      expect(await ids({'assignee': 'me'}), ['given']);
    });

    test('without mine every task is listed', () async {
      expect(await ids({}), hasLength(4));
    });

    test('tasks.mine and the attention layer share one rule', () async {
      final mine = await rt.runTool('query', {
        'capability': 'tasks.mine',
        'args': <String, Object?>{},
      });
      expect((mine['result'] as Map)['total'], 3, reason: '$mine');
      final only = await rt.runTool('query', {
        'capability': 'tasks.mine',
        'args': {'role': 'assigned'},
      });
      expect((only['result'] as Map)['total'], 1, reason: '$only');
      final me = AgentModeData(w, now: () => worldNow).me;
      final concerns = {
        for (final t in [row('made', 1, createdById: 'kevin'), row('given', 2, claimedById: 'kevin', claimedByType: 'user'), row('named', 3, title: '请 @Kevin 看一下'), row('other', 4, claimedById: 'a-cindy')])
          '${t['id']}': AgentModeData.relationOf(t, me),
      };
      expect(concerns['made']!.created, isTrue);
      expect(concerns['given']!.assigned, isTrue);
      expect(concerns['named']!.mentioned, isTrue);
      expect(
        [concerns['other']!.created, concerns['other']!.assigned, concerns['other']!.mentioned],
        everyElement(isFalse),
      );
    });

    test('the tool says what mine is', () {
      final show = agentReadToolDeclarations.firstWhere(
        (d) => d['name'] == 'show_list',
      );
      final props = (show['parameters'] as Map)['properties'] as Map;
      expect(props.keys, containsAll(['mine', 'relation']));
      expect(
        (props['relation'] as Map)['enum'],
        ['assigned', 'created', 'any_mine'],
      );
      expect(show['description'], contains('创建的、派给我的、或提到我的'));
    });
  });

  group('the order said is the order drawn', () {
    setUp(() {
      // Numbers and ages that disagree: #2 is the oldest, #133 the newest.
      w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'in_progress') ...[
            taskRow('t2', 2, 'in_progress', title: '最老', updated: 30),
            taskRow('t133', 133, 'in_progress', title: '最新', updated: 1),
          ],
          if (q?['status'] == 'in_review')
            taskRow('t50', 50, 'in_review', title: '中间', updated: 5),
          if (q?['status'] == 'todo')
            taskRow('t60', 60, 'todo', title: '同刻 60', updated: 9),
          if (q?['status'] == 'todo')
            taskRow('t61', 61, 'todo', title: '同刻 61', updated: 9),
        ],
      };
    });

    List<String?> drawn(AgentSurfaceDraft d) => [
      for (final n in cards(d)) n.string('id'),
    ];

    test('tasks: updated desc, ties by number, cards in that order', () async {
      final r = await rt.runTool('show_list', {'kind': 'tasks'});
      expect(r['order'], 'updated desc');
      final items = (r['items'] as List).cast<Map<String, Object?>>();
      // What the model is told is what the screen draws, card for card.
      expect([for (final i in items) i['id']], drawn(begun.single));
      expect([for (final i in items) i['id']], [
        't133',
        't50',
        't61',
        't60',
        't2',
      ]);
      expect([for (final i in items) i['handle']], ['①', '②', '③', '④', '⑤']);
      expect([for (final i in items) i['n']], [1, 2, 3, 4, 5]);
      expect(items.first['label'], startsWith('#133'));
      expect(items.first['note'], contains('进行中'));
      expect(r['say'], contains('编号'));
    });

    test('the order does not depend on how the server answered', () async {
      await rt.runTool('show_list', {'kind': 'tasks'});
      final first = drawn(begun.last);
      final fixed = w.routes['/tasks/server']!;
      w.routes['/tasks/server'] = (q) {
        final body = fixed(q) as Map<String, dynamic>;
        return {'tasks': (body['tasks'] as List).reversed.toList()};
      };
      await rt.runTool('show_list', {'kind': 'tasks'});
      expect(drawn(begun.last), first);
    });

    test('a status filter keeps the same rule', () async {
      final r = await rt.runTool('show_list', {
        'kind': 'tasks',
        'status': 'todo',
      });
      expect([for (final i in r['items'] as List) (i as Map)['id']], [
        't61',
        't60',
      ]);
      expect(drawn(begun.last), ['t61', 't60']);
    });

    test('other lists say their order too', () async {
      final channels = await rt.runTool('show_list', {'kind': 'channels'});
      expect(channels['order'], 'name asc');
      final ids = [for (final i in channels['items'] as List) (i as Map)['id']];
      expect(ids, drawn(begun.last));
      final saved = await rt.runTool('show_list', {'kind': 'saved'});
      expect(saved['order'], isA<String>());
      expect((saved['items'] as List).first, containsPair('handle', '①'));
    });

    test('a search says its order and numbers its hits', () async {
      final r = await rt.runTool('search_messages', {
        'q': '上线',
        'sort': 'recent',
      });
      expect(r['order'], 'newest first');
      expect(w.queries['/messages/search']!['sort'], 'recent');
      final items = (r['items'] as List).cast<Map<String, Object?>>();
      expect([for (final i in items) i['id']], drawn(begun.last));
      expect([for (final i in items) i['handle']], ['①', '②']);
      final plain = await rt.runTool('search_messages', {'q': '上线'});
      expect(plain['order'], 'relevance');
    });
  });

  group('the other direct reads', () {
    test('search_messages draws the hits as message cards', () async {
      final r = await rt.runTool('search_messages', {
        'q': '上线',
        'sender': 'Ada',
        'since': '7d',
      });
      expect(r['ok'], isTrue, reason: '$r');
      expect(begun, hasLength(1));
      expect(
        [for (final n in cards(begun.single)) n.string('id')],
        ['m1', 'm2'],
      );
      expect(w.queries['/messages/search']!['q'], '上线');
      expect(r['say'], contains('一句话'));
    });

    test('show_item by name, by id and by the number on screen', () async {
      final byName = await rt.runTool('show_item', {
        'kind': 'agent',
        'name': 'Cody',
      });
      expect(byName['ok'], isTrue, reason: '$byName');
      expect(cards(begun.last).single.string('id'), 'a-cody');
      expect(cards(begun.last).single.string('emphasis'), 'high');

      await rt.runTool('show_item', {'kind': 'task', 'number': 94});
      expect(cards(begun.last).single.string('id'), 't94');

      await rt.runTool('show_item', {'kind': 'channel', 'id': 'ch-design'});
      expect(cards(begun.last).single.string('id'), 'ch-design');

      final lost = await rt.runTool('show_item', {
        'kind': 'agent',
        'handle': '③',
      });
      expect(lost['error'], contains('③'));
    });

    test('show_item resolves a handle through the reference table', () async {
      final screen = AgentReferenceTable('l', [
        const AgentEntityRef(type: 'task', id: 't94', label: '#94 选型').at(1),
      ]);
      final other = AgentRuntime(
        workspace: w,
        data: AgentModeData(w, now: () => worldNow),
        surfaces: AgentSurfaceHost(
          begin: (d) {
            begun.add(d);
            return const {};
          },
          changed: (d, {added}) => const {},
          isOpen: begun.contains,
        ),
        references: () => screen,
      );
      addTearDown(other.dispose);
      final r = await other.runTool('show_item', {
        'kind': 'task',
        'handle': '①',
      });
      expect(r['ok'], isTrue, reason: '$r');
      expect(cards(begun.last).single.string('id'), 't94');
      expect(r['refs'], contains('①'));
    });

    test('show_thread: the message and all its replies', () async {
      final r = await rt.runTool('show_thread', {'message': 'm-1'});
      expect(r['ok'], isTrue, reason: '$r');
      final ids = [for (final n in cards(begun.single)) n.string('id')];
      expect(ids, ['m-1', 'r1', 'r2', 'r3']);
      expect(folded(begun.single), isEmpty);
    });

    test('show_agent_activity: the agent card and a timeline', () async {
      final r = await rt.runTool('show_agent_activity', {'agent': 'cody'});
      expect(r['ok'], isTrue, reason: '$r');
      final nodes = begun.single.root.walk().toList();
      expect(cards(begun.single).single.string('id'), 'a-cody');
      final timeline = nodes.firstWhere(
        (n) => n.component == AgentEntityComponents.timeline,
      );
      expect(timeline.list('items'), hasLength(2));
      expect(r['last'], contains('git'));
    });

    test('show_task_history: the task card and a timeline', () async {
      final r = await rt.runTool('show_task_history', {'task': '#94'});
      expect(r['ok'], isTrue, reason: '$r');
      expect(cards(begun.single).single.string('id'), 't94');
      final timeline = begun.single.root.walk().firstWhere(
        (n) => n.component == AgentEntityComponents.timeline,
      );
      expect(timeline.list('items'), hasLength(2));
      expect((timeline.list('items').last as Map)['title'], contains('Cody'));
    });

    test(
      'what is read may not outlive the request that asked for it',
      () async {
        rt.submitText('看所有任务');
        final slow = rt.runTool('show_list', {'kind': 'tasks'});
        // The person changes their mind before the read is back.
        rt.submitText('算了');
        expect((await slow)['cancelled'], isTrue);
        await pumpEventQueue();
        expect(begun, isEmpty);
      },
    );
  });

  group('which tool for which request', () {
    final tools = {
      for (final d in agentModeToolDeclarations()) '${d['name']}': d,
    };
    final prompt = agentSystemPrompt(channels: 'general');

    Map<String, Object?> props(String tool) =>
        ((tools[tool]!['parameters'] as Map)['properties'] as Map)
            .cast<String, Object?>();

    test('list and search are different tools with different arguments', () {
      // A list needs no keywords, a search needs words (or a sender or time).
      expect(
        props('show_list').keys,
        containsAll(['kind', 'status', 'unread_only']),
      );
      expect(props('show_list').keys, isNot(contains('q')));
      expect(((tools['show_list']!['parameters'] as Map)['required']), [
        'kind',
      ]);
      expect(
        props('search_messages').keys,
        containsAll(['q', 'sender', 'since']),
      );
      expect(
        (((tools['search_messages']!['parameters'] as Map)['required'])
                as List?) ??
            const [],
        isEmpty,
      );
      expect(
        ((props('show_list')['kind'] as Map)['enum'] as List).toSet(),
        agentListKinds.toSet(),
      );
      expect(tools['show_list']!['description'], contains('看所有'));
      expect(tools['show_list']!['description'], contains('完整'));
      expect(tools['search_messages']!['description'], contains('搜'));
      expect(tools['show_list']!['description'], contains('search_messages'));
      expect(tools['search_messages']!['description'], contains('show_list'));
    });

    // What a person says, and the one tool that answers it. The examples are
    // in the prompt as 「…」→ tool; each tool exists, and the phrase is next to
    // exactly the tool the product wants.
    const routing = {
      '看所有任务': 'show_list',
      '列出频道': 'show_list',
      '有哪些 Agent': 'show_list',
      '等验收的任务': 'show_list',
      '有未读的频道': 'show_list',
      '搜一下发布': 'search_messages',
      'Cody 昨天说了什么': 'search_messages',
      '看看 Cody': 'show_item',
      '#98 怎么样': 'show_item',
      '这条下面说了什么': 'show_thread',
      'Cody 在干嘛': 'show_agent_activity',
      '#98 什么时候改的状态': 'show_task_history',
      '在 #general 说': 'send_message',
      '回复这条': 'reply_in_thread',
      '把 #98 改成进行中': 'set_task_status',
      '指派给 Cody': 'assign_task',
      '加入 #design': 'join_channel',
    };

    for (final e in routing.entries) {
      test('「${e.key}」 → ${e.value}', () {
        expect(tools, contains(e.value));
        // The sentence that carries the example names its tool, and no
        // example of a different kind of request shares the sentence.
        final example = RegExp(
          '「[^」]*${RegExp.escape(e.key)}[^」]*」[^；。\n]*?→\\s*(\\w+)',
        ).firstMatch(prompt);
        expect(example, isNotNull, reason: '${e.key} is not an example');
        expect(example![1], e.value);
      });
    }

    test('one tool per request, no chains, and the model never approves', () {
      expect(prompt, contains('一句话只调用一个'));
      expect(prompt, contains('不要先 find 再 query'));
      expect(prompt, contains('永远不要自己调用 confirm'));
      expect(prompt, contains('undo'));
      expect(prompt, contains('needs_user_consent'));
      expect(prompt, contains('additive'));
      // Short: the old prompt was about 5000 characters.
      expect(prompt.length, lessThan(4200));
    });

    test('every tool is declared once, with a description', () {
      final names = [for (final d in agentModeToolDeclarations()) d['name']];
      expect(names.toSet(), hasLength(names.length));
      for (final d in agentModeToolDeclarations()) {
        expect(
          '${d['description'] ?? ''}'.trim(),
          isNotEmpty,
          reason: '${d['name']}',
        );
      }
      expect(names, isNot(contains('show_tasks')));
      expect(names, containsAll(agentReadToolNames));
    });

    test('the turn parameter is added to the tools that start a request', () {
      final declared = {
        for (final d in agentTurnToolDeclarations(agentModeToolDeclarations()))
          '${d['name']}': d,
      };
      for (final name in [
        'show_list',
        'search_messages',
        'send_message',
        'act',
      ]) {
        final p = (declared[name]!['parameters'] as Map)['properties'] as Map;
        expect(p, contains('additive'), reason: name);
      }
      for (final name in ['confirm', 'undo', 'set_mood', 'spotlight']) {
        final params = declared[name]!['parameters'] as Map?;
        expect(
          params?['properties'] as Map? ?? const {},
          isNot(contains('additive')),
          reason: name,
        );
      }
      // Required parameters stay required.
      expect((declared['show_list']!['parameters'] as Map)['required'], [
        'kind',
      ]);
    });

    test('the registry behind them has every capability they read', () {
      for (final id in [
        'channels.list',
        'dms.list',
        'tasks.board',
        'agents.list',
        'computers.list',
        'members.list',
        'saved.list',
        'activity.inbox',
        'activity.mentions',
        'messages.search',
        'threads.messages',
        'agents.activity_log',
        'tasks.history',
      ]) {
        expect(agentStandardCapabilities[id], isNotNull, reason: id);
        expect(agentStandardCapabilities[id]!.kind, AgentCapabilityKind.query);
      }
    });
  });

  group('display: how the cards look, asked for and changed on screen', () {
    setUp(() {
      w.routes['/channels/saved'] = (_) => {
        'saved': [
          for (final id in ['m9', 'm10'])
            {
              'messageId': id,
              'channelId': 'ch-general',
              'channelName': 'general',
              'senderName': 'Ada',
              'content': 'keep $id',
              'createdAt': hoursAgo(1),
            },
        ],
        'total': 2,
      };
    });

    Future<Map<String, Object?>> update(Map<String, Object?> args) =>
        rt.runTool('update_component', {
          ...args,
          'props': jsonEncode(args['props']),
        });

    test('show_list passes display and childDisplay to what it draws', () async {
      final r = await rt.runTool('show_list', {
        'kind': 'tasks',
        'display': {'level': 'minimum'},
        'childDisplay': {
          'level': 'medium',
          'show': {'assignee': false},
        },
      });
      expect(r['ok'], isTrue, reason: '$r');
      final draft = begun.single;
      final sections = [
        for (final n in draft.root.walk())
          if (n.component == AgentComponents.section) n,
      ];
      expect(sections, hasLength(1));
      for (final section in sections) {
        expect(section.props['display'], {'level': 'minimum'});
      }
      // The cards' look is the screen's: one change reaches every group.
      expect(draft.root.props['childDisplay'], {
        'level': 'medium',
        'show': {'assignee': false},
      });
      // The screen says where to change it later.
      expect(r['surface_id'], draft.id);
      expect(r['root'], draft.root.id);
    });

    test('one card tools take display for the card itself', () async {
      await rt.runTool('show_item', {
        'kind': 'agent',
        'id': 'a-cody',
        'display': {
          'show': {'avatar': false},
          'size': 'large',
        },
      });
      expect(cards(begun.last).single.props['display'], {
        'show': {'avatar': false},
        'size': 'large',
      });
      await rt.runTool('show_agent_activity', {
        'agent': 'cody',
        'display': {'level': 'minimum'},
      });
      expect(cards(begun.last).single.props['display'], {'level': 'minimum'});
      await rt.runTool('show_task_history', {
        'task': '94',
        'display': {'lines': 2},
      });
      expect(cards(begun.last).single.props['display'], {'lines': 2});
      // A thread: display is the message, childDisplay the replies.
      final r = await rt.runTool('show_thread', {
        'message': 'm-1',
        'display': {'level': 'detail'},
        'childDisplay': {
          'show': {'avatar': false},
        },
      });
      expect(r['ok'], isTrue, reason: '$r');
      final thread = cards(begun.last);
      expect(thread.first.props['display'], {'level': 'detail'});
      expect(begun.last.root.props['childDisplay'], {
        'level': 'detail',
        'show': {'avatar': false},
      });
    });

    test('search_messages takes them like the other lists', () async {
      await rt.runTool('search_messages', {
        'q': '上线',
        'childDisplay': {
          'show': {'avatar': false},
        },
      });
      expect(begun.last.root.props['childDisplay'], {
        'level': 'detail',
        'show': {'avatar': false},
      });
    });

    test('a wrong display is refused with the names that exist', () async {
      final before = begun.length;
      final list = await rt.runTool('show_list', {
        'kind': 'saved',
        'childDisplay': {
          'show': {'nope': true},
        },
      });
      expect('$list', contains('nope'));
      expect(list['error'], isNotNull);
      final item = await rt.runTool('show_item', {
        'kind': 'agent',
        'id': 'a-cody',
        'display': {
          'show': {'thread_count': true},
        },
      });
      expect('${item['error']}', contains('thread_count'));
      expect('${item['error']}', contains('avatar'));
      final level = await rt.runTool('show_list', {
        'kind': 'saved',
        'childDisplay': {'level': 'loud'},
      });
      expect(level['error'], isNotNull);
      expect(begun, hasLength(before), reason: 'nothing was shown');
    });

    test('the model is given the same display schema as the catalog', () {
      final declared = {
        for (final d in agentModeToolDeclarations()) '${d['name']}': d,
      };
      for (final name in [
        'show_list',
        'show_item',
        'search_messages',
        'show_thread',
        'show_agent_activity',
        'show_task_history',
      ]) {
        final p = (declared[name]!['parameters'] as Map)['properties'] as Map;
        final display = p['display'] as Map;
        expect((display['properties'] as Map).keys, contains('show'));
        expect(jsonEncode(display), isNot(contains('x-describe')));
      }
      for (final name in ['show_list', 'search_messages', 'show_thread']) {
        final p = (declared[name]!['parameters'] as Map)['properties'] as Map;
        expect(p, contains('childDisplay'), reason: name);
      }
      final update =
          (declared['update_component']!['parameters'] as Map)['properties']
              as Map;
      expect(update, contains('handle'));
    });

    testWidgets('a list without avatars, then an update brings them back in '
        'place, one card at a time too', (t) async {
      await t.runAsync(() async {
        final r = await rt.runTool('show_list', {
          'kind': 'saved',
          'childDisplay': {
            'show': {'avatar': false},
          },
        });
        expect(r['ok'], isTrue, reason: '$r');
      });
      final draft = begun.single;
      t.view.physicalSize = const Size(390, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      Future<void> draw() async {
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(RaftFamily.brutal),
            home: Scaffold(
              body: AgentEntityScope(
                resolver: _MessageResolver(),
                child: AgentSurfaceView(
                  spec: draft.spec,
                  focusPrefix: 's',
                  compact: true,
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }

      await draw();
      expect(find.textContaining('keep m9'), findsOneWidget);
      expect(find.textContaining('keep m10'), findsOneWidget);
      expect(find.byType(HfAvatar), findsNothing);
      final card = find.byKey(const ValueKey('entity-card-message')).first;
      final element = card.evaluate().single;

      // Everything: avatars back, through the screen's root.
      late Map<String, Object?> r;
      await t.runAsync(() async {
        r = await update({
          'id': 'root',
          'props': {
            'childDisplay': {
              'show': {'avatar': true},
            },
          },
        });
      });
      expect(r['ok'], isTrue, reason: '$r');
      // Only what was named changed: the screen's detail level stays.
      expect(draft.root.props['childDisplay'], {
        'level': 'detail',
        'show': {'avatar': true},
      });
      await draw();
      expect(find.byType(HfAvatar), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('entity-card-message')).first.evaluate().single,
        same(element),
        reason: 'the same card, changed in place',
      );

      // One card, by the number the person sees.
      refs = AgentReferenceTable('s', [
        const AgentEntityRef(
          type: 'message',
          id: 'm10',
          label: 'Ada',
          handle: '②',
          index: 2,
        ),
      ]);
      await t.runAsync(() async {
        r = await update({
          'handle': '②',
          'props': {
            'display': {
              'show': {'avatar': false},
            },
          },
        });
      });
      expect(r['ok'], isTrue, reason: '$r');
      await draw();
      expect(find.byType(HfAvatar), findsOneWidget);
      expect(
        cards(draft).map((n) => n.string('id')),
        ['m9', 'm10'],
        reason: 'nothing moved',
      );

      // A handle that is not on this screen is refused, nothing changes.
      await t.runAsync(() async {
        r = await update({
          'handle': '⑦',
          'props': {
            'display': {'level': 'minimum'},
          },
        });
      });
      expect(r['error'], isNotNull);
    });
  });
}

class _MessageResolver implements AgentEntityResolver {
  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  AgentEntityResolution resolve(ui.AgentEntityRef ref) => AgentEntityFound(
    AgentMessageData(author: 'Ada', text: 'keep ${ref.id}', time: '10:32'),
  );
}
