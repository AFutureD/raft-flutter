import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/orb_prompt.dart';
import 'package:raft_ui/raft_ui.dart';

import 'agent_orb_briefing_cards_test.dart' show briefing, needsYou;
import 'agent_orb_shell_session_test.dart' show fakeTool;
import 'agent_orb_shell_test.dart' show OrbFixture;

/// The driving mode: the orb's immersive layer, kept open and showing one
/// thing at a time ("第 1 件 / 共 N 件"), low-risk actions only. Swipe down,
/// Back or a tap on the backdrop leave it (and close the layer); hanging up
/// does not. Phone window 412x915 with 24 dp insets, real gestures.

/// A needs-you item that is not an approval: a reply the driver may send.
OrbBriefItem replyItem(String title) => needsYou(title: title).copyWith(
  reason: OrbReason.dmAsk,
  suggestedAction: const OrbSuggestedAction(
    label: '回复：收到',
    kind: 'reply',
    text: '收到',
  ),
);

void main() {
  late OrbFixture f;

  final nav = fakeTool('navigate', (args, ctx) async {
    ctx.operating.value = true;
    return {'route': '/s/alpha/activity', 'title': '#raft-flutter'};
  });

  Future<void> fixture(
    WidgetTester t, {
    RaftFamily family = RaftFamily.brutal,
    double textScale = 1.0,
  }) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump(tools: [nav], family: family, textScale: textScale);
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
    await settle(t);
    return done;
  }

  Future<void> driveInCall(WidgetTester t) async {
    await f.startCall();
    await call(t, 'set_driving_mode', {'on': true});
  }

  final layer = find.byKey(const ValueKey('orb-layer'));
  final tag = find.byKey(const ValueKey('orb-driving-tag'));
  final progress = find.byKey(const ValueKey('orb-driving-progress'));
  final primary = find.byKey(const ValueKey('orb-driving-primary'));
  final next = find.byKey(const ValueKey('orb-driving-next'));
  final later = find.byKey(const ValueKey('orb-driving-later'));
  final done = find.byKey(const ValueKey('orb-driving-done'));

  final two = briefing(needs: [needsYou(), replyItem('Alice 问你周五有没有空')]);

  group('entering and leaving', () {
    testWidgets('set_driving_mode on opens the layer and says so: the pill '
        'and the label', (t) async {
      await fixture(t);
      await f.startCall();
      expect(f.controller.layerOpen, isFalse);
      final r = await call(t, 'set_driving_mode', {'on': true});
      expect(r['ok'], isTrue);
      expect(f.controller.driving, isTrue);
      expect(f.controller.layerOpen, isTrue);
      expect(layer, findsOneWidget);
      expect(find.textContaining('通话中 0:00 · 驾驶中'), findsOneWidget);
      expect(find.text('驾驶模式'), findsOneWidget);
      expect(find.text('向下划退出'), findsOneWidget);
      expect(find.text('向下划收起'), findsNothing);
      // The label is at the top left.
      final rect = t.getRect(tag);
      expect(rect.left, closeTo(24, 4));
      expect(rect.top, lessThan(24 + 40));
    });

    testWidgets('without a call the pill still says 驾驶中', (t) async {
      await fixture(t);
      await call(t, 'set_driving_mode', {'on': true});
      expect(find.text('驾驶中'), findsOneWidget);
    });

    testWidgets('the tool is declared in Chinese for the model', (t) async {
      await fixture(t);
      await f.startCall();
      final decls = {for (final d in f.sessions.single.tools) d['name']: d};
      expect(decls.keys, containsAll(['set_driving_mode', 'driving_next']));
      expect(
        decls['set_driving_mode']!['description'] as String,
        contains('开车'),
      );
      expect(decls['driving_next']!['description'] as String, contains('下一件'));
    });

    testWidgets('a move while driving keeps the layer open; off and the next '
        'move collapses it again', (t) async {
      await fixture(t);
      await driveInCall(t);
      await call(t, 'navigate', {'target': '动态'});
      expect(f.controller.layerOpen, isTrue);
      expect(layer, findsOneWidget);
      expect(f.controller.inCall, isTrue);
      // The person touches the page: the screen is theirs again.
      f.controller.operating.takeOver();

      final off = await call(t, 'set_driving_mode', {'on': false});
      expect(off['ok'], isTrue);
      expect(f.controller.driving, isFalse);
      expect(find.text('驾驶模式'), findsNothing);
      expect(find.text('向下划收起'), findsOneWidget);
      expect(find.textContaining('驾驶中'), findsNothing);

      await call(t, 'navigate', {'target': '动态'});
      await settle(t);
      expect(layer, findsNothing);
    });

    testWidgets('a swipe down EXITS driving mode and closes the layer', (
      t,
    ) async {
      await fixture(t);
      await driveInCall(t);
      await t.flingFrom(const Offset(200, 300), const Offset(0, 400), 1500);
      await settle(t);
      expect(layer, findsNothing);
      expect(f.controller.layerOpen, isFalse);
      expect(f.controller.driving, isFalse);
      expect(f.controller.voice.state, AgentMicState.live);
      expect(find.textContaining('驾驶中'), findsNothing);
    });

    testWidgets('Back exits driving mode and closes the layer', (t) async {
      await fixture(t);
      await driveInCall(t);
      expect(await t.binding.handlePopRoute(), isTrue);
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);
      expect(f.controller.driving, isFalse);
    });

    testWidgets('a tap on the backdrop exits driving mode', (t) async {
      await fixture(t);
      await driveInCall(t);
      await t.tapAt(const Offset(200, 130));
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);
      expect(f.controller.driving, isFalse);
    });

    testWidgets('hanging up does not exit driving mode; closing the layer '
        'does, and a new layer is a normal one', (t) async {
      await fixture(t);
      await driveInCall(t);
      await t.tap(OrbFixture.orbFinder);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(f.controller.inCall, isFalse);
      expect(f.controller.driving, isTrue);
      expect(layer, findsOneWidget);
      expect(find.textContaining('已挂断'), findsOneWidget);
      expect(find.textContaining('驾驶中'), findsOneWidget);

      f.controller.closeLayer();
      await settle(t);
      await settle(t);
      expect(f.controller.driving, isFalse);
      await f.openLayer();
      expect(find.text('驾驶模式'), findsNothing);
      expect(find.text('向下划收起'), findsOneWidget);
    });
  });

  group('one thing at a time', () {
    testWidgets('a briefing shows one big card with the progress line', (
      t,
    ) async {
      await fixture(t);
      await driveInCall(t);
      f.sessions.single.onOutputText!('Cody 在等你批准。');
      f.controller.showBriefing(two);
      await settle(t);
      expect(find.text('第 1 件 / 共 2 件'), findsOneWidget);
      expect(progress, findsOneWidget);
      final title = find.text('Cody 在等你批准重构第 10 步');
      expect(title, findsOneWidget);
      expect(t.widget<Text>(title).style!.fontSize, inInclusiveRange(28, 32));
      // The second item and the progress rows wait.
      expect(find.text('Alice 问你周五有没有空'), findsNothing);
      expect(find.textContaining('CodexMac'), findsNothing);
      // The agent's line stays above the card.
      expect(
        t.getRect(find.text('Cody 在等你批准。')).bottom,
        lessThan(t.getRect(title).top),
      );
      expect(next, findsOneWidget);
      expect(later, findsOneWidget);
      expect(find.text('下一件'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('下一件 (a tap) goes on; after the last: 就这些 and the '
        'routine count', (t) async {
      await fixture(t);
      await driveInCall(t);
      f.controller.showBriefing(two);
      await settle(t);
      await t.tap(next);
      await t.pump();
      expect(find.text('第 2 件 / 共 2 件'), findsOneWidget);
      expect(find.text('Alice 问你周五有没有空'), findsOneWidget);
      expect(find.text('Cody 在等你批准重构第 10 步'), findsNothing);
      // The model is told, so that it speaks the new one.
      expect(f.sessions.single.sentTexts.last, contains('Alice'));

      await t.tap(next);
      await t.pump();
      expect(done, findsOneWidget);
      expect(find.text('就这些'), findsOneWidget);
      expect(find.text('其余 5 条是常规进度'), findsOneWidget);
      expect(progress, findsNothing);
      expect(next, findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('稍后 sets the item aside and shows the next one', (t) async {
      await fixture(t);
      await driveInCall(t);
      f.controller.showBriefing(two);
      await settle(t);
      await t.tap(later);
      await t.pump();
      expect(find.text('第 2 件 / 共 2 件'), findsOneWidget);
    });

    testWidgets('the tool driving_next goes on the same way', (t) async {
      await fixture(t);
      await driveInCall(t);
      f.controller.showBriefing(two);
      await settle(t);
      final r = await call(t, 'driving_next');
      expect(r['ok'], isTrue);
      expect(r['index'], 2);
      expect(r['total'], 2);
      expect(r['done'], isFalse);
      expect((r['item']! as Map)['title'], 'Alice 问你周五有没有空');
      expect(find.text('第 2 件 / 共 2 件'), findsOneWidget);

      final last = await call(t, 'driving_next');
      expect(last['done'], isTrue);
      expect(find.text('就这些'), findsOneWidget);
      // Past the end it stays at the end.
      final again = await call(t, 'driving_next');
      expect(again['done'], isTrue);
      expect(find.text('就这些'), findsOneWidget);
    });

    testWidgets('driving_next outside driving mode is an error', (t) async {
      await fixture(t);
      await f.openLayer();
      final r = await call(t, 'driving_next');
      expect(r['error'], isNotNull);
    });

    testWidgets('a new briefing starts at the first item', (t) async {
      await fixture(t);
      await driveInCall(t);
      f.controller.showBriefing(two);
      await settle(t);
      await t.tap(next);
      await t.pump();
      f.controller.showBriefing(two);
      await settle(t);
      expect(find.text('第 1 件 / 共 2 件'), findsOneWidget);
    });

    testWidgets('an item with a quiet action: the button is its action and '
        'works without closing the layer', (t) async {
      await fixture(t);
      await driveInCall(t);
      f.controller.showBriefing(briefing(needs: [replyItem('Alice 问你周五有没有空')]));
      await settle(t);
      expect(find.text('第 1 件 / 共 1 件'), findsOneWidget);
      expect(find.text('回复：收到'), findsOneWidget);
      await t.tap(primary);
      await settle(t);
      expect(layer, findsOneWidget);
      expect(f.controller.driving, isTrue);
    });

    testWidgets('an item without an action gets 打开', (t) async {
      await fixture(t);
      await driveInCall(t);
      final plain = OrbBriefItem(
        id: 'x',
        title: 'Grok 的任务卡住了',
        who: 'Grok',
        where: '#raft-flutter',
        since: '已等 5 分钟',
        link: '/s/s1/channel/ca',
        sourceIds: const ['m9'],
        reason: OrbReason.agentBlocked,
        why: '被卡住',
      );
      f.controller.showBriefing(briefing(needs: [plain]));
      await settle(t);
      expect(find.text('打开'), findsOneWidget);
    });

    testWidgets('an approval waits until parked: 停车后批准, disabled', (t) async {
      await fixture(t);
      await driveInCall(t);
      f.controller.showBriefing(briefing());
      await settle(t);
      expect(find.text('停车后批准'), findsOneWidget);
      expect(find.text('回复：批准'), findsNothing);
      final button = t.widget<GestureDetector>(
        find.descendant(of: primary, matching: find.byType(GestureDetector)),
      );
      expect(button.onTap, isNull);
      await t.tap(primary, warnIfMissed: false);
      await settle(t);
      expect(layer, findsOneWidget);
      expect(f.controller.driving, isTrue);
    });

    testWidgets('out of driving mode the briefing is the normal cards', (
      t,
    ) async {
      await fixture(t);
      f.controller.showBriefing(two);
      await settle(t);
      expect(find.text('第 1 件 / 共 2 件'), findsNothing);
      expect(find.text('Cody 在等你批准重构第 10 步'), findsOneWidget);
      expect(find.text('Alice 问你周五有没有空'), findsOneWidget);
      expect(find.text('回复：批准'), findsOneWidget);
    });

    testWidgets('with nothing that needs the person: 就这些 at once', (t) async {
      await fixture(t);
      await driveInCall(t);
      f.controller.showBriefing(briefing(needs: const []));
      await settle(t);
      expect(find.text('就这些'), findsOneWidget);
      expect(find.text('其余 5 条是常规进度'), findsOneWidget);
    });
  });

  group('the prompt', () {
    test('has the triggers, one item per turn and the low-risk rule', () {
      final p = orbSystemPrompt(channels: '');
      for (final phrase in ['我在开车', '进入驾驶模式', '开车模式', '停车了', '退出驾驶模式']) {
        expect(p, contains(phrase));
      }
      expect(p, contains('set_driving_mode'));
      expect(p, contains('driving_next'));
      expect(p, contains('下一件'));
      expect(p, contains('每次只说一件'));
      expect(p, contains('两句'));
      expect(p, contains('批准'));
      expect(p, contains('合并'));
      expect(p, contains('删除'));
      expect(p, contains('停车'));
    });
  });

  group('looks right', () {
    for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
      testWidgets('${family.name} at text scale 1.3: no overflow with a long '
          'title, the card and the hints', (t) async {
        await fixture(t, family: family, textScale: 1.3);
        await driveInCall(t);
        f.sessions.single.onOutputText!('第 10 步的方案 Cody 已经写好了，在等你批准。' * 3);
        f.controller.showBriefing(
          briefing(
            needs: [
              needsYou(title: '很长的标题' * 10),
              replyItem('Alice 问你周五有没有空'),
            ],
          ),
        );
        await settle(t);
        expect(t.takeException(), isNull);
        expect(find.byKey(const ValueKey('orb-input')), findsOneWidget);
        // The big button and the hints are on the screen, above the input.
        final inputTop = t.getRect(find.byKey(const ValueKey('orb-input'))).top;
        expect(t.getRect(primary).top, greaterThan(0));
        expect(t.getRect(next).bottom, lessThanOrEqualTo(inputTop));
        await t.tap(next);
        await t.pump(const Duration(milliseconds: 300));
        await t.tap(next);
        await t.pump(const Duration(milliseconds: 300));
        expect(find.text('就这些'), findsOneWidget);
        expect(t.takeException(), isNull);
        t.view.viewInsets = const FakeViewPadding(bottom: 300);
        addTearDown(t.view.resetViewInsets);
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
      });
    }
  });
}
