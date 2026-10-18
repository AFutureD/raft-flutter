import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_resolver.dart';
import 'package:raft_flutter/features/agent_orb/orb_fast_path.dart';

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
  bool inConversation = false,
}) => orbFastCommand(
  said,
  driving: driving,
  onActivity: activity,
  queue: queue,
  directory: directory,
  inConversation: inConversation,
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

    test('what was not read: from any page but a conversation', () {
      for (final said in [
        '把我没有读的那些摘要都拿出来看一下',
        '把我没读的摘要拿出来看一下。',
        '没读的',
        '未读',
        '未读消息',
        '看一下未读的动态',
        '我还没看的消息',
        '把未读的都读一下',
        '给我看没看过的摘要',
        '有什么没读的',
        '有没有未读的消息',
        '还有什么没看的吗',
        '好的，帮我把没读的消息念一下',
      ]) {
        final off = parse(said);
        expect((off?.kind, off?.tool), ('unread', 'navigate'), reason: said);
        expect(off?.args, {'page': 'activity'}, reason: said);
        final on = parse(said, activity: true);
        expect((on?.kind, on?.tool), ('unread', 'get_briefing'), reason: said);
        expect(on?.args, {'show': true, 'full': true}, reason: said);
      }
    });

    test('what is new: only on the Activity', () {
      for (final said in [
        '新消息',
        '有什么新的',
        '有新消息吗',
        '有没有新的动态',
        '看一下新的摘要',
        '摘要',
        '看看动态摘要',
      ]) {
        expect(parse(said), isNull, reason: said);
        expect(parse(said, activity: true)?.kind, 'unread', reason: said);
      }
    });

    test('not driving, and not in a conversation', () {
      expect(parse('没读的', driving: true), isNull);
      expect(parse('有什么新的', driving: true, activity: true), isNull);
      expect(parse('没读的', inConversation: true), isNull);
      expect(parse('没读的', inConversation: true, activity: true), isNull);
    });

    test('words that are more than asking for the unread are the model\'s', () {
      for (final said in [
        '把没读的标为已读',
        '全部标为已读',
        '把未读的都标成已读',
        '回复没读的',
        '回他可以',
        '未读的消息回复一下',
        '没读的那个任务怎么样了',
        '我还没读完',
        'raft-flutter 里没读的',
        '去 raft-flutter 看看未读',
        '把视图切到未读',
        '有什么要我处理的',
        '有新的任务吗',
        '谁没读我的消息',
        '总结一下这个频道',
        '删掉没读的',
      ]) {
        expect(parse(said), isNull, reason: said);
        expect(parse(said, activity: true), isNull, reason: said);
      }
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

    test('"go" in its several ways; a look or a question is not one', () {
      for (final said in [
        '带我去 raft-flutter',
        '我想去 raft-flutter',
        '我要去 raft-flutter',
        '切换到动态',
        '带我进入动态',
        '去 raft-flutter',
      ]) {
        expect(parse(said), isNotNull, reason: said);
      }
      for (final said in [
        '看看 Cody 私信',
        '看看 raft-flutter',
        '看一下动态',
        '去 raft-flutter 有什么新的',
        '去 raft-flutter 看看谁找我',
        '打开了吗',
      ]) {
        expect(parse(said), isNull, reason: said);
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
        '第 2 件，共 3 件：Alice 问你：周五能来评审吗，已经等了 15 分钟。',
      );
    });

    test('who is in the sentence even when the title does not name them', () {
      expect(
        orbDrivingSay({
          'index': 2,
          'total': 3,
          'item': {'who': 'Alice', 'title': '周五能来评审吗？', 'since': '已等 15 分钟'},
        }),
        '第 2 件，共 3 件：Alice：周五能来评审吗，已经等了 15 分钟。',
      );
      expect(
        orbDrivingSay({
          'index': 1,
          'total': 1,
          'item': {'who': 'Grok', 'title': 'Grok 问你：好吗？'},
        }),
        '第 1 件，共 1 件：Grok 问你：好吗。',
      );
    });

    test('driving mode on: the first card, or nothing for the user', () {
      expect(
        orbDriveSay({
          'needsYou': [
            {'who': 'Cody', 'title': 'Cody 问你：上线吗？', 'since': '已等 5 分钟'},
            {'who': 'Ada', 'title': 'Ada 问你'},
          ],
        }),
        '好，驾驶模式。第 1 件，共 2 件：Cody 问你：上线吗，已经等了 5 分钟。',
      );
      expect(
        orbDriveSay({'needsYou': <Object?>[], 'routineCount': 4}),
        '好，驾驶模式。没有要你处理的。其余 4 条是常规进度。',
      );
      // Did not read: no claim.
      expect(orbDriveSay({'error': 'x'}), isNull);
      expect(orbDriveSay({'loading': true, 'needsYou': <Object?>[]}), isNull);
    });

    test('the unread: overview, then each with where and how many', () {
      expect(
        orbUnreadSay({
          'overview': '3 条新动态，2 件需要你处理。',
          'needsYou': [
            {
              'who': 'Alice',
              'title': 'Alice 问你：周五能来评审吗？',
              'where': '@Alice',
              'unread': 3,
              'since': '已等 5 分钟',
            },
            {
              'who': 'Cody',
              'title': '第 10 步可以合入吗',
              'where': '#raft-flutter',
              'unread': 2,
            },
          ],
          'progress': [
            {'who': 'Grok', 'title': '构建通过了', 'where': '#swift-workflow'},
          ],
          'routineCount': 4,
        }),
        '3 条新动态，2 件需要你处理。'
        'Alice 问你：周五能来评审吗，在 @Alice，3 条未读；'
        'Cody：第 10 步可以合入吗，在 #raft-flutter，2 条未读；'
        'Grok：构建通过了，在 #swift-workflow。'
        '其余 4 条是常规进度。',
      );
    });

    test('the unread: at most five are told, the rest are counted', () {
      final say = orbUnreadSay({
        'overview': '7 条新动态',
        'needsYou': [
          for (var i = 1; i <= 7; i++)
            {'who': 'P$i', 'title': 'P$i 问你', 'where': '#a', 'unread': i},
        ],
        'routineCount': 1,
      });
      expect(say, contains('P5 问你，在 #a，5 条未读。'));
      expect(say, isNot(contains('P6')));
      expect(say, endsWith('其余 3 条是常规进度。'));
    });

    test('the unread: none, or not read (no claim)', () {
      expect(
        orbUnreadSay({
          'overview': '没有新的动态',
          'needsYou': <Object?>[],
          'progress': <Object?>[],
          'routineCount': 0,
        }),
        '没有未读的动态。',
      );
      expect(orbUnreadSay({'error': 'x'}), isNull);
      expect(orbUnreadSay({'loading': true, 'overview': ''}), isNull);
      expect(orbUnreadSay({'needsYou': <Object?>[]}), isNull);
    });

    test('a private conversation: who, what they asked, and answer or not', () {
      expect(
        orbArrivalSay({
          'title': 'Cody',
          'matched': {'kind': 'dm', 'id': 'd1', 'score': 1.0},
          'briefing': {
            'needsYou': [
              {'who': 'Cody', 'title': 'Cody 问你：需要我补什么吗？', 'since': '已等 15 分钟'},
            ],
          },
        }),
        'Cody 问你：需要我补什么吗，已经等了 15 分钟。要回吗？',
      );
      expect(
        orbArrivalSay({
          'title': 'Cody',
          'matched': {'kind': 'dm', 'id': 'd1', 'score': 1.0},
          'briefing': {'needsYou': <Object?>[]},
          'page': {
            'messages': [
              {'from': 'Cody', 'text': '收到，我接着做。'},
              {'from': 'Sam', 'fromMe': true, 'text': '好'},
            ],
          },
        }),
        'Cody 说：收到，我接着做。不用回。',
      );
      expect(
        orbArrivalSay({
          'title': 'Cody',
          'matched': {'kind': 'dm', 'id': 'd1', 'score': 1.0},
          'briefing': {'needsYou': <Object?>[]},
        }),
        '到了Cody的私信。没有要你处理的。',
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
      expect(
        orbTaskPassSay({
          'index': 1,
          'current': {
            'number': 14,
            'title': '己',
            'assignee': 'Cody',
            'waitsFor': '等你验收',
          },
        }),
        '第 1 个任务：#14「己」等你验收。',
      );
      expect(
        orbTaskPassSay({
          'index': 3,
          'current': {'number': 15, 'title': '庚', 'assignee': 'Ada'},
        }),
        '第 3 个任务：#15「庚」，由 Ada 负责。',
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
        '到了#general。有 2 件事在等你：Cody 问你：上线吗，已经等了 5 分钟；Ada 问你：开会吗，已经等了 9 分钟。',
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
        '任务 #136「重构第 10 步」在等你验收，由 Cody 负责。',
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
