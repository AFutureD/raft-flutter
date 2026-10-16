import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_headlines.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_flutter/features/agent_mode/agent_tools.dart';
import 'package:raft_flutter/features/agent_mode/gemini_text.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Fictional workspace: no real names, servers or data.
final _now = DateTime.utc(2026, 10, 15, 12);
String _ago({int minutes = 0, int hours = 0}) =>
    _now.subtract(Duration(minutes: minutes, hours: hours)).toIso8601String();

class _Server extends WorkspaceController {
  _Server(super.client);

  final agents = <Map<String, dynamic>>[];
  final tasks = <Map<String, dynamic>>[];
  final threads = <String, List<Map<String, dynamic>>>{};
  final failing = <String>{};
  final reads = <String>[];

  @override
  Future<dynamic> sharedQuery(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/channels/inbox'
      ? {'items': []}
      : this.query(path, query: query);

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async {
    reads.add(path);
    if (failing.contains(path)) throw StateError('offline');
    if (path == '/agents') return agents;
    if (path == '/tasks/server') {
      return {
        'tasks': [
          for (final t in tasks)
            if (t['status'] == query?['status']) t,
        ],
      };
    }
    final full = RegExp(r'^/tasks/channel/([^/]+)/number/(\d+)$')
        .firstMatch(path);
    if (full != null) {
      final t = tasks.firstWhere(
        (t) => t['channelId'] == full[1] && '${t['taskNumber']}' == full[2],
      );
      return {
        'task': {...t, 'description': 'Full text of #${t['taskNumber']}'},
      };
    }
    if (path.startsWith('/messages/channel/')) {
      return {'messages': threads[path.split('/').last] ?? const []};
    }
    return <String, dynamic>{};
  }
}

Map<String, dynamic> _agent(
  String id,
  String name, {
  String status = 'active',
  String? activity,
  String? detail,
  String? lastSeenAt,
}) => {
  'id': id,
  'name': name,
  'status': status,
  'runtime': 'codex',
  'model': 'm',
  'activity': activity,
  'activityDetail': detail,
  'lastSeenAt': lastSeenAt,
};

Map<String, dynamic> _task(
  int number,
  String status, {
  String title = 'A task',
  String? claimedById,
  String? claimedByName,
  String channel = 'seed',
  int minutes = 5,
  String? thread,
}) => {
  'id': 't$number',
  'taskNumber': number,
  'title': title,
  'status': status,
  'channelId': 'ch-$channel',
  'channelName': channel,
  'claimedById': claimedById,
  'claimedByName': claimedByName,
  'createdByName': 'Zed',
  'threadChannelId': thread,
  'updatedAt': _ago(minutes: minutes),
};

Map<String, dynamic> _msg(int seq, String who, String text) => {
  'id': 'm$seq',
  'seq': '$seq',
  'senderName': who,
  'content': text,
  'createdAt': _ago(minutes: 30 - seq),
};

Map<String, Object?> _card(String name, String state) => {
  'component': 'AgentStatusCard',
  'name': name,
  'state': state,
};

String _surface(Object root, {String title = '标题'}) =>
    jsonEncode({'title': title, 'root': root});

void main() {
  final catalog = agentStandardCatalog;

  group('catalog validation', () {
    test('a valid surface of every component is accepted', () {
      final parsed = catalog.parse(
        jsonEncode({
          'title': '全部',
          'summary': '一句话',
          'root': {
            'component': 'Column',
            'children': [
              {
                'component': 'AgentStatusGroup',
                'title': '在忙',
                'state': 'busy',
                'children': [_card('Aria', 'busy')],
              },
              {
                'component': 'TaskCard',
                'title': '修复返回',
                'status': 'in_review',
                'number': 98,
                'quote': {'who': 'Aria', 'text': '已修复'},
              },
              {
                'component': 'Section',
                'title': '最近讨论',
                'children': [
                  {
                    'component': 'MessageQuote',
                    'author': 'Aria',
                    'text': '已修复',
                  },
                ],
              },
              {
                'component': 'StatRow',
                'stats': [
                  {'label': '在忙', 'value': '1'},
                ],
              },
            ],
          },
        }),
      );
      expect(parsed.problems, isEmpty);
      expect(parsed.spec!.title, '全部');
      expect(parsed.spec!.root.walk().map((n) => n.component).toList(), [
        'Column',
        'AgentStatusGroup',
        'AgentStatusCard',
        'TaskCard',
        'Section',
        'MessageQuote',
        'StatRow',
      ]);
    });

    test('a decoded map and a fenced JSON string are accepted too', () {
      final map = {'title': 't', 'root': _card('Aria', 'idle')};
      expect(catalog.parse(map).ok, isTrue);
      expect(catalog.parse('```json\n${jsonEncode(map)}\n```').ok, isTrue);
    });

    void rejects(Object? raw, String reason) {
      final parsed = catalog.parse(raw);
      expect(parsed.ok, isFalse, reason: '$raw');
      expect(parsed.problems.join('\n'), contains(reason));
    }

    test('an unknown component is rejected and the catalog is listed', () {
      rejects(_surface({'component': 'Carousel'}), 'Carousel');
      rejects(_surface({'component': 'Carousel'}), 'AgentStatusCard');
    });

    test('an unknown field is rejected, also deep in the tree', () {
      rejects(
        _surface({
          'component': 'Column',
          'children': [
            {..._card('Aria', 'busy'), 'avatar': 'x.png'},
          ],
        }),
        '"avatar"',
      );
      rejects(
        _surface({..._card('Aria', 'busy'), 'children': []}),
        '"children"',
      );
      rejects(
        jsonEncode({'title': 't', 'root': _card('A', 'busy'), 'theme': 'dark'}),
        '"theme"',
      );
    });

    test('required fields, enums and types are checked', () {
      rejects(
        _surface({'component': 'AgentStatusCard', 'name': 'A'}),
        '"state"',
      );
      rejects(_surface(_card('A', 'sleeping')), 'busy');
      rejects(
        _surface({
          'component': 'TaskCard',
          'title': 't',
          'status': 'done',
          'number': '98',
        }),
        '整数',
      );
      rejects(_surface({'component': 'StatRow', 'stats': []}), '1 到 6');
      rejects(
        _surface({
          'component': 'StatRow',
          'stats': [
            {'label': 'a'},
          ],
        }),
        '"value"',
      );
      rejects(
        _surface({
          'component': 'TaskCard',
          'title': 't',
          'status': 'done',
          'quote': {'text': 'x', 'mood': 'happy'},
        }),
        '"mood"',
      );
      rejects(_surface(_card('A' * 80, 'busy')), '太长');
    });

    test('a group only holds status cards; depth and size are bounded', () {
      rejects(
        _surface({
          'component': 'AgentStatusGroup',
          'title': 'g',
          'children': [
            {'component': 'MessageQuote', 'author': 'a', 'text': 'b'},
          ],
        }),
        '只能放',
      );
      Object nest(int n) => n == 0
          ? _card('A', 'busy')
          : {
              'component': 'Column',
              'children': [nest(n - 1)],
            };
      rejects(_surface(nest(8)), '嵌套太深');
      rejects(
        _surface({
          'component': 'Column',
          'children': [for (var i = 0; i < 90; i++) _card('A$i', 'busy')],
        }),
        '组件太多',
      );
    });

    test('broken input never throws', () {
      rejects('not json', 'JSON');
      rejects('[]', '{title, root}');
      rejects(null, '{title, root}');
      rejects(jsonEncode({'title': '', 'root': _card('A', 'busy')}), 'title');
      rejects(jsonEncode({'title': 't'}), 'root');
    });

    test('the model reference lists every component with an example', () {
      final doc = catalog.describe();
      for (final item in catalog.items.values.where((i) => !i.internal)) {
        expect(doc, contains(item.name));
      }
      // The actions are the app's own: the model is not told about them.
      expect(doc, isNot(contains('ActionRow')));
      expect(doc, contains('density'));
      expect(doc, contains('例：'));
      final tool = groundedToolDeclarations(catalog)
          .firstWhere((t) => t['name'] == 'show_surface');
      expect(tool['description'], contains('AgentStatusGroup'));
      // Every example in the catalog is itself a valid surface node.
      for (final item in catalog.items.values.where((i) => !i.internal)) {
        expect(
          catalog.parse(_surface(item.example!)).problems,
          isEmpty,
          reason: item.name,
        );
      }
    });
  });

  group('renderer', () {
    testWidgets('every component builds in all three themes', (t) async {
      final spec = catalog
          .parse(
            jsonEncode({
              'title': '一屏',
              'summary': '摘要一句',
              'root': {
                'component': 'Column',
                'children': [
                  {
                    'component': 'AgentStatusGroup',
                    'title': '在忙',
                    'state': 'busy',
                    'children': [
                      {
                        ..._card('Aria', 'busy'),
                        'activity': '在做 #98',
                        'since': '5 分钟前有进展',
                        'channel': 'seed',
                      },
                    ],
                  },
                  {
                    'component': 'TaskCard',
                    'title': '修复返回',
                    'status': 'in_review',
                    'number': 98,
                    'assignee': 'Aria',
                    'channel': 'seed',
                    'quote': {
                      'who': 'Aria',
                      'time': '10:30',
                      'text': '已修复并补了测试',
                    },
                    'ask': '验收这个任务',
                  },
                  {
                    'component': 'Section',
                    'title': '最近讨论',
                    'children': [
                      {
                        'component': 'MessageQuote',
                        'author': 'Bo',
                        'time': '10:20',
                        'text': '看起来可以',
                        'channel': 'seed',
                      },
                    ],
                  },
                  {
                    'component': 'StatRow',
                    'stats': [
                      {'label': '在忙', 'value': '3'},
                      {'label': '卡住', 'value': '1'},
                    ],
                  },
                ],
              },
            }),
          )
          .spec!;
      t.view.physicalSize = const Size(390, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      for (final (family, dark) in [
        (RaftFamily.brutal, false),
        (RaftFamily.elegant, false),
        (RaftFamily.elegant, true),
      ]) {
        await t.pumpWidget(
          MaterialApp(
            theme: raftTheme(family, dark: dark),
            home: Scaffold(
              body: AgentSurfaceView(
                spec: spec,
                focusPrefix: 'surface:1',
                compact: false,
              ),
            ),
          ),
        );
        for (final text in [
          '一屏',
          '摘要一句',
          '在忙',
          'Aria',
          '在做 #98',
          '5 分钟前有进展',
          '#seed',
          '修复返回',
          '#98',
          '等验收',
          'Aria',
          'Aria · 10:30  已修复并补了测试',
          '验收这个任务',
          '最近讨论',
          'Bo · 10:20 · #seed',
          '看起来可以',
          '3',
          '卡住',
        ]) {
          expect(
            find.textContaining(text),
            findsWidgets,
            reason: '$family $dark $text',
          );
        }
        expect(t.takeException(), isNull);
      }
    });

    testWidgets(
      'long text at large type and a narrow screen does not overflow',
      (t) async {
        final long = '很长的一句话' * 12;
        final spec = catalog
            .parse(
              jsonEncode({
                'title': long.substring(0, 40),
                'root': {
                  'component': 'Column',
                  'children': [
                    {
                      'component': 'AgentStatusGroup',
                      'title': '在忙',
                      'children': [
                        {
                          ..._card('Aria-${'x' * 40}', 'blocked'),
                          'activity': long,
                          'since': '12 分钟前有进展',
                          'channel': 'raft-flutter-long-name',
                        },
                      ],
                    },
                    {
                      'component': 'TaskCard',
                      'title': long,
                      'status': 'in_review',
                      'number': 98,
                      'assignee': 'Aria-${'x' * 20}',
                      'channel': 'raft-flutter-long-name',
                      'quote': {
                        'who': 'Aria',
                        'time': '昨天 10:30',
                        'text': long,
                      },
                      'ask': long.substring(0, 60),
                    },
                    {
                      'component': 'StatRow',
                      'stats': [
                        for (var i = 0; i < 6; i++)
                          {'label': '标签标签$i', 'value': '${i * 1000}'},
                      ],
                    },
                  ],
                },
              }),
            )
            .spec!;
        t.view.physicalSize = const Size(320, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        for (final (scale, compact) in [
          (1.0, false),
          (2.0, false),
          (1.0, true),
          (2.0, true),
        ]) {
          await t.pumpWidget(
            MaterialApp(
              theme: raftTheme(RaftFamily.brutal),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: AgentSurfaceView(
                  spec: spec,
                  focusPrefix: 's',
                  compact: compact,
                ),
              ),
            ),
          );
          expect(t.takeException(), isNull, reason: 'scale $scale $compact');
        }
      },
    );

    testWidgets('items are numbered like the serialized frame', (t) async {
      final spec = catalog
          .parse(
            _surface({
              'component': 'Column',
              'children': [
                _card('Aria', 'busy'),
                {'component': 'MessageQuote', 'author': 'Bo', 'text': 'hi'},
              ],
            }),
          )
          .spec!;
      final frame = agentSurfaceFrame(spec);
      final items = (frame['items'] as List).cast<Map<String, Object?>>();
      expect(items.map((i) => i['kind']), ['priority', 'message']);
      expect(items.first['title'], 'Aria');
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(
            body: AgentSurfaceView(spec: spec, focusPrefix: 'surface:7'),
          ),
        ),
      );
      final ids = [
        for (final f in t.widgetList<AgentFocusable>(
          find.byType(AgentFocusable),
        ))
          f.id,
      ];
      expect(ids, ['surface:7#1', 'surface:7#2']);
    });
  });

  group('density', () {
    Map<String, Object?> agents({String? density, String? column}) => {
      'component': 'Column',
      'density': ?column,
      'children': [
        {
          'component': 'StatRow',
          'stats': [
            {'label': '在忙', 'value': '1'},
            {'label': '空闲', 'value': '2'},
          ],
        },
        {
          'component': 'AgentStatusGroup',
          'title': '在忙',
          'state': 'busy',
          'density': ?density,
          'children': [
            {..._card('Cindy', 'busy'), 'activity': '在做 #119'},
          ],
        },
        {
          'component': 'AgentStatusGroup',
          'title': '空闲',
          'state': 'idle',
          'children': [
            {..._card('Cy', 'idle'), 'activity': '空闲'},
            {..._card('Di', 'idle'), 'activity': '空闲'},
          ],
        },
      ],
    };

    AgentSurfaceSpec spec(Object root) => catalog.parse(_surface(root)).spec!;

    Future<void> show(
      WidgetTester t,
      AgentSurfaceSpec spec, {
      bool? compact,
      Set<String> expanded = const {},
      ValueChanged<String>? onExpand,
    }) async {
      t.view.physicalSize = const Size(390, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(
            body: AgentSurfaceView(
              spec: spec,
              focusPrefix: 's',
              compact: compact,
              expanded: expanded,
              onExpand: onExpand,
            ),
          ),
        ),
      );
    }

    Finder row(String line) => find.byWidgetPredicate(
      (w) =>
          w is HfSummaryRow &&
          '${w.title} ${w.count}${w.text.isEmpty ? '' : '：${w.text}'}' == line,
    );

    test('density is a schema-validated field of the containers only', () {
      for (final c in ['Column', 'AgentStatusGroup', 'Section']) {
        for (final d in ['summary', 'detail']) {
          final node = {
            'component': c,
            'density': d,
            if (c != 'Column') 'title': 'x',
          };
          expect(
            catalog.parse(_surface(node)).problems,
            isEmpty,
            reason: '$c $d',
          );
        }
      }
      final bad = catalog.parse(
        _surface({'component': 'Column', 'density': 'full'}),
      );
      expect(bad.ok, isFalse);
      expect(
        bad.problems.join(),
        allOf(contains('density'), contains('summary')),
      );
      expect(
        catalog
            .parse(_surface({'component': 'Column', 'density': 3}))
            .problems
            .join(),
        contains('density 必须是字符串'),
      );
      // A leaf has no density.
      expect(
        catalog
            .parse(_surface({..._card('A', 'busy'), 'density': 'detail'}))
            .problems
            .join(),
        contains('没有字段 "density"'),
      );
      expect(catalog.describe(), contains('density:summary|detail'));
    });

    test(
      'folding follows the field, the enclosing container, then the width',
      () {
        Set<String> folded(Object root, {required bool compact}) =>
            foldedPaths(catalog, spec(root).root, compact: compact);
        expect(folded(agents(), compact: true), {'r.1', 'r.2'});
        expect(folded(agents(), compact: false), isEmpty);
        // One group in full, the other still a row.
        expect(folded(agents(density: 'detail'), compact: true), {'r.2'});
        // A column's density reaches the groups that do not say their own.
        expect(folded(agents(column: 'detail'), compact: true), isEmpty);
        expect(folded(agents(column: 'summary'), compact: false), {
          'r.1',
          'r.2',
        });
        // A path the person opened is no longer a row.
        expect(
          foldedPaths(
            catalog,
            spec(agents()).root,
            compact: true,
            expanded: {'r.1'},
          ),
          {'r.2'},
        );
      },
    );

    testWidgets('a phone shows numbers and one line per group', (t) async {
      await show(t, spec(agents()));
      expect(find.byType(HfStatStrip), findsOneWidget);
      expect(row('在忙 1：Cindy 在做 #119'), findsOneWidget);
      // Idle agents have nothing to say besides the name.
      expect(row('空闲 2：Cy、Di'), findsOneWidget);
      // No agent card until somebody asks.
      expect(find.byType(HfStatusCard), findsNothing);
      expect(find.text('在做 #119'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('a wide screen shows the cards', (t) async {
      await show(t, spec(agents()), compact: false);
      expect(find.byType(HfSummaryRow), findsNothing);
      expect(find.byType(HfStatusCard), findsNWidgets(3));
      expect(find.text('Cindy'), findsOneWidget);
    });

    testWidgets('density detail on a group shows its cards on a phone', (
      t,
    ) async {
      await show(t, spec(agents(density: 'detail')));
      expect(find.text('Cindy'), findsOneWidget);
      expect(find.textContaining('在做 #119'), findsOneWidget);
      // The other group still folds.
      expect(row('空闲 2：Cy、Di'), findsOneWidget);
      expect(find.text('Cy'), findsNothing);
    });

    testWidgets('tapping a row asks the owner to show that group', (t) async {
      final asked = <String>[];
      await show(t, spec(agents()), onExpand: asked.add);
      await t.tap(row('空闲 2：Cy、Di'));
      expect(asked, ['r.2']);
      await show(t, spec(agents()), expanded: {'r.2'}, onExpand: asked.add);
      expect(find.text('Cy'), findsOneWidget);
      expect(find.text('Di'), findsOneWidget);
      expect(row('在忙 1：Cindy 在做 #119'), findsOneWidget);
    });

    testWidgets('item numbers match the frame folded and expanded', (t) async {
      for (final expanded in [
        <String>{},
        {'r.1'},
        {'r.1', 'r.2'},
      ]) {
        final s = spec(agents());
        final frame = agentSurfaceFrame(s, compact: true, expanded: expanded);
        final items = (frame['items'] as List).cast<Map<String, Object?>>();
        await show(t, s, compact: true, expanded: expanded);
        final ids = [
          for (final f in t.widgetList<AgentFocusable>(
            find.byType(AgentFocusable),
          ))
            f.id,
        ];
        final numbered = items.where((i) => i['kind'] != 'section').length;
        expect(ids, [
          for (var n = 1; n <= numbered; n++) 's#$n',
        ], reason: '$expanded');
      }
      final folded =
          agentSurfaceFrame(spec(agents()), compact: true)['items'] as List;
      expect((folded[1] as Map)['title'], '在忙 1：Cindy 在做 #119');
    });

    testWidgets(
      'the actions are not a numbered item and carry no model field',
      (t) async {
        final s = catalog.parse({
          'title': 'x',
          'root': {
            'component': 'Column',
            'children': [
              _card('A', 'busy'),
              {'component': 'ActionRow', 'itemId': 'i1', 'approve': true},
            ],
          },
        }).spec!;
        final frame = agentSurfaceFrame(s);
        expect((frame['items'] as List), hasLength(1));
        await show(t, s);
        expect(find.byType(AgentFocusable), findsOneWidget);
        expect(
          find.byKey(const ValueKey('attention-approve-i1')),
          findsOneWidget,
        );
      },
    );
  });

  group('grounded tools', () {
    late ActivityClient client;
    late _Server w;
    late AgentModeData data;
    late AgentGroundedTools tools;
    late List<AgentSurfaceSpec> shown;

    setUp(() {
      AgentModeData.clearSession();
      client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
      client.selectServer('s1');
      w = _Server(client)..server = RaftRecord({'id': 's1', 'role': 'owner'});
      w.agents.addAll([
        _agent('a1', 'Aria', activity: 'working', detail: 'editing files'),
        _agent('a2', 'Bo', activity: 'online'),
        _agent('a3', 'Cy', activity: 'working'),
        _agent('a4', 'Di', status: 'stopped', activity: 'offline'),
        _agent(
          'a5',
          'Ed',
          activity: 'error',
          detail: '{"message":"quota exceeded"}',
        ),
      ]);
      w.tasks.addAll([
        _task(
          98,
          'in_review',
          title: '修复返回',
          claimedById: 'a1',
          claimedByName: 'Aria',
          thread: 'th98',
        ),
        _task(
          102,
          'in_progress',
          title: '历史上拉',
          claimedById: 'a3',
          claimedByName: 'Cy',
          minutes: 12,
        ),
        _task(
          7,
          'in_progress',
          title: '旧任务',
          claimedById: 'a2',
          claimedByName: 'Bo',
          minutes: 360,
        ),
        _task(
          98,
          'in_progress',
          title: '另一频道的 98',
          channel: 'other',
          claimedByName: 'Cy',
        ),
      ]);
      w.threads['th98'] = [
        _msg(1, 'Zed', '请修复返回'),
        _msg(2, 'Aria', '已修复并补了测试。**详情**见 PR。'),
      ];
      data = AgentModeData(w, now: () => _now);
      shown = [];
      tools = AgentGroundedTools(
        data: data,
        host: AgentSurfaceHost(
          begin: (draft) {
            shown.add(draft.spec);
            return {'layer': shown.length + 1};
          },
          changed: (draft, {added}) => const {},
          isOpen: (_) => true,
        ),
      );
    });
    tearDown(() async {
      w.dispose();
      await client.dispose();
    });

    Future<Map<String, Object?>> show(Object root) async =>
        (await tools.run('show_surface', {'surface': _surface(root)}))!;

    test(
      'list_agents reports state and activity from the agents API',
      () async {
        final got = (await tools.run('list_agents', const {}))!;
        final agents = {
          for (final a in (got['agents'] as List).cast<Map<String, Object?>>())
            a['name']: a,
        };
        expect(w.reads, contains('/agents'));
        expect(got['total'], 5);
        expect(got['counts'], {
          'busy': 2,
          'idle': 0,
          'blocked': 2,
          'offline': 1,
        });
        // Working on a task it holds: the activity names it.
        expect(agents['Cy']!['state'], 'busy');
        expect(agents['Cy']!['activity'], '在做 #102「历史上拉」');
        expect(agents['Cy']!['since'], '12 分钟前有进展');
        expect(agents['Cy']!['channel'], 'seed');
        // Working, but its task has not moved in hours -> blocked, like attention.
        expect(agents['Bo']!['state'], 'blocked');
        expect(agents['Bo']!['activity'], contains('#7'));
        // Runtime error: the message, not raw JSON.
        expect(agents['Ed']!['state'], 'blocked');
        expect(agents['Ed']!['activity'], '出错：quota exceeded');
        expect(agents['Di']!['state'], 'offline');
        // No task held: the runtime's own words.
        expect(agents['Aria']!['state'], 'busy');
        expect(agents['Aria']!['activity'], 'editing files');
      },
    );

    test('get_task returns content, owner and the end of the thread', () async {
      final got = (await tools.run('get_task', {'number': 102}))!;
      final task = got['task'] as Map<String, Object?>;
      expect(task['number'], 102);
      expect(task['status'], 'in_progress');
      expect(task['claimer'], 'Cy');
      expect(task['channel'], 'seed');
      expect(task['description'], 'Full text of #102');
      expect(task['thread'], isEmpty);
    });

    test(
      'get_task reads the thread and asks for a channel when ambiguous',
      () async {
        final ambiguous = (await tools.run('get_task', {'number': '#98'}))!;
        expect(ambiguous['error'], contains('多个频道'));
        expect(ambiguous['channels'], unorderedEquals(['seed', 'other']));
        final got = (await tools.run('get_task', {
          'number': 98,
          'channel': '#seed',
        }))!;
        final task = got['task'] as Map<String, Object?>;
        expect(task['status'], 'in_review');
        final thread = (task['thread'] as List).cast<Map<String, Object?>>();
        expect(thread.map((l) => l['who']), ['Zed', 'Aria']);
        // Markdown is stripped from what the model reads.
        expect(thread.last['text'], '已修复并补了测试。详情见 PR。');
        expect(
          (await tools.run('get_task', {'number': 5}))!['error'],
          contains('#5'),
        );
        expect((await tools.run('get_task', const {}))!['error'], isNotNull);
      },
    );

    test('search_tasks finds by words, number and status', () async {
      final byWord = (await tools.run('search_tasks', {'query': '历史'}))!;
      expect((byWord['tasks'] as List).single, containsPair('number', 102));
      final byNumber = (await tools.run('search_tasks', {'query': '#98'}))!;
      expect(byNumber['count'], 2);
      final review = (await tools.run('search_tasks', {
        'query': '',
        'status': 'in_review',
      }))!;
      expect((review['tasks'] as List).single, containsPair('number', 98));
    });

    test('a lane the server refuses does not fail a read', () async {
      // Status lanes are separate queries; the others still answer.
      w.failing.add('/tasks/server');
      final got = (await tools.run('get_task', {'number': 98}))!;
      expect(got['error'], contains('没有找到'));
      final agents = (await tools.run('list_agents', const {}))!;
      expect(agents['total'], 5);
    });

    test('show_surface shows what was read and nothing else', () async {
      await tools.run('list_agents', const {});
      final ok = await show({
        'component': 'Column',
        'children': [
          {
            'component': 'AgentStatusGroup',
            'title': '在忙',
            'state': 'busy',
            'children': [_card('Cy', 'busy'), _card('Aria', 'busy')],
          },
        ],
      });
      expect(ok, containsPair('ok', true));
      expect(ok['layer'], 2);
      expect(shown.single.title, '标题');
    });

    test(
      'invented or contradicted agents are refused with the reason',
      () async {
        final unread = await show(_card('Cy', 'busy'));
        expect(unread['error'], isNotNull);
        expect((unread['problems'] as List).join(), contains('list_agents'));
        await tools.run('list_agents', const {});
        final invented = await show(_card('Zoe', 'busy'));
        expect((invented['problems'] as List).join(), contains('Zoe'));
        final wrong = await show(_card('Cy', 'idle'));
        expect((wrong['problems'] as List).join(), contains('state 是 busy'));
        final group = await show({
          'component': 'AgentStatusGroup',
          'title': '在忙',
          'state': 'busy',
          'children': [_card('Bo', 'blocked')],
        });
        expect(group['problems'], isNotEmpty);
        expect(shown, isEmpty);
      },
    );

    test(
      'a task card needs a task that was read, with its real status',
      () async {
        Map<String, Object?> taskCard(Map<String, Object?> extra) => {
          'component': 'TaskCard',
          'title': '修复返回',
          'status': 'in_review',
          'number': 98,
          ...extra,
        };
        expect(
          (await show(taskCard({})))['problems'].toString(),
          contains('get_task'),
        );
        await tools.run('get_task', {'number': 98, 'channel': 'seed'});
        expect(
          (await show(taskCard({'status': 'done'})))['problems'].toString(),
          contains('不是 done'),
        );
        expect(
          (await show(taskCard({'assignee': 'Zoe'})))['problems'].toString(),
          contains('负责人'),
        );
        expect(
          (await show(taskCard({'number': null})))['problems'].toString(),
          contains('number'),
        );
        expect(
          await show(taskCard({'assignee': 'Aria', 'channel': 'seed'})),
          containsPair('ok', true),
        );
      },
    );

    test('quotes must be the original words of the right person', () async {
      await tools.run('get_task', {'number': 98, 'channel': 'seed'});
      Map<String, Object?> quote(String who, String text) => {
        'component': 'MessageQuote',
        'author': who,
        'text': text,
      };
      // An excerpt (even clipped with an ellipsis) is the original.
      expect(await show(quote('Aria', '已修复并补了测试…')), containsPair('ok', true));
      expect(
        await show(quote('Aria', '已修复并补了测试。详情见 PR。')),
        containsPair('ok', true),
      );
      expect(
        (await show(quote('Aria', '已经全部修好了')))['problems'].toString(),
        contains('原话'),
      );
      expect(
        (await show(quote('Zed', '已修复并补了测试')))['problems'].toString(),
        contains('原话'),
      );
      expect(
        (await show({
          'component': 'TaskCard',
          'title': 't',
          'status': 'in_review',
          'number': 98,
          'quote': {'who': 'Aria', 'text': '我完全重写了它'},
        }))['problems'].toString(),
        contains('TaskCard.quote'),
      );
    });

    test('a surface that breaks the catalog is reported, not shown', () async {
      Object? rejected;
      final t = AgentGroundedTools(
        data: data,
        host: AgentSurfaceHost(
          begin: (_) => {},
          changed: (draft, {added}) => const {},
          isOpen: (_) => true,
        ),
        onRejected: (p) => rejected = p,
      );
      final out = (await t.run('show_surface', {
        'surface': '{"title":"x","root":{"component":"Nope"}}',
      }))!;
      expect(out['error'], isNotNull);
      expect((rejected as List).single, contains('Nope'));
      expect(await t.run('open_channel', const {}), isNull);
    });
  });

  group('headline summarizer', () {
    final a = AgentHeadlineRequest(
      id: 't1',
      version: '2026-10-15T10:00:00Z',
      kind: 'decision',
      text: '修复返回',
      ask: '验收',
      wait: '等了 2 小时',
      doer: 'Aria',
    );
    final b = AgentHeadlineRequest(
      id: 't2',
      version: '2026-10-15T09:00:00Z',
      kind: 'blocked',
      text: '历史上拉',
      ask: '解除阻塞',
      wait: '5 小时没动',
      doer: 'Cy',
    );

    String reply(Map<String, String> byId) => jsonEncode([
      for (final e in byId.entries) {'id': e.key, 'headline': e.value},
    ]);

    test(
      'one request writes all cards; the prompt carries what is known',
      () async {
        final prompts = <String>[];
        final s = ModelHeadlineSummarizer(
          generate: (system, prompt) async {
            prompts.add(prompt);
            return reply({
              't1': 'Aria 完成了修复返回，等你验收',
              't2': 'Cy 的历史上拉卡了 5 小时，请你解除阻塞',
            });
          },
        );
        final got = await s.summarize([a, b]);
        expect(got, {
          't1': 'Aria 完成了修复返回，等你验收',
          't2': 'Cy 的历史上拉卡了 5 小时，请你解除阻塞',
        });
        expect(s.requests, 1);
        final sent = jsonDecode(prompts.single) as List;
        expect(sent, hasLength(2));
        expect(sent.first, containsPair('doer', 'Aria'));
        expect(sent.first, containsPair('ask', '验收'));
        expect(ModelHeadlineSummarizer.system, contains('谁做了什么，要你做什么'));
      },
    );

    test(
      'cached per task id + updatedAt: only changed cards are asked again',
      () async {
        final asked = <List<String>>[];
        final s = ModelHeadlineSummarizer(
          generate: (system, prompt) async {
            final ids = [
              for (final r in jsonDecode(prompt) as List) '${(r as Map)['id']}',
            ];
            asked.add(ids);
            return reply({for (final id in ids) id: '句子 $id ${asked.length}'});
          },
        );
        await s.summarize([a, b]);
        expect(await s.summarize([a, b]), {'t1': '句子 t1 1', 't2': '句子 t2 1'});
        expect(
          asked,
          hasLength(1),
          reason: 'an unchanged batch is not asked again',
        );
        // Task 2 moved on (new updatedAt): only it is rewritten.
        final moved = AgentHeadlineRequest(
          id: 't2',
          version: '2026-10-15T11:00:00Z',
          kind: 'blocked',
          text: b.text,
          ask: b.ask,
          wait: '1 小时没动',
        );
        final got = await s.summarize([a, moved]);
        expect(asked.last, ['t2']);
        expect(got, {'t1': '句子 t1 1', 't2': '句子 t2 2'});
      },
    );

    test('no key, errors and bad replies fall back without throwing', () async {
      final noKey = ModelHeadlineSummarizer(generate: (_, _) async => null);
      expect(await noKey.summarize([a]), isEmpty);

      final offline = ModelHeadlineSummarizer(
        generate: (_, _) async => throw StateError('offline'),
      );
      expect(await offline.summarize([a]), isEmpty);

      for (final bad in [
        'nope',
        '{"x":1}',
        '[1,2]',
        reply({'zzz': '别人的 id'}),
        reply({'t1': ''}),
        reply({'t1': 'x' * 200}),
      ]) {
        final s = ModelHeadlineSummarizer(generate: (_, _) async => bad);
        expect(await s.summarize([a]), isEmpty, reason: bad);
      }
    });

    test('a failed request is not repeated at once, then retried', () async {
      var now = _now;
      var calls = 0;
      final s = ModelHeadlineSummarizer(
        now: () => now,
        generate: (_, _) async {
          calls++;
          if (calls == 1) throw StateError('offline');
          return reply({'t1': '好了'});
        },
      );
      expect(await s.summarize([a]), isEmpty);
      expect(await s.summarize([a]), isEmpty);
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      expect(await s.summarize([a]), {'t1': '好了'});
      expect(calls, 2);
    });

    test('a fenced reply and a partial reply keep what is usable', () async {
      final s = ModelHeadlineSummarizer(
        generate: (_, _) async =>
            '```json\n${reply({'t1': '好', 'zzz': 'x'})}\n```',
      );
      expect(await s.summarize([a, b]), {'t1': '好'});
    });

    test('the cache is bounded', () async {
      final s = ModelHeadlineSummarizer(
        cacheLimit: 2,
        generate: (_, prompt) async {
          final ids = [
            for (final r in jsonDecode(prompt) as List) '${(r as Map)['id']}',
          ];
          return reply({for (final id in ids) id: id});
        },
      );
      AgentHeadlineRequest r(String id) => AgentHeadlineRequest(
        id: id,
        version: 'v',
        kind: 'decision',
        text: '',
        ask: '',
        wait: '',
      );
      await s.summarize([r('1'), r('2'), r('3')]);
      expect(s.requests, 1);
      await s.summarize([r('1')]);
      expect(s.requests, 2, reason: 'the oldest entry was dropped');
    });

    test('the model is the newest stable Flash that can generate text', () {
      Map<String, dynamic> m(
        String n, [
        List<String> methods = const ['generateContent'],
      ]) => {'name': 'models/$n', 'supportedGenerationMethods': methods};
      expect(
        GeminiText.pickModel([
          m('gemini-2.5-flash'),
          m('gemini-2.5-flash-lite'),
          m('gemini-3.5-flash-preview-09'),
          m('gemini-3.0-flash'),
          m('gemini-3.0-flash-live', ['bidiGenerateContent']),
          m('gemini-3.0-flash-image'),
          m('gemini-3.5-pro'),
        ]),
        'models/gemini-3.0-flash',
      );
      expect(
        () => GeminiText.pickModel([m('gemini-3.5-pro')]),
        throwsFormatException,
      );
    });
  });

  group('attention headlines', () {
    test(
      'the summarizer rewrites cards before the result is accepted',
      () async {
        AgentModeData.clearSession();
        final client = ActivityClient()
          ..user = RaftRecord({'id': 'kevin', 'displayName': 'Kevin'});
        client.selectServer('s1');
        final w = _Server(client)
          ..server = RaftRecord({'id': 's1', 'role': 'owner'});
        addTearDown(() async {
          w.dispose();
          await client.dispose();
        });
        w.tasks.add({
          ..._task(
            98,
            'in_review',
            title: '修复返回',
            claimedById: 'a1',
            claimedByName: 'Aria',
            minutes: 120,
          ),
          'createdById': 'kevin',
          'createdByType': 'user',
        });
        final seen = <AgentHeadlineRequest>[];
        final fake = _Fake((requests) async {
          seen.addAll(requests);
          return {for (final r in requests) r.id: '${r.doer} 做完了，等你${r.ask}'};
        });
        final got = await AgentModeData(
          w,
          now: () => _now,
          summarizer: fake,
        ).attention();
        expect(got.items.single.headline, 'Aria 做完了，等你验收「修复返回」');
        expect(seen.single.id, 't98');
        expect(seen.single.kind, 'decision');

        // The same data with a summarizer that fails keeps the rule sentence.
        final rule = await AgentModeData(
          w,
          now: () => _now,
          summarizer: _Fake((_) async => throw StateError('x')),
        ).attention();
        expect(rule.items.single.headline, contains('修复返回'));
        expect(rule.items.single.headline, endsWith('等你验收'));
        final none = await AgentModeData(w, now: () => _now).attention();
        expect(none.items.single.headline, rule.items.single.headline);
      },
    );
  });
}

class _Fake implements AgentHeadlineSummarizer {
  _Fake(this.fn);
  final Future<Map<String, String>> Function(List<AgentHeadlineRequest>) fn;
  @override
  Future<Map<String, String>> summarize(List<AgentHeadlineRequest> r) => fn(r);
}
