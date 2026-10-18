import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_orb_shell_test.dart' show OrbFixture;

/// Live subtitles (design frames 03 and 04): one line above the orb with what
/// the person is saying and then what the agent is saying; it fades about two
/// seconds after the last change. Only while the immersive layer is collapsed.

void main() {
  late OrbFixture f;

  Future<void> fixture(WidgetTester t) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump();
    await t.pump(const Duration(milliseconds: 300));
    await f.startCall();
  }

  final bubble = find.byKey(const ValueKey('orb-subtitle'));

  testWidgets('what the person says shows as one line and fades after 2 s', (
    t,
  ) async {
    await fixture(t);
    expect(bubble, findsNothing);
    f.sessions.single.onInputText!('去 raft-flutter');
    await t.pump();
    expect(find.text('“去 raft-flutter”'), findsOneWidget);
    expect(
      t.widget<Text>(find.text('“去 raft-flutter”')).maxLines,
      1,
      reason: 'one line',
    );

    await t.pump(const Duration(milliseconds: 1900));
    expect(bubble, findsOneWidget);
    await t.pump(const Duration(milliseconds: 200));
    // Fading out; gone once the fade is over.
    await t.pump(const Duration(milliseconds: 400));
    expect(bubble, findsNothing);
  });

  testWidgets('a new word keeps it up; the agent line takes over after it', (
    t,
  ) async {
    await fixture(t);
    f.sessions.single.onInputText!('看看');
    await t.pump(const Duration(milliseconds: 1500));
    f.sessions.single.onInputText!('动态');
    await t.pump(const Duration(milliseconds: 1500));
    expect(find.text('“看看动态”'), findsOneWidget, reason: 'the clock restarted');

    f.sessions.single.onOutputText!('八戒在等你批准发布，');
    await t.pump();
    expect(find.text('“看看动态”'), findsNothing);
    expect(find.text('八戒在等你批准发布，'), findsOneWidget);
    f.sessions.single.onOutputText!('已经等了 3 天');
    await t.pump();
    expect(find.text('八戒在等你批准发布，已经等了 3 天'), findsOneWidget);

    await t.pump(const Duration(milliseconds: 2200));
    await t.pump(const Duration(milliseconds: 400));
    expect(bubble, findsNothing);
  });

  testWidgets('it sits above the orb and the pill', (t) async {
    await fixture(t);
    f.sessions.single.onInputText!('你好');
    await t.pump();
    expect(
      t.getRect(bubble).bottom,
      lessThanOrEqualTo(
        t.getRect(find.byKey(const ValueKey('orb-call-pill'))).top,
      ),
    );
    expect(t.getRect(bubble).bottom, lessThan(f.orbRect().top));
    expect(t.takeException(), isNull);
  });

  testWidgets('with the layer open it is beside the docked orb, once; the '
      'transcript is not on the layer', (t) async {
    await fixture(t);
    f.sessions.single.onInputText!('你好');
    await t.pump();
    expect(bubble, findsOneWidget);
    await f.openLayerInCall();
    f.sessions.single.onOutputText!('你好呀');
    await t.pump();
    final dock = find.byKey(const ValueKey('orb-layer-dock'));
    expect(bubble, findsOneWidget);
    expect(find.descendant(of: dock, matching: bubble), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('orb-layer-content')),
        matching: find.text('你好呀'),
      ),
      findsNothing,
    );
  });

  testWidgets('a long line stays on one line', (t) async {
    await fixture(t);
    f.sessions.single.onOutputText!(
      '第 10 步的方案 Cody 已经写好了，在等你批准，要不要我现在帮你回复他。' * 2,
    );
    await t.pump();
    expect(bubble, findsOneWidget);
    expect(t.getSize(bubble).height, lessThan(48));
    expect(t.takeException(), isNull);
  });
}
