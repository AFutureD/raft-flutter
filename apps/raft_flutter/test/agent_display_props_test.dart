import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_stream.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Every generative component takes `display` (a level and per-element
/// switches) and every list `childDisplay`: schema, strict validation,
/// inheritance down the tree and `update_component`. Fictional data only.
final _now = DateTime.utc(2026, 10, 15, 12);

String _surface(Object root) => jsonEncode({'title': '标题', 'root': root});

Map<String, Object?> _quote(String author, [Map<String, Object?>? display]) => {
  'component': 'MessageQuote',
  'author': author,
  'time': '10:32',
  'text': 'said-by-$author',
  'display': ?display,
};

Map<String, Object?> _entity(
  String kind,
  String id, [
  Map<String, Object?>? display,
]) => {
  'component': 'EntityCard',
  'entity': kind,
  'id': id,
  'display': ?display,
};

class _Resolver implements AgentEntityResolver {
  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  AgentEntityResolution resolve(AgentEntityRef ref) => switch (ref.kind) {
    AgentEntityKind.message => AgentEntityFound(
      AgentMessageData(
        author: 'Zed-${ref.id}',
        text: 'hello-${ref.id}',
        time: '10:32',
      ),
    ),
    _ => const AgentEntityMissing('没有'),
  };
}

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => _now);

  @override
  Future<AgentAttention> attention() async => const AgentAttention(items: []);

  @override
  Future<List<AgentRuntimeInfo>> agents() async => [
    AgentRuntimeInfo(
      id: 'id-Aria',
      name: 'Aria',
      state: AgentWorkState.busy,
      activity: '在做 #102',
      since: '12 分钟前有进展',
    ),
  ];

  @override
  List<AgentRuntimeInfo>? cachedAgents() => null;
}

void main() {
  final catalog = agentStandardCatalog;

  group('schema', () {
    test('every component has the display field it should', () {
      for (final name in [
        'AgentStatusCard',
        'AgentStatusGroup',
        'TaskCard',
        'MessageQuote',
        'StatRow',
        'Section',
        'EntityCard',
        'Table',
        'Timeline',
        'CodeBlock',
        'Callout',
        'ConfirmCard',
      ]) {
        expect(
          catalog.item(name)!.properties.containsKey('display'),
          isTrue,
          reason: name,
        );
      }
      for (final name in ['Column', 'Section', 'AgentStatusGroup']) {
        expect(
          catalog.item(name)!.properties.containsKey('childDisplay'),
          isTrue,
          reason: name,
        );
      }
      // Nothing to show or hide on these.
      for (final name in ['Choice', 'Toggle', 'Column']) {
        expect(
          catalog.item(name)!.properties.containsKey('display'),
          isFalse,
          reason: name,
        );
      }
    });

    test('the reference tells the model every element name', () {
      final doc = catalog.describe();
      expect(doc, contains('display:{level:minimum|medium|detail,show:{'));
      expect(doc, contains('size:compact|regular|large'));
      for (final kind in agentDisplayKinds.values) {
        for (final e in kind.elements) {
          expect(doc, contains(e), reason: '${kind.key}.$e');
        }
      }
      // The entity card says what each kind shows at each level.
      expect(doc, contains('minimum=text、handle'));
      expect(doc, contains('childDisplay'));
    });

    test('every element of every component can be switched either way', () {
      for (final entry in agentDisplayKinds.entries) {
        final kind = entry.value;
        final entity = const {
          'message',
          'task',
          'agent',
          'channel',
          'member',
          'computer',
          'file',
        }.contains(kind.key);
        final item = catalog.item(entity ? 'EntityCard' : kind.key)!;
        for (final on in [true, false]) {
          final node = {...item.example!};
          if (entity) {
            node['entity'] = kind.key;
          }
          node['display'] = {
            'level': 'medium',
            'show': {for (final e in kind.elements) e: on},
          };
          final parsed = catalog.parse(_surface(node));
          expect(parsed.problems, isEmpty, reason: '${kind.key} $on');
        }
      }
    });

    void rejects(Object root, List<String> mentions) {
      final parsed = catalog.parse(_surface(root));
      expect(parsed.ok, isFalse, reason: '$root');
      final text = parsed.problems.join('\n');
      for (final m in mentions) {
        expect(text, contains(m));
      }
    }

    test('an unknown element is refused, with the valid names', () {
      rejects(
        _quote('A', {
          'show': {'avator': false},
        }),
        ['avator', 'author', 'time', 'text', 'bar'],
      );
      rejects(
        {
          'component': 'Table',
          'columns': ['a'],
          'rows': [
            ['x'],
          ],
          'display': {
            'show': {'stripes': true},
          },
        },
        ['stripes', 'header', 'borders', 'zebra'],
      );
      rejects(
        {
          'component': 'Column',
          'childDisplay': {
            'show': {'nope': false},
          },
        },
        ['nope', 'avatar', 'thread_count', 'zebra'],
      );
    });

    test('an element of another kind is refused on an entity card', () {
      rejects(
        _entity('message', 'm-1', {
          'show': {'model': true},
        }),
        ['"model"', 'avatar', 'author', 'text', 'reactions', 'thread_count'],
      );
      // On the kind that has it, it is fine.
      expect(
        catalog
            .parse(
              _surface(
                _entity('agent', 'a-1', {
                  'show': {'model': true},
                }),
              ),
            )
            .ok,
        isTrue,
      );
    });

    test('level, size, lines and show values are checked', () {
      rejects(_quote('A', {'level': 'huge'}), ['minimum', 'medium', 'detail']);
      rejects(_quote('A', {'size': 'tiny'}), ['compact', 'regular', 'large']);
      rejects(_quote('A', {'lines': 0}), ['display.lines', '1']);
      rejects(_quote('A', {'lines': 9}), ['display.lines', '8']);
      rejects(_quote('A', {'lines': '3'}), ['display.lines', '整数']);
      rejects(
        _quote('A', {
          'show': {'bar': 'no'},
        }),
        ['display.show.bar', 'true 或 false'],
      );
      rejects(_quote('A', {'color': 'red'}), ['color', 'level', 'show']);
      for (final lines in [1, 8]) {
        expect(catalog.parse(_surface(_quote('A', {'lines': lines}))).ok, true);
      }
    });

    test('a component with no text has no lines', () {
      rejects(
        {
          'component': 'StatRow',
          'stats': [
            {'label': 'a', 'value': '1'},
          ],
          'display': {'lines': 2},
        },
        ['lines', 'level', 'show'],
      );
    });

    test('display is not a field of a list, childDisplay is', () {
      rejects(
        {
          'component': 'Column',
          'display': {'level': 'minimum'},
        },
        ['display'],
      );
      final ok = catalog.parse(
        _surface({
          'component': 'Column',
          'childDisplay': {
            'level': 'minimum',
            'show': {'avatar': false},
            'lines': 2,
            'size': 'large',
          },
          'children': [_quote('A')],
        }),
      );
      expect(ok.problems, isEmpty);
    });
  });

  group('the surface draws what the display says', () {
    Future<void> show(
      WidgetTester t,
      Object root, {
      bool? compact = false,
      Set<String> expanded = const {},
    }) async {
      final parsed = catalog.parse(_surface(root));
      expect(parsed.problems, isEmpty);
      t.view.physicalSize = const Size(390, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(
            body: AgentEntityScope(
              resolver: _Resolver(),
              child: AgentSurfaceView(
                spec: parsed.spec!,
                focusPrefix: 's',
                compact: compact,
                expanded: expanded,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    }

    testWidgets('a message list without authors is one property', (t) async {
      await show(t, {
        'component': 'Section',
        'title': '最近讨论',
        'childDisplay': {
          'show': {'author': false},
        },
        'children': [_quote('Ann'), _quote('Bob')],
      });
      expect(find.textContaining('said-by-Ann'), findsOneWidget);
      expect(find.textContaining('Ann'), findsOneWidget);
      expect(find.textContaining('Bob'), findsOneWidget);
      // The time stays: only the author went.
      expect(find.textContaining('10:32'), findsNWidgets(2));
    });

    testWidgets('without it the author is there', (t) async {
      await show(t, {
        'component': 'Section',
        'title': '最近讨论',
        'children': [_quote('Ann')],
      });
      expect(find.textContaining('Ann · 10:32'), findsOneWidget);
    });

    testWidgets('a child can say its own, element by element', (t) async {
      await show(t, {
        'component': 'Section',
        'title': 'x',
        'childDisplay': {
          'show': {'author': false, 'time': false},
        },
        'children': [
          _quote('Ann'),
          _quote('Bob', {
            'show': {'author': true},
          }),
        ],
      });
      // Bob turned his author back on; his time is still the list's.
      expect(find.text('Bob'), findsOneWidget);
      expect(find.textContaining('Ann'), findsOneWidget);
      expect(find.textContaining('10:32'), findsNothing);
    });

    testWidgets('a level reaches the children, a child level beats it', (
      t,
    ) async {
      await show(t, {
        'component': 'Column',
        'childDisplay': {'level': 'minimum'},
        'children': [
          _quote('Ann'),
          _quote('Bob', {'level': 'medium'}),
        ],
      });
      // Minimum is the words only; medium adds the author line.
      expect(find.textContaining('said-by-Ann'), findsOneWidget);
      expect(find.textContaining('Ann'), findsOneWidget);
      expect(find.textContaining('Bob · 10:32'), findsOneWidget);
    });

    testWidgets('it goes down through lists, the nearest list wins', (t) async {
      await show(t, {
        'component': 'Column',
        'childDisplay': {
          'show': {'author': false, 'time': false},
        },
        'children': [
          {
            'component': 'Section',
            'title': 'outer',
            'children': [_quote('Ann')],
          },
          {
            'component': 'Section',
            'title': 'inner',
            'childDisplay': {
              'show': {'author': true},
            },
            'children': [_quote('Bob')],
          },
        ],
      });
      expect(find.text('Ann'), findsNothing);
      expect(find.text('Bob'), findsOneWidget);
      expect(find.textContaining('10:32'), findsNothing);
    });

    testWidgets('entity cards: no avatars for the whole list', (t) async {
      await show(t, {
        'component': 'Column',
        'childDisplay': {
          'show': {'avatar': false},
        },
        'children': [_entity('message', 'm1'), _entity('message', 'm2')],
      });
      expect(find.byType(AgentEntityAvatar), findsNothing);
      expect(find.textContaining('hello-m1'), findsOneWidget);
      await show(t, {
        'component': 'Column',
        'children': [_entity('message', 'm1'), _entity('message', 'm2')],
      });
      expect(find.byType(AgentEntityAvatar), findsNWidgets(2));
      await show(t, {
        'component': 'Column',
        'childDisplay': {
          'show': {'avatar': false},
        },
        'children': [
          _entity('message', 'm1'),
          _entity('message', 'm2', {
            'show': {'avatar': true},
          }),
        ],
      });
      expect(find.byType(AgentEntityAvatar), findsOneWidget);
    });

    testWidgets('a list of other kinds takes names it has no use for', (
      t,
    ) async {
      await show(t, {
        'component': 'Column',
        'childDisplay': {
          'show': {'model': false, 'avatar': false},
        },
        'children': [
          _entity('message', 'm1'),
          {'component': 'Callout', 'text': '好。'},
        ],
      });
      expect(find.byType(AgentEntityAvatar), findsNothing);
      expect(find.text('好。'), findsOneWidget);
    });

    testWidgets('a hidden handle badge is still the card\'s number', (t) async {
      final semantics = t.ensureSemantics();
      await show(t, {
        'component': 'Column',
        'children': [
          _entity('message', 'm1', {
            'show': {'handle': false},
          }),
          _entity('message', 'm2'),
        ],
      });
      // Only the second wears its ②, but both are numbered in order.
      expect(find.byKey(const ValueKey('entity-handle')), findsOneWidget);
      expect(find.text('②'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^① ')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^② ')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a folded group follows its display', (t) async {
      Object group(Map<String, Object?>? display) => {
        'component': 'Column',
        'children': [
          {
            'component': 'AgentStatusGroup',
            'title': '在忙',
            'state': 'busy',
            'display': ?display,
            'children': [
              {
                'component': 'AgentStatusCard',
                'name': 'Cindy',
                'state': 'busy',
                'activity': '在做 #119',
              },
            ],
          },
        ],
      };
      await show(t, group(null), compact: true);
      expect(find.textContaining('在忙 1：Cindy'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      await show(
        t,
        group({
          'show': {'count': false, 'collapse': false},
        }),
        compact: true,
      );
      expect(find.textContaining('在忙：Cindy'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('the cards of a group take its childDisplay', (t) async {
      await show(t, {
        'component': 'AgentStatusGroup',
        'title': '在忙',
        'state': 'busy',
        'density': 'detail',
        'childDisplay': {
          'show': {'activity': false},
        },
        'children': [
          {
            'component': 'AgentStatusCard',
            'name': 'Cindy',
            'state': 'busy',
            'activity': '在做 #119',
          },
        ],
      }, compact: true);
      expect(find.text('Cindy'), findsOneWidget);
      expect(find.text('在做 #119'), findsNothing);
    });

    testWidgets('changing the display moves the card smoothly', (t) async {
      Object card(Map<String, Object?> display) => {
        'component': 'Column',
        'children': [_entity('message', 'm1', display)],
      };
      double height() =>
          t.getSize(find.byKey(const ValueKey('entity-card-message'))).height;
      await show(t, card({'level': 'minimum'}));
      final small = height();
      final spec = catalog
          .parse(_surface(card({'level': 'detail', 'size': 'regular'})))
          .spec!;
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: Scaffold(
            body: AgentEntityScope(
              resolver: _Resolver(),
              child: AgentSurfaceView(
                spec: spec,
                focusPrefix: 's',
                compact: true,
              ),
            ),
          ),
        ),
      );
      expect(height(), small, reason: 'no jump on the first frame');
      await t.pump(const Duration(milliseconds: 90));
      final mid = height();
      expect(mid, greaterThan(small));
      await t.pumpAndSettle();
      expect(height(), greaterThan(mid));
    });
  });

  group('update_component', () {
    late ActivityClient client;
    late WorkspaceController w;
    late AgentGroundedTools tools;
    late AgentSurfaceDraft draft;

    setUp(() async {
      AgentModeData.clearSession();
      FlutterSecureStorage.setMockInitialValues({});
      client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
      client.selectServer('s1');
      w = WorkspaceController(client)
        ..server = RaftRecord({'id': 's1', 'role': 'owner'});
      tools = AgentGroundedTools(
        data: _Data(w),
        host: AgentSurfaceHost(
          begin: (d) {
            draft = d;
            return {'layer': 2};
          },
          changed: (d, {added}) => const {},
          isOpen: (_) => true,
        ),
      );
      await tools.run('list_agents', const {});
      await tools.run('begin_surface', {
        'surface_id': 'agents',
        'title': 'Agent',
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
      await tools.run('add_component', {
        'surface_id': 'agents',
        'parent_id': 'busy',
        'component': jsonEncode({
          'id': 'aria',
          'component': 'AgentStatusCard',
          'name': 'Aria',
          'state': 'busy',
          'activity': '在做 #102',
          'since': '12 分钟前有进展',
          'display': {
            'level': 'medium',
            'show': {'since': true},
          },
        }),
      });
    });
    tearDown(() async {
      w.dispose();
      await client.dispose();
    });

    Future<Map<String, Object?>> update(
      Object props, [
      String id = 'aria',
    ]) async => (await tools.run('update_component', {
      'surface_id': 'agents',
      'id': id,
      'props': jsonEncode(props),
    }))!;

    test('only the named elements change, the rest of display stays', () async {
      expect(
        await update({
          'display': {
            'show': {'activity': false},
          },
        }),
        {'ok': true},
      );
      expect(draft.find('aria')!.props['display'], {
        'level': 'medium',
        'show': {'since': true, 'activity': false},
      });
      await update({
        'display': {'level': 'detail', 'size': 'large'},
      });
      expect(draft.find('aria')!.props['display'], {
        'level': 'detail',
        'show': {'since': true, 'activity': false},
        'size': 'large',
      });
    });

    test(
      'null puts an element back to the preset, then drops display',
      () async {
        await update({
          'display': {
            'show': {'since': null},
          },
        });
        expect(draft.find('aria')!.props['display'], {'level': 'medium'});
        await update({'display': null});
        expect(draft.find('aria')!.props.containsKey('display'), isFalse);
        // The rest of the card is as it was.
        expect(draft.find('aria')!.string('activity'), '在做 #102');
      },
    );

    test('an unknown element is refused and nothing changes', () async {
      final r = await update({
        'display': {
          'show': {'avator': false},
        },
      });
      expect(r['error'], isNotNull);
      final text = jsonEncode(r);
      expect(text, contains('avator'));
      expect(text, contains('activity'));
      expect(draft.find('aria')!.props['display'], {
        'level': 'medium',
        'show': {'since': true},
      });
    });

    test('a list takes childDisplay the same way', () async {
      await update({
        'childDisplay': {
          'show': {'since': false},
        },
      }, 'busy');
      expect(draft.find('busy')!.props['childDisplay'], {
        'show': {'since': false},
      });
      await update({
        'childDisplay': {
          'show': {'nope': false},
        },
      }, 'busy');
      expect(draft.find('busy')!.props['childDisplay'], {
        'show': {'since': false},
      });
    });
  });
}
