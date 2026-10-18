import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_lists.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_rows.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_surface.dart';

/// The driving surfaces as a state machine: no widgets, no clock. Which
/// surface is up, which page, which row is open, where "返回" goes, and what
/// the app says for each step.

OrbBriefItem item(
  String id,
  String who,
  String title, {
  OrbReason reason = OrbReason.dmAsk,
  int unread = 0,
  String where = '#design',
  String since = '已等 20 分钟',
}) => OrbBriefItem(
  id: id,
  title: title,
  who: who,
  where: where,
  since: since,
  link: '/s/s1/channel/$id',
  sourceIds: const ['m1'],
  reason: reason,
  why: '点名你',
  unread: unread,
);

OrbBriefing briefing(int needs, {int progress = 0, int routine = 0}) =>
    OrbBriefing(
      scope: OrbBriefScope.activity,
      overview: '$needs 件',
      needsYou: [
        for (var i = 0; i < needs; i++)
          item('n$i', 'N$i', '第 $i 件事', unread: i),
      ],
      progress: [
        for (var i = 0; i < progress; i++)
          item('p$i', 'P$i', '进展 $i', reason: OrbReason.progress, unread: 2),
      ],
      routineCount: routine,
    );

OrbList unread(int needs, {int progress = 0, int routine = 0}) =>
    orbListOfBriefing(
      briefing(needs, progress: progress, routine: routine),
      OrbListKind.unread,
    )!;

void main() {
  group('the surface state machine', () {
    test('starts on the deck, with nowhere to go back to', () {
      final s = OrbDrivingSurface();
      expect(s.kind, OrbSurfaceKind.deck);
      expect(s.list, isNull);
      expect(s.back(), isFalse);
      expect(s.openRow(0), isFalse);
      expect(s.nextPage(), isFalse);
    });

    test('a list replaces the deck; its first row is the one spoken', () {
      final s = OrbDrivingSurface()..showList(unread(7));
      expect(s.kind, OrbSurfaceKind.list);
      expect(s.list!.total, 7);
      expect(s.pageCount, 2);
      expect(s.pageRows, hasLength(orbListPageSize));
      expect(s.speaking, 0);
      expect(s.hasNextPage, isTrue);
    });

    test('next page: rows 5 to 7, the first of them spoken; none after', () {
      final s = OrbDrivingSurface()..showList(unread(7));
      expect(s.nextPage(), isTrue);
      expect(s.page, 1);
      expect(s.pageRows.map((r) => r.who), ['N4', 'N5', 'N6']);
      expect(s.speaking, 4);
      expect(s.hasNextPage, isFalse);
      expect(s.nextPage(), isFalse);
      expect(s.page, 1);
    });

    test(
      '"the N-th" is the N-th of the page on the screen, else of the list',
      () {
        final s = OrbDrivingSurface()..showList(unread(7));
        expect(s.indexOfNth(2), 1);
        expect(s.indexOfNth(6), 5, reason: 'not on this page: the whole list');
        expect(s.indexOfNth(8), isNull);
        expect(s.indexOfNth(0), isNull);
        s.nextPage();
        expect(s.indexOfNth(2), 5, reason: 'the 2nd row of page 2');
        expect(
          s.indexOfNth(4),
          3,
          reason: 'page 2 has 3 rows: 4 is the whole list',
        );
      },
    );

    test('open a row, back: the list on the same page, that row lifted', () {
      final s = OrbDrivingSurface()..showList(unread(7));
      s.nextPage();
      expect(s.openRow(5), isTrue);
      expect(s.kind, OrbSurfaceKind.detail);
      expect(s.detailRow!.who, 'N5');
      expect(s.page, 1);
      expect(s.back(), isTrue);
      expect(s.kind, OrbSurfaceKind.list);
      expect(s.page, 1);
      expect(s.speaking, 5);
    });

    test('back from page 2 is page 1, then the deck', () {
      final s = OrbDrivingSurface()..showList(unread(7));
      s.nextPage();
      expect(s.back(), isTrue);
      expect(s.kind, OrbSurfaceKind.list);
      expect(s.page, 0);
      expect(s.back(), isTrue);
      expect(s.kind, OrbSurfaceKind.deck);
      expect(s.list, isNull);
      expect(s.back(), isFalse);
    });

    test('a list over a list: back is the list before, on its page', () {
      final s = OrbDrivingSurface()..showList(unread(7));
      s.nextPage();
      final tasks = OrbList(kind: OrbListKind.tasks, rows: unread(2).rows);
      s.showList(tasks);
      expect(s.list!.kind, OrbListKind.tasks);
      s.back();
      expect(s.list!.kind, OrbListKind.unread);
      expect(s.page, 1);
    });

    test(
      'next and previous in a detail walk the rows and stop at the ends',
      () {
        final s = OrbDrivingSurface()..showList(unread(3));
        s.openRow(1);
        expect(s.stepDetail(1), isTrue);
        expect(s.detailRow!.who, 'N2');
        expect(s.stepDetail(1), isFalse);
        expect(s.stepDetail(-1), isTrue);
        expect(s.stepDetail(-1), isTrue);
        expect(s.stepDetail(-1), isFalse);
        expect(s.detailRow!.who, 'N0');
        // Several steps are still one way back.
        expect(s.back(), isTrue);
        expect(s.kind, OrbSurfaceKind.list);
      },
    );

    test('a row far on in the list opens on its own page', () {
      final s = OrbDrivingSurface()..showList(unread(7));
      s.openRow(5);
      s.stepDetail(-2);
      expect(s.detailIndex, 3);
      expect(s.page, 0);
    });

    test('a write from a detail: the list is back, that row ticked', () {
      final s = OrbDrivingSurface()..showList(unread(4));
      s.openRow(1);
      final row = s.detailRow!;
      expect(s.finishDetail('已回复'), isTrue);
      expect(s.kind, OrbSurfaceKind.list);
      expect(s.markOf(row), '已回复');
      expect(s.markOf(s.pageRows[0]), isNull);
      expect(s.finishDetail('已回复'), isFalse, reason: 'no row is open');
    });

    test('a loading list is resolved in place; a back meanwhile drops it', () {
      const loading = OrbList.loading(OrbListKind.unread);
      final s = OrbDrivingSurface()..showList(loading);
      expect(s.loading, isTrue);
      expect(s.indexOfNth(1), isNull);
      expect(s.openRow(0), isFalse);
      final read = unread(3);
      expect(s.resolve(loading, read), isTrue);
      expect(s.loading, isFalse);
      expect(s.list!.total, 3);

      final again = OrbDrivingSurface()..showList(loading);
      again.back();
      expect(again.resolve(loading, read), isFalse);
      expect(again.kind, OrbSurfaceKind.deck);
    });

    test('reset is the deck again, marks gone', () {
      final s = OrbDrivingSurface()..showList(unread(4));
      s.openRow(0);
      s.finishDetail('已回复');
      s.reset();
      expect(s.kind, OrbSurfaceKind.deck);
      expect(s.list, isNull);
      expect(s.back(), isFalse);
      s.showList(unread(4));
      expect(s.markOf(s.pageRows[0]), isNull);
    });

    test('an empty list has one empty page, no row to open', () {
      final s = OrbDrivingSurface()..showList(unread(0));
      expect(s.pageCount, 1);
      expect(s.pageRows, isEmpty);
      expect(s.speaking, isNull);
      expect(s.openRow(0), isFalse);
    });
  });

  group('the rows', () {
    test(
      'unread: what needs the person first, then the progress, in order',
      () {
        final list = unread(2, progress: 2, routine: 5);
        expect(list.rows.map((r) => r.who), ['N0', 'N1', 'P0', 'P1']);
        expect(list.routine, 5);
        expect(list.heading, '未读 4');
      },
    );

    test('a row says who and where, the headline, and the one quiet fact', () {
      final list = unread(2, progress: 1);
      final waiting = list.rows[0];
      expect(waiting.meta, 'N0 · #design');
      expect(waiting.fact, '已等 20 分钟', reason: 'waiting: how long');
      final progressed = list.rows.last;
      expect(progressed.fact, '2 条未读', reason: 'else: how many unread');
      expect(waiting.item, isNotNull);
    });

    test('mentions are only the ones that name the person', () {
      final b = OrbBriefing(
        scope: OrbBriefScope.activity,
        overview: '',
        needsYou: [
          item('a', 'Alice', '问你', reason: OrbReason.mentionAsk),
          item('b', 'Bob', '问你', reason: OrbReason.dmAsk),
        ],
        progress: [item('c', 'Cody', '提到你', reason: OrbReason.mentionFyi)],
        routineCount: 0,
      );
      final list = orbListOfBriefing(b, OrbListKind.mentions)!;
      expect(list.rows.map((r) => r.who), ['Alice', 'Cody']);
      expect(orbListOfBriefing(b, OrbListKind.tasks), isNull);
    });

    test('an approval cannot be replied to while driving', () {
      final reply = orbRowOfItem(item('a', 'Alice', '问你'), waiting: true);
      final approval = orbRowOfItem(
        item('b', 'Cody', '等你批准', reason: OrbReason.awaitingApproval),
        waiting: true,
      );
      final fyi = orbRowOfItem(item('c', 'Grok', '进展'), waiting: false);
      expect(reply.canReply, isTrue);
      expect(approval.canReply, isFalse);
      expect(fyi.canReply, isFalse);
    });

    test('tasks: the number and the title, who has it, what it waits for', () {
      final list = orbListOfTasks({
        'tasks': [
          {
            'number': 138,
            'title': '整理发布说明',
            'statusText': '进行中',
            'assignee': '八戒',
            'channel': 'swift-workflow',
            'idle': '4 天',
            'waitsFor': '八戒 在做',
          },
        ],
      });
      final row = list.rows.single;
      expect(list.kind, OrbListKind.tasks);
      expect(row.meta, '任务 #138 · #swift-workflow');
      expect(row.title, '整理发布说明');
      expect(row.fact, '八戒 在做 · 4 天没动');
      expect(row.openArgs, {'task_number': 138, 'channel': 'swift-workflow'});
      expect(list.countSay, '1 个任务');
    });

    test(
      'a conversation: newest first, system lines left out, long text cut',
      () {
        final list = orbListOfConversation({
          'conversation': {'id': 'c1', 'name': '#design', 'type': 'channel'},
          'messages': [
            {'id': 'm1', 'from': 'Alice', 'text': '旧的', 'time': '昨天'},
            {'id': 'm2', 'system': true, 'text': '系统'},
            {'id': 'm3', 'from': 'Cody', 'text': '长' * 90, 'time': '5 分钟前'},
          ],
        });
        expect(list.kind, OrbListKind.channel);
        expect(list.rows.map((r) => r.who), ['Cody', 'Alice']);
        expect(list.rows.first.title.runes.length, orbRowTextCap + 1);
        expect(list.rows.first.clipped, isTrue);
        expect(list.rows.last.clipped, isFalse);
        expect(list.rows.first.openArgs, {'channel_id': 'c1'});
        expect(list.title, '#design');
      },
    );

    test('a private conversation is a person\'s list', () {
      final list = orbListOfConversation({
        'conversation': {'id': 'd1', 'name': 'Cody', 'type': 'dm'},
        'messages': [
          {'id': 'm1', 'from': 'Cody', 'text': '好', 'time': '1 分钟前'},
        ],
      });
      expect(list.kind, OrbListKind.person);
      expect(list.title, 'Cody');
      expect(list.rows.single.openArgs, {'dm_id': 'd1'});
    });

    test('a new arrival is one plain line', () {
      expect(
        orbArrivalLine(item('a', 'Alice', 'x', reason: OrbReason.mentionAsk)),
        '新的：Alice @你',
      );
      expect(orbArrivalLine(item('b', 'Bob', 'x')), '新的：Bob 找你');
    });

    test('the kinds a tool names', () {
      expect(orbListKindOf('unread'), OrbListKind.unread);
      expect(orbListKindOf('mentions'), OrbListKind.mentions);
      expect(orbListKindOf('tasks'), OrbListKind.tasks);
      expect(orbListKindOf('channel'), OrbListKind.channel);
      expect(orbListKindOf('person'), OrbListKind.person);
      expect(orbListKindOf('everything'), isNull);
      expect(orbListKindOf(null), isNull);
    });
  });

  group('what the app says', () {
    test('a list: the total and the top two, the rest is for the eyes', () {
      final say = unread(7).say!;
      expect(say, startsWith('7 条未读。'));
      expect(say, contains('最急的是N0：第 0 件事'));
      expect(say, contains('还有N1：第 1 件事'));
      expect(say, contains('其余看屏幕'));
      expect(say, isNot(contains('N2')));
    });

    test('a short list says everything and no "其余"', () {
      final say = unread(2).say!;
      expect(say, contains('N0'));
      expect(say, contains('N1'));
      expect(say, isNot(contains('其余')));
      expect(unread(1).say, isNot(contains('还有')));
    });

    test('an empty list says so, and a loading one says nothing', () {
      expect(unread(0).say, '没有未读的。');
      expect(const OrbList.loading(OrbListKind.unread).say, isNull);
    });

    test('a page: how many are left, the first two, and when it ends', () {
      final list = unread(7);
      expect(orbPageSay(list, 1), startsWith('还有 3 条：N4：第 4 件事；N5：第 5 件事。'));
      expect(orbPageSay(list, 1), endsWith('就这些了。'));
      final long = unread(10);
      expect(orbPageSay(long, 1), contains('后面还有 2 条'));
    });

    test('a row: who and what, how long, whether to answer', () {
      final row = orbRowOfItem(
        item('a', 'Alice', '周五评审你来吗', since: '已等 2 小时'),
        waiting: true,
      );
      final say = orbRowSay(row);
      expect(say, contains('Alice：周五评审你来吗'));
      expect(say, contains('已经等了 2 小时'));
      expect(say, endsWith('要回复吗？'));
    });

    test('a cut message is for when the car stops', () {
      final list = orbListOfConversation({
        'conversation': {'id': 'c1', 'name': '#design', 'type': 'channel'},
        'messages': [
          {'id': 'm3', 'from': 'Cody', 'text': '长' * 90},
        ],
      });
      expect(orbRowSay(list.rows.single), contains('停车后看'));
    });
  });
}
