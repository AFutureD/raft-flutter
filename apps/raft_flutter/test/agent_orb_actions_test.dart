import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentPriority;
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_snooze.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_action_declarations.dart'
    show orbActionCapabilities;
import 'package:raft_flutter/features/agent_orb/actions/orb_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// The orb's actions: the model asks, the layer shows a confirm card, and
/// nothing is written until the person taps 确认 or says it (the model then
/// relays it through `confirm`). One action waits at a time. While
/// driving the risky ones are refused. All of it on the Agent mode
/// capabilities, so what happens here is what happens there.
void main() {
  late CapabilityWorld w;
  late ActivityClient client;
  late OrbActions actions;
  late AgentSnoozeStore snooze;
  var driving = false;
  var clock = worldNow;
  final told = <String>[];
  var cardIds = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    DevicePreferences.adopt(await SharedPreferences.getInstance());
    AgentModeData.clearSession();
    clock = worldNow;
    driving = false;
    told.clear();
    cardIds = [];
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.ledger.switchServer('s1');
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          {
            ...taskRow(
              't3',
              9,
              'in_progress',
              title: '丙',
              claimedById: 'a-cody',
              claimedByName: 'Cody',
              updated: 100,
            ),
            'messageId': 'm-task-9',
          },
        if (q?['status'] == 'in_review')
          {
            ...taskRow(
              't4',
              12,
              'in_review',
              title: '丁',
              claimedById: 'a-cody',
              claimedByName: 'Cody',
            ),
            'messageId': 'm-task-12',
          },
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
          updated: 100,
        ),
        'messageId': 'm-task-9',
        'revision': 4,
      },
    };
    w.routes['/tasks/channel/ch-general/number/12'] = (_) => {
      'task': {
        ...taskRow(
          't4',
          12,
          'in_review',
          title: '丁',
          claimedById: 'a-cody',
          claimedByName: 'Cody',
        ),
        'messageId': 'm-task-12',
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
    for (final id in ['m-1', 'm-2']) {
      w.routes['/messages/context/$id'] = (_) => {
        'messages': [
          {
            'id': id,
            'channelId': 'ch-general',
            'content': '周五上线可以吗？',
            'senderName': 'Cody',
            'senderType': 'agent',
            'createdAt': hoursAgo(1),
            'seq': '10',
          },
        ],
      };
    }
    snooze = AgentSnoozeStore(w, now: () => clock, timers: false);
    AgentModeData.remember(
      w,
      AgentAttention(
        items: [
          AgentAttentionItem(
            id: 'mention:ch-design',
            priority: AgentPriority.mention,
            headline: 'Ada 在 design 里点名了你',
            ask: '回答',
            reason: '点名找你',
            at: worldNow,
            channelId: 'ch-design',
            channelName: 'design',
          ),
        ],
      ),
    );
    actions = OrbActions(
      workspace: w,
      driving: () => driving,
      env: AgentCapabilityEnv(
        data: AgentModeData(w, now: () => worldNow),
        snooze: snooze,
      ),
      now: () => clock,
      random: Random(3),
      card: () => cardIds,
    )..onTell = told.add;
  });
  tearDown(() async {
    actions.dispose();
    DevicePreferences.reset();
    AgentModeData.clearSession();
    w.dispose();
    await client.dispose();
  });

  Map<String, Object?> preview(Map<String, Object?> r) =>
      Map<String, Object?>.from(r['preview'] as Map);

  /// Everything that would have gone to the server or the device.
  int writes() =>
      w.sent.length +
      w.commands.length +
      w.toggles.length +
      snooze.active.length;

  final asks = <(String, String, Map<String, Object?>, String)>[
    ('回复频道', 'send_message', {'channel': 'general', 'text': '可以合'}, '发到'),
    ('回复讨论', 'reply_in_thread', {'message': 'm-1', 'text': '可以'}, 'Cody'),
    ('点赞', 'react', {'message': 'm-1', 'emoji': '👍'}, '👍'),
    ('改状态', 'set_task_status', {'task': '9', 'status': 'in_review'}, '等验收'),
    ('交给别人', 'assign_task', {'task': '9', 'assignee': 'Ada'}, 'Ada'),
    ('催负责人', 'nudge_task', {'task': '9', 'text': '这个放了 4 天了，现在到哪了？'}, 'Cody'),
    (
      '稍后提醒',
      'snooze_item',
      {'item': 'mention:ch-design', 'when': 'tomorrow'},
      '放一放',
    ),
  ];

  group('every action shows a confirm card and writes nothing', () {
    for (final (name, tool, args, summary) in asks) {
      test(name, () async {
        final r = await actions.request(tool, args);
        expect(r['status'], 'needs_confirmation', reason: '$r');
        expect(r.containsKey('confirmToken'), isFalse, reason: 'one at a time');
        expect(preview(r)['summary'], contains(summary));
        final pending = actions.pending!;
        expect(pending.summary, contains(summary));
        expect(pending.rows, isNotEmpty);
        expect(writes(), 0);
        expect(r['next'], contains('confirm'));
      });
    }

    test('the card says who, where and the exact words', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '@Cody 可以合',
      });
      final rows = {for (final r in actions.pending!.rows) r.label: r.value};
      expect(rows['发到'], '#general');
      // The mention is written the way the person's handle is.
      expect(rows['内容'], '@cody 可以合');
      expect(rows['提到'], '@cody');
    });

    test(
      'a request that cannot be previewed says why and shows no card',
      () async {
        final r = await actions.request('set_task_status', {
          'task': '9',
          'status': 'in_progress',
        });
        expect(r['error'], contains('已经是'));
        expect(actions.pending, isNull);
        expect(writes(), 0);
      },
    );

    test('an unknown tool is an error', () async {
      final r = await actions.request('delete_everything', const {});
      expect(r['error'], isNotNull);
      expect(actions.pending, isNull);
    });
  });

  group('confirm by tap', () {
    test('writes once, and the model is told', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      await actions.confirmTapped();
      expect(w.sent, hasLength(1));
      expect(w.sent.single.text, '可以合');
      expect(actions.pending, isNull);
      expect(actions.outcome!.kind, OrbOutcomeKind.done);
      expect(actions.outcome!.text, '已发送');
      expect(told.single, contains('已发送'));
      expect(told.single, contains('用户点了确认'));
    });

    test(
      'a second tap, and the model relaying it later, write nothing more',
      () async {
        await actions.request('send_message', {
          'channel': 'general',
          'text': '可以合',
        });
        await actions.confirmTapped();
        await actions.confirmTapped();
        final later = await actions.confirm();
        expect(w.sent, hasLength(1));
        expect(later['status'], 'done');
        expect(later['already'], isTrue);
      },
    );

    test('a task change is a PATCH after the tap and not before', () async {
      await actions.request('set_task_status', {
        'task': '9',
        'status': 'in_review',
      });
      expect(w.commands, isEmpty);
      await actions.confirmTapped();
      expect(w.commands.single.$1, 'PATCH');
      expect(w.commands.single.$2, '/tasks/t3/status');
      expect(w.commands.single.$3, {'status': 'in_review'});
    });

    test('a failed write says so, to the layer and to the model', () async {
      w.sendAccepted = false;
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      await actions.confirmTapped();
      expect(actions.outcome!.kind, OrbOutcomeKind.failed);
      expect(actions.outcome!.text, isNotEmpty);
      expect(told.single, contains('没有成功'));
      expect(actions.pending, isNull);
    });
  });

  group('confirm by the model', () {
    test('without a word or a tap from the person it writes nothing', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      final r = await actions.confirm();
      expect(r['error'], 'needs_user_confirmation');
      expect(w.sent, isEmpty);
      expect(actions.pending, isNotNull, reason: 'the person may still agree');
    });

    test('after the person said yes it writes once', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      actions.userSaid('发吧');
      final r = await actions.confirm();
      expect(r['status'], 'done');
      expect(r['done'], '已发送');
      expect(w.sent, hasLength(1));
      final again = await actions.confirm();
      expect(w.sent, hasLength(1));
      expect(again['already'], isTrue);
      expect(actions.pending, isNull);
    });

    for (final yes in ['确认', '好', '发吧', '可以', '好的']) {
      test('"$yes" counts as yes', () async {
        await actions.request('send_message', {
          'channel': 'general',
          'text': '可以合',
        });
        actions.userSaid(yes);
        expect((await actions.confirm())['status'], 'done');
      });
    }

    test('words said before the card was up do not count', () async {
      actions.userSaid('好');
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      expect((await actions.confirm())['error'], 'needs_user_confirmation');
      expect(w.sent, isEmpty);
    });

    test('a no cancels it', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      actions.userSaid('算了，不发了');
      expect(actions.pending, isNull);
      expect(actions.outcome!.kind, OrbOutcomeKind.cancelled);
      final r = await actions.confirm();
      expect(r['status'], isNot('done'));
      expect(w.sent, isEmpty);
    });

    test('a question is not a yes', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      actions.userSaid('发给谁？');
      expect((await actions.confirm())['error'], 'needs_user_confirmation');
    });

    test('with nothing waiting it says so', () async {
      final r = await actions.confirm();
      expect(r['error'], contains('没有'));
      expect(w.sent, isEmpty);
    });
  });

  group('cancel', () {
    test('a tap on 取消 writes nothing and tells the model', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      await actions.cancelTapped();
      expect(actions.pending, isNull);
      expect(actions.outcome!.kind, OrbOutcomeKind.cancelled);
      expect(told.single, contains('取消'));
      // Whatever the model does after, nothing goes out.
      actions.userSaid('好');
      await actions.confirm();
      await actions.confirmTapped();
      expect(w.sent, isEmpty);
    });

    test('the model can cancel when the person changes their mind', () async {
      await actions.request('react', {'message': 'm-1', 'emoji': '👍'});
      final r = await actions.cancel();
      expect(r['status'], 'cancelled');
      expect(actions.pending, isNull);
      actions.userSaid('好');
      await actions.confirm();
      expect(w.toggles, isEmpty);
    });
  });

  group('one action at a time', () {
    test('a new request replaces the one waiting', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '第一句',
      });
      final first = actions.pending!;
      await actions.request('send_message', {
        'channel': 'general',
        'text': '第二句',
      });
      final second = actions.pending!;
      expect(second.cardId, isNot(first.cardId));
      expect(second.rows.map((r) => r.value), contains('第二句'));
      expect(second.rows.map((r) => r.value), isNot(contains('第一句')));
      await actions.confirmTapped();
      expect(w.sent.map((s) => s.text), ['第二句']);
    });

    test('words that agreed to the old one cannot send the old one', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '第一句',
      });
      actions.userSaid('好');
      await actions.request('send_message', {
        'channel': 'general',
        'text': '第二句',
      });
      // The yes was for the first card; the second still needs its own.
      expect((await actions.confirm())['error'], 'needs_user_confirmation');
      expect(w.sent, isEmpty);
      actions.userSaid('确认');
      expect((await actions.confirm())['status'], 'done');
      expect(w.sent.map((s) => s.text), ['第二句']);
    });

    test('a request that fails still drops the old card', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '第一句',
      });
      await actions.request('set_task_status', {
        'task': '9',
        'status': 'in_progress',
      });
      expect(actions.pending, isNull);
      await actions.confirmTapped();
      expect(w.sent, isEmpty);
    });
  });

  group('the card runs out', () {
    test('after two minutes nothing is waiting and nothing is sent', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以合',
      });
      clock = clock.add(const Duration(minutes: 3));
      expect(actions.pending, isNull);
      await actions.confirmTapped();
      actions.userSaid('好');
      await actions.confirm();
      expect(w.sent, isEmpty);
    });
  });

  group('while driving', () {
    setUp(() => driving = true);

    for (final (name, tool, args, _) in asks) {
      if (const {'set_task_status'}.contains(tool)) continue;
      test('$name is allowed, and still asks first', () async {
        final r = await actions.request(tool, args);
        expect(r['status'], 'needs_confirmation', reason: '$r');
        expect(writes(), 0);
      });
    }

    test('changing a task to done is refused: park first', () async {
      final r = await actions.request('set_task_status', {
        'task': '12',
        'status': 'done',
      });
      expect(r['refused'], isTrue);
      expect(r['error'], '停车后再做');
      expect(actions.pending, isNull);
      expect(actions.outcome!.kind, OrbOutcomeKind.refused);
      expect(actions.outcome!.text, contains('停车后再做'));
      expect(w.commands, isEmpty);
    });

    test('so is any other status change', () async {
      final r = await actions.request('set_task_status', {
        'task': '9',
        'status': 'in_review',
      });
      expect(r['refused'], isTrue);
      expect(w.commands, isEmpty);
    });

    test('an approval or a merge in a reply is refused', () async {
      for (final text in ['批准发布', '可以合并', 'approve it', '删除它']) {
        final r = await actions.request('send_message', {
          'channel': 'general',
          'text': text,
        });
        expect(r['refused'], isTrue, reason: text);
      }
      expect(actions.pending, isNull);
      expect(w.sent, isEmpty);
    });

    test('an ordinary reply goes ahead', () async {
      final r = await actions.request('send_message', {
        'channel': 'general',
        'text': '可以',
      });
      expect(r['status'], 'needs_confirmation');
    });

    test('a refusal leaves the card that waits', () async {
      await actions.request('send_message', {
        'channel': 'general',
        'text': '可以',
      });
      await actions.request('set_task_status', {
        'task': '12',
        'status': 'done',
      });
      expect(actions.pending, isNotNull);
      await actions.confirmTapped();
      expect(w.sent, hasLength(1));
    });

    test('after parking the same change is previewed', () async {
      await actions.request('set_task_status', {
        'task': '12',
        'status': 'done',
      });
      driving = false;
      final r = await actions.request('set_task_status', {
        'task': '12',
        'status': 'done',
      });
      expect(r['status'], 'needs_confirmation');
      expect(w.commands, isEmpty);
      await actions.confirmTapped();
      expect(w.commands.single.$2, '/tasks/t4/status');
    });

    test('remind me later works on the card in front of the person', () async {
      cardIds = ['activity:no-such-row', 'mention:ch-design'];
      final r = await actions.request('snooze_item', {'when': 'tomorrow'});
      expect(r['status'], 'needs_confirmation', reason: '$r');
      await actions.confirmTapped();
      expect(snooze.active.single.id, 'mention:ch-design');
    });

    test('remind me later with no card and no item asks which', () async {
      final r = await actions.request('snooze_item', {'when': 'tomorrow'});
      expect(r['error'], isNotNull);
      expect(actions.pending, isNull);
    });
  });

  group('nudge', () {
    test('is a reply in the task thread that names the assignee', () async {
      await actions.request('nudge_task', {'task': '9'});
      expect(actions.pending!.summary, contains('Cody'));
      expect(w.sent, isEmpty);
      await actions.confirmTapped();
      final sent = w.sent.single;
      expect(sent.thread, isTrue);
      expect(sent.parent, 'm-task-9');
      expect(sent.text, contains('@cody'));
      expect(sent.mentions!.single['name'], 'cody');
    });

    test('without an assignee there is nobody to nudge', () async {
      w.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'todo')
            {...taskRow('t5', 5, 'todo', title: '戊'), 'messageId': 'm-5'},
        ],
      };
      w.routes['/tasks/channel/ch-general/number/5'] = (_) => {
        'task': {...taskRow('t5', 5, 'todo', title: '戊'), 'messageId': 'm-5'},
      };
      final r = await actions.request('nudge_task', {'task': '5'});
      expect(r['error'], contains('负责人'));
      expect(actions.pending, isNull);
    });
  });

  group('the rest of the capability layer', () {
    test('act: any action goes through the same card', () async {
      final r = await actions.call('act', {
        'capability': 'messages.send',
        'args': '{"channel":"general","text":"可以合"}',
      });
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(actions.pending!.summary, contains('#general'));
      expect(w.sent, isEmpty);
      await actions.confirmTapped();
      expect(w.sent.single.text, '可以合');
    });

    test('act on a query, or on nothing, says so and shows no card', () async {
      final q = await actions.call('act', {'capability': 'tasks.board'});
      expect(q['error'], contains('查询'));
      final n = await actions.call('act', {'capability': 'no.such_thing'});
      expect(n['error'], contains('no.such_thing'));
      expect(actions.pending, isNull);
    });

    test(
      'query: reads, without the screen hint and with an activity line',
      () async {
        final r = await actions.call('query', {
          'capability': 'tasks.board',
          'args': '{"status":"in_review"}',
        });
        expect(r['capability'], 'tasks.board');
        expect(r.containsKey('render'), isFalse);
        expect(r['activity'], contains('tasks.board'));
        expect(((r['result'] as Map)['tasks'] as List).single['number'], 12);
      },
    );

    test('query: a failing read is an answer, not a throw', () async {
      w.routes['/tasks/server'] = (_) => throw StateError('offline');
      final r = await actions.call('query', {'capability': 'tasks.board'});
      expect(r['error'], isNotNull);
    });

    test('find: the same matches Agent mode gets', () async {
      final r = await actions.call('find', {'intent': '加个表情'});
      expect([
        for (final m in r['matches'] as List) (m as Map)['id'],
      ], contains('messages.react'));
    });

    test('a sensitive operation needs two presses, never words', () async {
      final r = await actions.call('act', {
        'capability': 'agents.stop',
        'args': {'agent': 'Cody'},
      });
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(actions.pending!.total, 2);
      expect(actions.pending!.step, 1);
      // Words and the model's own confirm do not count.
      actions.userSaid('好');
      final early = await actions.confirm();
      expect(early['error'], 'needs_user_confirmation');
      expect(early['message'], contains('确认卡'));
      expect(w.commands, isEmpty);
      // One press makes the second card.
      await actions.confirmTapped();
      expect(w.commands, isEmpty, reason: 'nothing before the second yes');
      expect(actions.pending!.step, 2);
      expect(actions.outcome, isNull);
      expect(told.last, contains('再点一次'));
      actions.userSaid('确认');
      expect((await actions.confirm())['error'], 'needs_user_confirmation');
      await actions.confirmTapped();
      expect(w.commands.single.$2, '/agents/a-cody/stop');
      expect(actions.pending, isNull);
      expect(actions.outcome!.kind, OrbOutcomeKind.done);
    });

    test(
      'what can be taken back is: the person says 撤销, the model undoes',
      () async {
        await actions.request('set_task_status', {
          'task': '9',
          'status': 'in_review',
        });
        await actions.confirmTapped();
        expect(w.commands.single.$3, {'status': 'in_review'});
        final early = await actions.call('undo', const {});
        expect(early['error'], 'needs_user_consent');
        actions.userSaid('撤销');
        final r = await actions.call('undo', const {});
        expect(r['status'], 'undone', reason: '$r');
        expect(w.commands.last.$3, {'status': 'in_progress'});
      },
    );

    test(
      'a page the person must open themselves is opened, with no card',
      () async {
        final r = await actions.call('act', {
          'capability': 'channels.delete',
          'args': {'channel': 'general'},
        });
        expect(r['status'], 'open_page', reason: '$r');
        expect(actions.pending, isNull);
        expect(w.commands, isEmpty);
      },
    );

    test(
      'while driving only the low-risk ones, whatever way they are asked',
      () async {
        driving = true;
        for (final (id, args) in [
          ('tasks.set_status', {'task': '12', 'status': 'done'}),
          ('channels.set_pinned', {'channel': 'general', 'pinned': true}),
          ('agents.stop', {'agent': 'Cody'}),
          ('channels.delete', {'channel': 'general'}),
          ('activity.mark_done', {'item': 'x'}),
        ]) {
          final r = await actions.call('act', {'capability': id, 'args': args});
          expect(r['refused'], isTrue, reason: id);
          expect(r['error'], '停车后再做', reason: id);
        }
        expect(actions.pending, isNull);
        expect(w.commands, isEmpty);
        final ok = await actions.call('act', {
          'capability': 'messages.send',
          'args': {'channel': 'general', 'text': '可以'},
        });
        expect(ok['status'], 'needs_confirmation');
        final risky = await actions.call('act', {
          'capability': 'messages.send',
          'args': '{"channel":"general","text":"批准发布"}',
        });
        expect(risky['refused'], isTrue);
      },
    );

    test('driving reads are free: query works', () async {
      driving = true;
      final r = await actions.call('query', {'capability': 'tasks.board'});
      expect(r['capability'], 'tasks.board');
    });
  });

  group('the tools', () {
    test('are named for what they do, and confirm takes no token', () {
      final names = [for (final t in actions.tools) t.name];
      expect(
        names,
        containsAll([
          'send_message',
          'reply_in_thread',
          'react',
          'set_task_status',
          'assign_task',
          'snooze_item',
          'nudge_task',
          'mark_read',
          'mark_done',
          'create_task',
          'unassign_task',
          'join_channel',
          'reject_task',
          'find',
          'query',
          'act',
          'confirm',
          'undo',
          'cancel_action',
        ]),
      );
      final confirm = actions.tools.firstWhere((t) => t.name == 'confirm');
      final params = confirm.declaration['parameters'] as Map;
      expect(params['required'], anyOf(isNull, isEmpty));
    });

    test('every declaration says nothing happens before the person agrees', () {
      for (final t in actions.tools) {
        if (!orbActionCapabilities.containsKey(t.name) && t.name != 'act') {
          continue;
        }
        expect(
          t.declaration['description'],
          allOf(contains('确认'), contains('不会马上')),
          reason: t.name,
        );
      }
    });

    test('snooze_item does not require the item', () {
      final t = actions.tools.firstWhere((t) => t.name == 'snooze_item');
      final params = t.declaration['parameters'] as Map;
      expect(params['required'], anyOf(isNull, isEmpty));
    });
  });

  test('the model has no tool that approves, merges, deletes or releases', () {
    final names = [for (final t in actions.tools) t.name];
    expect(
      names.where(RegExp('approve|merge|delete|release').hasMatch),
      isEmpty,
    );
  });

  test('a card listens: the layer is told when it appears and goes', () async {
    var changes = 0;
    actions.addListener(() => changes++);
    await actions.request('send_message', {
      'channel': 'general',
      'text': '可以合',
    });
    expect(changes, greaterThan(0));
    final before = changes;
    await actions.cancelTapped();
    expect(changes, greaterThan(before));
  });
}
