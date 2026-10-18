import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_list.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_rows.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_surface.dart';
import 'package:raft_ui/raft_ui.dart';

import 'agent_orb_driving_live_test.dart' show FakeActivity, live;
import 'agent_orb_shell_session_test.dart' show fakeTool;
import 'agent_orb_shell_test.dart' show OrbFixture;

/// The summary card, the recent and the results lists and the "就这些" of an
/// empty deck, drawn on the black scrim of the driving layer, in both
/// themes; and the layer drawing the summary card for a summary list.

OrbBriefItem progress(String id, String who, String title) => OrbBriefItem(
  id: id,
  title: title,
  who: who,
  where: '#raft-flutter',
  since: '5 分钟前',
  link: '/s/s1/channel/$id',
  sourceIds: const ['m1'],
  reason: OrbReason.progress,
  why: '',
);

OrbList recentList({int routine = 4}) => orbListOfBriefing(
  OrbBriefing(
    scope: OrbBriefScope.activity,
    overview: '',
    needsYou: const [],
    progress: [
      progress('p1', 'CodexMac', '构建通过了'),
      progress('p2', 'Cody', '第 10 步已经合入'),
      progress('p3', 'Alice', '设计稿更新了'),
    ],
    routineCount: routine,
  ),
  OrbListKind.recent,
)!;

OrbList resultsList({int channels = 3}) => orbListOfTargets({
  'channels': [
    for (var i = 0; i < channels; i++)
      {'id': 'c$i', 'name': '#raft-flutter$i', 'unread': i == 0 ? 3 : 0},
  ],
  'dms': [
    {'id': 'd1', 'name': 'Cody', 'unread': 1},
  ],
  'people': [
    {'id': 'u1', 'name': 'Alice'},
  ],
});

const longSentence =
    '大家讨论了第 10 步能不能合入，Cody 说测试都过了但是还差评审，Alice 提出要先把设计稿对齐再合并，最后约好周五下午再看一次';

OrbList summaryList({bool clipped = true}) => orbListOfSummary([
  'Cody 在问第 10 步可以合入吗',
  'Alice 说测试都过了，等你点头',
  if (clipped) longSentence else '最后约好周五下午再看一次',
], where: '#raft-flutter');

Future<void> host(
  WidgetTester t,
  Widget child, {
  RaftFamily family = RaftFamily.brutal,
  bool dark = false,
}) async {
  t.view.physicalSize = const Size(412, 860) * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: raftTheme(family, dark: dark),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: child,
        ),
      ),
    ),
  );
}

OrbDrivingSurface on(OrbList list) => OrbDrivingSurface()..showList(list);

void main() {
  final speaking = find.byKey(const ValueKey('orb-list-speaking'));
  final foot = find.byKey(const ValueKey('orb-list-foot'));
  final summaryFoot = find.byKey(const ValueKey('orb-summary-foot'));
  Finder line(int i) => find.byKey(ValueKey('orb-summary-line-$i'));
  Finder card(int i) => find.byKey(ValueKey('orb-list-card-$i'));

  group('the summary card', () {
    for (final (family, dark) in [
      (RaftFamily.brutal, false),
      (RaftFamily.elegant, true),
    ]) {
      testWidgets('shows the sentences, the spoken one ringed ($family)', (
        t,
      ) async {
        final surface = on(summaryList());
        surface.spotlight(1);
        await host(
          t,
          OrbDrivingSummary(surface: surface),
          family: family,
          dark: dark,
        );
        expect(find.byKey(const ValueKey('orb-summary')), findsOneWidget);
        for (var i = 0; i < 3; i++) {
          expect(line(i), findsOneWidget);
        }
        expect(find.text('Cody 在问第 10 步可以合入吗'), findsOneWidget);
        expect(find.text('Alice 说测试都过了，等你点头'), findsOneWidget);
        expect(speaking, findsOneWidget);
        expect(
          find.descendant(of: speaking, matching: line(1)),
          findsOneWidget,
        );
        expect(find.descendant(of: speaking, matching: line(0)), findsNothing);
        // The spoken one is lifted over the one before.
        expect(
          t.getTopLeft(line(1)).dy - t.getBottomLeft(line(0)).dy,
          lessThan(t.getTopLeft(line(2)).dy - t.getBottomLeft(line(1)).dy),
        );
      });
    }

    testWidgets('the heading names the place and has no count', (t) async {
      await host(t, OrbDrivingSummary(surface: on(summaryList())));
      expect(
        find.textContaining('摘要 · #raft-flutter', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('摘要 · #raft-flutter 3'), findsNothing);
      final heading = t.widget<OrbListHeading>(
        find.byKey(const ValueKey('orb-summary-heading')),
      );
      expect(heading.title, '摘要 · #raft-flutter');
      expect(heading.hint, isEmpty);
    });

    testWidgets('a cut sentence brings the foot, an uncut one does not', (
      t,
    ) async {
      await host(t, OrbDrivingSummary(surface: on(summaryList())));
      expect(summaryFoot, findsOneWidget);
      expect(find.text('停车后看原文'), findsOneWidget);
      await host(
        t,
        OrbDrivingSummary(surface: on(summaryList(clipped: false))),
      );
      expect(summaryFoot, findsNothing);
      expect(find.text('停车后看原文'), findsNothing);
    });

    testWidgets('the sentences are big type and a long one stays in its card', (
      t,
    ) async {
      await host(t, OrbDrivingSummary(surface: on(summaryList())));
      for (var i = 0; i < 3; i++) {
        final text = t.widget<Text>(
          find.descendant(of: line(i), matching: find.byType(Text)),
        );
        expect(text.style!.fontSize, greaterThanOrEqualTo(22));
        expect(text.maxLines, orbSummaryMaxLines);
      }
      expect(t.takeException(), isNull);
      // The cut sentence is the cap and a mark, nothing more.
      expect(
        summaryList().rows.last.title.runes.length,
        lessThanOrEqualTo(orbRowTextCap + 1),
      );
    });

    testWidgets('no row is tapped open: a tap does nothing', (t) async {
      final surface = on(summaryList());
      await host(t, OrbDrivingSummary(surface: surface));
      await t.tap(line(0));
      await t.pump();
      expect(surface.kind, OrbSurfaceKind.list);
      expect(surface.openRow(0), isFalse);
    });
  });

  group('the recent list', () {
    testWidgets('"最近动态 3": the rows, the hint, the routine foot', (t) async {
      final surface = on(recentList());
      await host(
        t,
        OrbDrivingList(surface: surface, onOpenRow: (_) {}),
        dark: true,
        family: RaftFamily.elegant,
      );
      expect(find.textContaining('最近动态 3', findRichText: true), findsOneWidget);
      expect(find.textContaining('说「第 2 个」打开', findRichText: true), findsOne);
      for (var i = 0; i < 3; i++) {
        expect(card(i), findsOneWidget);
      }
      expect(card(3), findsNothing);
      expect(find.text('构建通过了'), findsOneWidget);
      expect(find.text('CodexMac · #raft-flutter'), findsOneWidget);
      expect(find.descendant(of: card(0), matching: speaking), findsOneWidget);
      expect(find.text('其余 4 条是常规进度'), findsOneWidget);
      expect(foot, findsOneWidget);
    });

    testWidgets('no routine items: no foot', (t) async {
      await host(
        t,
        OrbDrivingList(surface: on(recentList(routine: 0)), onOpenRow: (_) {}),
      );
      expect(foot, findsNothing);
    });
  });

  group('the results list', () {
    testWidgets('five rows are four and a pager; rows with no fact fit', (
      t,
    ) async {
      final surface = on(resultsList());
      await host(t, OrbDrivingList(surface: surface, onOpenRow: (_) {}));
      expect(find.textContaining('找到 5', findRichText: true), findsOneWidget);
      expect(find.textContaining('说「第 2 个」打开', findRichText: true), findsOne);
      for (var i = 0; i < 4; i++) {
        expect(card(i), findsOneWidget);
      }
      expect(card(4), findsNothing);
      expect(find.text('还有 1 条，说「下一批」'), findsOneWidget);
      // A channel: the kind over the name; the first one has unread to show.
      expect(find.text('频道'), findsNWidgets(3));
      expect(find.text('3 条未读'), findsOneWidget);
      expect(find.text('私信'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a row whose who and fact are empty still draws', (t) async {
      final list = OrbList(
        kind: OrbListKind.results,
        rows: const [
          OrbListRow(
            id: 'x',
            who: '',
            meta: '',
            title: '构建通过了',
            fact: '',
            say: '构建通过了',
          ),
        ],
      );
      await host(t, OrbDrivingList(surface: on(list), onOpenRow: (_) {}));
      expect(find.text('构建通过了'), findsOneWidget);
      expect(find.textContaining('说「第 1 个」打开', findRichText: true), findsOne);
      expect(t.takeException(), isNull);
    });

    testWidgets('a tap on a row opens it', (t) async {
      int? opened;
      await host(
        t,
        OrbDrivingList(
          surface: on(resultsList()),
          onOpenRow: (i) => opened = i,
        ),
      );
      await t.tap(card(1));
      expect(opened, 1);
    });
  });

  group('"就这些" of a deck with nothing', () {
    testWidgets('names the recent items that were all routine', (t) async {
      await host(t, const OrbDrivingDone(routineCount: 2, nothing: true));
      expect(find.text('就这些'), findsOneWidget);
      expect(find.text('最近动态 2 条，都是常规进度'), findsOneWidget);
      expect(find.textContaining('其余'), findsNothing);
    });

    testWidgets('and nothing new at all', (t) async {
      await host(t, const OrbDrivingDone(routineCount: 0, nothing: true));
      expect(find.text('就这些'), findsOneWidget);
      expect(find.text('最近没有新动态'), findsOneWidget);
    });

    testWidgets('a deck that had items keeps "其余"', (t) async {
      await host(t, const OrbDrivingDone(routineCount: 2));
      expect(find.text('其余 2 条是常规进度'), findsOneWidget);
      await host(t, const OrbDrivingDone(routineCount: 0));
      expect(find.byKey(const Key('orb-briefing-routine')), findsNothing);
    });
  });

  group('the layer', () {
    late OrbFixture f;
    late FakeActivity activity;

    testWidgets(
      'draws the summary card for a summary list, the list otherwise',
      (t) async {
        activity = FakeActivity();
        addTearDown(activity.source.dispose);
        f = OrbFixture(t);
        await f.setUp();
        addTearDown(f.tearDown);
        f.activityWatcher = (w) => activity.make(w);
        f.liveBriefer = (w) async => live(const []);
        await f.pump(
          tools: [
            fakeTool(
              'navigate',
              (args, ctx) async => {'route': '/s/s1/activity'},
            ),
          ],
        );
        await t.pump(const Duration(milliseconds: 300));
        final done = f.controller.dispatch('set_driving_mode', {'on': true});
        await t.pump(const Duration(milliseconds: 300));
        await done;
        f.controller.showBriefing(live([progress('n0', 'Cody', '合入第 10 步')]));
        await t.pump(const Duration(milliseconds: 300));

        f.controller.surface.showList(summaryList());
        // ignore: invalid_use_of_protected_member
        f.controller.notifyListeners();
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byType(OrbDrivingSummary), findsOneWidget);
        expect(find.byType(OrbDrivingList), findsNothing);
        expect(speaking, findsOneWidget);
        expect(find.text('Cody 在问第 10 步可以合入吗'), findsOneWidget);

        f.controller.surface.showList(recentList());
        // ignore: invalid_use_of_protected_member
        f.controller.notifyListeners();
        await t.pump(const Duration(milliseconds: 300));
        expect(find.byType(OrbDrivingSummary), findsNothing);
        expect(find.byType(OrbDrivingList), findsOneWidget);
      },
    );
  });
}
