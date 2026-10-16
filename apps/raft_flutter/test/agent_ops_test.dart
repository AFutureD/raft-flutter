import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';

import 'support/agent_action_harness.dart';
import 'support/agent_capability_world.dart';

/// Stop, start, restart, reset a session, the SOS, and the reads about
/// Agents and notices. The operations are sensitive: two confirmations.
void main() {
  late ActionHarness h;

  setUp(() {
    h = ActionHarness();
    h.w.routes['/agents'] = (_) => [
      {
        'id': 'a-cody',
        'name': 'cody',
        'displayName': 'Cody',
        'runtime': 'codex',
        'machineId': 'm1',
      },
      {'id': 'a-ext', 'name': 'ext', 'displayName': 'Ext', 'external': true},
      {
        'id': 'a-old',
        'name': 'old',
        'displayName': 'Old',
        'deletedAt': '2026-09-01T00:00:00Z',
      },
      {
        'id': 'a-mine',
        'name': 'mine',
        'displayName': 'Mine',
        'creatorType': 'user',
        'creatorId': 'kevin',
      },
    ];
  });
  tearDown(() => h.dispose());

  final ops = {
    'agents.stop': ('停掉 Cody', 'stop', <String, Object?>{}, '运行中 → 已停止'),
    'agents.start': ('启动 Cody', 'start', <String, Object?>{}, '已停止 → 运行中'),
    'agents.restart': ('重启 Cody', 'reset', {'mode': 'restart'}, '运行中 → 重启'),
    'agents.reset_session': (
      '重置 Cody 的会话',
      'reset',
      {'mode': 'session'},
      '当前会话 → 新会话',
    ),
  };

  group('every runtime operation is sensitive', () {
    for (final e in ops.entries) {
      test('${e.key}: preview, two confirmations, then it runs', () async {
        expect(h.tools.registry[e.key]!.risk, AgentCapabilityRisk.sensitive);
        final r = await h.act(e.key, {'agent': 'Cody'});
        expect(r['status'], 'needs_confirmation', reason: '$r');
        expect(r['confirmation'], '1/2');
        expect(h.summary(r), startsWith(e.value.$1));
        expect(ActionHarness.lineOk(h.changes(r).single), isTrue);
        expect(h.changes(r).single, endsWith(e.value.$4));
        // The model cannot confirm; one press is not enough.
        final early = await h.tools.run('confirm', {'token': r['confirmToken']});
        expect(early!['error'], 'needs_user_confirmation');
        final second = await h.approve(r);
        expect(second['status'], 'needs_second_confirmation');
        expect(h.w.commands, isEmpty, reason: 'nothing before the second yes');
        final done = await h.approve(second);
        expect(done['status'], 'done', reason: '$done');
        final call = h.w.commands.single;
        expect(call.$1, 'POST');
        expect(call.$2, '/agents/a-cody/${e.value.$2}');
        expect(call.$3, e.value.$3);
        expect((done['result'] as Map)['entity'], 'agent');
        expect(h.tools.audit.entries.single.capability, e.key);
      });
    }

    test('stop and start can be taken back, restart and reset cannot', () async {
      var done = await h.approveTwice(await h.act('agents.stop', {'agent': 'Cody'}));
      expect((done['undo'] as Map)['label'], '重新启动');
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect(h.w.commands.last.$2, '/agents/a-cody/start');
      done = await h.approveTwice(await h.act('agents.restart', {'agent': 'Cody'}));
      expect(done.containsKey('undo'), isFalse);
    });

    test('a failure is a card with retry, and says it', () async {
      h.w.commandError = const RaftApiException('offline');
      final r = await h.act('agents.stop', {'agent': 'Cody'});
      final done = await h.approveTwice(r);
      expect(done['status'], 'failed');
      expect(h.tools.audit.entries.single.ok, isFalse);
    });

    test('refused at the preview: external, archived, unknown', () async {
      for (final (agent, message) in [
        ('Ext', '外部 Agent'),
        ('Old', '没有叫'),
        ('Nobody', '没有叫'),
      ]) {
        final r = await h.act('agents.stop', {'agent': agent});
        expect('${r['error']}', contains(message), reason: agent);
        expect(r.containsKey('confirmToken'), isFalse);
      }
      expect(h.w.commands, isEmpty);
    });
  });

  group('SOS', () {
    test('stop: previewed, confirmed twice, then the channel call', () async {
      final r = await h.act('channels.sos_stop', {'channel': 'general'});
      expect(h.summary(r), startsWith('紧急停止 #general 里的所有 Agent'));
      expect(h.changes(r).single, '#general 的 Agent: 运行中 → 全部停止');
      final done = await h.approveTwice(r);
      expect(done['status'], 'done', reason: '$done');
      expect(h.w.commands.single.$1, 'POST');
      expect(h.w.commands.single.$2, '/channels/ch-general/stop-all-agents');
      expect((done['result'] as Map)['entity'], 'channel');
    });

    test('resume carries the person\'s guidance in the dialog\'s wording', () async {
      final r = await h.act('channels.sos_resume', {
        'channel': 'general',
        'guidance': '先别动数据库，只改前端',
      });
      expect(h.changes(r), [
        '#general 的 Agent: 已停止 → 继续运行',
        '新指示:  → 先别动数据库，只改前端',
      ]);
      await h.approveTwice(r);
      final call = h.w.commands.single;
      expect(call.$2, '/channels/ch-general/resume-all-agents');
      final prompt = (call.$3 as Map)['prompt'] as String;
      expect(prompt, startsWith('[SOS] The user has emergency-stopped all agents in #general'));
      expect(prompt, contains('先别动数据库，只改前端'));
    });

    test('refused: a DM, no right, no guidance, unknown channel', () async {
      for (final (cap, args, message) in [
        ('channels.sos_stop', {'channel': 'Ada'}, '私信里没有'),
        ('channels.sos_stop', {'channel': 'nowhere'}, '没有叫'),
        ('channels.sos_resume', {'channel': 'general'}, '缺少参数 guidance'),
      ]) {
        final r = await h.act(cap, args);
        expect('${r['error']}', contains(message), reason: '$args');
      }
      h.w.server = RaftRecord({'id': 's1', 'role': 'guest'});
      final r = await h.act('channels.sos_stop', {'channel': 'general'});
      expect('${r['error']}', contains('权限'));
      expect(h.w.commands, isEmpty);
    });
  });

  group('agents.workspace_files', () {
    Future<Map<String, Object?>> files(Map<String, Object?> args) async {
      final r = await h.tools.run('query', {
        'capability': 'agents.workspace_files',
        'args': args,
      });
      return r!;
    }

    test('lists a directory', () async {
      h.w.routes['/agents/a-cody/workspace-files'] = (_) => {
        'files': [
          {'name': 'MEMORY.md', 'path': 'MEMORY.md', 'type': 'file', 'size': 1200},
          {'name': 'notes', 'path': 'notes', 'type': 'directory'},
        ],
      };
      final r = (await files({'agent': 'Cody'}))['result'] as Map;
      expect(r['agent'], 'Cody');
      expect(r['count'], 2);
      expect((r['files'] as List).cast<Map>().map((f) => f['kind']), [
        'file',
        'directory',
      ]);
      final q = h.w.queries['/agents/a-cody/workspace-files']!;
      expect(q['includeHidden'], 'false');
      expect(q.containsKey('dirPath'), isFalse);
      await files({'agent': 'Cody', 'dir': 'notes', 'hidden': true});
      final q2 = h.w.queries['/agents/a-cody/workspace-files']!;
      expect(q2['dirPath'], 'notes');
      expect(q2['includeHidden'], 'true');
    });

    test('reads a file, cut short for speaking', () async {
      h.w.routes['/agents/a-cody/workspace-files/read'] = (q) => {
        'content': '# 记忆\n${'喜欢简短的回复。' * 600}',
      };
      final r = (await files({'agent': 'Cody', 'file': 'MEMORY.md'}))['result'] as Map;
      expect(r['file'], 'MEMORY.md');
      expect((r['content'] as String).length, 3000);
      expect(r['truncated'], isTrue);
      expect(h.w.queries['/agents/a-cody/workspace-files/read'], {'path': 'MEMORY.md'});
    });

    test('an empty file and an unknown agent are said', () async {
      h.w.routes['/agents/a-cody/workspace-files/read'] = (_) => {'content': ''};
      final r = (await files({'agent': 'Cody', 'file': 'x.md'}))['result'] as Map;
      expect(r['message'], '这个文件是空的');
      expect('${(await files({'agent': 'Nobody'}))['error']}', contains('没有叫'));
    });
  });

  test('agents.mcp_usage lists only what was called', () async {
    h.w.routes['/mcp/agents/a-cody'] = (_) => {
      'servers': [
        {
          'name': 'Docs',
          'usage': {
            'invocationCount': 12,
            'lastInvokedAt': hoursAgo(2),
            'lastToolName': 'search_docs',
          },
        },
        {
          'name': 'Idle',
          'usage': {'invocationCount': 0},
        },
        {'name': 'NoUsage'},
      ],
    };
    final r = await h.tools.run('query', {
      'capability': 'agents.mcp_usage',
      'args': {'agent': 'Cody'},
    });
    final result = r!['result'] as Map;
    expect(result['count'], 1);
    final row = (result['servers'] as List).single as Map;
    expect(row['name'], 'Docs');
    expect(row['calls'], 12);
    expect(row['lastTool'], 'search_docs');
    expect(row['lastUsed'], isNotNull);
    h.w.routes['/mcp/agents/a-cody'] = (_) => {'servers': <Object>[]};
    final none = await h.tools.run('query', {
      'capability': 'agents.mcp_usage',
      'args': {'agent': 'Cody'},
    });
    expect((none!['result'] as Map)['message'], contains('还没有调用过'));
  });

  group('notifications.center', () {
    test('lists the notices the bell would', () async {
      h.w.server = RaftRecord({
        'id': 's1',
        'role': 'owner',
        'plan': 'free',
        'planDowngradedAt': DateTime.now()
            .subtract(const Duration(days: 2))
            .toUtc()
            .toIso8601String(),
      });
      final r = await h.tools.run('query', {'capability': 'notifications.center'});
      final result = r!['result'] as Map;
      expect(result['count'], greaterThanOrEqualTo(1));
      final first = (result['notices'] as List).first as Map;
      expect(first['title'], isNotEmpty);
      expect(first['goes'], isNotNull);
      expect(h.w.reads, contains('/product-feedback/tickets'));
    });

    test('unread feedback is a notice; nothing says so', () async {
      h.w.routes['/servers/s1/machines'] = (_) => {
        'machines': [
          {'id': 'm1', 'name': 'Studio', 'status': 'online'},
        ],
      };
      h.w.routes['/product-feedback/tickets'] = (_) => {'unread_total': 2};
      var r = await h.tools.run('query', {'capability': 'notifications.center'});
      var result = r!['result'] as Map;
      expect(
        (result['notices'] as List).cast<Map>().map((n) => n['goes']),
        contains('反馈页'),
      );
      h.w.routes['/product-feedback/tickets'] = (_) => {'unread_total': 0};
      r = await h.tools.run('query', {'capability': 'notifications.center'});
      result = r!['result'] as Map;
      expect(result['count'], 0);
      expect(result['message'], contains('没有系统提示'));
    });
  });

  test('find answers what people say', () async {
    for (final (said, id) in [
      ('重启一下 Grok', 'agents.restart'),
      ('重置会话', 'agents.reset_session'),
      ('停掉 Cody', 'agents.stop'),
      ('启动 Cody', 'agents.start'),
      ('停掉所有 Agent', 'channels.sos_stop'),
      ('Cody 的记忆里写了什么', 'agents.workspace_files'),
      ('Cody 最近调用了哪些工具', 'agents.mcp_usage'),
      ('有系统通知吗', 'notifications.center'),
    ]) {
      final r = await h.tools.run('find', {'intent': said});
      final ids = [for (final m in r!['matches'] as List) (m as Map)['id']];
      expect(ids.take(3), contains(id), reason: said);
    }
  });
}
