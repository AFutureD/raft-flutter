import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_action_board.dart';

import 'support/agent_action_harness.dart';
import 'support/agent_capability_world.dart';

/// "打回去，因为……": one action that moves the task back and tells its thread
/// why, with one preview, one confirmation and one undo.
void main() {
  late ActionHarness h;

  setUp(() {
    h = ActionHarness();
    final w = h.w;
    final row = taskRow(
      't7',
      7,
      'in_review',
      title: '导出报表',
      claimedById: 'a-cody',
      claimedByName: 'Cody',
    );
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_review') row,
        if (q?['status'] == 'done')
          taskRow('t8', 8, 'done', title: '改名', channel: 'general'),
      ],
    };
    w.routes['/tasks/channel/ch-general/number/7'] = (_) => {
      'task': {...row, 'revision': 3, 'messageId': 'm-task-7'},
    };
    w.routes['/tasks/channel/ch-general/number/8'] = (_) => {
      'task': {
        ...taskRow('t8', 8, 'done', title: '改名'),
        'revision': 1,
        'messageId': 'm-task-8',
      },
    };
  });
  tearDown(() => h.dispose());

  Map<String, Object?> args([Map<String, Object?> more = const {}]) => {
    'task': '7',
    'reason': '登录页还会跳回首页，复现步骤在上面',
    ...more,
  };

  test('one preview says both things that will happen', () async {
    final r = await h.act('tasks.reject_with_reason', args());
    expect(r['status'], 'needs_confirmation', reason: '$r');
    expect(h.summary(r), contains('#7'));
    expect(h.summary(r), contains('打回'));
    expect(h.summary(r), contains('进行中'));
    expect(h.summary(r), contains('留言'));
    final lines = h.changes(r);
    expect(lines, hasLength(greaterThanOrEqualTo(2)));
    for (final line in lines) {
      expect(ActionHarness.lineOk(line), isTrue, reason: line);
    }
    expect(lines.first, '状态: 等验收 → 进行中');
    expect(
      lines.any((l) => l.startsWith('讨论串留言: ') && l.contains('登录页还会跳回首页')),
      isTrue,
    );
    expect(lines.any((l) => l == '通知: ' ' → @cody' || l.contains('@cody')), isTrue);
    expect((r['preview'] as Map)['reversible'], isTrue);
    // One card, and nothing has happened.
    expect(h.ledger.active, hasLength(1));
    expect(h.w.commands, isEmpty);
    expect(h.w.sent, isEmpty);
  });

  test('on confirmation: status first, then the reason in the thread', () async {
    final done = await h.run('tasks.reject_with_reason', args());
    expect(done['status'], 'done', reason: '$done');
    final patch = h.w.commands.single;
    expect(patch.$1, 'PATCH');
    expect(patch.$2, '/tasks/t7/status');
    expect(patch.$3, {'status': 'in_progress'});
    final sent = h.w.sent.single;
    expect(sent.thread, isTrue);
    expect(sent.parent, 'm-task-7');
    expect(sent.channel, 'ch-general');
    expect(sent.text, contains('@cody'));
    expect(sent.text, contains('打回'));
    expect(sent.text, contains('登录页还会跳回首页'));
    expect(sent.mentions!.single['id'], 'a-cody');
    final result = done['result'] as Map;
    expect(result['entity'], 'task');
    expect(result['id'], 't7');
    expect(result['done'], contains('#7'));
    expect(h.tools.audit.entries.single.capability, 'tasks.reject_with_reason');
    expect(h.tools.audit.entries.single.ok, isTrue);
  });

  test('back to todo when asked, and the direct tool is the same', () async {
    final r = await h.tools.run('reject_task', args({'status': 'todo'}));
    expect(r!['status'], 'needs_confirmation');
    expect(h.changes(r).first, '状态: 等验收 → 待办');
    await h.approve(r);
    expect(h.w.commands.single.$3, {'status': 'todo'});
  });

  test('a task that is not in review can be sent back too (owner)', () async {
    final r = await h.act('tasks.reject_with_reason', {
      'task': '8',
      'reason': '又坏了',
    });
    expect(r['status'], 'needs_confirmation', reason: '$r');
    expect(h.changes(r).first, '状态: 已完成 → 进行中');
  });

  group('refused at the preview, nothing sent', () {
    Future<void> refused(
      Map<String, Object?> a,
      String message, {
      String cap = 'tasks.reject_with_reason',
    }) async {
      final r = await h.act(cap, a);
      expect('${r['error']}', contains(message), reason: '$a $r');
      expect(r.containsKey('confirmToken'), isFalse);
      expect(h.w.commands, isEmpty);
      expect(h.w.sent, isEmpty);
      expect(h.ledger.active, isEmpty);
    }

    test('missing or wrong arguments', () async {
      await refused({'task': '7'}, '缺少参数 reason');
      await refused({'reason': 'x'}, '缺少参数 task');
      await refused(args({'status': 'done'}), 'in_progress / todo');
      await refused(args({'colour': 'red'}), '未知参数 colour');
    });

    test('an unknown task', () async {
      await refused(args({'task': '404'}), '没有找到任务');
    });

    test('a task already where it would be sent', () async {
      h.w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'in_progress')
            taskRow('t3', 9, 'in_progress', title: '丙'),
        ],
      };
      h.w.routes['/tasks/channel/ch-general/number/9'] = (_) => {
        'task': {
          ...taskRow('t3', 9, 'in_progress', title: '丙'),
          'messageId': 'm9',
        },
      };
      await refused(args({'task': '9'}), '已经是 进行中');
    });

    test('a task without a thread has nowhere to say why', () async {
      h.w.routes['/tasks/channel/ch-general/number/7'] = (_) => {
        'task': {
          ...taskRow('t7', 7, 'in_review', title: '导出报表'),
          'revision': 3,
        },
      };
      await refused(args(), '没有对应的讨论串');
    });

    test('a member may not make a move the board would not allow', () async {
      h.w.server = RaftRecord({'id': 's1', 'role': 'member'});
      await refused(args({'status': 'todo'}), '不能直接改成');
    });

    test('a channel the person is not in', () async {
      h.w.channels = [
        for (final c in h.w.channels)
          c.id == 'ch-general' ? RaftChannel({...c.json, 'joined': false}) : c,
      ];
      await refused(args(), '没有加入');
    });
  });

  group('when the reason cannot be sent', () {
    test('the status is put back and the card says so', () async {
      h.w.sendAccepted = false;
      final done = await h.run('tasks.reject_with_reason', args());
      expect(done['status'], 'failed', reason: '$done');
      expect('${done['error']}', contains('任务状态已恢复为 等验收'));
      expect(h.w.commands.map((c) => c.$3), [
        {'status': 'in_progress'},
        {'status': 'in_review'},
      ]);
      expect(h.tools.audit.entries.single.ok, isFalse);
      expect(h.board.records.single.phase, AgentActionPhase.failed);
    });

    test('and says so when even that fails', () async {
      h.w.sendAccepted = false;
      // The second PATCH fails.
      var patches = 0;
      h.w.commandRoutes['PATCH /tasks/t7/status'] = (_) {
        patches++;
        if (patches > 1) throw const RaftApiException('offline');
        return <String, dynamic>{};
      };
      final done = await h.run('tasks.reject_with_reason', args());
      expect(done['status'], 'failed');
      expect('${done['error']}', contains('没能恢复'));
    });

    test('a status the server refuses sends no message', () async {
      h.w.commandError = const RaftApiException('Task is read only');
      final done = await h.run('tasks.reject_with_reason', args());
      expect(done['status'], 'failed');
      expect(h.w.sent, isEmpty);
    });
  });

  group('undo', () {
    test('puts the status back and says in the thread that it was undone', () async {
      final done = await h.run('tasks.reject_with_reason', args());
      expect((done['undo'] as Map)['label'], '改回 等验收 并在串里说明');
      final undone = await h.undoSaid();
      expect(undone['status'], 'undone', reason: '$undone');
      expect(h.w.commands.map((c) => c.$3), [
        {'status': 'in_progress'},
        {'status': 'in_review'},
      ]);
      expect(h.w.sent, hasLength(2));
      expect(h.w.sent.last.text, contains('撤销了刚才的打回'));
      expect(h.w.sent.last.text, contains('等验收'));
      expect('${undone['message']}', contains('讨论串里说明了'));
      final log = h.tools.audit.entries;
      expect(log.last.undo, isTrue);
    });

    test('the card button needs no words; the model alone cannot', () async {
      await h.run('tasks.reject_with_reason', args());
      final byModel = await h.tools.run('undo', {});
      expect(byModel!['error'], 'needs_user_consent');
      expect(h.w.commands, hasLength(1));
    });
  });
}
