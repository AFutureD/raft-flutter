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

  group('the page read instead of the briefing', () {
    const quiet = OrbBriefing(
      scope: OrbBriefScope.activity,
      overview: '没有需要你处理的',
      needsYou: [],
      progress: [],
      routineCount: 0,
      waitingTasks: 1,
      waitingTaskTitles: ['重构第 10 步'],
    );
    final channelPage = run('describe_page', {
      'page': 'conversation',
      'loading': false,
      'conversation': {'id': 'c1', 'type': 'channel', 'name': 'raft-flutter'},
      'messages': <Object?>[],
    });

    test('the scope is the Activity or the conversation on the page', () {
      expect(
        orbPageScope([
          run('describe_page', {'page': 'activity'}),
        ]),
        OrbBriefScope.activity,
      );
      expect(
        orbPageScope([channelPage]),
        const OrbBriefScope.conversation('c1'),
      );
      expect(
        orbPageScope([
          run('describe_page', {'page': 'task'}),
        ]),
        isNull,
      );
      expect(
        orbPageScope([
          run('describe_page', {'page': 'activity', 'loading': true}),
        ]),
        isNull,
      );
      expect(orbPageScope([run('list_tasks', {})]), isNull);
      // Reading the conversation is reading the place too (the last read wins).
      final read = run('read_conversation', {
        'conversation': {
          'id': 'c1',
          'name': '#raft-flutter',
          'type': 'channel',
        },
        'messages': <Object?>[],
      });
      expect(orbPageScope([read]), const OrbBriefScope.conversation('c1'));
      expect(
        orbPageScope([
          channelPage,
          run('describe_page', {'page': 'activity'}),
        ]),
        OrbBriefScope.activity,
      );
      expect(
        orbPageScope([
          run('read_conversation', {'error': 'x'}),
        ]),
        isNull,
      );
    });

    test(
      'asked what is new, the briefing of that page is read and used',
      () async {
        OrbBriefScope? asked;
        final seen = await orbWithBriefing(
          [channelPage],
          said: '这里有什么新的吗',
          brief: (scope) async {
            asked = scope;
            return quiet;
          },
        );
        expect(asked, const OrbBriefScope.conversation('c1'));
        final r = orbReviewReply('Cody 说他接着做第 10 步了。', seen, cardUp: false);
        expect(r?.text, '没有要你处理的。Cody 说他接着做第 10 步了。另外有 1 个任务在等你验收，不急。');
      },
    );

    test(
      'reading the conversation instead of the page works the same',
      () async {
        OrbBriefScope? asked;
        final seen = await orbWithBriefing(
          [
            run('read_conversation', {
              'conversation': {'id': 'c1', 'type': 'channel'},
              'messages': <Object?>[],
            }),
          ],
          said: '这里有什么新的吗',
          brief: (scope) async {
            asked = scope;
            return quiet;
          },
        );
        expect(asked, const OrbBriefScope.conversation('c1'));
        expect(
          orbReviewReply('Grok 说第 9 步合入了。', seen, cardUp: false)?.text,
          startsWith('没有要你处理的。'),
        );
      },
    );

    test('answered without reading: the page the person is on', () async {
      OrbBriefScope? asked;
      final seen = await orbWithBriefing(
        const [],
        said: '有什么新的',
        screen: () => const OrbBriefScope.conversation('c9'),
        brief: (scope) async {
          asked = scope;
          return quiet;
        },
      );
      expect(asked, const OrbBriefScope.conversation('c9'));
      expect(seen.single.name, 'get_briefing');
      // But a read that found the page unreadable is not second-guessed.
      asked = null;
      await orbWithBriefing(
        [
          run('describe_page', {'loading': true}),
        ],
        said: '有什么新的',
        screen: () => OrbBriefScope.activity,
        brief: (scope) async {
          asked = scope;
          return quiet;
        },
      );
      expect(asked, isNull);
    });

    test('a question about the content does not read one', () async {
      var read = false;
      final seen = await orbWithBriefing(
        [channelPage],
        said: '这个讨论最后定了什么',
        brief: (scope) async {
          read = true;
          return quiet;
        },
      );
      expect(read, isFalse);
      expect(seen, hasLength(1));
    });

    test('a briefing the model already has is not read again', () async {
      var read = false;
      final runs = [channelPage, run('get_briefing', briefing())];
      final seen = await orbWithBriefing(
        runs,
        said: '有什么新的',
        brief: (scope) async {
          read = true;
          return quiet;
        },
      );
      expect(read, isFalse);
      expect(seen, runs);
    });

    test('a briefing that cannot be read leaves the reply alone', () async {
      final seen = await orbWithBriefing(
        [channelPage],
        said: '有什么新的',
        brief: (scope) async => throw StateError('no'),
      );
      expect(seen, [channelPage]);
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

  group('a turn that ends without a word after a tool', () {
    final tasks = run('list_tasks', {
      'total': 3,
      'waitingOnMe': 1,
      'tasks': [
        {
          'number': 142,
          'title': '迁移旧的缓存',
          'assignee': 'Cody',
          'waitsFor': '等你验收',
          'idle': '5 天',
        },
        {
          'number': 141,
          'title': '整理发布说明',
          'assignee': '八戒',
          'waitsFor': '八戒 在做',
          'idle': '4 天',
        },
        {'number': 143, 'title': '补充设计评审记录', 'waitsFor': '没人认领'},
        {'number': 144, 'title': '第四个', 'assignee': 'Grok'},
      ],
    });

    test('the model is asked once, and the app has the words ready', () {
      final r = orbReviewReply('', [tasks], cardUp: false, driving: true);
      expect(r?.retry, contains('还没有回答'));
      expect(
        r?.text,
        '共 3 个任务，其中 1 个在等你验收。'
        '迁移旧的缓存，Cody 负责，等你验收，5 天没动；'
        '整理发布说明，八戒 在做，4 天没动；'
        '补充设计评审记录，没人认领。',
      );
    });

    test('while driving it is two sentences and three tasks', () {
      final said = orbSummarize([tasks], driving: true)!;
      expect(said.split('。').where((s) => s.isNotEmpty), hasLength(2));
      expect(said, isNot(contains('第四个')));
      expect(orbSummarize([tasks]), contains('第四个'));
    });

    test('one task, an empty list, a briefing', () {
      expect(
        orbSummarize([
          run('task_detail', {
            'task': {
              'number': 136,
              'title': '重构第 10 步',
              'assignee': 'Cody',
              'waitsFor': '等你验收',
              'idle': '45 分钟',
            },
          }),
        ]),
        '任务 #136：重构第 10 步，Cody 负责，等你验收，45 分钟没动。',
      );
      expect(
        orbSummarize([
          run('list_tasks', {'total': 0, 'tasks': <Object?>[]}),
        ]),
        '没有符合的任务。',
      );
      expect(
        orbSummarize([
          run('get_briefing', {'overview': '2 条新的'}),
        ]),
        '2 条新的。',
      );
    });

    test('a tool that found nothing to say leaves nothing to say', () {
      final r = orbReviewReply('', [
        run('navigate', {'title': 'X'}),
      ], cardUp: false);
      expect(r?.retry, isNotNull);
      expect(r?.text, isNull);
      expect(orbReviewReply('', const [], cardUp: false), isNull);
    });
  });

  group('reading the Activity out', () {
    Map<String, Object?> item(
      int n,
      String who,
      String where,
      String preview,
    ) => {'n': n, 'who': who, 'where': where, 'preview': preview};

    final page = run('describe_page', {
      'page': 'activity',
      'loading': false,
      'items': [
        item(1, 'Alice', '@Alice', '周五能来评审吗？'),
        item(2, 'Cody', '#raft-flutter', '@Sam 第 10 步可以合入吗？'),
        item(3, 'Grok', '#swift-workflow', '构建通过了。'),
        item(4, 'Cody', '#raft-flutter', '第一部分写完了。'),
        item(5, 'Cody', '@Cody', '第 9 步已经合入了。'),
        item(6, 'Bajie', '#x', '第六条'),
      ],
    });

    test('who asks: the list, not one thing', () {
      for (final said in ['读一下动态', '念一下动态', '动态里都有什么', '读读消息', '都有什么']) {
        expect(orbAsksToReadList(said), isTrue, reason: said);
      }
      for (final said in [
        '读 Alice 那条原文',
        '最新那条说了什么',
        '打开动态里的第一条消息',
        '什么要紧',
        '去动态',
      ]) {
        expect(orbAsksToReadList(said), isFalse, reason: said);
      }
    });

    test('everyone named in the page\'s order passes', () {
      expect(
        orbReviewReply(
          'Alice 问评审。Cody 问合入。Grok 构建通过。Cody 写完了。Cody 已合入。',
          [page],
          cardUp: false,
          said: '读一下动态',
        ),
        isNull,
      );
    });

    test('only the first: sent back once, with the list ready', () {
      final r = orbReviewReply(
        'Alice 问你周五能不能来评审。',
        [page],
        cardUp: false,
        said: '读一下动态',
      );
      expect(r?.retry, contains('一条条说'));
      expect(r?.retry, contains('共 6 条'));
      expect(
        r?.text,
        '共 6 条：Alice，@Alice，周五能来评审吗；'
        'Cody，#raft-flutter，@Sam 第 10 步可以合入吗；'
        'Grok，#swift-workflow，构建通过了；'
        'Cody，#raft-flutter，第一部分写完了；'
        'Cody，@Cody，第 9 步已经合入了。还有 1 条。',
      );
    });

    test('out of order counts as short', () {
      final r = orbReviewReply(
        'Cody 问合入。Alice 问评审。Grok 构建通过。Cody 写完了。Cody 已合入。',
        [page],
        cardUp: false,
        said: '读一下动态',
      );
      expect(r?.retry, isNotNull);
    });

    test('one item, another question, another page: not held', () {
      expect(
        orbReviewReply(
          'Alice 问评审。',
          [page],
          cardUp: false,
          said: '读 Alice 那条原文',
        ),
        isNull,
      );
      expect(
        orbReviewReply('Alice 问评审。', [page], cardUp: false, said: '什么要紧'),
        isNull,
      );
      final one = run('describe_page', {
        'page': 'activity',
        'items': [item(1, 'Alice', '@Alice', '好')],
      });
      expect(
        orbReviewReply('Alice 说好。', [one], cardUp: false, said: '读一下动态'),
        isNull,
      );
    });

    test('no words at all: the list is the fallback', () {
      final r = orbReviewReply('', [page], cardUp: false, said: '读一下动态');
      expect(r?.text, startsWith('共 6 条：Alice，@Alice'));
    });
  });

  group('what needs the user: every one is named', () {
    Map<String, Object?> item(String who, String title, String since) => {
      'who': who,
      'title': title,
      'since': since,
    };
    final navigated = run('navigate', {
      'title': '动态',
      'briefing': briefing(
        needsYou: [
          item('Alice', 'Alice 问你：周五能来评审吗？', '已等 5 分钟'),
          item('Cody', 'Cody 问你：第 10 步可以合入吗？', '已等 12 分钟'),
        ],
        waiting: 1,
        titles: ['重构第 10 步'],
      ),
    });

    test('asked "什么需要我处理": both named in order passes', () {
      expect(
        orbReviewReply(
          'Alice 周五问评审，等了 5 分钟。Cody 问第 10 步合入，等了 12 分钟。另外有 1 个任务在等你验收，不急。',
          [navigated],
          cardUp: false,
          said: '打开动态，什么需要我处理',
        ),
        isNull,
      );
    });

    test('one left out: sent back once, then the app says all of them', () {
      final r = orbReviewReply(
        '有两件事在等你处理。Alice 问你周五能不能去评审。',
        [navigated],
        cardUp: false,
        said: '打开动态，什么需要我处理',
      );
      expect(r?.retry, contains('2 件事'));
      expect(
        r?.text,
        '有 2 件事在等你：Alice 问你：周五能来评审吗，已等 5 分钟；'
        'Cody 问你：第 10 步可以合入吗，已等 12 分钟。'
        '另外有 1 个任务在等你验收，不急。',
      );
    });

    test('a hallucinated reply instead of the list is not an answer', () {
      final r = orbReviewReply(
        '发给 Alice：可以合入，要发吗？',
        [navigated],
        cardUp: false,
        said: '什么要紧',
      );
      expect(r?.retry, isNotNull);
    });

    test('five at most; another question is not held', () {
      final many = run('get_briefing', {
        ...briefing(
          needsYou: [for (var i = 0; i < 7; i++) item('P$i', 'P$i 问你', '刚刚')],
        ),
      });
      final r = orbReviewReply(
        'P0 P1 P2 P3 P4',
        [many],
        cardUp: false,
        said: '有什么要我处理的',
      );
      expect(r, isNull);
      expect(
        orbReviewReply('P0', [many], cardUp: false, said: '有什么要我处理的')?.text,
        endsWith('还有 2 件。'),
      );
      expect(
        orbReviewReply(
          'Cody 在等。',
          [navigated],
          cardUp: false,
          said: '全部处理掉',
        )?.retry,
        isNull,
      );
    });
  });

  group('a private conversation: the person, and whether to reply', () {
    Map<String, Object?> dmPage(List<Map<String, Object?>> messages) => {
      'conversation': {'id': 'd1', 'type': 'dm', 'name': 'Cody'},
      'messages': messages,
    };
    final asked = [
      {'from': 'Cody', 'text': '第 10 步的改动我提交了。'},
      {'from': 'Cody', 'text': '你看一下，需要我补什么吗？'},
    ];
    run_(List<Map<String, Object?>> ms, {Map<String, Object?>? b}) => [
      run('navigate', {
        'title': 'Cody',
        'matched': {'kind': 'dm', 'id': 'd1'},
        'page': dmPage(ms),
        'briefing': ?b,
      }),
    ];

    test('the name and "要回他吗" pass', () {
      expect(
        orbReviewReply(
          'Cody 在问你要不要补充，要回他吗？',
          run_(asked),
          cardUp: false,
          said: '看看 Cody 私信',
        ),
        isNull,
      );
      expect(
        orbReviewReply(
          'Cody 说提交了，不用回。',
          run_(asked),
          cardUp: false,
          said: '看看 Cody 私信',
        ),
        isNull,
      );
    });

    test('no name, or no word on replying: sent back, then "X 问你：…，要回吗？"', () {
      for (final reply in ['要我帮你回复他吗？', 'Cody 已经等了 15 分钟了，他问你看看行不行。']) {
        final r = orbReviewReply(
          reply,
          run_(asked),
          cardUp: false,
          said: '看看 Cody 私信',
        );
        expect(r?.retry, contains('Cody'), reason: reply);
        expect(r?.text, 'Cody 问你：你看一下，需要我补什么吗，要回吗？', reason: reply);
      }
    });

    test('the briefing decides; without it a question does', () {
      final quiet = briefing();
      expect(
        orbReviewReply(
          '好的。',
          run_([
            {'from': 'Cody', 'text': '收到，我接着做。'},
          ], b: quiet),
          cardUp: false,
          said: '看看 Cody 私信',
        )?.text,
        'Cody 说：收到，我接着做，不用回。',
      );
      expect(
        orbReviewReply(
          '好的。',
          run_([
            {'from': 'Cody', 'text': '收到，我接着做。'},
          ]),
          cardUp: false,
          said: '看看 Cody 私信',
        )?.text,
        'Cody 说：收到，我接着做，不用回。',
      );
    });

    test('a DM read with read_conversation, and other requests', () {
      final read = [run('read_conversation', dmPage(asked))];
      expect(
        orbReviewReply('他在问。', read, cardUp: false, said: '看看 Cody 私信')?.text,
        startsWith('Cody 问你：'),
      );
      expect(
        orbReviewReply('他在问。', read, cardUp: false, said: '读 Cody 那条原文'),
        isNull,
      );
      expect(
        orbReviewReply('他在问。', read, cardUp: false, said: '他问的是什么'),
        isNull,
      );
    });
  });

  group('a request to see the tasks: each one is named with its owner', () {
    final tasks = run('list_tasks', {
      'total': 4,
      'tasks': [
        {
          'number': 142,
          'title': '迁移旧的缓存',
          'assignee': 'Cody',
          'waitsFor': '等你验收',
          'idle': '5 天',
        },
        {
          'number': 141,
          'title': '整理发布说明',
          'assignee': '八戒',
          'waitsFor': '八戒 在做',
          'idle': '4 天',
        },
        {
          'number': 143,
          'title': '补充设计评审记录',
          'assignee': 'Grok',
          'waitsFor': 'Grok 在做',
          'idle': '3 天',
        },
        {'number': 144, 'title': '第四个', 'assignee': 'Cody'},
      ],
    });
    const said = '好，看看那几个放了好几天的任务';

    test('all three named with their owners passes while driving', () {
      expect(
        orbReviewReply(
          '迁移旧的缓存是 Cody 的，整理发布说明是八戒的，补充设计评审记录是 Grok 的。',
          [tasks],
          cardUp: false,
          driving: true,
          said: said,
        ),
        isNull,
      );
    });

    test(
      'one only: sent back, then the app lists three (five when parked)',
      () {
        final r = orbReviewReply(
          'Cody 的缓存迁移等了 5 天。',
          [tasks],
          cardUp: false,
          driving: true,
          said: said,
        );
        expect(r?.retry, contains('最多 3 个'));
        expect(r?.text, contains('整理发布说明，八戒 在做'));
        expect(r?.text, isNot(contains('第四个')));
        final parked = orbReviewReply(
          'Cody 的缓存迁移等了 5 天。',
          [tasks],
          cardUp: false,
          said: said,
        );
        expect(parked?.text, contains('第四个'));
      },
    );

    test('a title but no owner is short too', () {
      expect(
        orbReviewReply(
          '迁移旧的缓存，整理发布说明，补充设计评审记录。',
          [tasks],
          cardUp: false,
          driving: true,
          said: said,
        )?.retry,
        isNotNull,
      );
    });

    test('counting or acting on them is not listing them', () {
      for (final s in ['看看这些任务现在什么状态', '全部处理掉', '打开 task 136', '把 142 标成完成']) {
        expect(
          orbReviewReply('共 4 个。', [tasks], cardUp: false, said: s),
          isNull,
          reason: s,
        );
      }
    });
  });

  test('no briefing, no card, nothing to say about it', () {
    expect(orbReviewReply('你好。', const [], cardUp: false), isNull);
  });
}
