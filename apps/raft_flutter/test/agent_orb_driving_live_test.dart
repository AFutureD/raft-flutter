import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_activity_watch.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_queue.dart';
import 'package:raft_flutter/features/agent_orb/orb_prompt.dart';

import 'agent_orb_shell_test.dart' show OrbFixture;

/// Driving mode, step B: the queue is live. While driving the orb watches the
/// Activity; a change re-runs the briefing after a debounce and merges it into
/// the queue without moving the card the person is on.

OrbBriefItem item(
  String id,
  String title, {
  String version = 'v1',
  String who = 'Alice',
  OrbReason reason = OrbReason.dmAsk,
}) => OrbBriefItem(
  id: id,
  title: title,
  who: who,
  where: '#raft-flutter',
  since: '已等 5 分钟',
  link: '/s/s1/channel/ca',
  sourceIds: const ['m1'],
  reason: reason,
  why: '问你',
  versionKey: version,
);

/// A notifier that says whether anybody listens.
class Listened extends ValueNotifier<int> {
  Listened() : super(0);
  bool get listened => hasListeners;
}

/// An Activity store stand-in: [source] notifies, [rows] is the window.
class FakeActivity {
  final source = Listened();
  var rows = <Map<String, dynamic>>[];
  var _n = 0;
  var made = 0;
  OrbActivityWatch? watch;

  OrbActivityWatch make(Object workspace) {
    made++;
    return watch = OrbActivityWatch(source: source, rows: () => rows);
  }

  /// A new row arrived.
  void arrive() {
    _n++;
    rows = [
      ...rows,
      {'channelId': 'r$_n', 'lastMessageId': 'm$_n', 'unreadCount': 1},
    ];
    source.value++;
  }

  /// The store notified, the window is the same.
  void noise() => source.value++;
}

OrbBriefing live(
  List<OrbBriefItem> needs, {
  int routine = 5,
  int waiting = 0,
}) => OrbBriefing(
  scope: OrbBriefScope.activity,
  overview: '${needs.length} 件需要你处理',
  needsYou: needs,
  progress: const [],
  routineCount: routine,
  waitingTasks: waiting,
);

void main() {
  late OrbFixture f;
  late FakeActivity activity;
  var calls = 0;
  var current = live(const []);
  Completer<OrbBriefing>? hold;
  Object? fail;

  Future<void> fixture(WidgetTester t, {bool wired = true}) async {
    calls = 0;
    hold = null;
    fail = null;
    activity = FakeActivity();
    addTearDown(activity.source.dispose);
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    if (wired) {
      f.activityWatcher = (w) => activity.make(w);
      f.liveBriefer = (w) async {
        calls++;
        if (fail != null) throw fail!;
        return hold != null ? hold!.future : current;
      };
    }
    await f.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
  }

  /// Time passes in the fake clock; the futures that finish are let through.
  Future<void> wait(WidgetTester t, Duration d) async {
    await t.pump(d);
    await t.pump();
    await t.pump();
  }

  final a = item('a', 'A 问你周五有没有空', who: 'Alice');
  final b = item('b', 'B 想知道进度', who: 'Bob');
  final n = item('n', 'N 构建失败了', who: 'Nina', reason: OrbReason.buildFailure);

  Future<void> drive(
    WidgetTester t,
    List<OrbBriefItem> queue, {
    bool inCall = false,
    int routine = 5,
  }) async {
    if (inCall) await f.startCall();
    current = live(queue, routine: routine);
    final done = f.controller.dispatch('set_driving_mode', {'on': true});
    await settle(t);
    await done;
    f.controller.showBriefing(live(queue, routine: routine));
    await settle(t);
    // Entering told the model the first item (its own test, "entering");
    // what follows counts only the notes after it.
    if (inCall) f.sessions.single.sentTexts.clear();
  }

  final progress = find.byKey(const ValueKey('orb-driving-progress'));
  final badge = find.byKey(const ValueKey('orb-driving-new'));
  final marker = find.byKey(const ValueKey('orb-driving-card-new'));
  final next = find.byKey(const ValueKey('orb-driving-next'));

  // On the G100 "start driving mode" turned the mode on and showed nothing:
  // the model did not ask for a briefing. Kevin: entering it pushes up what
  // matters first.
  group('entering', () {
    testWidgets('driving on with nothing shown lays out the Activity '
        'briefing by itself', (t) async {
      await fixture(t);
      current = live([a, b]);
      final on = f.controller.dispatch('set_driving_mode', {'on': true});
      await settle(t);
      await on;
      await settle(t);
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'b']);
      expect(find.text('第 1 件 / 共 2 件'), findsOneWidget);
    });

    testWidgets('in a call the model is told what the first item is', (
      t,
    ) async {
      await fixture(t);
      await f.startCall();
      current = live([a]);
      final on = f.controller.dispatch('set_driving_mode', {'on': true});
      await settle(t);
      await on;
      await settle(t);
      expect(
        f.sessions.single.sentTexts.any((n) => n.contains('A 问你周五有没有空')),
        isTrue,
      );
    });
  });

  group('watching', () {
    testWidgets('starts when driving mode goes on, stops when it goes off', (
      t,
    ) async {
      await fixture(t);
      expect(activity.made, 0);
      expect(activity.source.listened, isFalse);
      await drive(t, [a, b]);
      expect(activity.made, 1);
      expect(activity.source.listened, isTrue);
      final off = f.controller.dispatch('set_driving_mode', {'on': false});
      await settle(t);
      await off;
      expect(activity.source.listened, isFalse);
    });

    testWidgets('stops when the layer closes', (t) async {
      await fixture(t);
      await drive(t, [a, b]);
      f.controller.closeLayer();
      await settle(t);
      await settle(t);
      expect(f.controller.driving, isFalse);
      expect(activity.source.listened, isFalse);
    });

    testWidgets('stops when the orb is disposed, with a re-brief pending', (
      t,
    ) async {
      await fixture(t);
      await drive(t, [a, b]);
      activity.arrive();
      await t.pump(const Duration(seconds: 1));
      // The host (and the orb) go away while the debounce is running.
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      expect(activity.source.listened, isFalse);
    });

    testWidgets('not driving: changes do nothing', (t) async {
      await fixture(t);
      f.controller.showBriefing(live([a, b]));
      await settle(t);
      activity.arrive();
      await wait(t, const Duration(seconds: 10));
      expect(activity.made, 0);
      expect(calls, 0);
      expect(f.controller.drivingNewCount, 0);
    });

    testWidgets('a store that notifies with the same window is no change', (
      t,
    ) async {
      await fixture(t);
      await drive(t, [a, b]);
      final base = calls;
      activity.noise();
      activity.noise();
      await wait(t, const Duration(seconds: 6));
      expect(calls, base);
    });
  });

  group('the queue grows without moving the card', () {
    testWidgets('a new needs-you row: the queue grows after the debounce, the '
        'card stays, the new one is next, the counter and the badge', (
      t,
    ) async {
      await fixture(t);
      await drive(t, [a, b]);
      expect(find.text('第 1 件 / 共 2 件'), findsOneWidget);
      expect(badge, findsNothing);
      final base = calls;

      current = live([n, a, b]);
      activity.arrive();
      await wait(t, const Duration(seconds: 2));
      expect(calls, base, reason: 'still debouncing');
      expect(find.text('第 1 件 / 共 2 件'), findsOneWidget);
      await wait(t, const Duration(milliseconds: 1100));
      expect(calls, base + 1);

      // The card the person looks at did not move.
      expect(find.text('A 问你周五有没有空'), findsOneWidget);
      expect(find.text('第 1 件 / 共 3 件'), findsOneWidget);
      expect(progress, findsOneWidget);
      expect(badge, findsOneWidget);
      expect(find.text('新的 1 件'), findsOneWidget);
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'n', 'b']);
      // The new card is not the one on screen, so it has no mark yet.
      expect(marker, findsNothing);

      // The badge goes after a few seconds.
      await wait(t, const Duration(seconds: 6));
      expect(badge, findsNothing);
      expect(find.text('第 1 件 / 共 3 件'), findsOneWidget);

      // Next: the new one, marked.
      await t.tap(next);
      await t.pump();
      expect(find.text('N 构建失败了'), findsOneWidget);
      expect(find.text('第 2 件 / 共 3 件'), findsOneWidget);
      expect(marker, findsOneWidget);
      await t.tap(next);
      await t.pump();
      expect(find.text('B 想知道进度'), findsOneWidget);
      expect(marker, findsNothing);
    });

    testWidgets('new ones come right after the current card, most urgent '
        'first, as the briefing orders them', (t) async {
      await fixture(t);
      final c = item('c', 'C 的新问题', who: 'Cara');
      await drive(t, [a, b]);
      await t.tap(next);
      await t.pump();
      expect(find.text('B 想知道进度'), findsOneWidget);
      current = live([n, c, a, b]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'b', 'n', 'c']);
      expect(find.text('B 想知道进度'), findsOneWidget);
      expect(find.text('第 2 件 / 共 4 件'), findsOneWidget);
      expect(find.text('新的 2 件'), findsOneWidget);
    });

    testWidgets('on 就这些 a new item brings a card back', (t) async {
      await fixture(t);
      await drive(t, [a]);
      await t.tap(next);
      await t.pump();
      expect(find.byKey(const ValueKey('orb-driving-done')), findsOneWidget);
      current = live([a, n]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(find.byKey(const ValueKey('orb-driving-done')), findsNothing);
      expect(find.text('N 构建失败了'), findsOneWidget);
      expect(find.text('第 2 件 / 共 2 件'), findsOneWidget);
      expect(marker, findsOneWidget);
      expect(find.text('新的 1 件'), findsOneWidget);
    });

    testWidgets('a shown item with a new version comes back as new', (t) async {
      await fixture(t);
      await drive(t, [a, b]);
      final a2 = item('a', 'A 又问：改到周六行吗', version: 'v2');
      current = live([a2, b]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      // On A still (it is the card); the new version is next.
      expect(f.controller.drivingItems.map((i) => i.title), [
        a.title,
        a2.title,
        b.title,
      ]);
      expect(find.text(a.title), findsOneWidget);
      expect(find.text('新的 1 件'), findsOneWidget);
      // The same version again is not new.
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems, hasLength(3));
    });

    testWidgets('an item that no longer needs the person is dropped, unless '
        'it is the card', (t) async {
      await fixture(t);
      final c = item('c', 'C 的问题', who: 'Cara');
      await drive(t, [a, b, c]);
      current = live([a, c]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'c']);
      expect(find.text('第 1 件 / 共 2 件'), findsOneWidget);
      expect(badge, findsNothing, reason: 'nothing new');

      current = live([c]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      // A is the card: it stays until the person moves on.
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'c']);
      expect(find.text(a.title), findsOneWidget);
      await t.tap(next);
      await t.pump();
      current = live([c]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems.map((i) => i.id), ['c']);
      expect(find.text('第 1 件 / 共 1 件'), findsOneWidget);
    });

    testWidgets('a burst of changes inside the debounce makes ONE re-brief', (
      t,
    ) async {
      await fixture(t);
      await drive(t, [a, b]);
      final base = calls;
      current = live([n, a, b]);
      for (var i = 0; i < 5; i++) {
        activity.arrive();
        await t.pump(const Duration(milliseconds: 500));
      }
      expect(calls, base);
      await wait(t, const Duration(seconds: 4));
      expect(calls, base + 1);
    });

    testWidgets('a change while a re-brief runs is read once more after it', (
      t,
    ) async {
      await fixture(t);
      await drive(t, [a, b]);
      final base = calls;
      hold = Completer<OrbBriefing>();
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(calls, base + 1);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      // Not started a second one on top of the first.
      expect(calls, base + 1);
      final gate = hold!;
      hold = null;
      current = live([n, a, b]);
      gate.complete(live([a, b]));
      await wait(t, const Duration(seconds: 4));
      expect(calls, base + 2);
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'n', 'b']);
    });

    testWidgets('a re-brief that ends after driving ended changes nothing', (
      t,
    ) async {
      await fixture(t, wired: true);
      await drive(t, [a, b], inCall: true);
      hold = Completer<OrbBriefing>();
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      final off = f.controller.dispatch('set_driving_mode', {'on': false});
      await settle(t);
      await off;
      hold!.complete(live([n, a, b]));
      await wait(t, const Duration(seconds: 1));
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'b']);
      expect(
        f.sessions.single.sentTexts.where((s) => s.contains('有新的')),
        isEmpty,
      );
    });

    testWidgets('a failing re-brief leaves the queue as it is', (t) async {
      await fixture(t);
      await drive(t, [a, b]);
      fail = StateError('offline');
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems.map((i) => i.id), ['a', 'b']);
      expect(badge, findsNothing);
      expect(t.takeException(), isNull);
      // The next change works again.
      fail = null;
      current = live([n, a, b]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems, hasLength(3));
    });

    testWidgets('items that were already there when driving began are not '
        'new', (t) async {
      await fixture(t);
      // The briefing the person was shown holds A only (B was told before).
      current = live([a, b]);
      final on = f.controller.dispatch('set_driving_mode', {'on': true});
      await settle(t);
      await on;
      f.controller.showBriefing(live([a]));
      await settle(t);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems.map((i) => i.id), ['a']);
      expect(badge, findsNothing);
    });
  });

  group('routine only', () {
    testWidgets('the routine count updates, no badge, no note', (t) async {
      await fixture(t);
      await drive(t, [a], inCall: true);
      current = live([a], routine: 9);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(badge, findsNothing);
      expect(f.controller.shownBriefing!.routineCount, 9);
      expect(f.sessions.single.sentTexts, isEmpty);
      await t.tap(next);
      await t.pump();
      expect(find.text('其余 9 条是常规进度'), findsOneWidget);
    });

    testWidgets('waiting tasks update the line on 就这些', (t) async {
      await fixture(t);
      await drive(t, [a]);
      current = live([a], waiting: 2);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(badge, findsNothing);
      await t.tap(next);
      await t.pump();
      expect(find.text('另外有 2 个任务在等你验收，不急'), findsOneWidget);
    });
  });

  group('the model is told', () {
    testWidgets('in a call: one note per batch, with who and what, and the '
        'rule', (t) async {
      await fixture(t);
      await drive(t, [a, b], inCall: true);
      final session = f.sessions.single;
      expect(session.sentTexts, isEmpty);

      final c = item('c', 'C 的新问题', who: 'Cara');
      current = live([n, c, a, b]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(session.sentTexts, hasLength(1));
      final note = session.sentTexts.single;
      expect(note, contains('有新的 2 件'));
      expect(note, contains('Nina'));
      expect(note, contains('N 构建失败了'));
      expect(note, isNot(contains('C 的新问题')));
      expect(note, contains('先别打断'));
      expect(note, contains('还有吗'));
      expect(note, contains('被卡住'));
      expect(note, contains('构建失败'));

      // A second batch is a second note.
      final d = item('d', 'D 的新问题', who: 'Dan');
      current = live([d, n, c, a, b]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(session.sentTexts, hasLength(2));
      expect(session.sentTexts.last, contains('有新的 1 件'));
      expect(session.sentTexts.last, contains('Dan'));
    });

    testWidgets('a title that starts with the name is not said twice', (
      t,
    ) async {
      await fixture(t);
      await drive(t, [a], inCall: true);
      final cody = item(
        'cd',
        'Cody 在等你批准重构第 10 步',
        who: 'Cody',
        reason: OrbReason.awaitingApproval,
      );
      current = live([a, cody]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      final note = f.sessions.single.sentTexts.single;
      expect('Cody'.allMatches(note), hasLength(1));
    });

    testWidgets('without a call the queue grows and nothing is sent', (
      t,
    ) async {
      await fixture(t);
      await drive(t, [a, b]);
      current = live([n, a, b]);
      activity.arrive();
      await wait(t, const Duration(seconds: 4));
      expect(f.controller.drivingItems, hasLength(3));
      expect(f.controller.inCall, isFalse);
      expect(f.sessions, isEmpty);
    });
  });

  group('the queue merge', () {
    List<String> ids(OrbQueueMerge m) => [for (final i in m.items) i.id];

    test('keeps what was shown, inserts the new after the current', () {
      final m = mergeDrivingQueue(
        queue: [a, b],
        index: 0,
        seen: {orbItemKey(a), orbItemKey(b)},
        fresh: [n, a, b],
      );
      expect(ids(m), ['a', 'n', 'b']);
      expect(m.index, 0);
      expect(m.added.map((i) => i.id), ['n']);
    });

    test('at the end the new ones are the next cards', () {
      final m = mergeDrivingQueue(
        queue: [a, b],
        index: 2,
        seen: {orbItemKey(a), orbItemKey(b)},
        fresh: [n, a, b],
      );
      expect(ids(m), ['a', 'b', 'n']);
      expect(m.index, 2);
    });

    test('an empty queue takes the new ones from the first', () {
      final m = mergeDrivingQueue(
        queue: const [],
        index: 0,
        seen: {},
        fresh: [n, a],
      );
      expect(ids(m), ['n', 'a']);
      expect(m.index, 0);
    });

    test('dropping what passed moves the index with it', () {
      final m = mergeDrivingQueue(
        queue: [a, b, n],
        index: 2,
        seen: {orbItemKey(a), orbItemKey(b), orbItemKey(n)},
        fresh: [n, b],
      );
      expect(ids(m), ['b', 'n']);
      expect(m.index, 1);
      expect(m.items[m.index].id, 'n');
    });

    test('a seen key is not new again, even after it was dropped', () {
      final m = mergeDrivingQueue(
        queue: [b],
        index: 0,
        seen: {orbItemKey(a), orbItemKey(b)},
        fresh: [a, b],
      );
      expect(ids(m), ['b']);
      expect(m.added, isEmpty);
    });

    test('the same item twice in the briefing is one card', () {
      final m = mergeDrivingQueue(
        queue: [a],
        index: 0,
        seen: {orbItemKey(a)},
        fresh: [n, n, a],
      );
      expect(ids(m), ['a', 'n']);
    });
  });

  group('the Activity watch', () {
    test('notifies when a row is new or its newest message changed, not on '
        'noise; stops when disposed', () {
      final source = Listened();
      addTearDown(source.dispose);
      var rows = <Map<String, dynamic>>[
        {'channelId': 'c1', 'lastMessageId': 'm1', 'unreadCount': 1},
      ];
      final watch = OrbActivityWatch(source: source, rows: () => rows);
      var heard = 0;
      watch.addListener(() => heard++);
      source.value++;
      expect(heard, 0, reason: 'same window');
      rows = [
        {'channelId': 'c1', 'lastMessageId': 'm2', 'unreadCount': 2},
      ];
      source.value++;
      expect(heard, 1);
      rows = [
        ...rows,
        {'channelId': 'c2', 'lastMessageId': 'x', 'unreadCount': 1},
      ];
      source.value++;
      expect(heard, 2);
      watch.dispose();
      expect(source.listened, isFalse);
      source.value++;
      expect(heard, 2);
    });
  });

  group('the prompt', () {
    test('says what to do with "有新的 N 件"', () {
      final p = orbSystemPrompt(channels: '');
      expect(p, contains('有新的'));
      expect(p, contains('先别打断'));
      expect(p, contains('还有吗'));
    });
  });
}
