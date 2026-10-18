import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/orb_driving_surface.dart';

import 'agent_orb_driving_live_test.dart' show FakeActivity, live;
import 'agent_orb_shell_session_test.dart' show fakeTool;
import 'agent_orb_shell_test.dart' show OrbFixture;
import 'support/orb_action_world.dart';

/// The driving surfaces against the layer: a list of cards replaces the deck,
/// "第 N 个" opens one large, "下一批" pages, "返回" goes back; a new arrival
/// is one plain line and the list does not move; the rows are grey while they
/// are read; after a write from a detail the list is back with that card
/// ticked. Phone window 412x915, real taps.

OrbBriefItem item(
  String id,
  String who,
  String title, {
  OrbReason reason = OrbReason.dmAsk,
  int unread = 0,
}) => OrbBriefItem(
  id: id,
  title: title,
  who: who,
  where: '#design',
  since: '已等 20 分钟',
  link: '/s/s1/channel/$id',
  sourceIds: const ['m1'],
  reason: reason,
  why: '点名你',
  unread: unread,
);

OrbBriefItem needs(int i, {OrbReason reason = OrbReason.dmAsk}) => item(
  'n$i',
  ['Alice', 'Cody', 'Grok', '八戒', 'Sam', 'Nina', 'Omar'][i],
  [
    '周五评审你来吗',
    '合入第 10 步',
    '#136 评审通过',
    'CI 红了，等你看',
    '设计稿更新了',
    '构建失败',
    '版本发布',
  ][i],
  reason: reason,
  unread: i + 1,
);

OrbBriefing seven() => live([for (var i = 0; i < 7; i++) needs(i)], routine: 5);

void main() {
  late OrbFixture f;
  late FakeActivity activity;
  var current = seven();
  Completer<Map<String, Object?>>? tasksGate;

  Future<void> fixture(WidgetTester t) async {
    activity = FakeActivity();
    addTearDown(activity.source.dispose);
    tasksGate = null;
    current = seven();
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    f.activityWatcher = (w) => activity.make(w);
    f.liveBriefer = (w) async => current;
    f.liveDebounce = const Duration(milliseconds: 500);
    await f.pump(
      tools: [
        fakeTool('navigate', (args, ctx) async {
          ctx.operating.value = true;
          return {'route': '/s/s1/activity', 'title': '动态'};
        }),
        fakeTool('list_tasks', (args, ctx) async {
          final gate = tasksGate;
          if (gate != null) return gate.future;
          return {
            'tasks': [
              for (var i = 0; i < 3; i++)
                {
                  'number': 138 + i,
                  'title': '任务 ${138 + i}',
                  'statusText': '进行中',
                  'assignee': 'Cody',
                  'channel': 'design',
                  'waitsFor': 'Cody 在做',
                },
            ],
          };
        }),
        fakeTool(
          'read_conversation',
          (args, ctx) async => {
            'conversation': {
              'id': 'c9',
              'name': '#${args['conversation']}',
              'type': 'channel',
            },
            'messages': [
              for (var i = 0; i < 6; i++)
                {
                  'id': 'm$i',
                  'from': 'Alice',
                  'text': '消息 $i',
                  'time': '$i 分钟前',
                },
            ],
          },
        ),
      ],
    );
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
  }

  Future<Map<String, Object?>> call(
    WidgetTester t,
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final done = f.controller.dispatch(name, args);
    var finished = false;
    unawaited(done.whenComplete(() => finished = true));
    for (var i = 0; i < 60 && !finished; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await settle(t);
    return done;
  }

  Future<void> drive(WidgetTester t, {bool inCall = false}) async {
    if (inCall) await f.startCall();
    await call(t, 'set_driving_mode', {'on': true});
    f.controller.showBriefing(seven());
    await settle(t);
    if (inCall) f.sessions.single.sentTexts.clear();
  }

  final list = find.byKey(const ValueKey('orb-list'));
  final heading = find.byKey(const ValueKey('orb-list-heading'));
  final foot = find.byKey(const ValueKey('orb-list-foot'));
  final speaking = find.byKey(const ValueKey('orb-list-speaking'));
  final detail = find.byKey(const ValueKey('orb-detail'));
  final deckCard = find.byKey(const ValueKey('orb-driving-card'));
  final back = find.byKey(const ValueKey('orb-layer-history'));
  final hint = find.byKey(const ValueKey('orb-driving-hint'));
  final arrival = find.byKey(const ValueKey('orb-list-arrival'));
  Finder card(int i) => find.byKey(ValueKey('orb-list-card-$i'));
  Finder placeholder(int i) => find.byKey(ValueKey('orb-list-placeholder-$i'));

  group('a list replaces the deck', () {
    testWidgets('the unread: four cards, the count, the most urgent first and '
        'lifted, the pager', (t) async {
      await fixture(t);
      await drive(t);
      expect(deckCard, findsOneWidget);
      final r = await call(t, 'show_list', {'kind': 'unread'});
      expect(r['ok'], isTrue);
      expect(r['total'], 7);
      expect(list, findsOneWidget);
      expect(deckCard, findsNothing);
      expect(find.textContaining('未读 7', findRichText: true), findsOneWidget);
      expect(heading, findsOneWidget);
      for (var i = 0; i < 4; i++) {
        expect(card(i), findsOneWidget);
      }
      expect(card(4), findsNothing);
      // The first card is the first of the briefing, the most urgent.
      expect(
        find.descendant(of: card(0), matching: find.text('周五评审你来吗')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card(0), matching: find.text('Alice · #design')),
        findsOneWidget,
      );
      // It is the row being talked about: lifted and ringed.
      expect(speaking, findsOneWidget);
      expect(find.descendant(of: card(0), matching: speaking), findsOneWidget);
      expect(find.descendant(of: card(1), matching: speaking), findsNothing);
      expect(t.getTopLeft(card(0)).dy, lessThan(t.getTopLeft(card(1)).dy));
      expect(find.text('还有 3 条，说「下一批」'), findsOneWidget);
      expect(hint, findsOneWidget);
      expect(find.textContaining('下一批'), findsWidgets);
    });

    testWidgets('while driving there is no input to type in', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      expect(find.byKey(const ValueKey('orb-input')), findsNothing);
      expect(hint, findsOneWidget);
    });

    testWidgets('the app says the total and the top two, and the tool carries '
        'the rows the screen shows', (t) async {
      await fixture(t);
      await drive(t);
      final r = await call(t, 'show_list', {'kind': 'unread'});
      final say = r['screenSay'] as String;
      expect(say, startsWith('7 条未读。'));
      expect(say, contains('Alice'));
      expect(say, contains('Cody'));
      expect(say, isNot(contains('Grok')));
      expect((r['rows'] as List), hasLength(4));
      expect(r['page'], 1);
      expect(r['pages'], 2);
    });

    testWidgets('mentions, tasks, a channel and a person each make a list', (
      t,
    ) async {
      await fixture(t);
      current = live([
        needs(0, reason: OrbReason.mentionAsk),
        needs(1),
        needs(2, reason: OrbReason.mentionFyi),
      ]);
      f.controller.showBriefing(current);
      await call(t, 'set_driving_mode', {'on': true});
      f.controller.showBriefing(current);
      await settle(t);

      var r = await call(t, 'show_list', {'kind': 'mentions'});
      expect(r['total'], 2);
      expect(find.textContaining('点名你 2', findRichText: true), findsOneWidget);
      r = await call(t, 'show_list', {'kind': 'tasks'});
      expect(r['total'], 3);
      expect(find.textContaining('任务 3', findRichText: true), findsOneWidget);
      expect(find.text('任务 #138 · #design'), findsOneWidget);
      r = await call(t, 'show_list', {'kind': 'channel', 'target': 'design'});
      expect(r['total'], 6);
      expect(
        find.textContaining('#design 6', findRichText: true),
        findsOneWidget,
      );
      r = await call(t, 'show_list', {'kind': 'person', 'target': 'Alice'});
      expect(r['ok'], isTrue);
      // Four lists over the deck: back four times to be on it again.
      for (var i = 0; i < 4; i++) {
        expect(f.controller.surface.isDeck, isFalse);
        await call(t, 'driving_back');
      }
      expect(f.controller.surface.isDeck, isTrue);
      expect(deckCard, findsOneWidget);
    });

    testWidgets('a list that cannot be made says why and leaves the deck', (
      t,
    ) async {
      await fixture(t);
      await drive(t);
      var r = await call(t, 'show_list', {'kind': 'channel'});
      expect(r['error'], isNotNull);
      r = await call(t, 'show_list', {'kind': 'everything'});
      expect(r['error'], isNotNull);
      expect(f.controller.surface.isDeck, isTrue);
      expect(deckCard, findsOneWidget);
    });

    testWidgets('not driving, show_list is refused and nothing changes', (
      t,
    ) async {
      await fixture(t);
      final r = await call(t, 'show_list', {'kind': 'unread'});
      expect(r['error'], isNotNull);
      expect(f.controller.surface.isDeck, isTrue);
    });
  });

  group('the detail', () {
    testWidgets('"第 2 个": that row large, with the big buttons', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      final r = await call(t, 'open_item', {'n': 2});
      expect(r['surface'], 'detail');
      expect(r['screenSay'], contains('Cody'));
      expect(detail, findsOneWidget);
      expect(list, findsNothing);
      expect(find.text('未读 7 · 第 2 个'), findsOneWidget);
      final card = find.byKey(const ValueKey('orb-detail-card'));
      expect(
        find.descendant(of: card, matching: find.text('Cody · #design')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('合入第 10 步')),
        findsOneWidget,
      );
      for (final key in ['primary', 'later', 'next']) {
        final button = find.byKey(ValueKey('orb-detail-$key'));
        expect(button, findsOneWidget, reason: key);
        expect(t.getSize(button).height, greaterThanOrEqualTo(64), reason: key);
      }
    });

    testWidgets(
      'a number past the screen is the list\'s, one that is not there '
      'is said',
      (t) async {
        await fixture(t);
        await drive(t);
        await call(t, 'show_list', {'kind': 'unread'});
        var r = await call(t, 'open_item', {'n': 6});
        expect(r['surface'], 'detail');
        expect(find.text('未读 7 · 第 6 个'), findsOneWidget);
        await call(t, 'driving_back');
        r = await call(t, 'open_item', {'n': 9});
        expect(r['error'], contains('一共 7 个'));
        expect(f.controller.surface.kind, OrbSurfaceKind.list);
      },
    );

    testWidgets('下一个 on the detail is the next row\'s detail; at the end it '
        'says so', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      await call(t, 'open_item', {'n': 4});
      await t.tap(find.byKey(const ValueKey('orb-detail-next')));
      await settle(t);
      expect(find.text('未读 7 · 第 5 个'), findsOneWidget);
      expect(find.text('设计稿更新了'), findsWidgets);
      final r = await call(t, 'driving_next');
      expect(r['surface'], 'detail');
      await call(t, 'driving_next');
      final end = await call(t, 'driving_next');
      expect(end['screenSay'], '这是最后一个了。');
      expect(find.text('未读 7 · 第 7 个'), findsOneWidget);
    });

    testWidgets('稍后 puts the row aside: back to the list', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      await call(t, 'open_item', {'n': 2});
      await t.tap(find.byKey(const ValueKey('orb-detail-later')));
      await settle(t);
      expect(list, findsOneWidget);
      expect(detail, findsNothing);
    });

    testWidgets('a tap on a card is the same as saying its number', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      await t.tap(card(2));
      await settle(t);
      expect(detail, findsOneWidget);
      expect(find.text('未读 7 · 第 3 个'), findsOneWidget);
    });

    testWidgets('in a call a tap is said by the model\'s note, and the "回复" '
        'asks what to say', (t) async {
      await fixture(t);
      await drive(t, inCall: true);
      await call(t, 'show_list', {'kind': 'unread'});
      final s = f.sessions.single;
      s.sentTexts.clear();
      await t.tap(card(0));
      await settle(t);
      expect(s.sentTexts.single, contains('Alice'));
      s.sentTexts.clear();
      expect(find.text('回复'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('orb-detail-primary')));
      await settle(t);
      expect(s.sentTexts.single, contains('回复'));
      expect(s.sentTexts.single, contains('问我要回什么'));
    });
  });

  group('next page and back', () {
    testWidgets('下一批: rows 5 to 7, the first of them lifted, the pager '
        'ends', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      final r = await call(t, 'driving_next');
      expect(r['page'], 2);
      expect((r['rows'] as List), hasLength(3));
      expect(r['screenSay'], startsWith('还有 3 条'));
      expect(card(2), findsOneWidget);
      expect(card(3), findsNothing);
      expect(
        find.descendant(of: card(0), matching: find.text('设计稿更新了')),
        findsOneWidget,
      );
      expect(speaking, findsOneWidget);
      expect(foot, findsOneWidget);
      expect(find.text('就这些 · 其余 5 条是常规进度'), findsOneWidget);
      expect(find.textContaining('下一批'), findsNothing);
      final end = await call(t, 'driving_next');
      expect(end['screenSay'], '没有更多了，就这些。');
    });

    testWidgets('返回 from a detail: the same list, the same page, that row '
        'lifted', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      await call(t, 'driving_next');
      await call(t, 'open_item', {'n': 2});
      expect(detail, findsOneWidget);
      // The layer's own button is the way back while driving.
      expect(
        find.descendant(of: back, matching: find.text('返回')),
        findsOneWidget,
      );
      await t.tap(back);
      await settle(t);
      expect(list, findsOneWidget);
      expect(f.controller.surface.page, 1);
      expect(
        find.descendant(of: card(1), matching: find.text('构建失败')),
        findsOneWidget,
      );
      expect(speaking, findsOneWidget);
      expect(t.getTopLeft(card(1)).dy, lessThan(t.getTopLeft(card(2)).dy));
    });

    testWidgets('返回 from the first page is the deck, at the card it was', (
      t,
    ) async {
      await fixture(t);
      await drive(t);
      await call(t, 'driving_next');
      await call(t, 'show_list', {'kind': 'unread'});
      await call(t, 'driving_back');
      expect(list, findsNothing);
      expect(deckCard, findsOneWidget);
      expect(find.text('第 2 件 / 共 7 件'), findsOneWidget);
      expect(find.text('对话记录'), findsOneWidget);
      final r = await call(t, 'driving_back');
      expect(r['screenSay'], '已经在最前面了。');
    });

    testWidgets('a new briefing, or leaving driving, is the deck again', (
      t,
    ) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      f.controller.showBriefing(seven());
      await settle(t);
      expect(list, findsNothing);
      expect(deckCard, findsOneWidget);
      await call(t, 'show_list', {'kind': 'unread'});
      await call(t, 'set_driving_mode', {'on': false});
      expect(f.controller.surface.isDeck, isTrue);
      expect(list, findsNothing);
    });
  });

  group('what comes in while a list is up', () {
    testWidgets('one plain line at the top, the rows do not move, and it goes '
        'after a few seconds', (t) async {
      await fixture(t);
      await drive(t);
      await call(t, 'show_list', {'kind': 'unread'});
      final before = [for (var i = 0; i < 4; i++) t.getTopLeft(card(i)).dy];
      expect(arrival, findsNothing);

      final fresh = item('new', 'Mia', '线上有问题', reason: OrbReason.mentionAsk);
      current = live([fresh, for (var i = 0; i < 7; i++) needs(i)]);
      activity.arrive();
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      await t.pump();
      expect(arrival, findsOneWidget);
      expect(find.text('新的：Mia @你'), findsOneWidget);
      // The list is as it was: the same cards in the same places.
      expect(card(4), findsNothing);
      expect(find.textContaining('未读 7', findRichText: true), findsOneWidget);
      expect(
        find.descendant(of: card(0), matching: find.text('周五评审你来吗')),
        findsOneWidget,
      );
      // (The line is above the content and moves it as a whole, never a row
      // against another.)
      final after = [for (var i = 0; i < 4; i++) t.getTopLeft(card(i)).dy];
      for (var i = 1; i < 4; i++) {
        expect(after[i] - after[0], closeTo(before[i] - before[0], .5));
      }
      // The deck's own badge is not drawn on top of a list.
      expect(find.byKey(const ValueKey('orb-driving-new')), findsNothing);

      await t.pump(const Duration(seconds: 6));
      expect(arrival, findsNothing);
    });

    testWidgets('on the deck the arrival is the deck\'s badge, not the line', (
      t,
    ) async {
      await fixture(t);
      await drive(t);
      current = live([
        item('new', 'Mia', '线上有问题'),
        for (var i = 0; i < 7; i++) needs(i),
      ]);
      activity.arrive();
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('orb-driving-new')), findsOneWidget);
      expect(arrival, findsNothing);
    });
  });

  group('while the rows are read', () {
    testWidgets('grey cards and "正在读…", then the rows', (t) async {
      await fixture(t);
      await drive(t);
      tasksGate = Completer();
      final done = f.controller.dispatch('show_list', {'kind': 'tasks'});
      await settle(t);
      expect(find.byKey(const ValueKey('orb-list-loading')), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        expect(placeholder(i), findsOneWidget);
      }
      expect(find.textContaining('正在读…'), findsOneWidget);
      expect(card(0), findsNothing);
      // The numbers do nothing yet.
      final early = await call(t, 'open_item', {'n': 1});
      expect(early['error'], isNotNull);

      tasksGate!.complete({
        'tasks': [
          {
            'number': 7,
            'title': '写测试',
            'statusText': '进行中',
            'assignee': 'Cody',
          },
        ],
      });
      final r = await done;
      await settle(t);
      expect(r['total'], 1);
      expect(placeholder(0), findsNothing);
      expect(card(0), findsOneWidget);
      expect(find.text('写测试'), findsOneWidget);
    });

    testWidgets('a 返回 while it is read drops the list: the rows do not '
        'come back over the deck', (t) async {
      await fixture(t);
      await drive(t);
      tasksGate = Completer();
      final done = f.controller.dispatch('show_list', {'kind': 'tasks'});
      await settle(t);
      await call(t, 'driving_back');
      tasksGate!.complete({'tasks': <Object?>[]});
      final r = await done;
      await settle(t);
      expect(r['note'], isNotNull);
      expect(list, findsNothing);
      expect(deckCard, findsOneWidget);
    });
  });

  group('after a write from a detail', () {
    late ActionOrbFixture a;

    testWidgets('the list is back, that card dimmed with "已回复", the outcome '
        'on top', (t) async {
      a = ActionOrbFixture(t);
      f = a;
      await a.setUp();
      addTearDown(a.tearDown);
      await a.pump();
      await t.pump(const Duration(milliseconds: 300));
      await a.startCall();
      await a.openLayerInCall();
      await call(t, 'set_driving_mode', {'on': true});
      f.controller.showBriefing(seven());
      await settle(t);
      await call(t, 'show_list', {'kind': 'unread'});
      await call(t, 'open_item', {'n': 2});
      expect(detail, findsOneWidget);

      final asked = await call(t, 'send_message', {
        'channel': 'general',
        'text': '晚上看',
      });
      expect(asked['status'], 'needs_confirmation');
      // The card is the one thing on the screen.
      expect(find.byKey(const ValueKey('orb-confirm-card')), findsOneWidget);
      expect(detail, findsNothing);
      expect(list, findsNothing);

      await t.tap(find.byKey(const ValueKey('orb-confirm-yes')));
      await settle(t);
      expect(a.world.sent, isNotEmpty);
      expect(find.byKey(const ValueKey('orb-action-outcome')), findsOneWidget);
      expect(list, findsOneWidget);
      expect(detail, findsNothing);
      expect(find.text('已回复'), findsOneWidget);
      // Card 2 (the one that was open) is the dimmed one; the others are not.
      expect(
        find.descendant(of: card(1), matching: find.text('已回复')),
        findsOneWidget,
      );
      final dim = t.widget<Opacity>(
        find.descendant(of: card(1), matching: find.byType(Opacity)).first,
      );
      expect(dim.opacity, lessThan(1));
      final other = t.widget<Opacity>(
        find.descendant(of: card(2), matching: find.byType(Opacity)).first,
      );
      expect(other.opacity, 1);
      expect(
        f.controller.surface.markOf(f.controller.surface.pageRows[1]),
        '已回复',
      );
    });

    testWidgets('a card that is cancelled leaves the detail as it was', (
      t,
    ) async {
      a = ActionOrbFixture(t);
      f = a;
      await a.setUp();
      addTearDown(a.tearDown);
      await a.pump();
      await t.pump(const Duration(milliseconds: 300));
      await a.startCall();
      await a.openLayerInCall();
      await call(t, 'set_driving_mode', {'on': true});
      f.controller.showBriefing(seven());
      await settle(t);
      await call(t, 'show_list', {'kind': 'unread'});
      await call(t, 'open_item', {'n': 2});
      await call(t, 'send_message', {'channel': 'general', 'text': '晚上看'});
      await t.tap(find.byKey(const ValueKey('orb-confirm-cancel')));
      await settle(t);
      expect(detail, findsOneWidget);
      expect(find.text('已回复'), findsNothing);
      expect(a.world.sent, isEmpty);
    });
  });

  group('not driving', () {
    testWidgets('the normal layer: cards, no list, the input is there', (
      t,
    ) async {
      await fixture(t);
      f.controller.showBriefing(seven());
      await settle(t);
      expect(list, findsNothing);
      expect(deckCard, findsNothing);
      expect(find.byKey(const ValueKey('orb-input')), findsOneWidget);
      expect(hint, findsNothing);
      expect(find.text('对话记录'), findsOneWidget);
    });
  });

  group('the model path', () {
    testWidgets('show_list, driving_back and driving_next are given only '
        'while driving', (t) async {
      await fixture(t);
      await f.startCall();
      var names = {for (final d in f.sessions.single.tools) d['name']};
      // The realtime session has every tool; the text agent's scope is
      // asked in agent_orb_scope_test.
      expect(names, containsAll(['show_list', 'driving_back']));
      expect(
        f.sessions.single.tools.firstWhere(
          (d) => d['name'] == 'show_list',
        )['description'],
        contains('每页 4 张'),
      );
    });

    testWidgets('the model is told what is on the screen: the list, then the '
        'opened row', (t) async {
      await fixture(t);
      await drive(t, inCall: true);
      await call(t, 'show_list', {'kind': 'unread'});
      await t.pump(const Duration(seconds: 1));
      final s = f.sessions.single;
      expect(s.contexts.last, contains('未读 7'));
      expect(s.contexts.last, contains('1. Alice · #design 周五评审你来吗'));
      await call(t, 'open_item', {'n': 2});
      await t.pump(const Duration(seconds: 1));
      expect(s.contexts.last, contains('第 2 个的详情'));
      expect(s.contexts.last, contains('Cody'));
    });
  });
}
