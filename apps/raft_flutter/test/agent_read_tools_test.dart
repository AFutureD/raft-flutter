import 'package:flutter_test/flutter_test.dart';
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

  setUp(() {
    begun.clear();
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
      references: () => AgentReferenceTable.empty,
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
        // Full, not a summary: every card detailed, nothing folded on a phone.
        expect([
          for (final n in cards(draft)) n.string('density'),
        ], everyElement('detail'));
        expect(folded(draft), isEmpty);
        // The model has one sentence to say, and nothing to read out.
        expect(r['say'], contains('一句话'));
        expect(r.containsKey('cards'), isFalse);
      });
    }

    test(
      'a task list is grouped by where it stands, most urgent first',
      () async {
        await rt.runTool('show_list', {'kind': 'tasks'});
        final sections = [
          for (final n in begun.single.root.walk())
            if (n.component == AgentComponents.section) n.string('title'),
        ];
        expect(sections, ['待验收 · 1', '进行中 · 1', '待办 · 1']);
      },
    );

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

    test('a summary is only given when asked for', () async {
      await rt.runTool('show_list', {
        'kind': 'agents',
        'display': {'level': 'summary'},
      });
      final draft = begun.single;
      expect([
        for (final n in cards(draft)) n.string('density'),
      ], everyElement('summary'));
      expect(folded(draft), isNotEmpty, reason: 'the phone folds it');
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
}
