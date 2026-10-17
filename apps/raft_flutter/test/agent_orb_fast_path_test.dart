import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_resolver.dart';
import 'package:raft_flutter/features/agent_orb/orb_fast_path.dart';
import 'package:raft_flutter/features/agent_orb/orb_open.dart';

/// Commands the app does by itself: unambiguous words, one tool, a sentence
/// made from what it returned. No model call.

const directory = OrbDirectory(
  channels: [OrbChannelRef(id: 'c1', name: 'raft-flutter')],
  dms: [OrbDmRef(id: 'd1', name: 'Cody', peerId: 'p1', peerType: 'agent')],
);

OrbFastCommand? parse(
  String said, {
  bool driving = false,
  bool activity = false,
  bool queue = false,
}) => orbFastCommand(
  said,
  driving: driving,
  onActivity: activity,
  queue: queue,
  directory: directory,
);

void main() {
  group('which words are a command', () {
    test('driving: next, previous, parked', () {
      for (final said in ['下一件', '下一个', '下一条。', '好的，下一个', '下一件吧']) {
        final c = parse(said, driving: true);
        expect((c?.kind, c?.tool), ('next', 'driving_next'), reason: said);
      }
      expect(parse('下一个', driving: true, queue: true)?.tool, 'next_task');
      expect(parse('上一件', driving: true)?.tool, 'driving_previous');
      for (final said in ['停车了', '我停车了', '退出驾驶', '退出驾驶模式', '结束驾驶模式', '不开车了']) {
        final c = parse(said, driving: true);
        expect(c?.tool, 'set_driving_mode', reason: said);
        expect(c?.args, {'on': false}, reason: said);
      }
    });

    test('not driving: start; and the driving words mean nothing', () {
      for (final said in ['开始驾驶模式', '开始驾驶', '进入驾驶模式', '我在开车']) {
        expect(parse(said)?.args, {'on': true}, reason: said);
      }
      expect(parse('开始驾驶模式', driving: true), isNull);
      expect(parse('下一件'), isNull, reason: 'nothing to go through');
      expect(parse('停车了'), isNull);
    });

    test('an item of the Activity, only on the Activity', () {
      for (final said in [
        '打开动态里的第一条消息',
        '打开动态里的第 2 条',
        '读动态里的第三条',
        '动态里的第十条',
      ]) {
        expect(parse(said, activity: true)?.tool, 'open_item', reason: said);
      }
      expect(parse('打开动态里的第一条消息', activity: true)?.args, {'n': 1});
      expect(parse('读动态里的第十二条', activity: true)?.args, {'n': 12});
      expect(parse('打开动态里的第一条消息'), isNull, reason: 'not on the Activity');
    });

    test('a place the resolver is sure of', () {
      expect(parse('打开 task 136')?.args, {'task_number': 136});
      expect(parse('进入动态')?.args, {'page': 'activity'});
      expect(parse('去动态')?.args, {'page': 'activity'});
      expect(parse('去 raft-flutter')?.args, {'channel_id': 'c1'});
      expect(parse('打开 Cody 私信')?.args, {'dm_id': 'd1'});
    });

    test('anything else goes to the model', () {
      for (final said in [
        '',
        '确认',
        '去 raft-flutter 看看谁找我',
        '打开动态，什么需要我处理',
        '去 Roughslutter',
        '下一件是什么',
        '下一件的细节',
        '回他可以',
        '停车了吗',
        '有什么新的',
      ]) {
        expect(
          parse(said, driving: true, activity: true),
          isNull,
          reason: said,
        );
      }
    });

    test('a bare "go" is told from a question', () {
      for (final said in [
        '带我去 general',
        '我想看看 general',
        '打开 design',
        '去 raft-flutter',
      ]) {
        expect(orbJustGo(said), isTrue, reason: said);
      }
      for (final said in ['去 general 有什么新的', '去 general 看看谁找我', '确认', '打开了吗']) {
        expect(orbJustGo(said), isFalse, reason: said);
      }
    });
  });

  group('what is said', () {
    OrbBriefing briefing({int routine = 0, int tasks = 0}) => OrbBriefing(
      scope: OrbBriefScope.activity,
      overview: '',
      needsYou: const [],
      progress: const [],
      routineCount: routine,
      waitingTasks: tasks,
    );

    test('the next card in a sentence', () {
      expect(
        orbDrivingSay({
          'index': 2,
          'total': 3,
          'done': false,
          'item': {
            'who': 'Alice',
            'title': 'Alice 问你：周五能来评审吗？',
            'since': '已等 15 分钟',
          },
        }),
        '第 2 件，共 3 件：Alice 问你：周五能来评审吗，已等 15 分钟。',
      );
    });

    test('the end of the cards: that is all, and what is left', () {
      expect(orbDrivingSay({'done': true}), '就这些。');
      expect(
        orbDrivingSay({'done': true}, briefing: briefing(routine: 4, tasks: 2)),
        '就这些。其余 4 条是常规进度。另外有 2 个任务在等你验收，不急。',
      );
      expect(orbDrivingSay({'error': 'x'}), isNull);
    });

    test('the task pass', () {
      expect(
        orbTaskPassSay({
          'index': 2,
          'current': {
            'number': 13,
            'title': '戊',
            'assignee': '八戒',
            'waitsFor': '八戒 在做',
          },
        }),
        '第 2 个任务：#13「戊」，八戒 在做。',
      );
      expect(orbTaskPassSay({'done': true}), '就这些。');
    });

    test('an arrival: where, and what needs the user, or nothing', () {
      expect(
        orbArrivalSay({
          'title': '#general',
          'briefing': {
            'needsYou': [
              {'who': 'Cody', 'title': 'Cody 问你：上线吗？', 'since': '已等 5 分钟'},
              {'who': 'Ada', 'title': 'Ada 问你：开会吗？', 'since': '已等 9 分钟'},
            ],
          },
        }),
        '到了#general。有 2 件事在等你：Cody 问你：上线吗，已等 5 分钟；Ada 问你：开会吗，已等 9 分钟。',
      );
      expect(
        orbArrivalSay({
          'title': '动态',
          'briefing': {'needsYou': <Object?>[], 'waitingTasks': 1},
        }),
        '到了动态。没有要你处理的。另外有 1 个任务在等你验收，不急。',
      );
      expect(orbArrivalSay({'title': '设置'}), '到了设置。');
      expect(orbArrivalSay({'title': 'X', 'loading': true}), '到了X，内容还在加载。');
      // Not clear: the model.
      expect(orbArrivalSay({'error': 'x'}), isNull);
      expect(orbArrivalSay({'candidates': <Object?>[]}), isNull);
      expect(orbArrivalSay({'title': 'X', 'briefingNote': '没读出来'}), isNull);
    });

    test('a task arrival is the task in a sentence', () {
      expect(
        orbArrivalSay({
          'title': '#136 重构第 10 步',
          'page': {
            'page': 'task',
            'task': {
              'number': 136,
              'title': '重构第 10 步',
              'status': 'in_review',
              'assignee': 'Cody',
            },
          },
        }),
        '任务 #136「重构第 10 步」，等验收，Cody 负责。',
      );
    });

    test('an opened item', () {
      expect(
        orbItemSay({'opened': 1, 'title': '@Alice'}, 1),
        '打开了第 1 条：@Alice。',
      );
      expect(orbItemSay({'error': 'x'}, 1), isNull);
    });
  });
}
