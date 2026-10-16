import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_stream.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Streaming surfaces: incremental ops, per-component rejection, append-only
/// stability, the cached-then-patched agent list and the scripted flow.
/// Fictional agents and tasks only.
final _now = DateTime.utc(2026, 10, 15, 12);

AgentRuntimeInfo _a(
  String name,
  AgentWorkState state,
  String activity, {
  String? since,
  String? channel,
}) => AgentRuntimeInfo(
  id: 'id-$name',
  name: name,
  state: state,
  activity: activity,
  since: since,
  channel: channel,
);

/// An agent directory answered twice: what the app already has, then the
/// fresh read, which the test releases when it wants.
class _Data extends AgentModeData {
  _Data(super.w, {this.cached, List<AgentRuntimeInfo>? fresh})
    : fresh = fresh ?? const [],
      super(now: () => _now);

  List<AgentRuntimeInfo>? cached;
  List<AgentRuntimeInfo> fresh;

  /// When set, [agents] waits for it.
  Completer<void>? gate;
  int reads = 0;

  @override
  Future<AgentAttention> attention() async => const AgentAttention(items: []);

  @override
  List<AgentRuntimeInfo>? cachedAgents() => cached;

  @override
  Future<List<AgentRuntimeInfo>> agents() async {
    reads++;
    await gate?.future;
    return fresh;
  }
}

/// A host that records what the tools asked the screen to do.
class _Host {
  final shown = <AgentSurfaceDraft>[];
  final changes = <String>[];
  var open = true;
  var ended = 0;

  late final host = AgentSurfaceHost(
    begin: (draft) {
      shown.add(draft);
      return {'layer': shown.length + 1};
    },
    changed: (draft, {added}) {
      changes.add(added ?? '*');
      return added == null ? const {} : {'item': draft.count};
    },
    isOpen: (_) => open,
    ended: (_) => ended++,
  );
}

Map<String, Object?> _card(
  String name,
  String state, [
  String activity = '空闲',
]) => {
  'component': 'AgentStatusCard',
  'name': name,
  'state': state,
  'activity': activity,
};

void main() {
  late ActivityClient client;
  late WorkspaceController w;
  setUp(() {
    AgentModeData.clearSession();
    FlutterSecureStorage.setMockInitialValues({});
    client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
    client.selectServer('s1');
    w = WorkspaceController(client)
      ..server = RaftRecord({'id': 's1', 'role': 'owner'});
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  group('incremental ops', () {
    late _Data data;
    late _Host host;
    late AgentGroundedTools tools;
    late List<List<String>> rejected;

    final agents = [
      _a('Aria', AgentWorkState.busy, '在做 #102「历史上拉」', since: '12 分钟前有进展'),
      _a('Bo', AgentWorkState.blocked, '#7 超过 6 小时没动'),
      _a('Cy', AgentWorkState.idle, '空闲'),
    ];

    setUp(() async {
      data = _Data(w, fresh: agents);
      host = _Host();
      rejected = [];
      tools = AgentGroundedTools(
        data: data,
        host: host.host,
        onRejected: rejected.add,
      );
      await tools.run('list_agents', const {});
    });

    Future<Map<String, Object?>> run(
      String name,
      Map<String, Object?> args,
    ) async => (await tools.run(name, args))!;

    Future<Map<String, Object?>> begin({Object? layout}) =>
        run('begin_surface', {
          'surface_id': 'agents',
          'title': '现在所有 Agent 在做什么',
          'layout': jsonEncode(
            layout ??
                {
                  'component': 'Column',
                  'id': 'root',
                  'children': [
                    {
                      'component': 'AgentStatusGroup',
                      'id': 'busy',
                      'title': '在忙',
                      'state': 'busy',
                    },
                    {
                      'component': 'AgentStatusGroup',
                      'id': 'blocked',
                      'title': '卡住了',
                      'state': 'blocked',
                    },
                  ],
                },
          ),
        });

    Future<Map<String, Object?>> add(String parent, Map<String, Object?> c) =>
        run('add_component', {
          'surface_id': 'agents',
          'parent_id': parent,
          'component': jsonEncode(c),
        });

    test('begin, add, update, end build the surface piece by piece', () async {
      final began = await begin();
      expect(began['ok'], isTrue);
      expect(began['surface_id'], 'agents');
      expect(began['root'], 'root');
      expect(
        [for (final c in (began['containers'] as List).cast<Map>()) c['id']],
        ['root', 'busy', 'blocked'],
      );
      // The layer is pushed at once, with the titles and no data.
      expect(host.shown, hasLength(1));
      final draft = host.shown.single;
      expect(draft.title, '现在所有 Agent 在做什么');
      expect(draft.find('busy')!.string('title'), '在忙');
      expect(draft.find('busy')!.children, isEmpty);
      expect(draft.ended, isFalse);

      final first = await add('busy', _card('Aria', 'busy', '在做 #102「历史上拉」'));
      expect(first['ok'], isTrue);
      final id = first['id'] as String;
      expect(draft.find('busy')!.children.map((c) => c.id), [id]);
      final second = await add(
        'blocked',
        _card('Bo', 'blocked', '#7 超过 6 小时没动'),
      );
      expect(second['ok'], isTrue);
      expect(draft.find('blocked')!.children, hasLength(1));

      final patch = await run('update_component', {
        'surface_id': 'agents',
        'id': id,
        'props': jsonEncode({'activity': '在做 #102，刚推了一版', 'since': null}),
      });
      expect(patch['ok'], isTrue);
      final card = draft.find(id)!;
      expect(card.string('activity'), '在做 #102，刚推了一版');
      expect(card.props.containsKey('since'), isFalse);
      // Patched in place: same place in the tree.
      expect(draft.pathOf(id), 'r.0.0');

      final end = await run('end_surface', {'surface_id': 'agents'});
      expect(end['ok'], isTrue);
      expect(draft.ended, isTrue);
      expect(host.ended, 1);
      expect(host.changes, [id, second['id'], '*']);
    });

    test('a component without an id is given one; ids stay unique', () async {
      await begin();
      final a = await add('busy', _card('Aria', 'busy'));
      final b = await add('busy', {..._card('Aria', 'busy'), 'id': 'aria'});
      final c = await add('busy', {..._card('Aria', 'busy'), 'id': 'aria'});
      expect(a['id'], isNotNull);
      expect(b['id'], 'aria');
      expect(c['error'], isNotNull);
      expect((c['problems'] as List).single, contains('id 已存在'));
    });

    test('an ungrounded component is refused alone, the others stay', () async {
      await begin();
      final good = await add('busy', _card('Aria', 'busy'));
      final invented = await add('busy', _card('Zoe', 'busy'));
      expect(invented['error'], contains('其余的不受影响'));
      expect((invented['problems'] as List).single, contains('Zoe'));
      // Wrong state for a known agent.
      final wrong = await add('blocked', _card('Aria', 'blocked'));
      expect((wrong['problems'] as List).single, contains('state'));
      // Right agent, wrong group.
      final misplaced = await add('busy', _card('Bo', 'blocked'));
      expect(
        (misplaced['problems'] as List).single,
        contains('AgentStatusGroup'),
      );
      final also = await add('blocked', _card('Bo', 'blocked'));
      expect(also['ok'], isTrue);
      final draft = host.shown.single;
      expect(draft.find('busy')!.children.map((c) => c.string('name')), [
        'Aria',
      ]);
      expect(draft.find('blocked')!.children.map((c) => c.string('name')), [
        'Bo',
      ]);
      expect(good['ok'], isTrue);
      // Each refusal gave the screen a small caption.
      expect(rejected, hasLength(3));
    });

    test('a schema problem refuses that component only', () async {
      await begin();
      final bad = await add('busy', {
        'component': 'AgentStatusCard',
        'name': 'Aria',
        'state': 'sleeping',
      });
      expect(bad['error'], isNotNull);
      final unknown = await add('busy', {'component': 'Carousel'});
      expect((unknown['problems'] as List).single, contains('Carousel'));
      final notJson = await run('add_component', {
        'surface_id': 'agents',
        'parent_id': 'busy',
        'component': 'not json',
      });
      expect(notJson['error'], isNotNull);
      expect((await add('busy', _card('Aria', 'busy')))['ok'], isTrue);
    });

    test('a skeleton keeps what is fine and drops what is not', () async {
      final began = await begin(
        layout: {
          'component': 'Column',
          'id': 'root',
          'children': [
            {
              'component': 'AgentStatusGroup',
              'id': 'busy',
              'title': '在忙',
              'state': 'busy',
            },
            {'component': 'Carousel', 'id': 'bad'},
            {
              'component': 'AgentStatusGroup',
              'id': 'blocked',
              'title': '卡住了',
              'state': 'blocked',
              'children': [_card('Zoe', 'blocked'), _card('Bo', 'blocked')],
            },
          ],
        },
      );
      expect(began['ok'], isTrue);
      expect((began['rejected'] as List), hasLength(2));
      final draft = host.shown.single;
      expect(draft.root.children.map((c) => c.id), ['busy', 'blocked']);
      expect(draft.find('blocked')!.children.map((c) => c.string('name')), [
        'Bo',
      ]);
      expect(rejected, isNotEmpty);
    });

    test('a skeleton whose root is refused does not start a screen', () async {
      final began = await begin(layout: {'component': 'Carousel'});
      expect(began['error'], isNotNull);
      expect(host.shown, isEmpty);
    });

    test('children go into containers that accept them', () async {
      await begin();
      final inCard = await add('busy', _card('Aria', 'busy'));
      final under = await add(inCard['id'] as String, _card('Cy', 'idle'));
      expect(under['error'], isNotNull);
      expect((under['problems'] as List).single, contains('不能放子组件'));
      final missing = await add('nowhere', _card('Aria', 'busy'));
      expect((missing['problems'] as List).single, contains('nowhere'));
      // A group only takes agent cards.
      final stray = await add('busy', {
        'component': 'StatRow',
        'stats': [
          {'label': '在忙', 'value': '1'},
        ],
      });
      expect((stray['problems'] as List).single, contains('里只能放'));
    });

    test('update_component checks fields and facts too', () async {
      await begin();
      final id = (await add('busy', _card('Aria', 'busy')))['id'] as String;
      Future<Map<String, Object?>> patch(Object props, {String? on}) =>
          run('update_component', {
            'surface_id': 'agents',
            'id': on ?? id,
            'props': props is String ? props : jsonEncode(props),
          });
      expect((await patch({'mood': 'x'}))['error'], isNotNull);
      expect((await patch({'state': 'idle'}))['error'], isNotNull);
      expect((await patch({'children': []}))['error'], isNotNull);
      expect((await patch('nope'))['error'], isNotNull);
      expect((await patch({'activity': 'x'}, on: 'ghost'))['error'], isNotNull);
      expect(host.shown.single.find(id)!.string('activity'), '空闲');
      expect((await patch({'activity': '新的一句'}))['ok'], isTrue);
    });

    test('a closed screen takes no more components', () async {
      await begin();
      host.open = false;
      final late = await add('busy', _card('Aria', 'busy'));
      expect(late['error'], contains('已经关闭'));
      final none = await run('add_component', {
        'surface_id': 'ghost',
        'component': jsonEncode(_card('Aria', 'busy')),
      });
      expect(none['error'], contains('begin_surface'));
    });

    test('show_surface still shows a whole tree, and ids are added', () async {
      final out = await run('show_surface', {
        'surface': jsonEncode({
          'title': '一屏',
          'root': {
            'component': 'Column',
            'children': [_card('Aria', 'busy')],
          },
        }),
      });
      expect(out['ok'], isTrue);
      final draft = host.shown.single;
      expect(draft.ended, isTrue);
      expect(draft.root.id, isNotNull);
      expect(draft.root.children.single.id, isNotNull);
      // One bad component still refuses the whole screen here.
      final bad = await run('show_surface', {
        'surface': jsonEncode({
          'title': '二屏',
          'root': {
            'component': 'Column',
            'children': [_card('Aria', 'busy'), _card('Zoe', 'busy')],
          },
        }),
      });
      expect(bad['error'], isNotNull);
      expect(host.shown, hasLength(1));
    });

    test('existing components keep their place while others are added', () {
      final draft = AgentSurfaceDraft(
        id: 'd',
        title: 't',
        root: const SurfaceNode(
          'Column',
          {},
          id: 'root',
          children: [
            SurfaceNode('AgentStatusGroup', {'title': 'A'}, id: 'a'),
            SurfaceNode('AgentStatusGroup', {'title': 'B'}, id: 'b'),
          ],
        ),
      );
      SurfaceNode card(String n) => draft.named(
        SurfaceNode('AgentStatusCard', {'name': n, 'state': 'busy'}),
      );
      draft.add('a', card('one'));
      draft.add('b', card('two'));
      final before = {
        for (final n in draft.root.walk()) n.id!: draft.pathOf(n.id!),
      };
      draft.add('b', card('three'));
      draft.patch(draft.root.children.first.children.first.id!, {
        'state': 'idle',
      });
      for (final e in before.entries) {
        expect(draft.pathOf(e.key), e.value, reason: e.key);
      }
    });
  });

  group('list_agents: cached first, then only what changed', () {
    final cached = [
      _a(
        'Aria',
        AgentWorkState.busy,
        '在做 #102',
        since: '5 分钟前有进展',
        channel: 'seed',
      ),
      _a('Bo', AgentWorkState.busy, '在做 #7'),
      _a('Cy', AgentWorkState.idle, '空闲'),
    ];
    final fresh = [
      // Aria: activity moved on.
      _a(
        'Aria',
        AgentWorkState.busy,
        '在做 #103',
        since: '1 分钟前有进展',
        channel: 'seed',
      ),
      // Bo: now stuck.
      _a('Bo', AgentWorkState.blocked, '#7 超过 6 小时没动'),
      // Cy: the same.
      _a('Cy', AgentWorkState.idle, '空闲'),
    ];

    late _Data data;
    late _Host host;
    late AgentGroundedTools tools;

    setUp(() {
      data = _Data(w, cached: cached, fresh: fresh)..gate = Completer<void>();
      host = _Host();
      tools = AgentGroundedTools(data: data, host: host.host);
    });

    Future<void> compose() async {
      await tools.run('begin_surface', {
        'surface_id': 'agents',
        'title': '现在所有 Agent 在做什么',
        'layout': jsonEncode({
          'component': 'Column',
          'id': 'root',
          'children': [
            {
              'component': 'StatRow',
              'id': 'counts',
              'stats': [
                {'label': '在忙', 'value': '2'},
                {'label': '空闲', 'value': '1'},
              ],
            },
            {
              'component': 'AgentStatusGroup',
              'id': 'busy',
              'title': '在忙',
              'state': 'busy',
            },
            {
              'component': 'AgentStatusGroup',
              'id': 'blocked',
              'title': '卡住了',
              'state': 'blocked',
            },
            {
              'component': 'AgentStatusGroup',
              'id': 'idle',
              'title': '空闲',
              'state': 'idle',
            },
          ],
        }),
      });
      Future<void> add(String parent, String id, AgentRuntimeInfo a) async {
        final r = await tools.run('add_component', {
          'surface_id': 'agents',
          'parent_id': parent,
          'component': jsonEncode({
            'component': 'AgentStatusCard',
            'id': id,
            'name': a.name,
            'state': a.state.name,
            'activity': a.activity,
            'since': ?a.since,
            'channel': ?a.channel,
          }),
        });
        expect(r!['ok'], isTrue, reason: '$r');
      }

      await add('busy', 'aria', cached[0]);
      await add('busy', 'bo', cached[1]);
      await add('idle', 'cy', cached[2]);
    }

    test('answers from the cache at once, the fresh read follows', () async {
      final got = (await tools.run('list_agents', const {}))!;
      // Answered without waiting for the (still blocked) fresh read.
      expect(got['source'], 'cache');
      expect(got['total'], 3);
      expect(
        [for (final a in (got['agents'] as List).cast<Map>()) a['name']],
        ['Aria', 'Bo', 'Cy'],
      );
      expect(data.reads, 1);
      data.gate!.complete();
      await tools.agentsRefresh;
    });

    test(
      'the fresh read patches only the agents that changed, in place',
      () async {
        await tools.run('list_agents', const {});
        await compose();
        final draft = host.shown.single;
        final cyBefore = draft.find('cy')!;
        final pathsBefore = {
          for (final n in draft.root.walk()) n.id!: draft.pathOf(n.id!),
        };
        host.changes.clear();

        data.gate!.complete();
        await tools.agentsRefresh;

        // Aria's activity moved on, in the same place.
        expect(draft.find('aria')!.string('activity'), '在做 #103');
        expect(draft.find('aria')!.string('since'), '1 分钟前有进展');
        expect(draft.pathOf('aria'), pathsBefore['aria']);
        // Bo is now blocked: it moved to the group of its new state.
        expect(draft.find('bo')!.string('state'), 'blocked');
        expect(draft.parentOf('bo')!.id, 'blocked');
        expect(draft.find('busy')!.children.map((c) => c.id), ['aria']);
        // The numbers above the groups follow.
        final stats = draft.find('counts')!.list('stats').cast<Map>();
        expect(
          {for (final s in stats) s['label']: s['value']},
          {'在忙': '1', '空闲': '1'},
        );
        // Cy did not change: the very same node, untouched.
        expect(identical(draft.find('cy'), cyBefore), isTrue);
        // Only the changed agents were touched, and the screen was told once.
        expect(tools.patched, unorderedEquals(['agents/aria', 'agents/bo']));
        expect(host.changes, ['*']);
      },
    );

    test(
      'a card added after the fresh read is corrected on the spot',
      () async {
        await tools.run('list_agents', const {});
        await tools.run('begin_surface', {
          'surface_id': 'agents',
          'title': 'x',
          'layout': jsonEncode({
            'component': 'Column',
            'id': 'root',
            'children': [
              {
                'component': 'AgentStatusGroup',
                'id': 'busy',
                'title': '在忙',
                'state': 'busy',
              },
            ],
          }),
        });
        data.gate!.complete();
        await tools.agentsRefresh;
        // The model still has the cached reading of Aria in mind.
        final r = (await tools.run('add_component', {
          'surface_id': 'agents',
          'parent_id': 'busy',
          'component': jsonEncode({
            'component': 'AgentStatusCard',
            'id': 'aria',
            'name': 'Aria',
            'state': 'busy',
            'activity': '在做 #102',
          }),
        }))!;
        expect(r['ok'], isTrue);
        expect(host.shown.single.find('aria')!.string('activity'), '在做 #103');
      },
    );

    test('an unchanged read touches nothing', () async {
      data.fresh = cached;
      await tools.run('list_agents', const {});
      await compose();
      host.changes.clear();
      data.gate!.complete();
      await tools.agentsRefresh;
      expect(tools.patched, isEmpty);
      expect(host.changes, isEmpty);
    });

    test('a failing fresh read leaves the cached screen as it is', () async {
      final failing = _Failing(w, cached);
      final t = AgentGroundedTools(data: failing, host: host.host);
      await t.run('list_agents', const {});
      await t.agentsRefresh;
      expect(t.patched, isEmpty);
    });
  });

  group('declarations', () {
    test('the surface ops are non-blocking and describe the catalog', () {
      final tools = {
        for (final t in [
          ...agentToolDeclarations,
          ...groundedToolDeclarations(agentStandardCatalog),
        ])
          t['name']: t,
      };
      for (final name in [
        'begin_surface',
        'add_component',
        'update_component',
        'end_surface',
        'spotlight',
        'mark',
        'release_spotlight',
      ]) {
        expect(tools[name]!['behavior'], 'NON_BLOCKING', reason: name);
      }
      // Reads and the whole-tree convenience answer normally.
      for (final name in ['list_agents', 'get_task', 'show_surface']) {
        expect(tools[name]!.containsKey('behavior'), isFalse, reason: name);
      }
      expect(
        tools['begin_surface']!['description'],
        contains('AgentStatusCard'),
      );
    });

    test('a model that refuses non-blocking gets plain functions', () {
      final all = [
        ...agentToolDeclarations,
        ...groundedToolDeclarations(agentStandardCatalog),
      ];
      final blocking = GeminiLiveSession.declarations(all, nonBlocking: false);
      expect(blocking.any((t) => t.containsKey('behavior')), isFalse);
      expect(blocking.length, all.length);
      final kept = GeminiLiveSession.declarations(all, nonBlocking: true);
      expect(kept.where((t) => t['behavior'] == 'NON_BLOCKING'), isNotEmpty);
      // The originals are not touched.
      expect(all.any((t) => t['behavior'] == 'NON_BLOCKING'), isTrue);
      expect(
        GeminiLiveSession.nonBlockingNames(all),
        containsAll(['begin_surface', 'add_component', 'update_component']),
      );
    });

    test('a non-blocking answer is quiet, an error is told when idle', () {
      expect(
        GeminiLiveSession.quietResponse({'ok': true})['scheduling'],
        'SILENT',
      );
      expect(
        GeminiLiveSession.quietResponse({'error': 'x'})['scheduling'],
        'WHEN_IDLE',
      );
      expect(GeminiLiveSession.quietResponse({'ok': true})['ok'], isTrue);
    });
  });

  group('on screen', () {
    late _Data data;

    Future<void> open(
      WidgetTester t,
      AgentScriptedModel model, {
      double width = 1200,
    }) async {
      t.view.physicalSize = Size(width, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: AgentModePage(controller: w, data: data, model: model),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('agent-keyboard')));
      await t.pumpAndSettle();
    }

    Future<void> send(WidgetTester t, String text) async {
      await t.enterText(find.byKey(const ValueKey('agent-input')), text);
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pump();
    }

    final agents = [
      _a('Aria', AgentWorkState.busy, '在做 #102「历史上拉」', channel: 'seed'),
      _a('Bo', AgentWorkState.busy, '在做 #7「旧任务」'),
      _a('Cy', AgentWorkState.busy, '在做 #9「第三件」'),
      _a('Di', AgentWorkState.idle, '空闲'),
    ];

    setUp(() => data = _Data(w, fresh: agents));

    testWidgets('the scripted model streams: titles first, cards one by one', (
      t,
    ) async {
      await open(
        t,
        const AgentScriptedModel(streamDelay: Duration(milliseconds: 300)),
      );
      await send(t, '现在所有的 Agent 都在干什么？');
      await t.pump(const Duration(milliseconds: 50));
      // The skeleton is on screen: the layer, the title, the group titles and
      // the numbers, and no card yet.
      expect(find.text('第 2 层'), findsOneWidget);
      expect(find.text('现在所有 Agent 在做什么'), findsWidgets);
      expect(find.text('在忙'), findsWidgets);
      expect(find.byType(HfStatusCard), findsNothing);
      // The agent is already saying the conclusion.
      expect(find.textContaining('4 个 Agent'), findsWidgets);

      final seen = <int>[];
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 150));
        seen.add(t.widgetList(find.byType(HfStatusCard)).length);
      }
      // Cards arrive one after another, never all at once.
      expect(seen.first, lessThan(4));
      expect(seen.toSet().length, greaterThan(2));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      await t.pumpAndSettle();
      expect(find.byType(HfStatusCard), findsNWidgets(4));
      // Nobody was spotlit: this was a fill, not a talk.
      expect(find.byKey(const ValueKey('agent-spotlight-scrim')), findsNothing);
      expect(find.byKey(const ValueKey('agent-surface-error')), findsNothing);
    });

    testWidgets('what is on screen never moves when more is appended', (
      t,
    ) async {
      final model = _Scripted((call, say) async {
        await call('list_agents', const {});
        await call('begin_surface', {
          'surface_id': 's',
          'title': '一屏',
          'layout': jsonEncode({
            'component': 'Column',
            'id': 'root',
            'children': [
              {
                'component': 'AgentStatusGroup',
                'id': 'busy',
                'title': '在忙',
                'state': 'busy',
              },
              {
                'component': 'AgentStatusGroup',
                'id': 'idle',
                'title': '空闲',
                'state': 'idle',
              },
            ],
          }),
        });
      });
      await open(t, model);
      await send(t, 'go');
      await t.pumpAndSettle();

      Future<void> add(String parent, Map<String, Object?> c) async {
        final r = await model.call!('add_component', {
          'surface_id': 's',
          'parent_id': parent,
          'component': jsonEncode(c),
        });
        expect(r['ok'], isTrue, reason: '$r');
        await t.pumpAndSettle();
      }

      Offset at(String text) => t.getTopLeft(find.text(text).first);

      await add('busy', _card('Aria', 'busy', '在做 #102'));
      await add('busy', _card('Bo', 'busy', '在做 #7'));
      final before = {'在忙': at('在忙'), 'Aria': at('Aria'), 'Bo': at('Bo')};
      final idleTitle = at('空闲');

      // Appended at the end of the same group: everything above stays.
      await add('busy', {
        'component': 'AgentStatusCard',
        'name': 'Cy',
        'state': 'busy',
        'activity': '在做 #9',
      });
      for (final e in before.entries) {
        expect(at(e.key), e.value, reason: '${e.key} moved');
      }
      // What follows it makes room below, never above.
      expect(at('空闲').dy, greaterThan(idleTitle.dy));

      // Appended in the next group: the group above is untouched.
      final busyTitle = at('在忙');
      await add('idle', _card('Di', 'idle'));
      expect(at('在忙'), busyTitle);
      expect(at('Aria'), before['Aria']);
      expect(at('Bo'), before['Bo']);

      // A patch changes the text in place and nothing around it.
      final ariaTop = at('Aria');
      final r = await model.call!('update_component', {
        'surface_id': 's',
        'id': 'c1',
        'props': jsonEncode({'activity': '在做 #103'}),
      });
      expect(r['ok'], isTrue, reason: '$r');
      await t.pumpAndSettle();
      expect(find.textContaining('在做 #103'), findsOneWidget);
      expect(find.textContaining('在做 #102'), findsNothing);
      expect(at('Aria'), ariaTop);
      expect(at('Bo'), before['Bo']);
    });

    testWidgets('a refused component shows a small caption, the rest stays', (
      t,
    ) async {
      final model = _Scripted((call, say) async {
        await call('list_agents', const {});
        await call('begin_surface', {'surface_id': 's', 'title': '一屏'});
      });
      await open(t, model);
      await send(t, 'go');
      await t.pumpAndSettle();
      final ok = await model.call!('add_component', {
        'component': jsonEncode(_card('Aria', 'busy', '在做 #102')),
      });
      expect(ok['ok'], isTrue, reason: '$ok');
      final bad = await model.call!('add_component', {
        'component': jsonEncode(_card('Zoe', 'busy')),
      });
      expect(bad['error'], isNotNull);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-surface-error')), findsOneWidget);
      expect(find.text('Aria'), findsOneWidget);
      expect(find.text('Zoe'), findsNothing);
      // The model is not blocked by it: the next one goes in.
      final next = await model.call!('add_component', {
        'component': jsonEncode(_card('Bo', 'busy', '在做 #7')),
      });
      expect(next['ok'], isTrue);
      await t.pumpAndSettle();
      expect(find.text('Bo'), findsOneWidget);
    });

    testWidgets(
      'cached agents show first and the fresh read patches the screen',
      (t) async {
        data
          ..cached = [
            _a('Aria', AgentWorkState.busy, '在做 #102「历史上拉」', channel: 'seed'),
            _a('Bo', AgentWorkState.busy, '在做 #7「旧任务」'),
            _a('Cy', AgentWorkState.busy, '在做 #9「第三件」'),
            _a('Di', AgentWorkState.idle, '空闲'),
          ]
          ..fresh = [
            _a('Aria', AgentWorkState.busy, '在做 #103「新任务」', channel: 'seed'),
            _a('Bo', AgentWorkState.busy, '在做 #7「旧任务」'),
            _a('Cy', AgentWorkState.busy, '在做 #9「第三件」'),
            _a('Di', AgentWorkState.idle, '空闲'),
          ]
          ..gate = Completer<void>();
        await open(
          t,
          const AgentScriptedModel(streamDelay: Duration(milliseconds: 100)),
        );
        await send(t, '现在所有的 Agent 都在干什么？');
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        // Shown from what the app had, while the fresh read is still out.
        expect(find.textContaining('在做 #102「历史上拉」'), findsOneWidget);
        expect(find.byType(HfStatusCard), findsNWidgets(4));
        await t.pumpAndSettle();
        final boTop = t.getTopLeft(find.text('Bo'));
        data.gate!.complete();
        await t.pumpAndSettle();
        expect(find.textContaining('在做 #103「新任务」'), findsOneWidget);
        expect(find.textContaining('在做 #102「历史上拉」'), findsNothing);
        // Only the changed card changed; the others did not move.
        expect(t.getTopLeft(find.text('Bo')), boTop);
        expect(data.reads, 1);
      },
    );
  });
}

class _Failing extends _Data {
  _Failing(super.w, List<AgentRuntimeInfo> cached) : super(cached: cached);
  @override
  Future<List<AgentRuntimeInfo>> agents() async => throw StateError('offline');
}

/// A model that lets the test drive the tools by hand after it is asked once.
class _Scripted extends AgentScriptedModel {
  _Scripted(this.first) : super(streamDelay: Duration.zero);
  final Future<void> Function(AgentToolHandler call, void Function(String) say)
  first;
  AgentToolHandler? call;

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String) say,
  ) async {
    this.call = call;
    await first(call, say);
    return true;
  }
}
