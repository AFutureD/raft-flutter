import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';
import 'package:raft_flutter/features/agent_orb/orb_widget.dart'
    show orbLiveGreen, orbLiveRed;

import 'agent_orb_shell_session_test.dart' show fakeTool;
import 'agent_orb_shell_test.dart' show OrbFixture;

/// The five states of a call must be unmistakable from the orb alone (design
/// frame 09): idle, connecting, live and listening, live and speaking,
/// operating, and the grey "hung up" pill that stays for three seconds. Real
/// long-presses and taps; fake sessions with Completers; time moves only when
/// the test pumps.

void main() {
  late OrbFixture f;

  Future<void> fixture(WidgetTester t, {List<OrbTool> tools = const []}) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump(tools: tools);
    await t.pump(const Duration(milliseconds: 300));
  }

  final pill = find.byKey(const ValueKey('orb-call-pill'));
  Finder rings(String name) => find.byKey(ValueKey('orb-rings-$name'));
  final dot = find.byKey(const ValueKey('orb-dot'));
  Color? dotColor(WidgetTester t) =>
      (t.widget<DecoratedBox>(dot).decoration as BoxDecoration).color;
  Color? orbFill(WidgetTester t) =>
      (t.widget<Container>(OrbFixture.orbFinder).decoration as BoxDecoration)
          .color;

  group('idle', () {
    testWidgets('a cream orb with no ring, no dot, no label', (t) async {
      await fixture(t);
      expect(OrbFixture.orbFinder, findsOneWidget);
      expect(pill, findsNothing);
      expect(dot, findsNothing);
      expect(find.textContaining('通话'), findsNothing);
      expect(find.text('点球挂断 · 点标签展开'), findsNothing);
      for (final name in ['connecting', 'listening', 'speaking', 'operating']) {
        expect(rings(name), findsNothing, reason: name);
      }
    });
  });

  group('connecting', () {
    testWidgets('a turning dashed ring and the cyan pill', (t) async {
      await fixture(t);
      final idleFill = orbFill(t);
      await t.longPress(OrbFixture.orbFinder);
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('连接中…'), findsOneWidget);
      expect(pill, findsOneWidget);
      expect(rings('connecting'), findsOneWidget);
      expect(dot, findsNothing);
      expect(find.textContaining('通话中'), findsNothing);
      // Still the plain orb, not yet the yellow one of a live call.
      expect(orbFill(t), idleFill);
    });

    testWidgets('a tap while connecting hangs up with no "hung up" pill', (
      t,
    ) async {
      await fixture(t);
      await t.longPress(OrbFixture.orbFinder);
      await t.pump();
      await t.tap(OrbFixture.orbFinder);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(find.text('连接中…'), findsNothing);
      // Nothing was said: no call to report.
      expect(find.textContaining('已挂断'), findsNothing);
      expect(pill, findsNothing);
    });
  });

  group('live', () {
    testWidgets('listening: yellow orb, pink rings, red dot, black pill with '
        'a timer, and the hint', (t) async {
      await fixture(t);
      final idleFill = orbFill(t);
      await f.startCall();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('通话中 0:00 · 在听'), findsOneWidget);
      expect(find.text('点球挂断 · 点标签展开'), findsOneWidget);
      // The hint sits on its own plate, readable over any page.
      expect(
        find.ancestor(
          of: find.text('点球挂断 · 点标签展开'),
          matching: find.byKey(const ValueKey('orb-call-hint')),
        ),
        findsOneWidget,
      );
      expect(rings('listening'), findsOneWidget);
      expect(rings('connecting'), findsNothing);
      expect(dot, findsOneWidget);
      expect(dotColor(t), orbLiveRed);
      expect(orbFill(t), isNot(idleFill));
      expect(t.takeException(), isNull);
    });

    testWidgets('the timer advances while the call lasts', (t) async {
      await fixture(t);
      await f.startCall();
      await f.advance(const Duration(seconds: 42));
      expect(find.text('通话中 0:42 · 在听'), findsOneWidget);
      await f.advance(const Duration(seconds: 23));
      expect(find.text('通话中 1:05 · 在听'), findsOneWidget);
      await f.advance(const Duration(minutes: 10));
      expect(find.text('通话中 11:05 · 在听'), findsOneWidget);
    });

    testWidgets('the rings follow how loud the person is', (t) async {
      await fixture(t);
      await f.startCall();
      final level = f.controller.voice.micLevel;
      expect(level.value, 0);
      // PCM16 little-endian: a loud chunk, then silence.
      Uint8List chunk(int sample) {
        final data = ByteData(3200);
        for (var i = 0; i < 1600; i++) {
          data.setInt16(i * 2, sample, Endian.little);
        }
        return data.buffer.asUint8List();
      }

      f.audio.mics.last.add(chunk(9000));
      await t.pump();
      expect(level.value, greaterThan(.9));
      expect(rings('listening'), findsOneWidget);

      for (var i = 0; i < 6; i++) {
        f.audio.mics.last.add(chunk(0));
        await t.pump();
      }
      expect(level.value, lessThan(.1));

      // Hanging up turns the microphone, and the level, off.
      f.audio.mics.last.add(chunk(9000));
      await t.pump();
      await t.tap(OrbFixture.orbFinder);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(level.value, 0);
    });

    testWidgets('speaking: green rings, green dot, "在说"; back to listening '
        'when the turn ends', (t) async {
      await fixture(t);
      await f.startCall();
      await f.advance(const Duration(seconds: 65));
      f.sessions.single.onAudio!(Uint8List(8));
      await t.pump();
      expect(find.text('通话中 1:05 · 在说'), findsOneWidget);
      expect(rings('speaking'), findsOneWidget);
      expect(rings('listening'), findsNothing);
      expect(dotColor(t), orbLiveGreen);

      f.sessions.single.onTurnComplete!();
      await t.pump();
      expect(find.text('通话中 1:05 · 在听'), findsOneWidget);
      expect(rings('listening'), findsOneWidget);
      expect(dotColor(t), orbLiveRed);
    });

    testWidgets('operating: cyan rings, the screen-edge frame and the pill '
        'names what was opened', (t) async {
      await fixture(
        t,
        tools: [
          fakeTool('navigate', (args, ctx) async {
            ctx.operating.value = true;
            return {'title': '#raft-flutter'};
          }),
        ],
      );
      await f.startCall();
      await f.advance(const Duration(seconds: 90));
      expect(find.byKey(const ValueKey('orb-operating-frame')), findsNothing);

      await f.controller.dispatch('navigate', {'target': 'raft-flutter'});
      await t.pump();
      expect(find.byKey(const ValueKey('orb-operating-frame')), findsOneWidget);
      expect(find.text('通话中 1:30 · 打开了 #raft-flutter'), findsOneWidget);
      expect(rings('operating'), findsOneWidget);
      expect(dotColor(t), orbLiveGreen);
      // The call is still on.
      expect(f.controller.inCall, isTrue);

      // The person touches the page: the screen is theirs again.
      await t.tap(find.byKey(const ValueKey('page-content')));
      await t.pump();
      expect(find.byKey(const ValueKey('orb-operating-frame')), findsNothing);
      expect(find.text('通话中 1:30 · 在听'), findsOneWidget);
    });

    testWidgets('operating with no call: the pill names the page and has no '
        'timer', (t) async {
      await fixture(t);
      f.controller.operating
        ..label = '#raft-flutter'
        ..value = true;
      await t.pump();
      expect(find.text('打开了 #raft-flutter'), findsOneWidget);
      expect(find.textContaining('通话中'), findsNothing);
    });
  });

  group('a typed question', () {
    testWidgets('answered by the agent is not a call: no timer, no hint', (
      t,
    ) async {
      await fixture(t);
      await f.openLayer();
      await t.enterText(find.byKey(const ValueKey('orb-input')), '你好');
      await t.tap(find.byKey(const ValueKey('orb-send')));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      f.sessions.single.connectGate.complete();
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      f.sessions.single.onOutputText!('你好呀');
      await t.pump();
      expect(find.textContaining('通话中'), findsNothing);
      expect(find.text('点球挂断 · 点标签展开'), findsNothing);
      expect(find.text('正在回答…'), findsOneWidget);
      f.sessions.single.onTurnComplete!();
      await t.pump();
      expect(pill, findsNothing);
    });
  });

  group('hung up', () {
    testWidgets('a grey pill with the call length for 3 s, then idle', (
      t,
    ) async {
      await fixture(t);
      await f.startCall();
      await f.advance(const Duration(seconds: 42));

      await t.tap(OrbFixture.orbFinder);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(f.controller.inCall, isFalse);
      expect(find.text('已挂断 · 通话 0:42'), findsOneWidget);
      expect(find.text('点球挂断 · 点标签展开'), findsNothing);
      expect(dot, findsNothing);
      expect(rings('listening'), findsNothing);

      await t.pump(const Duration(milliseconds: 2900));
      expect(find.text('已挂断 · 通话 0:42'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 200));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('已挂断'), findsNothing);
      expect(pill, findsNothing);
    });

    testWidgets('a new call replaces the grey pill and times from zero', (
      t,
    ) async {
      await fixture(t);
      await f.startCall();
      await f.advance(const Duration(seconds: 20));
      await t.tap(OrbFixture.orbFinder);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(find.text('已挂断 · 通话 0:20'), findsOneWidget);
      await f.advance(const Duration(seconds: 1));

      await f.startCall();
      expect(find.textContaining('已挂断'), findsNothing);
      expect(find.text('通话中 0:00 · 在听'), findsOneWidget);
    });
  });
}
