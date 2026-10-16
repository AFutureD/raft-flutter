import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_action_board.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_tools.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_consent.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_direct_tools.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The ordinary operations: for each one the preview (what the card says),
/// that nothing runs without the person, the controller call it makes, the
/// result card, and the way back where there is one.
void main() {
  late CapabilityWorld w;
  late ActivityClient client;
  late AgentConsentLedger ledger;
  late AgentActionBoard board;
  late AgentCapabilityTools tools;
  var clock = worldNow;

  setUp(() {
    clock = worldNow;
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    ledger = AgentConsentLedger(now: () => clock, random: Random(2));
    board = AgentActionBoard(now: () => clock);
    tools = AgentCapabilityTools(
      workspace: w,
      env: AgentCapabilityEnv(data: AgentModeData(w, now: () => worldNow)),
      userConsent: ledger,
      board: board,
      now: () => clock,
      random: Random(1),
    );
    w.ledger.switchServer('s1');
    w.channels = [
      ...w.channels,
      RaftChannel({'id': 'ch-random', 'name': 'random'}),
      RaftChannel({'id': 'ch-secret', 'name': 'secret', 'type': 'private'}),
    ];
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          taskRow(
            't3',
            9,
            'in_progress',
            title: '丙',
            claimedById: 'a-cody',
            claimedByName: 'Cody',
          ),
        if (q?['status'] == 'todo')
          taskRow('t5', 5, 'todo', title: '戊', channel: 'design'),
      ],
    };
    w.routes['/tasks/channel/ch-general/number/9'] = (_) => {
      'task': {
        ...taskRow(
          't3',
          9,
          'in_progress',
          title: '丙',
          claimedById: 'a-cody',
          claimedByName: 'Cody',
        ),
        'revision': 4,
      },
    };
    w.routes['/tasks/channel/ch-design/number/5'] = (_) => {
      'task': {
        ...taskRow('t5', 5, 'todo', title: '戊', channel: 'design'),
        'revision': 1,
      },
    };
    w.routes['/channels/ch-general/members'] = (_) => {
      'humans': [
        {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
        {'userId': 'kevin', 'name': 'kevin', 'displayName': 'Kevin'},
      ],
      'agents': [
        {'id': 'a-cody', 'name': 'cody', 'displayName': 'Cody'},
      ],
    };
    w.routes['/channels/ch-design/members'] =
        w.routes['/channels/ch-general/members']!;
    w.routes['/messages/context/m-1'] = (_) => {
      'messages': [
        {
          'id': 'm-1',
          'channelId': 'ch-general',
          'content': '周五上线可以吗？',
          'senderName': 'Cody',
          'senderType': 'agent',
          'createdAt': hoursAgo(1),
          'seq': '10',
        },
      ],
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  /// The one-step tool: a preview, the card the app draws, and the answer.
  Future<Map<String, Object?>> ask(
    String tool,
    Map<String, Object?> args,
  ) async {
    final r = await tools.run(tool, args);
    return r!;
  }

  /// The person presses 确认 on the card, then the model calls confirm.
  Future<Map<String, Object?>> approve(Map<String, Object?> previewed) async {
    expect(previewed['status'], 'needs_confirmation', reason: '$previewed');
    expect(ledger.cardTapped(ledger.active.last.cardId, yes: true), isTrue);
    return (await tools.run('confirm', {'token': previewed['confirmToken']}))!;
  }

  /// The person says 撤销, then the model calls the undo tool.
  Future<Map<String, Object?>> undoSaid() async {
    ledger.userSaid('撤销');
    return (await tools.run('undo', {}))!;
  }

  List<String> changes(Map<String, Object?> r) =>
      ((r['preview'] as Map)['changes'] as List).cast<String>();

  group('every operation needs the person', () {
    final calls = <String, Map<String, Object?>>{
      'send_message': {'channel': 'general', 'text': '大家好'},
      'reply_in_thread': {'message': 'm-1', 'text': '可以'},
      'react': {'message': 'm-1', 'emoji': '👍'},
      'mark_read': {'channel': 'general'},
      'mark_done': {'channel': 'general'},
      'create_task': {'channel': 'general', 'title': '新任务'},
      'set_task_status': {'task': '9', 'status': 'in_review'},
      'assign_task': {'task': '9', 'assignee': 'Ada'},
      'unassign_task': {'task': '9'},
      'join_channel': {'channel': 'random'},
    };
    setUp(() {
      w.routes['/channels/inbox'] = (_) => {
        'items': [
          {'kind': 'channel', 'channelId': 'ch-general', 'unreadCount': 3},
        ],
      };
    });
    for (final e in calls.entries) {
      test(
        '${e.key} previews, and the model\'s own confirm runs nothing',
        () async {
          final r = await ask(e.key, e.value);
          expect(r['status'], 'needs_confirmation', reason: '$r');
          expect((r['preview'] as Map)['summary'], isNotEmpty);
          // Every change line is `字段: 原值 → 新值` and the card is on screen.
          for (final line in changes(r)) {
            expect(AgentChangeLine.ok(line), isTrue, reason: line);
          }
          expect(ledger.active, hasLength(1));
          // Nothing has been sent to the server or the controller.
          expect(w.commands, isEmpty);
          expect(w.sent, isEmpty);
          expect(w.toggles, isEmpty);
          final early = await tools.run('confirm', {
            'token': r['confirmToken'],
          });
          expect(early!['error'], 'needs_user_confirmation');
          expect(w.commands, isEmpty);
          expect(w.sent, isEmpty);
          expect(w.toggles, isEmpty);
          expect(board.records, isEmpty);
        },
      );
    }

    test('declining stops it', () async {
      final r = await ask('send_message', calls['send_message']!);
      ledger.cardTapped(ledger.active.single.cardId, yes: false);
      final done = await tools.run('confirm', {'token': r['confirmToken']});
      expect(done!['status'], 'declined');
      expect(w.sent, isEmpty);
    });

    test('words after the preview count, like the tap', () async {
      final r = await ask('join_channel', calls['join_channel']!);
      ledger.userSaid('好的');
      final done = await tools.run('confirm', {'token': r['confirmToken']});
      expect(done!['status'], 'done');
      expect(w.commands.single.$2, '/channels/ch-random/join');
    });
  });

  group('messages.send', () {
    test('preview: where, what, who is mentioned', () async {
      final r = await ask('send_message', {
        'channel': '#general',
        'text': '@Cody 周五能上线吗',
      });
      expect((r['preview'] as Map)['summary'], '发到#general：“@cody 周五能上线吗”');
      expect(changes(r), [
        '发到:  → #general',
        '内容:  → @cody 周五能上线吗',
        '提到:  → @cody',
      ]);
      expect(((r['preview'] as Map)['refs'] as List).single, {
        'entity': 'channel',
        'id': 'ch-general',
      });
    });

    test('runs through the controller send, with the mention', () async {
      final r = await ask('send_message', {
        'channel': 'general',
        'text': '@Cody 周五能上线吗',
      });
      final done = await approve(r);
      expect(done['status'], 'done');
      final sent = w.sent.single;
      expect(sent.text, '@cody 周五能上线吗');
      expect(sent.channel, 'ch-general');
      expect(sent.thread, isFalse);
      expect(sent.mentions, [
        {'type': 'agent', 'id': 'a-cody', 'name': 'cody'},
      ]);
      // Sent to the channel by id: nothing was selected, not even briefly.
      expect(w.selected, isEmpty);
      expect(w.channel, isNull);
      // The card turned into the result, with the message it made.
      final card = board.records.single;
      expect(card.phase, AgentActionPhase.done);
      expect(card.text, '已发送');
      expect(card.entity, const AgentPreviewRef('message', 'm-sent-1'));
      expect(card.undoLabel, isNull);
      expect((done['result'] as Map)['id'], 'm-sent-1');
    });

    test('a DM is addressed by the other person\'s name', () async {
      final done = await approve(
        await ask('send_message', {'channel': 'Ada', 'text': '收到'}),
      );
      expect(done['status'], 'done');
      expect(w.sent.single.channel, 'dm-1');
    });

    test('the channel the person has open is never changed', () async {
      w.channel = w.channels.firstWhere((c) => c.id == 'ch-design');
      await approve(
        await ask('send_message', {'channel': 'general', 'text': '你好'}),
      );
      expect(w.selected, isEmpty);
      expect(w.sent.single.channel, 'ch-general');
      expect(w.channel?.id, 'ch-design');
    });

    test(
      'a channel not joined, archived or unknown is refused at preview',
      () async {
        expect(
          (await ask('send_message', {
            'channel': 'random',
            'text': 'x',
          }))['error'],
          contains('先加入'),
        );
        expect(
          (await ask('send_message', {
            'channel': 'nowhere',
            'text': 'x',
          }))['error'],
          contains('没有叫'),
        );
        expect(ledger.active, isEmpty);
      },
    );

    test('a failed send leaves an error card that can be retried', () async {
      w.sendAccepted = false;
      final r = await ask('send_message', {'channel': 'general', 'text': '你好'});
      final failed = await approve(r);
      expect(failed['status'], 'failed');
      expect(failed['error'], 'Failed to send message');
      var card = board.records.single;
      expect(card.phase, AgentActionPhase.failed);
      expect(card.canRetry, isTrue);

      w.sendAccepted = true;
      final again = await tools.retryAction(r['confirmToken']! as String);
      expect(again['status'], 'done');
      card = board.records.single;
      expect(card.phase, AgentActionPhase.done);
      expect(card.text, '已发送');
      // One card, one place: the same record id throughout.
      expect(board.records, hasLength(1));
      expect(w.sent, hasLength(2));
    });
  });

  group('messages.reply_thread', () {
    test('preview names the message being answered', () async {
      final r = await ask('reply_in_thread', {'message': 'm-1', 'text': '可以'});
      expect((r['preview'] as Map)['summary'], contains('Cody'));
      expect(changes(r), [
        '回复:  → Cody：周五上线可以吗？',
        '内容:  → 可以',
        '所在:  → #general',
      ]);
      expect(((r['preview'] as Map)['refs'] as List).single, {
        'entity': 'message',
        'id': 'm-1',
      });
    });

    test('sends into the thread without opening it', () async {
      w.channel = w.channels.firstWhere((c) => c.id == 'ch-design');
      final done = await approve(
        await ask('reply_in_thread', {'message': 'm-1', 'text': '可以'}),
      );
      expect(done['status'], 'done');
      // The open thread, the open channel and the selection are untouched.
      expect(w.threads, isEmpty);
      expect(w.selected, isEmpty);
      expect(w.channel?.id, 'ch-design');
      final sent = w.sent.single;
      expect(sent.thread, isTrue);
      expect(sent.parent, 'm-1');
      expect(sent.channel, 'ch-general');
      expect(board.records.single.text, '已回复');
      expect(board.records.single.entity?.entity, 'message');
    });

    test('a message that cannot be read is not guessed', () async {
      final r = await ask('reply_in_thread', {'message': 'nope', 'text': 'x'});
      expect(r['error'], contains('没有找到消息'));
      expect(ledger.active, isEmpty);
    });
  });

  group('messages.react', () {
    test('preview, a name for the emoji, and the controller toggle', () async {
      final r = await ask('react', {'message': 'm-1', 'emoji': '点赞'});
      expect((r['preview'] as Map)['summary'], contains('👍'));
      expect(changes(r).first, '表情:  → 👍');
      expect((r['preview'] as Map)['reversible'], isTrue);
      final done = await approve(r);
      expect(done['status'], 'done');
      expect(w.toggles, ['m-1:👍']);
      expect(board.records.single.text, '已加 👍');
      expect(board.records.single.undoLabel, '取消 👍');
    });

    test('undo is the toggle again', () async {
      final done = await approve(
        await ask('react', {'message': 'm-1', 'emoji': '🎉'}),
      );
      expect(done['undo'], containsPair('seconds', 30));
      final undone = await undoSaid();
      expect(undone['status'], 'undone');
      expect(w.toggles, ['m-1:🎉', 'm-1:🎉']);
      expect(board.records.single.undone, isTrue);
      expect(board.records.single.undoLabel, isNull);
    });

    test('a reaction the person already made is not toggled off', () async {
      w.reactionViewer.accept({
        'serverId': 's1',
        'messageId': 'm-1',
        'viewerVersion': 1,
        'reactedEmojis': ['👍'],
      }, serverId: 's1');
      final r = await ask('react', {'message': 'm-1', 'emoji': '👍'});
      expect(r['error'], contains('已经'));
      expect(ledger.active, isEmpty);
    });
  });

  group('activity.mark_read', () {
    test('one conversation: preview, receipt, undo is mark unread', () async {
      final r = await ask('mark_read', {'channel': 'general'});
      expect(changes(r), ['#general 未读: 3 条 → 0 条']);
      final done = await approve(r);
      expect(done['status'], 'done');
      expect(w.commands.single.$1, 'POST');
      expect(w.commands.single.$2, '/channels/ch-general/read-all');
      expect(w.readAcks, ['ch-general']);
      expect(w.unread['ch-general'], 0);
      final card = board.records.single;
      expect(card.entity, const AgentPreviewRef('channel', 'ch-general'));
      expect(card.undoLabel, '改回未读');

      final undone = await tools.undoAction(card.id);
      expect(undone['status'], 'undone');
      expect(w.commands.last.$2, '/channels/ch-general/unread');
      expect(w.unread['ch-general'], 1);
    });

    test('everything: one call, and no undo', () async {
      final r = await ask('mark_read', {'all': true});
      expect((r['preview'] as Map)['summary'], contains('全部 6 条'));
      final done = await approve(r);
      expect(w.commands.single.$2, '/channels/inbox/read-all');
      expect(done.containsKey('undo'), isFalse);
      expect(board.records.single.undoLabel, isNull);
      expect((await undoSaid())['error'], contains('没有能撤销'));
    });

    test('nothing unread is said, not previewed', () async {
      w.unread = {};
      final r = await ask('mark_read', {'channel': 'general'});
      expect(r['error'], contains('没有未读'));
    });
  });

  group('activity.mark_done', () {
    setUp(() {
      w.routes['/channels/inbox'] = (_) => {
        'items': [
          {
            'kind': 'channel',
            'channelId': 'ch-general',
            'unreadCount': 2,
            'doneFrontierSeq': '41',
          },
        ],
      };
    });

    test(
      'done with the frontier the page sends, undone puts it back',
      () async {
        final r = await ask('mark_done', {'channel': 'general'});
        expect(changes(r), ['#general 动态: 待处理 → 已处理', '未读: 2 条 → 0 条']);
        final done = await approve(r);
        expect(done['status'], 'done');
        expect(w.commands.first.$2, '/channels/inbox/done');
        expect(w.commands.first.$3, {
          'channelId': 'ch-general',
          'throughActivitySeq': '41',
          'frontierSpace': 'storage',
        });
        expect(board.records.single.undoLabel, '放回动态');
        await tools.undoAction(board.records.single.id);
        expect(w.commands.last.$2, '/channels/inbox/undone');
        expect(w.commands.last.$3, {'channelId': 'ch-general'});
      },
    );

    test('a conversation not in the Activity list is refused', () async {
      final r = await ask('mark_done', {'channel': 'design'});
      expect(r['error'], contains('不在动态里'));
    });
  });

  group('channels.join', () {
    test(
      'a public channel: join, refresh the list, show the channel',
      () async {
        final r = await ask('join_channel', {'channel': 'random'});
        expect(changes(r), ['#random: 未加入 → 已加入']);
        final done = await approve(r);
        expect(done['status'], 'done');
        expect(w.commands.single.$2, '/channels/ch-random/join');
        expect(w.channelRefreshes, 1);
        expect(board.records.single.text, '已加入 #random');
        expect(board.records.single.entity?.id, 'ch-random');
      },
    );

    test('private, joined and DM channels are not joinable', () async {
      expect(
        (await ask('join_channel', {'channel': 'secret'}))['error'],
        contains('不是公开频道'),
      );
      expect(
        (await ask('join_channel', {'channel': 'general'}))['error'],
        contains('已经在'),
      );
    });
  });

  group('tasks.create', () {
    setUp(() {
      w.commandRoutes['POST /tasks/channel/ch-general'] = (_) => {
        'tasks': [
          {'id': 't-new', 'taskNumber': 12, 'title': '整理发布说明', 'revision': 1},
        ],
      };
    });

    test('preview then the same POST the dialog sends', () async {
      final r = await ask('create_task', {
        'channel': 'general',
        'title': '整理发布说明',
      });
      expect(changes(r), ['频道:  → #general', '标题:  → 整理发布说明', '状态:  → 待办']);
      final done = await approve(r);
      expect(done['status'], 'done');
      final post = w.commands.single;
      expect(post.$1, 'POST');
      expect(post.$2, '/tasks/channel/ch-general');
      expect(post.$3, {
        'tasks': [
          {'title': '整理发布说明'},
        ],
      });
      final card = board.records.single;
      expect(card.text, '已新建 #12 整理发布说明');
      expect(card.entity, const AgentPreviewRef('task', 't-new'));
    });

    test('with an assignee, a second call sets the assignee', () async {
      final r = await ask('create_task', {
        'channel': 'general',
        'title': '整理发布说明',
        'assignee': 'Cody',
      });
      expect(changes(r).last, '负责人:  → Cody');
      await approve(r);
      expect(w.commands.map((c) => '${c.$1} ${c.$2}'), [
        'POST /tasks/channel/ch-general',
        'PATCH /tasks/t-new/assignee',
      ]);
      expect(w.commands.last.$3, {
        'assignee': {'type': 'agent', 'id': 'a-cody'},
        'expectedRevision': 1,
      });
    });

    test('an unknown assignee stops at preview', () async {
      final r = await ask('create_task', {
        'channel': 'general',
        'title': 'x',
        'assignee': 'Zed',
      });
      expect(r['error'], contains('没有叫“Zed”'));
      expect(ledger.active, isEmpty);
    });

    test('a task cannot be made in a DM', () async {
      final r = await ask('create_task', {'channel': 'Ada', 'title': 'x'});
      expect(r['error'], contains('私信'));
    });
  });

  group('tasks.set_status', () {
    test('preview, PATCH, result card with the task', () async {
      final r = await ask('set_task_status', {
        'task': '#9',
        'status': 'in_review',
      });
      expect((r['preview'] as Map)['summary'], '把 #9 丙 改为 等验收');
      expect(changes(r), ['状态: 进行中 → 等验收']);
      expect(((r['preview'] as Map)['refs'] as List).single, {
        'entity': 'task',
        'id': 't3',
      });
      final done = await approve(r);
      expect(done['status'], 'done');
      expect(w.commands.single.$1, 'PATCH');
      expect(w.commands.single.$2, '/tasks/t3/status');
      expect(w.commands.single.$3, {'status': 'in_review'});
      final card = board.records.single;
      expect(card.text, '已改为 等验收');
      expect(card.entity, const AgentPreviewRef('task', 't3'));
      expect(card.undoLabel, '改回 进行中');
    });

    test('undo sets the previous status, without asking again', () async {
      await approve(
        await ask('set_task_status', {'task': 't3', 'status': 'done'}),
      );
      final consented = ledger.active.length;
      final undone = await undoSaid();
      expect(undone['status'], 'undone');
      expect(w.commands.last.$3, {'status': 'in_progress'});
      expect(ledger.active.length, consented);
      expect(board.records.single.text, '已改回 进行中');
    });

    test('a move the person may not make is refused at preview', () async {
      w.server = RaftRecord({'id': 's1', 'role': 'member'});
      final r = await ask('set_task_status', {'task': '9', 'status': 'todo'});
      expect(r['error'], contains('不能直接改成'));
      expect(ledger.active, isEmpty);
    });

    test('the same status is said, and an unknown task is named', () async {
      expect(
        (await ask('set_task_status', {
          'task': '9',
          'status': 'in_progress',
        }))['error'],
        contains('已经是'),
      );
      expect(
        (await ask('set_task_status', {
          'task': '77',
          'status': 'done',
        }))['error'],
        contains('没有找到任务'),
      );
    });

    test('a failure from the server is a card with retry', () async {
      final r = await ask('set_task_status', {'task': '9', 'status': 'done'});
      w.commandError = const RaftApiException('Task is read only');
      final failed = await approve(r);
      expect(failed['status'], 'failed');
      expect(board.records.single.phase, AgentActionPhase.failed);
      expect(board.records.single.text, startsWith('没有成功'));
    });
  });

  group('tasks.assign / tasks.unassign', () {
    test(
      'assign: previews the change of owner, patches with the revision',
      () async {
        final r = await ask('assign_task', {'task': '9', 'assignee': 'Ada'});
        expect(changes(r), ['负责人: Cody → Ada']);
        final done = await approve(r);
        expect(done['status'], 'done');
        expect(w.commands.single.$2, '/tasks/t3/assignee');
        expect(w.commands.single.$3, {
          'assignee': {'type': 'user', 'id': 'ada'},
          'expectedRevision': 4,
        });
        expect(board.records.single.text, '已指派给 Ada');
        expect(board.records.single.undoLabel, '改回 Cody');
      },
    );

    test('assign undo goes back to the previous owner', () async {
      await approve(await ask('assign_task', {'task': '9', 'assignee': 'Ada'}));
      await tools.undoAction(board.records.single.id);
      expect(w.commands.last.$3, {
        'assignee': {'type': 'agent', 'id': 'a-cody'},
      });
      expect(board.records.single.text, '已改回 Cody');
    });

    test('assign: the one already on it, a stranger, a clash', () async {
      expect(
        (await ask('assign_task', {'task': '9', 'assignee': 'Cody'}))['error'],
        contains('已经是'),
      );
      expect(
        (await ask('assign_task', {'task': '9', 'assignee': 'Zed'}))['error'],
        contains('没有叫“Zed”'),
      );
      w.routes['/channels/ch-general/members'] = (_) => {
        'humans': [
          {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
          {'userId': 'ada2', 'name': 'ada.lee', 'displayName': 'Ada Lee'},
        ],
        'agents': <Object>[],
      };
      final clash = await ask('assign_task', {'task': '9', 'assignee': 'ad'});
      expect(clash['error'], contains('多个人'));
      expect(clash['candidates'], hasLength(2));
    });

    test('unassign: clears, and undo gives it back', () async {
      final r = await ask('unassign_task', {'task': '9'});
      expect(changes(r), ['负责人: Cody → （无）']);
      await approve(r);
      expect(w.commands.single.$3, {'assignee': null, 'expectedRevision': 4});
      expect(board.records.single.undoLabel, '改回 Cody');
      await tools.undoAction(board.records.single.id);
      expect(w.commands.last.$3, {
        'assignee': {'type': 'agent', 'id': 'a-cody'},
      });
    });

    test('unassign a task nobody holds', () async {
      w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'todo')
            taskRow('t5', 5, 'todo', title: '戊', channel: 'design'),
        ],
      };
      final r = await ask('unassign_task', {'task': '5'});
      expect(r['error'], contains('没有负责人'));
    });

    test('the permission to assign is checked first', () async {
      w.server = RaftRecord({'id': 's1', 'role': 'guest'});
      final r = await ask('assign_task', {'task': '9', 'assignee': 'Ada'});
      expect(r['error'], contains('权限'));
    });
  });

  group('undo', () {
    test('the model cannot undo on its own: the person must say so', () async {
      await approve(await ask('react', {'message': 'm-1', 'emoji': '🎉'}));
      final refused = await tools.run('undo', {});
      expect(refused!['error'], 'needs_user_consent');
      expect(w.toggles, ['m-1:🎉'], reason: 'nothing was taken back');
      expect(board.records.single.undone, isFalse);
      // Words that are not an undo, or only a question about one, do not count.
      ledger.userSaid('好的');
      ledger.userSaid('可以撤销吗');
      expect((await tools.run('undo', {}))!['error'], 'needs_user_consent');
      // Their own words do, once.
      ledger.userSaid('刚才那个撤销一下');
      expect((await tools.run('undo', {}))!['status'], 'undone');
      expect(w.toggles, ['m-1:🎉', 'm-1:🎉']);
    });

    test('words said long ago do not count, and are spent by use', () async {
      await approve(await ask('react', {'message': 'm-1', 'emoji': '🎉'}));
      ledger.userSaid('撤销');
      // Still inside the 30 s the operation can be taken back, but the
      // person's words are no longer what the model is acting on.
      clock = clock.add(const Duration(seconds: 20));
      expect((await tools.run('undo', {}))!['error'], 'needs_user_consent');
    });

    test('the press on the card is the person: no words needed', () async {
      await approve(await ask('react', {'message': 'm-1', 'emoji': '🎉'}));
      final undone = await tools.undoAction(board.records.single.id);
      expect(undone['status'], 'undone');
      expect(w.toggles, ['m-1:🎉', 'm-1:🎉']);
    });

    test('only within 30 s, and only once', () async {
      final r = await approve(
        await ask('set_task_status', {'task': '9', 'status': 'done'}),
      );
      expect(r['status'], 'done');
      final id = board.records.single.id;
      expect(board.records.single.undoOpen(clock), isTrue);
      clock = clock.add(const Duration(seconds: 31));
      expect(board.records.single.undoOpen(clock), isFalse);
      final late = await tools.undoAction(id);
      expect(late['error'], contains('30 秒'));
      expect(w.commands, hasLength(1));
      board.prune();
      expect(board.records.single.undoLabel, isNull);

      final second = await approve(
        await ask('set_task_status', {'task': '9', 'status': 'in_review'}),
      );
      expect(second['status'], 'done');
      expect((await undoSaid())['status'], 'undone');
      expect((await undoSaid())['error'], contains('没有能撤销'));
    });

    test('a failed undo keeps the card and says so', () async {
      await approve(await ask('react', {'message': 'm-1', 'emoji': '👍'}));
      w.toggleError = const RaftApiException('offline');
      final r = await undoSaid();
      expect(r['error'], contains('撤销没成功'));
      expect(board.records.single.phase, AgentActionPhase.done);
      expect(board.records.single.text, contains('撤销没成功'));
      expect(board.records.single.undoLabel, isNotNull);
    });
  });

  group('the audit log', () {
    test('every run is recorded, with failures and undos', () async {
      await approve(
        await ask('send_message', {'channel': 'general', 'text': '你好'}),
      );
      clock = clock.add(const Duration(minutes: 2));
      await approve(
        await ask('set_task_status', {'task': '9', 'status': 'done'}),
      );
      await undoSaid();
      w.commandError = const RaftApiException('nope');
      await approve(await ask('join_channel', {'channel': 'random'}));
      w.commandError = null;

      final entries = tools.audit.entries;
      expect(entries.map((e) => (e.capability, e.ok, e.undo)), [
        ('messages.send', true, false),
        ('tasks.set_status', true, false),
        ('tasks.set_status', true, true),
        ('channels.join', false, false),
      ]);
      expect(entries.first.result, '已发送');
      expect(entries[1].summary, '把 #9 丙 改为 已完成');
      expect(entries[3].result, startsWith('失败：'));
      expect(entries.first.entityId, 'm-sent-1');
    });

    test(
      'agent.audit_log reads it, oldest first, ready for a Timeline',
      () async {
        await approve(
          await ask('send_message', {'channel': 'general', 'text': '你好'}),
        );
        await approve(
          await ask('set_task_status', {'task': '9', 'status': 'done'}),
        );
        final r = await tools.run('query', {'capability': 'agent.audit_log'});
        final result = r!['result'] as Map;
        expect(result['total'], 2);
        final entries = (result['entries'] as List).cast<Map>();
        expect(entries.map((e) => e['capability']), [
          'messages.send',
          'tasks.set_status',
        ]);
        expect(entries.first['result'], '已发送');
        final timeline = (result['timeline'] as List).cast<Map>();
        expect(timeline, hasLength(2));
        expect(timeline.last['title'], contains('改为 已完成'));
        expect(timeline.last['entity'], 'task');
        expect(timeline.last['id'], 't3');
        expect(timeline.first['time'], matches(RegExp(r'^\d\d:\d\d$')));
        expect(result['render'], contains('Timeline'));
      },
    );

    test('an empty log says so', () async {
      final r = await tools.run('query', {'capability': 'agent.audit_log'});
      expect((r!['result'] as Map)['total'], 0);
      expect((r['result'] as Map)['entries'], isEmpty);
    });

    test('find answers 刚才你帮我做了什么 with the audit log', () async {
      final r = await tools.run('find', {'intent': '你刚才帮我做了什么'});
      expect(((r!['matches'] as List).first as Map)['id'], 'agent.audit_log');
    });
  });

  group('the one-step tools', () {
    test('declared by name, one capability each, short and distinct', () {
      final decls = directActionDeclarations(tools.registry);
      expect(
        [for (final d in decls) d['name']],
        [
          'send_message',
          'reply_in_thread',
          'react',
          'mark_read',
          'mark_done',
          'create_task',
          'set_task_status',
          'assign_task',
          'unassign_task',
          'join_channel',
          'reject_task',
          'snooze_item',
        ],
      );
      expect({for (final d in decls) d['description']}.length, decls.length);
      for (final d in decls) {
        expect((d['description'] as String).length, lessThan(160));
        final params = d['parameters'] as Map;
        expect(params['type'], 'object');
        for (final spec in (params['properties'] as Map).values) {
          expect(
            (spec as Map).keys,
            everyElement(isIn(['type', 'description', 'enum'])),
          );
        }
      }
      // The registry holds the capability behind every name.
      for (final id in agentDirectActionTools.values) {
        expect(tools.registry[id], isNotNull);
      }
      expect(agentDirectActionTools.containsKey('claim_task'), isFalse);
    });

    test(
      'a bad argument is refused with the schema, nothing previewed',
      () async {
        final r = await ask('set_task_status', {
          'task': '9',
          'status': 'finished',
        });
        expect(r['error'], contains('in_progress'));
        expect(ledger.active, isEmpty);
        final missing = await ask('send_message', {'channel': 'general'});
        expect(missing['error'], contains('缺少参数 text'));
      },
    );

    test(
      'act on the capability id is the same thing, for the long tail',
      () async {
        final viaAct = await tools.run('act', {
          'capability': 'tasks.set_status',
          'args': '{"task":"9","status":"done"}',
        });
        expect(viaAct!['status'], 'needs_confirmation');
        expect(
          AgentCapabilityTools.allNames,
          containsAll(agentDirectActionTools.keys),
        );
      },
    );
  });
}

/// Whether a confirm-card line has the shape `字段: 原值 → 新值`.
abstract final class AgentChangeLine {
  static bool ok(String line) => RegExp(r'^[^:：]+[:：].* → .*$').hasMatch(line);
}
