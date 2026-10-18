import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';
import 'package:raft_ui/raft_ui.dart';

import 'agent_orb_briefing_cards_test.dart' show briefing, needsYou;
import 'agent_orb_shell_session_test.dart' show fakeTool;
import 'agent_orb_shell_test.dart' show OrbFixture;

/// The immersive layer (design frames 05 to 08, 10): a full-screen layer over
/// the app with a blur and a dark scrim, no sheet; a light swipe down, a tap
/// on the empty backdrop or Back closes it, and closing it never hangs up the
/// call; a tool that moves the app collapses it. Phone window 412x915 with
/// 24 dp insets, real gestures.

void main() {
  late OrbFixture f;

  Future<void> fixture(
    WidgetTester t, {
    List<OrbTool> tools = const [],
    RaftFamily family = RaftFamily.brutal,
    double textScale = 1.0,
  }) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump(tools: tools, family: family, textScale: textScale);
    await t.pump(const Duration(milliseconds: 300));
  }

  /// Lets a layer finish opening or closing (its slide, then its fade).
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
  }

  final layer = find.byKey(const ValueKey('orb-layer'));
  final content = find.byKey(const ValueKey('orb-layer-content'));
  final scrim = find.byKey(const ValueKey('orb-layer-scrim'));

  double scrimAlpha(WidgetTester t) => t.widget<ColoredBox>(scrim).color.a;
  double contentTop(WidgetTester t) => t.getTopLeft(content).dy;
  double contentOpacity(WidgetTester t) => t.widget<Opacity>(content).opacity;

  group('what it is', () {
    testWidgets('a blurred, dimmed full-screen layer: no sheet, no panel', (
      t,
    ) async {
      await fixture(t);
      await f.openLayer();
      expect(layer, findsOneWidget);
      expect(t.getSize(layer), const Size(412, 915));
      expect(find.byType(RaftSheet), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('raft-sheet-handle')), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
      final blur = t.widget<BackdropFilter>(find.byType(BackdropFilter)).filter;
      expect(blur, ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12));
      expect(scrimAlpha(t), closeTo(.55, .01));
      expect(find.text('向下划收起'), findsOneWidget);
      expect(find.byKey(const ValueKey('orb-input')), findsOneWidget);
      expect(find.byKey(const ValueKey('orb-send')), findsOneWidget);
      // The page is still under it.
      expect(find.text('page'), findsOneWidget);
    });

    testWidgets('what the agent says is the bubble beside the orb, not the '
        'layer; the conversation is behind 对话记录', (t) async {
      await fixture(
        t,
        tools: [
          fakeTool(
            'fake_open',
            (a, c) async => {'activity': '已打开 #raft-flutter'},
          ),
        ],
      );
      await f.openLayer();
      expect(find.text('说点什么，或者长按球直接对话'), findsOneWidget);
      await f.startCall();
      f.sessions.single.onInputText!('去 raft-flutter');
      await f.controller.dispatch('fake_open', const {});
      f.sessions.single.onOutputText!('到了，这里有一件要你看。');
      await t.pump();

      final dock = find.byKey(const ValueKey('orb-layer-dock'));
      final inContent = find.descendant(
        of: content,
        matching: find.text('到了，这里有一件要你看。'),
      );
      // The agent's line: in the bubble by the docked orb, nowhere else on
      // the layer; nor the person's words or the tool lines.
      expect(
        find.descendant(of: dock, matching: find.text('到了，这里有一件要你看。')),
        findsOneWidget,
      );
      expect(inContent, findsNothing);
      expect(
        find.descendant(of: content, matching: find.text('去 raft-flutter')),
        findsNothing,
      );
      expect(find.text('说点什么，或者长按球直接对话'), findsOneWidget);

      // 对话记录: what was said and done, the newest first.
      await t.tap(find.byKey(const ValueKey('orb-layer-history')));
      await t.pump();
      final said = t.getRect(
        find.descendant(of: content, matching: find.text('去 raft-flutter')),
      );
      final activity = t.getRect(
        find.descendant(of: content, matching: find.text('已打开 #raft-flutter')),
      );
      final agent = t.getRect(inContent);
      expect(agent.top, lessThan(activity.top));
      expect(activity.top, lessThan(said.top));
      expect(find.text('返回'), findsOneWidget);

      // 返回: the content again.
      await t.tap(find.byKey(const ValueKey('orb-layer-history')));
      await t.pump();
      expect(inContent, findsNothing);
      expect(find.text('对话记录'), findsOneWidget);
    });

    testWidgets('the orb docks bottom-right with the live pill while a call '
        'is on', (t) async {
      await fixture(t);
      await f.startCall();
      await f.openLayerInCall();
      final dock = find.byKey(const ValueKey('orb-layer-dock'));
      expect(
        find.descendant(of: dock, matching: OrbFixture.orbFinder),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dock,
          matching: find.byKey(const ValueKey('orb-call-pill')),
        ),
        findsOneWidget,
      );
      final orb = f.orbRect();
      expect(orb.right, closeTo(412 - 20, 8));
      expect(orb.bottom, greaterThan(915 - 24 - 60));
      expect(find.textContaining('通话中 0:00'), findsOneWidget);
    });
  });

  group('closing it lightly', () {
    // A tap on the orb hangs up; in a call the pill is the way back in.
    testWidgets('in a call a tap on the pill opens the layer and the call '
        'goes on', (t) async {
      await fixture(t);
      await f.startCall();
      expect(f.controller.layerOpen, isFalse);
      await t.tap(find.byKey(const ValueKey('orb-call-pill')));
      await settle(t);
      expect(layer, findsOneWidget);
      expect(f.controller.layerOpen, isTrue);
      expect(f.controller.voice.state, AgentMicState.live);
      expect(f.sessions.single.closes, 0);
    });

    testWidgets('a swipe down closes it and the call goes on', (t) async {
      await fixture(t);
      await f.startCall();
      await f.openLayerInCall();
      expect(f.controller.voice.state, AgentMicState.live);

      await t.flingFrom(const Offset(200, 300), const Offset(0, 400), 1500);
      await settle(t);

      expect(layer, findsNothing);
      expect(f.controller.layerOpen, isFalse);
      expect(f.controller.voice.state, AgentMicState.live);
      expect(f.sessions.single.closes, 0);
      expect(find.text('通话中 0:00 · 在听'), findsOneWidget);
    });

    testWidgets('the layer follows the finger: it moves down, fades and the '
        'scrim lightens', (t) async {
      await fixture(t);
      await f.openLayer();
      final rest = contentTop(t);
      expect(contentOpacity(t), 1);
      final g = await t.startGesture(const Offset(200, 300));
      await g.moveBy(const Offset(0, 120));
      await t.pump();
      expect(contentTop(t) - rest, closeTo(120, 20));
      expect(contentOpacity(t), lessThan(1));
      expect(scrimAlpha(t), lessThan(.55));
      final blur = t.widget<BackdropFilter>(find.byType(BackdropFilter)).filter;
      expect(blur, isNot(ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12)));

      await g.moveBy(const Offset(0, 100));
      await t.pump();
      expect(contentTop(t) - rest, closeTo(220, 30));
      expect(scrimAlpha(t), lessThan(.4));
      // Past a quarter of the height: letting go closes it.
      await g.moveBy(const Offset(0, 40));
      await t.pump();
      await g.up();
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);
    });

    testWidgets('a short drag springs back and the layer stays', (t) async {
      await fixture(t);
      await f.openLayer();
      final rest = contentTop(t);
      final g = await t.startGesture(const Offset(200, 300));
      await g.moveBy(const Offset(0, 90));
      await t.pump();
      expect(contentTop(t) - rest, greaterThan(50));
      await g.up();
      await settle(t);
      await settle(t);
      expect(layer, findsOneWidget);
      expect(f.controller.layerOpen, isTrue);
      expect(contentTop(t), closeTo(rest, .5));
      expect(contentOpacity(t), 1);
      expect(scrimAlpha(t), closeTo(.55, .01));
    });

    testWidgets('past a quarter of the height it closes; a quick flick closes '
        'it too', (t) async {
      await fixture(t);
      await f.openLayer();
      var g = await t.startGesture(const Offset(200, 300));
      await g.moveBy(const Offset(0, 200));
      await g.up();
      await settle(t);
      await settle(t);
      expect(layer, findsOneWidget, reason: '200 of 915 is under a quarter');

      g = await t.startGesture(const Offset(200, 300));
      await g.moveBy(const Offset(0, 260));
      await t.pump();
      await g.up();
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);

      await f.openLayer();
      await t.flingFrom(const Offset(200, 300), const Offset(0, 80), 2500);
      await settle(t);
      await settle(t);
      expect(layer, findsNothing, reason: 'a downward fling closes');
    });

    testWidgets('a swipe up or sideways does not close it', (t) async {
      await fixture(t);
      await f.openLayer();
      await t.flingFrom(const Offset(200, 300), const Offset(0, -400), 1500);
      await settle(t);
      await t.flingFrom(const Offset(100, 300), const Offset(300, 40), 1500);
      await settle(t);
      expect(layer, findsOneWidget);
    });

    testWidgets('a tap on the empty backdrop closes it, a tap on the layer '
        'content does not', (t) async {
      await fixture(t);
      await f.openLayer();
      await t.tap(find.byKey(const ValueKey('orb-input')));
      await settle(t);
      expect(layer, findsOneWidget);

      // Between the hint and the first line of text: empty.
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t);
      await t.tapAt(const Offset(200, 130));
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);
      expect(f.controller.layerOpen, isFalse);
    });

    testWidgets('Back closes it and the call goes on', (t) async {
      await fixture(t);
      await f.startCall();
      await f.openLayerInCall();
      expect(await t.binding.handlePopRoute(), isTrue);
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);
      expect(f.controller.voice.state, AgentMicState.live);
      expect(f.sessions.single.closes, 0);
    });

    testWidgets('the tool hide_orb_sheet closes it', (t) async {
      await fixture(t);
      await f.openLayer();
      final hidden = f.controller.dispatch('hide_orb_sheet', const {});
      await settle(t);
      expect((await hidden)['ok'], isTrue);
      expect(layer, findsNothing);
    });

    testWidgets('a tap on the docked orb in a live call hangs up and keeps '
        'the layer', (t) async {
      await fixture(t);
      await f.startCall();
      await f.openLayerInCall();
      await t.tap(OrbFixture.orbFinder);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(f.controller.inCall, isFalse);
      expect(layer, findsOneWidget);
      expect(find.textContaining('已挂断'), findsOneWidget);
    });
  });

  group('operating the app in a call', () {
    final nav = fakeTool('navigate', (args, ctx) async {
      ctx.operating.value = true;
      return {'route': '/s/alpha/activity', 'title': '#raft-flutter'};
    });

    testWidgets('a navigation collapses the layer: the page, the orb, the '
        'operating pill and the subtitle are left', (t) async {
      await fixture(t, tools: [nav]);
      await f.startCall();
      await f.openLayerInCall();
      f.sessions.single.onOutputText!('这就带你过去。');
      await f.controller.dispatch('navigate', {'target': 'raft-flutter'});
      await settle(t);
      await settle(t);

      expect(layer, findsNothing);
      expect(f.controller.layerOpen, isFalse);
      expect(f.controller.inCall, isTrue, reason: 'the call goes on');
      expect(find.byKey(const ValueKey('orb-operating-frame')), findsOneWidget);
      expect(find.text('通话中 0:00 · 打开了 #raft-flutter'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('orb-layer-dock')),
          matching: OrbFixture.orbFinder,
        ),
        findsNothing,
      );
      expect(OrbFixture.orbFinder, findsOneWidget);
      f.sessions.single.onOutputText!('到了。');
      await t.pump();
      expect(find.text('到了。'), findsOneWidget);

      // The person touches the page: the screen is theirs again.
      await t.tap(find.byKey(const ValueKey('page-content')));
      await t.pump();
      expect(f.controller.operating.value, isFalse);
      expect(f.pageTaps, hasLength(1));
    });

    // Kevin asked where the big-text-and-cards briefing was: after a move
    // the layer stepped aside and the briefing was only spoken.
    final briefedNav = fakeTool('navigate', (args, ctx) async {
      ctx.operating.value = true;
      ctx.arrived = briefing();
      return {'route': '/s/alpha/activity', 'title': '动态'};
    });

    testWidgets('a move asked to show its briefing lays the cards over the '
        'page it opened', (t) async {
      await fixture(t, tools: [briefedNav]);
      await f.startCall();
      await f.controller.dispatch('navigate', {
        'page': 'activity',
        'show': true,
      });
      await settle(t);
      await settle(t);
      expect(f.controller.layerOpen, isTrue);
      expect(find.text('Cody 在等你批准重构第 10 步'), findsOneWidget);
      expect(f.controller.inCall, isTrue);
    });

    testWidgets('without show the same move only opens the page', (t) async {
      await fixture(t, tools: [briefedNav]);
      await f.startCall();
      await f.controller.dispatch('navigate', {'page': 'activity'});
      await settle(t);
      await settle(t);
      expect(f.controller.layerOpen, isFalse);
      expect(find.text('Cody 在等你批准重构第 10 步'), findsNothing);
    });

    testWidgets('tools that do not move the app, and failed moves, leave the '
        'layer alone', (t) async {
      await fixture(
        t,
        tools: [
          fakeTool('fake_read', (a, c) async => {'page': 'activity'}),
          fakeTool('fake_missing', (a, c) async {
            c.operating.value = true;
            c.operating.value = false;
            return {'error': '没有找到「动态」'};
          }),
          fakeTool('fake_pick', (a, c) async {
            c.operating.value = true;
            c.operating.value = false;
            return {
              'candidates': [
                {'title': 'a'},
              ],
            };
          }),
        ],
      );
      await f.openLayer();
      for (final name in ['fake_read', 'fake_missing', 'fake_pick']) {
        await f.controller.dispatch(name, {'target': '动态'});
        await settle(t);
        expect(layer, findsOneWidget, reason: name);
      }
    });

    testWidgets('a move with the layer closed does nothing to it', (t) async {
      await fixture(t, tools: [nav]);
      await f.controller.dispatch('navigate', {'target': '动态'});
      await settle(t);
      expect(f.controller.layerOpen, isFalse);
      expect(layer, findsNothing);
    });

    testWidgets('the keyboard goes down when the layer collapses', (t) async {
      await fixture(t, tools: [nav]);
      await f.openLayer();
      await t.tap(find.byKey(const ValueKey('orb-input')));
      await settle(t);
      bool focused() =>
          t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;
      expect(focused(), isTrue);
      await f.controller.dispatch('navigate', {'target': '动态'});
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);
      expect(
        t.testTextInput.isVisible,
        isFalse,
        reason: 'the keyboard went down',
      );
    });
  });

  group('briefing cards', () {
    testWidgets('get_briefing with show puts the cards in the layer, in '
        'brutal cards, and opens it', (t) async {
      await fixture(t);
      expect(f.controller.layerOpen, isFalse);
      f.controller.showBriefing(briefing());
      await settle(t);
      expect(f.controller.layerOpen, isTrue);
      expect(find.byType(RaftSheet), findsNothing);
      expect(find.text('3 条新动态，1 件需要你处理'), findsOneWidget);
      expect(find.text('Cody 在等你批准重构第 10 步'), findsOneWidget);
      expect(find.text('回复：批准'), findsOneWidget);
      expect(find.text('其余 5 条是常规进度'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('an item tapped opens its page and the layer collapses', (
      t,
    ) async {
      await fixture(t);
      f.controller.showBriefing(briefing(needs: [needsYou()]));
      await settle(t);
      await t.tap(find.text('Cody 在等你批准重构第 10 步'));
      await settle(t);
      await settle(t);
      expect(layer, findsNothing);
      expect(f.controller.layerOpen, isFalse);
    });

    testWidgets('closing the layer takes the cards with it', (t) async {
      await fixture(t);
      f.controller.showBriefing(briefing());
      await settle(t);
      f.controller.closeLayer();
      await settle(t);
      await settle(t);
      await f.openLayer();
      expect(find.text('3 条新动态，1 件需要你处理'), findsNothing);
    });
  });

  group('looks right', () {
    for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('${family.name} at text scale $scale: no overflow with a '
            'long transcript, cards and a call', (t) async {
          await fixture(t, family: family, textScale: scale);
          await f.startCall();
          f.controller.showBriefing(
            briefing(
              needs: [
                needsYou(),
                needsYou(title: '很长的标题' * 12),
              ],
            ),
          );
          await settle(t);
          f.sessions.single.onInputText!('看看动态里有什么要我处理的事情，顺便说说频道' * 2);
          f.sessions.single.onOutputText!('第 10 步的方案 Cody 已经写好了，在等你批准。' * 4);
          await t.pump();
          await t.pump(const Duration(milliseconds: 300));
          expect(t.takeException(), isNull);
          expect(find.byKey(const ValueKey('orb-input')), findsOneWidget);
          // The keyboard comes up: the input and the orb ride above it.
          t.view.viewInsets = const FakeViewPadding(bottom: 300);
          addTearDown(t.view.resetViewInsets);
          await t.pump(const Duration(milliseconds: 300));
          expect(t.takeException(), isNull);
          expect(
            t.getRect(find.byKey(const ValueKey('orb-input'))).bottom,
            lessThanOrEqualTo(915 - 300),
          );
        });
      }
    }
  });
}
