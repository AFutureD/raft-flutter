import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/orb_agent_review.dart';

/// What the app makes of the words a turn of the text agent ends with.

AgentToolRun run(String name, Map<String, Object?> result) =>
    AgentToolRun(name, const {}, result);

Map<String, Object?> briefing({
  List<Object?> needsYou = const [],
  int waiting = 0,
  List<String> titles = const [],
}) => {
  'scope': 'activity',
  'needsYou': needsYou,
  'progress': const [],
  'routineCount': 0,
  if (waiting > 0) 'waitingTasks': waiting,
  if (waiting > 0) 'waitingTaskTitles': titles,
};

void main() {
  group('asking without a card', () {
    test('"要发吗？" with no card and no action tool: told to call it', () {
      final r = orbReviewReply('回复 Cody：可以，要发吗？', const [], cardUp: false);
      expect(r?.retry, contains('动作工具'));
      expect(r?.text, isNull);
    });

    test('with a card up, or one made this turn, nothing is said', () {
      expect(orbReviewReply('要发吗？', const [], cardUp: true), isNull);
      expect(
        orbReviewReply('要发吗？', [
          run('send_message', {'status': 'needs_confirmation'}),
        ], cardUp: false),
        isNull,
      );
    });
  });

  group('claiming it is done', () {
    test('"已发送" while a card is up and nothing was confirmed', () {
      final r = orbReviewReply('已发送。', const [], cardUp: true);
      expect(r?.retry, contains('confirm'));
    });

    test('after a confirm that was done it stands', () {
      expect(
        orbReviewReply('已发送。', [
          run('confirm', {'status': 'done'}),
        ], cardUp: true),
        isNull,
      );
    });

    test('with no card up it is not this rule\'s business', () {
      expect(orbReviewReply('Cody 说已发送了', const [], cardUp: false), isNull);
    });
  });

  group('a briefing with nothing for the person', () {
    test('the line "没有要你处理的" starts the reply', () {
      final r = orbReviewReply('第 9 步的测试都过了。', [
        run('get_briefing', briefing()),
      ], cardUp: false);
      expect(r?.text, '没有要你处理的。第 9 步的测试都过了。');
    });

    test('the briefing navigate brought counts too', () {
      final r = orbReviewReply('到了。', [
        run('navigate', {'title': '动态', 'briefing': briefing()}),
      ], cardUp: false);
      expect(r?.text, startsWith('没有要你处理的。'));
    });

    test('a reply that says it already is left alone', () {
      expect(
        orbReviewReply('没有要你处理的，一切正常。', [
          run('get_briefing', briefing()),
        ], cardUp: false),
        isNull,
      );
    });

    test('a page still loading is not empty', () {
      expect(
        orbReviewReply('动态还在加载。', [
          run('describe_page', {'loading': true}),
          run('get_briefing', briefing()),
        ], cardUp: false),
        isNull,
      );
      expect(
        orbReviewReply('稍等，还没读到。', [
          run('get_briefing', briefing()),
        ], cardUp: false),
        isNull,
      );
    });

    test('a briefing that failed to read says nothing', () {
      expect(
        orbReviewReply('没读到。', [
          run('get_briefing', {'error': '简报没读出来'}),
        ], cardUp: false),
        isNull,
      );
    });

    test('something that needs the person is not "nothing"', () {
      expect(
        orbReviewReply('Alice 问你周五能不能来。', [
          run(
            'get_briefing',
            briefing(
              needsYou: [
                {'who': 'Alice'},
              ],
            ),
          ),
        ], cardUp: false),
        isNull,
      );
    });
  });

  group('tasks come last', () {
    final items = [
      {'who': 'Grok'},
    ];

    test('a task sentence in front goes to the end', () {
      final r = orbReviewReply('有 1 个任务在等你验收。Grok 回复了：测试补好了。', [
        run(
          'get_briefing',
          briefing(needsYou: items, waiting: 1, titles: ['重构第 10 步']),
        ),
      ], cardUp: false);
      expect(r?.text, 'Grok 回复了：测试补好了。有 1 个任务在等你验收。');
    });

    test('a title counts as a task sentence', () {
      final r = orbReviewReply('重构第 10 步放了 4 天。Grok 回复了你。', [
        run(
          'get_briefing',
          briefing(needsYou: items, waiting: 1, titles: ['重构第 10 步']),
        ),
      ], cardUp: false);
      expect(r?.text, 'Grok 回复了你。重构第 10 步放了 4 天。');
    });

    test('already last: untouched', () {
      expect(
        orbReviewReply('Grok 回复了你。另外有 1 个任务在等你验收，不急。', [
          run('get_briefing', briefing(needsYou: items, waiting: 1)),
        ], cardUp: false),
        isNull,
      );
    });

    test('a reply that leaves them out gets the one line', () {
      final r = orbReviewReply('Grok 回复了你。', [
        run('get_briefing', briefing(needsYou: items, waiting: 2)),
      ], cardUp: false);
      expect(r?.text, 'Grok 回复了你。另外有 2 个任务在等你验收，不急。');
    });

    test('asked about tasks, the order is theirs', () {
      expect(
        orbReviewReply('3 个任务。', [
          run('get_briefing', briefing(needsYou: items, waiting: 3)),
          run('list_tasks', {'tasks': <Object?>[]}),
        ], cardUp: false),
        isNull,
      );
    });
  });

  group('the briefing carries its own order for the agent layer', () {
    const quiet = OrbBriefing(
      scope: OrbBriefScope.activity,
      overview: '2 条新的，没有需要你处理的',
      needsYou: [],
      progress: [],
      routineCount: 2,
      waitingTasks: 2,
    );

    test('empty: what to say first; tasks: what to say last', () {
      final j = quiet.toJson(ordered: true);
      expect(j['sayFirst'], '没有要你处理的');
      expect(j['sayLast'], '另外有 2 个任务在等你验收，不急');
      expect(j['order'], contains('waitingTasks'));
    });

    test('the realtime model gets the briefing as before', () {
      final j = quiet.toJson();
      expect(j.keys, isNot(contains('sayFirst')));
      expect(j.keys, isNot(contains('sayLast')));
      expect(j.keys, isNot(contains('order')));
    });
  });

  test('no briefing, no card, nothing to say about it', () {
    expect(orbReviewReply('你好。', const [], cardUp: false), isNull);
  });
}
