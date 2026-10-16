import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/data/workspace_entity_directory.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_entity_binding.dart';
import 'package:raft_flutter/features/agent_mode/agent_surface.dart';
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;

/// Fictional workspace: no real names, servers or data.
final _now = DateTime.utc(2026, 10, 15, 12);
String _ago({int minutes = 0}) =>
    _now.subtract(Duration(minutes: minutes)).toIso8601String();

class _Server extends WorkspaceController {
  _Server(super.client);

  final agents = <Map<String, dynamic>>[];
  final members = <Map<String, dynamic>>[];
  final machines = <Map<String, dynamic>>[];
  final tasks = <Map<String, dynamic>>[];
  final contexts = <String, List<Map<String, dynamic>>>{};
  final reads = <String>[];
  Completer<void>? holdTasks;

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
    if (path == '/agents') return agents;
    if (path == '/servers/s1/members') return members;
    if (path == '/servers/s1/machines') return {'machines': machines};
    if (path == '/tasks/server') {
      await holdTasks?.future;
      return {
        'tasks': [
          for (final t in tasks)
            if (t['status'] == query?['status']) t,
        ],
      };
    }
    if (path.startsWith('/messages/context/')) {
      final id = Uri.decodeComponent(path.split('/').last);
      final rows = contexts[id];
      if (rows == null) throw StateError('404');
      return {'messages': rows};
    }
    return <String, dynamic>{};
  }
}

Map<String, dynamic> _agent(
  String id,
  String name, {
  String? machineId,
  String activity = 'online',
}) => {
  'id': id,
  'name': name,
  'status': 'active',
  'runtime': 'codex',
  'model': 'm',
  'activity': activity,
  'machineId': ?machineId,
};

Map<String, dynamic> _task(
  String id,
  int number,
  String status, {
  String title = 'A task',
  String channel = 'seed',
  String? claimedByName,
}) => {
  'id': id,
  'taskNumber': number,
  'title': title,
  'status': status,
  'channelId': 'ch-$channel',
  'channelName': channel,
  'claimedByName': claimedByName,
  'updatedAt': _ago(minutes: 5),
};

Map<String, dynamic> _message(
  String id,
  String channelId,
  String who,
  String text, {
  List<Map<String, dynamic>> attachments = const [],
}) => {
  'id': id,
  'channelId': channelId,
  'seq': '1',
  'senderName': who,
  'senderType': 'user',
  'content': text,
  'createdAt': _ago(minutes: 30),
  'attachments': attachments,
};

String _surface(Object root) => jsonEncode({'title': '标题', 'root': root});

void main() {
  final catalog = agentStandardCatalog;

  group('catalog and validators', () {
    Map<String, Object?> entity({
      String kind = 'task',
      String id = 'task-1',
      Map<String, Object?> more = const {},
    }) => {'component': 'EntityCard', 'entity': kind, 'id': id, ...more};

    void rejects(Object root, String reason) {
      final parsed = catalog.parse(_surface(root));
      expect(parsed.ok, isFalse, reason: '$root');
      expect(parsed.problems.join('\n'), contains(reason));
    }

    test(
      'every component is in the catalog, with an example that is valid',
      () {
        for (final name in [
          'EntityCard',
          'Table',
          'Timeline',
          'CodeBlock',
          'Callout',
          'ConfirmCard',
          'Choice',
          'Toggle',
        ]) {
          final item = catalog.item(name);
          expect(item, isNotNull, reason: name);
          expect(item!.schema['type'], 'object');
          final parsed = catalog.parse(_surface(item.example!));
          expect(parsed.problems, isEmpty, reason: name);
          expect(catalog.describe(), contains('- $name（'));
        }
      },
    );

    test('an entity card of every kind, with all the model controls', () {
      for (final kind in [
        'message',
        'task',
        'agent',
        'channel',
        'member',
        'computer',
        'file',
      ]) {
        final parsed = catalog.parse(
          _surface(
            entity(
              kind: kind,
              id: '3f2a-91',
              more: {
                'handle': '②',
                'emphasis': 'high',
                'tone': 'warn',
                'display': {
                  'level': 'detail',
                  'show': {'handle': false},
                  'lines': 3,
                  'size': 'regular',
                },
              },
            ),
          ),
        );
        expect(parsed.problems, isEmpty, reason: kind);
      }
    });

    test('entity refs are checked by kind and id format', () {
      rejects(entity(kind: 'robot'), '只能是 message、task');
      rejects(entity(id: '#98'), '不要带 # 或 @');
      rejects(entity(id: '@aria'), '不要带 # 或 @');
      rejects(entity(id: 'a b'), '不是 id');
      rejects(entity(id: 'x' * 65), '太长');
      rejects(entity(more: {'handle': '12345'}), '太长');
      rejects(entity(more: {'handle': '③④'}), '① 到 ⑳');
      rejects(entity(more: {'handle': '21'}), '① 到 ⑳');
      rejects(entity(more: {'tone': 'red'}), '只能是 neutral、good、warn');
      rejects(entity(more: {'emphasis': 'loud'}), '只能是 normal、high');
    });

    test('the model cannot choose colours, fonts or sizes', () {
      for (final field in ['color', 'fontSize', 'font', 'background']) {
        rejects(entity(more: {field: 'red'}), '没有字段 "$field"');
      }
    });

    Map<String, Object?> table(List<Object?> columns, List<Object?> rows) => {
      'component': 'Table',
      'columns': columns,
      'rows': rows,
    };

    test('a table: plain text and entity cells', () {
      final parsed = catalog.parse(
        _surface(
          table(
            ['任务', '人'],
            [
              [
                {'entity': 'task', 'id': 't1', 'handle': '1'},
                'Aria',
              ],
            ],
          ),
        ),
      );
      expect(parsed.problems, isEmpty);
    });

    test('table limits: 5 columns, 20 rows, rows as wide as the columns', () {
      expect(
        catalog
            .parse(
              _surface(
                table(
                  ['1', '2', '3', '4', '5'],
                  [
                    for (var i = 0; i < 20; i++) ['a', 'b', 'c', 'd', 'e'],
                  ],
                ),
              ),
            )
            .problems,
        isEmpty,
      );
      rejects(
        table(
          ['1', '2', '3', '4', '5', '6'],
          [
            ['a'],
          ],
        ),
        '需要 1 到 5 项',
      );
      rejects(
        table(
          ['a'],
          [
            for (var i = 0; i < 21; i++) ['x'],
          ],
        ),
        '需要 1 到 20 项',
      );
      rejects(
        table(
          ['a', 'b'],
          [
            ['only one'],
          ],
        ),
        '要和列数一样（2）',
      );
      rejects(
        table(
          ['a'],
          [
            [
              {'entity': 'task', 'id': '#98'},
            ],
          ],
        ),
        '不要带 # 或 @',
      );
      rejects(
        table(
          ['a'],
          [
            [42],
          ],
        ),
        'rows[0][0]',
      );
      rejects(
        table(
          ['a'],
          [
            [
              {'entity': 'task'},
            ],
          ],
        ),
        '缺少必填字段 "id"',
      );
    });

    test('timeline: entity and id come together', () {
      Map<String, Object?> timeline(List<Object?> items) => {
        'component': 'Timeline',
        'items': items,
      };
      expect(
        catalog
            .parse(
              _surface(
                timeline([
                  {'time': '09:10', 'title': '创建'},
                  {
                    'time': '10:32',
                    'title': '验收',
                    'entity': 'task',
                    'id': 't1',
                  },
                ]),
              ),
            )
            .problems,
        isEmpty,
      );
      rejects(
        timeline([
          {'time': '1', 'title': 'x', 'entity': 'task'},
        ]),
        '要一起写',
      );
      rejects(
        timeline([
          {'time': '1', 'title': 'x', 'entity': 'task', 'id': 'a b'},
        ]),
        '不是 id',
      );
      rejects(timeline([]), '需要 1 到 12 项');
    });

    test('code: at most 40 lines, text or diff', () {
      Map<String, Object?> code(String c, [String? format]) => {
        'component': 'CodeBlock',
        'code': c,
        'format': ?format,
      };
      final forty = [for (var i = 0; i < 40; i++) 'l$i'].join('\n');
      expect(catalog.parse(_surface(code(forty, 'diff'))).problems, isEmpty);
      rejects(code('$forty\nmore'), '最多 40 行');
      rejects(code('x', 'rust'), '只能是 text、diff');
    });

    test('callout: one sentence, a tone', () {
      Map<String, Object?> callout(String text, [String? tone]) => {
        'component': 'Callout',
        'text': text,
        'tone': ?tone,
      };
      expect(
        catalog.parse(_surface(callout('全量检查通过，可以合。', 'good'))).problems,
        isEmpty,
      );
      rejects(callout('通过了。可以合。'), '只写一句话');
      rejects(callout('第一行\n第二行'), '只写一句话');
      rejects(callout('x' * 81), '太长');
      rejects(callout('好', 'red'), '只能是 neutral、good、warn');
    });

    test('confirm: field: from → to lines, a risk', () {
      Map<String, Object?> confirm(List<Object?> changes, [String? risk]) => {
        'component': 'ConfirmCard',
        'title': '合入？',
        'changes': changes,
        'risk': ?risk,
      };
      expect(
        catalog
            .parse(_surface(confirm(['状态: 等验收 → 已完成'], 'sensitive')))
            .problems,
        isEmpty,
      );
      rejects(confirm(['改成已完成']), '"字段: 原值 → 新值"');
      rejects(confirm(['状态: 已完成']), '"字段: 原值 → 新值"');
      rejects(confirm([]), '需要 1 到 8 项');
      rejects(confirm(['a: b → c'], 'critical'), '只能是 change、sensitive');
    });

    test('choice: 2 to 5 distinct options; toggle: a label', () {
      Map<String, Object?> choice(List<Object?> options) => {
        'component': 'Choice',
        'options': options,
      };
      expect(catalog.parse(_surface(choice(['a', 'b']))).problems, isEmpty);
      expect(
        catalog.parse(_surface(choice(['a', 'b', 'c', 'd', 'e']))).problems,
        isEmpty,
      );
      rejects(choice(['a', 'b', 'c', 'd', 'e', 'f']), '需要 2 到 5 项');
      rejects(choice(['a']), '需要 2 到 5 项');
      rejects(choice(['a', 'a']), '重复');
      expect(
        catalog
            .parse(
              _surface({'component': 'Toggle', 'label': '通知我', 'value': true}),
            )
            .problems,
        isEmpty,
      );
      rejects({'component': 'Toggle', 'value': true}, '缺少必填字段 "label"');
      rejects({
        'component': 'Toggle',
        'label': 'x',
        'value': 'yes',
      }, '必须是 true 或 false');
    });

    test('a streamed component is checked the same way', () {
      final problems = <String>[];
      final node = catalog.salvage(
        entity(id: '#98'),
        problems: problems,
        budget: SurfaceBudget(10),
      );
      expect(node, isNull);
      expect(problems.join(), contains('不要带 # 或 @'));
    });

    test('update_component props go through the validator too', () {
      final item = catalog.item('EntityCard')!;
      expect(
        catalog.checkProps(item, {'entity': 'task', 'id': 'ok-1'}, 'x'),
        isEmpty,
      );
      expect(
        catalog.checkProps(item, {'entity': 'task', 'id': '#1'}, 'x').join(),
        contains('不要带 # 或 @'),
      );
    });

    test('the voice model is told about an entity card on screen', () {
      final spec = catalog
          .parse(
            _surface({
              'component': 'Column',
              'children': [
                entity(more: {'handle': '1'}),
                {'component': 'Callout', 'text': '好。'},
              ],
            }),
          )
          .spec!;
      final frame = agentSurfaceFrame(spec);
      final items = frame['items']! as List;
      expect(items, hasLength(1));
      // The app numbers the card itself (see agentHandle); the title is what
      // the app read for it, the id while nothing was.
      expect((items.single as Map)['title'], 'task-1');
      expect((items.single as Map)['detail'], 'task-1');
    });
  });

  group('resolving from the workspace', () {
    late ActivityClient client;
    late _Server w;
    late WorkspaceEntityResolver resolver;

    setUp(() async {
      client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
      client.selectServer('s1');
      w = _Server(client)..server = RaftRecord({'id': 's1', 'role': 'owner'});
      w.machines.add({
        'id': 'k1',
        'name': 'build-box',
        'status': 'online',
        'runtimes': ['codex', 'claude'],
      });
      w.agents.addAll([
        _agent('a1', 'Aria', machineId: 'k1', activity: 'working'),
        _agent('a2', 'Bo', machineId: 'k1'),
      ]);
      w.members.add({
        'userId': 'u1',
        'name': 'grace',
        'displayName': 'Grace',
        'role': 'admin',
      });
      w.channels = [
        RaftChannel({'id': 'ch-seed', 'name': 'seed', 'type': 'channel'}),
        RaftChannel({
          'id': 'ch-dm',
          'name': 'dm-x',
          'type': 'dm',
          'peerDisplayName': 'Grace',
        }),
      ];
      w.unread = {'ch-seed': 3};
      w.mentions = {'ch-seed'};
      w.ledger.switchServer('s1');
      w.ledger.ingest([
        _message(
          'm1',
          'ch-seed',
          'Aria',
          'PR 已合入，**全量检查** 0 失败。',
          attachments: [
            {
              'id': 'f1',
              'filename': 'report.pdf',
              'mimeType': 'application/pdf',
              'sizeBytes': 1258291,
            },
            {
              'id': 'f2',
              'filename': 'shot.png',
              'mimeType': 'image/png',
              'sizeBytes': 2048,
            },
          ],
        ),
      ], expectedGeneration: w.ledger.generation);
      w.tasks.addAll([
        _task('t98', 98, 'in_review', title: '修复返回', claimedByName: 'Aria'),
        _task('t7', 7, 'in_progress', title: '旧任务', channel: 'one'),
        _task('t7b', 7, 'todo', title: '另一个 7', channel: 'two'),
      ]);
      await w.entityDirectory.preload();
      resolver = WorkspaceEntityResolver(w, now: () => _now);
      addTearDown(() async {
        resolver.dispose();
        w.dispose();
        await client.dispose();
      });
    });

    AgentEntityResolution of(AgentEntityKind kind, String id) =>
        resolver.resolve(AgentEntityRef(kind, id));

    T data<T extends AgentEntityData>(AgentEntityKind kind, String id) {
      final r = of(kind, id);
      expect(r, isA<AgentEntityFound>(), reason: '$kind $id → $r');
      return (r as AgentEntityFound).data as T;
    }

    test('agent: state, activity and computer from the directory', () {
      final a = data<AgentAgentData>(AgentEntityKind.agent, 'a1');
      expect(a.name, 'Aria');
      expect(a.state, AgentWorkState.busy);
      expect(a.computer, 'build-box');
      final b = data<AgentAgentData>(AgentEntityKind.agent, 'a2');
      expect(b.state, AgentWorkState.idle);
    });

    test('member, computer, channel (and a direct message)', () {
      final m = data<AgentMemberData>(AgentEntityKind.member, 'u1');
      expect((m.name, m.role), ('Grace', '管理员'));
      expect(m.presence, isNull, reason: 'presence is not claimed');
      final c = data<AgentComputerData>(AgentEntityKind.computer, 'k1');
      expect(c.name, 'build-box');
      expect(c.online, isTrue);
      expect(c.runtimes, ['codex', 'claude']);
      expect(c.agentCount, 2);
      final ch = data<AgentChannelData>(AgentEntityKind.channel, 'ch-seed');
      expect((ch.name, ch.unread, ch.mentioned), ('seed', 3, true));
      expect(ch.lastActivity, '30 分钟前');
      final dm = data<AgentChannelData>(AgentEntityKind.channel, 'ch-dm');
      expect((dm.label, dm.direct), ('Grace', true));
    });

    test('message: from the held window, markdown stripped', () {
      final m = data<AgentMessageData>(AgentEntityKind.message, 'm1');
      expect(m.author, 'Aria');
      expect(m.text, contains('全量检查'));
      expect(m.text, isNot(contains('**')));
      expect(m.channel, 'seed');
      expect(m.attachmentCount, 2);
    });

    test('file: name, type, size, and an image has a thumbnail', () {
      final f = data<AgentFileData>(AgentEntityKind.file, 'f1');
      expect((f.name, f.type, f.size), ('report.pdf', 'PDF', '1.2 MB'));
      expect(f.isImage, isFalse);
      expect(f.thumbnail, isNull);
      final i = data<AgentFileData>(AgentEntityKind.file, 'f2');
      expect((i.type, i.size, i.isImage), ('PNG', '2 KB', true));
      expect(i.thumbnail, isNotNull);
    });

    test('an id the app does not have is missing, with a reason', () {
      for (final (kind, id) in [
        (AgentEntityKind.agent, 'nope'),
        (AgentEntityKind.member, 'nope'),
        (AgentEntityKind.computer, 'nope'),
        (AgentEntityKind.channel, 'nope'),
        (AgentEntityKind.file, 'nope'),
      ]) {
        final r = of(kind, id);
        expect(r, isA<AgentEntityMissing>(), reason: '$kind');
        expect((r as AgentEntityMissing).reason, isNotEmpty);
      }
    });

    test(
      'a role that may not see a kind says so, it is not "loading"',
      () async {
        w.server = RaftRecord({'id': 's1', 'role': 'guest'});
        final r = of(AgentEntityKind.computer, 'k1');
        expect(r, isA<AgentEntityMissing>());
        expect((r as AgentEntityMissing).reason, contains('权限'));
      },
    );

    test('task: read from the server once, then from memory', () async {
      expect(of(AgentEntityKind.task, 't98'), isA<AgentEntityLoading>());
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final t = data<AgentTaskData>(AgentEntityKind.task, 't98');
      expect((t.number, t.title, t.status), (98, '修复返回', 'in_review'));
      expect((t.assignee, t.channel, t.updated), ('Aria', 'seed', '5 分钟前'));
      final reads = w.reads.where((p) => p == '/tasks/server').length;
      data<AgentTaskData>(AgentEntityKind.task, 't98');
      expect(w.reads.where((p) => p == '/tasks/server').length, reads);
    });

    test('task: many cards for tasks not yet read start one read', () async {
      of(AgentEntityKind.task, 't98');
      of(AgentEntityKind.task, 't7');
      of(AgentEntityKind.task, 'unknown');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // Five lanes, read once.
      expect(w.reads.where((p) => p == '/tasks/server').length, 5);
    });

    test(
      'task: a number works when it is unique, not when it repeats',
      () async {
        of(AgentEntityKind.task, '98');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(data<AgentTaskData>(AgentEntityKind.task, '98').title, '修复返回');
        final dup = of(AgentEntityKind.task, '7');
        expect(dup, isA<AgentEntityMissing>());
        expect((dup as AgentEntityMissing).reason, contains('请改用任务的 id'));
      },
    );

    test('task: one that does not exist is missing after the read', () async {
      of(AgentEntityKind.task, 'nope');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(of(AgentEntityKind.task, 'nope'), isA<AgentEntityMissing>());
      // Not read again at once.
      final reads = w.reads.length;
      of(AgentEntityKind.task, 'nope');
      expect(w.reads.length, reads);
    });

    test(
      'message not in a window is read by id; a failure is missing',
      () async {
        w.contexts['m9'] = [_message('m9', 'ch-seed', 'Bo', '另一条')];
        expect(of(AgentEntityKind.message, 'm9'), isA<AgentEntityLoading>());
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(
          data<AgentMessageData>(AgentEntityKind.message, 'm9').author,
          'Bo',
        );
        of(AgentEntityKind.message, 'm404');
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(of(AgentEntityKind.message, 'm404'), isA<AgentEntityMissing>());
      },
    );

    test('a change in the workspace notifies the resolver\'s listeners', () {
      var notified = 0;
      resolver.addListener(() => notified++);
      w.unread = {'ch-seed': 5};
      w.notifyListeners();
      expect(notified, greaterThan(0));
      expect(
        data<AgentChannelData>(AgentEntityKind.channel, 'ch-seed').unread,
        5,
      );
    });

    test('task events patch a task that was read', () async {
      of(AgentEntityKind.task, 't98');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      var notified = 0;
      resolver.addListener(() => notified++);
      client.emit('task:updated', {
        'task': {
          'id': 't98',
          'status': 'done',
          'serverId': 's1',
          'updatedAt': _now.toIso8601String(),
        },
        'serverId': 's1',
      });
      expect(notified, greaterThanOrEqualTo(1));
      final t = data<AgentTaskData>(AgentEntityKind.task, 't98');
      expect((t.status, t.title, t.updated), ('done', '修复返回', '刚刚'));
      client.emit('task:deleted', {'taskId': 't98', 'serverId': 's1'});
      expect(of(AgentEntityKind.task, 't98'), isA<AgentEntityMissing>());
    });
  });

  group('on screen', () {
    late ActivityClient client;
    late _Server w;

    setUp(() async {
      client = ActivityClient()..user = RaftRecord({'id': 'kevin'});
      client.selectServer('s1');
      w = _Server(client)..server = RaftRecord({'id': 's1', 'role': 'owner'});
      w.agents.add(_agent('a1', 'Aria', activity: 'working'));
      w.channels = [
        RaftChannel({'id': 'ch-seed', 'name': 'seed', 'type': 'channel'}),
      ];
      w.unread = {'ch-seed': 3};
      w.ledger.switchServer('s1');
      await w.entityDirectory.preload();
      addTearDown(() async {
        w.dispose();
        await client.dispose();
      });
    });

    Widget host(
      Widget child, {
      AgentEntityProblem? onProblem,
      void Function(AgentInteraction)? onInteraction,
    }) => MaterialApp(
      theme: raftTheme(RaftFamily.brutal),
      home: Scaffold(
        body: AgentEntityBindingScope(
          controller: w,
          onProblem: onProblem,
          child: AgentInteractionScope(
            onInteraction: onInteraction ?? (_) {},
            child: child,
          ),
        ),
      ),
    );

    Widget surface(Object root, {bool animate = true}) => AgentSurfaceView(
      spec: catalog.parse(_surface(root)).spec!,
      focusPrefix: 'x',
      compact: true,
      animate: animate,
    );

    testWidgets('a surface of entity cards draws from the data and enters', (
      t,
    ) async {
      await t.pumpWidget(
        host(
          surface({
            'component': 'Column',
            'children': [
              {
                'component': 'EntityCard',
                'entity': 'agent',
                'id': 'a1',
                'handle': '1',
              },
              {
                'component': 'EntityCard',
                'entity': 'channel',
                'id': 'ch-seed',
                'handle': '2',
              },
              {'component': 'Callout', 'tone': 'good', 'text': '都在正常运行。'},
            ],
          }),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Aria'), findsOneWidget);
      expect(find.text('在忙'), findsOneWidget);
      expect(find.text('#seed'), findsOneWidget);
      expect(find.text('未读 3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('都在正常运行。'), findsOneWidget);
      // The same staged entrance as the other components.
      expect(find.byType(AgentAppear), findsWidgets);
    });

    testWidgets('a card follows the workspace when its data changes', (
      t,
    ) async {
      await t.pumpWidget(
        host(
          surface({
            'component': 'EntityCard',
            'entity': 'channel',
            'id': 'ch-seed',
          }, animate: false),
        ),
      );
      expect(find.text('未读 3'), findsOneWidget);
      w.unread = {'ch-seed': 0};
      w.notifyListeners();
      await t.pump();
      expect(find.text('未读 3'), findsNothing);
    });

    testWidgets('an agent card updates when the directory re-reads', (t) async {
      await t.pumpWidget(
        host(
          surface({
            'component': 'EntityCard',
            'entity': 'agent',
            'id': 'a1',
          }, animate: false),
        ),
      );
      expect(find.text('在忙'), findsOneWidget);
      w.agents.first['activity'] = 'online';
      await t.runAsync(
        () =>
            w.entityDirectory.refresh(WorkspaceEntityKind.agents, force: true),
      );
      await t.pump();
      expect(find.text('在忙'), findsNothing);
      expect(find.text('空闲'), findsWidgets);
    });

    testWidgets('an unknown id is a 找不到 stub and the model is told', (t) async {
      final problems = <(AgentEntityRef, String)>[];
      await t.pumpWidget(
        host(
          surface({
            'component': 'Column',
            'children': [
              {
                'component': 'EntityCard',
                'entity': 'agent',
                'id': 'ghost',
                'handle': '3',
              },
              {'component': 'EntityCard', 'entity': 'channel', 'id': 'ch-seed'},
            ],
          }, animate: false),
          onProblem: (ref, reason) => problems.add((ref, reason)),
        ),
      );
      await t.pump();
      expect(find.textContaining('找不到Agent'), findsOneWidget);
      // The model wrote 3; the cards wear their place on the screen.
      expect(find.text('3'), findsNothing);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('#seed'), findsOneWidget);
      expect(problems, hasLength(1));
      expect(
        problems.single.$1,
        const AgentEntityRef(AgentEntityKind.agent, 'ghost'),
      );
      expect(problems.single.$2, contains('ghost'));
    });

    testWidgets('confirm, choice and toggle report to the interaction scope', (
      t,
    ) async {
      final events = <AgentInteraction>[];
      await t.pumpWidget(
        host(
          surface({
            'component': 'Column',
            'children': [
              {
                'component': 'ConfirmCard',
                'id': 'c1',
                'title': '合入 #98？',
                'changes': ['分支: 未合入 → 已合入'],
              },
              {
                'component': 'Choice',
                'id': 'q1',
                'prompt': '合到哪里？',
                'options': ['integration', 'main'],
              },
              {'component': 'Toggle', 'id': 'tg', 'label': '完成后通知我'},
            ],
          }, animate: false),
          onInteraction: events.add,
        ),
      );
      await t.tap(find.text('确认'));
      await t.pump();
      await t.tap(find.text('main'));
      await t.pump();
      await t.tap(find.text('完成后通知我'));
      await t.pump(const Duration(milliseconds: 200));
      expect(events, hasLength(3));
      final confirm = events[0] as AgentConfirmed;
      expect(
        (confirm.nodeId, confirm.yes, confirm.title),
        ('c1', true, '合入 #98？'),
      );
      final chose = events[1] as AgentChose;
      expect((chose.nodeId, chose.index, chose.label), ('q1', 1, 'main'));
      final toggled = events[2] as AgentToggled;
      expect((toggled.nodeId, toggled.on), ('tg', true));
    });

    testWidgets('table, timeline and code draw inside a surface', (t) async {
      await t.pumpWidget(
        host(
          surface({
            'component': 'Column',
            'children': [
              {
                'component': 'Table',
                'columns': ['Agent', '状态'],
                'rows': [
                  [
                    {'entity': 'agent', 'id': 'a1'},
                    '在忙',
                  ],
                ],
              },
              {
                'component': 'Timeline',
                'items': [
                  {
                    'time': '10:32',
                    'title': '开始',
                    'entity': 'agent',
                    'id': 'a1',
                  },
                ],
              },
              {
                'component': 'CodeBlock',
                'format': 'diff',
                'code': '-old\n+new',
              },
            ],
          }, animate: false),
        ),
      );
      await t.pump();
      expect(find.text('Aria'), findsNWidgets(2));
      expect(find.text('开始'), findsOneWidget);
      expect(find.text('+new'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
