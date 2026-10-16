import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_mode/agent_choreography.dart';
import 'package:raft_ui/raft_ui.dart';

/// One owner for what moves while the agent talks: the current item travels
/// along the stream, bulk fills stay in place, the end is calm.
void main() {
  late AgentSpotlightController spotlight;
  late AgentMarkController marks;
  late AgentRevealSync reveal;
  late ValueNotifier<String> saying;
  late bool speaking;
  late bool follows;
  late AgentChoreographer choreo;

  setUp(() {
    spotlight = AgentSpotlightController();
    marks = AgentMarkController();
    reveal = AgentRevealSync();
    saying = ValueNotifier('');
    speaking = true;
    follows = true;
    choreo = AgentChoreographer(
      spotlight: spotlight,
      marks: marks,
      reveal: reveal,
      saying: saying,
      playbackLag: () async => Duration.zero,
      isSpeaking: () => speaking,
      followStream: () => follows,
    );
  });
  tearDown(() {
    choreo.dispose();
    spotlight.dispose();
    marks.dispose();
    reveal.dispose();
    saying.dispose();
  });

  // Timers of a visual that was typing when the test ended.
  Future<void> rest(WidgetTester t) => t.pump(const Duration(seconds: 1));

  Future<void> hear(WidgetTester t, String words) async {
    saying.value += words;
    await t.pump(const Duration(milliseconds: 5));
  }

  testWidgets('an item added while the agent speaks enters the spotlight '
      'when its words are played, its text waits for it', (t) async {
    choreo.added('s#1', 'Aria 在做 历史上拉');
    expect(reveal.isHeld('s#1'), isTrue);
    expect(spotlight.focused, isNull);
    await hear(t, '先看 Aria，她在做历史上拉。');
    expect(spotlight.focused, 's#1');
    // It is the current item as it was added.
    expect(spotlight.entering, isTrue);
    // The headline starts typing a moment after it landed.
    expect(reveal.isHeld('s#1'), isTrue);
    await t.pump(const Duration(milliseconds: 250));
    expect(reveal.isHeld('s#1'), isFalse);
    expect(choreo.log, ['enter:s#1']);
    await rest(t);
  });

  testWidgets('the focus travels along the stream, one item at a time', (
    t,
  ) async {
    final seen = <String?>[];
    spotlight.addListener(() => seen.add(spotlight.focused));
    choreo.added('s#1', 'Aria 在做 历史上拉');
    choreo.added('s#2', 'Bo 卡住了 旧任务超过六小时');
    // The model also asks to spotlight the one it just added: not twice.
    choreo.spotlightItem('s#2', 'Bo 卡住了 旧任务超过六小时');
    await hear(t, 'Aria 在做历史上拉。');
    expect(spotlight.focused, 's#1');
    // Bo's words have not been spoken yet: Aria stays.
    await t.pump(const Duration(milliseconds: 600));
    expect(spotlight.focused, 's#1');
    await hear(t, 'Bo 卡住了，旧任务超过六小时没动。');
    expect(spotlight.focused, 's#2');
    expect(seen, ['s#1', 's#2']);
    expect(choreo.log, ['enter:s#1', 'enter:s#2']);
    expect(reveal.isHeld('s#1'), isFalse);
    await rest(t);
  });

  testWidgets('words that never come still show, in order, after a while', (
    t,
  ) async {
    choreo.added('s#1', 'Aria 在做 历史上拉');
    choreo.added('s#2', 'Bo 卡住了 旧任务');
    saying.value = '好的。';
    await t.pump(const Duration(milliseconds: 3400));
    expect(spotlight.focused, isNull);
    await t.pump(const Duration(milliseconds: 200));
    expect(spotlight.focused, 's#1');
    await t.pump(const Duration(milliseconds: 3600));
    expect(spotlight.focused, 's#2');
    await rest(t);
    await rest(t);
  });

  testWidgets('items added without speech are not spotlit', (t) async {
    speaking = false;
    for (var i = 1; i <= 6; i++) {
      choreo.added('s#$i', 'Agent $i 在做 任务 $i');
    }
    saying.value = 'Agent 1 在做任务 1';
    await t.pump(const Duration(seconds: 5));
    expect(spotlight.focused, isNull);
    expect(spotlight.entering, isFalse);
    expect(reveal.isHeld('s#1'), isFalse);
    expect(choreo.log, isEmpty);
    expect(choreo.hasCues, isFalse);
  });

  testWidgets('the current item stays current when the speech ends', (t) async {
    choreo.added('s#1', 'Aria 在做 历史上拉');
    await hear(t, 'Aria 在做历史上拉');
    expect(spotlight.focused, 's#1');
    speaking = false;
    choreo.speechEnded();
    expect(spotlight.focused, 's#1');
    expect(choreo.log, ['enter:s#1']);
    await rest(t);
  });

  testWidgets('a screen with no stage only types the item in place', (t) async {
    follows = false;
    choreo.added('s#1', 'Aria 在做 历史上拉');
    expect(reveal.isHeld('s#1'), isTrue);
    await hear(t, 'Aria 在做历史上拉');
    // Not current (a sheet would cover the screen for each item), but its
    // text is released to type.
    expect(spotlight.focused, isNull);
    await t.pump(const Duration(milliseconds: 250));
    expect(reveal.isHeld('s#1'), isFalse);
    await rest(t);
  });

  testWidgets('end_surface leaves the screen calm: the current item stays, '
      'marks lighter and then gone', (t) async {
    choreo.added('s#1', 'Aria 在做 历史上拉');
    await hear(t, 'Aria 在做历史上拉');
    choreo.mark(
      const AgentMark(
        itemId: 's#1',
        phrase: '历史上拉',
        style: AgentMarkStyle.circle,
      ),
    );
    await hear(t, '重点是历史上拉');
    expect(marks.marks, hasLength(1));
    expect(marks.dimmed, isFalse);

    // Still speaking: end_surface is noted, the screen waits.
    choreo.end();
    expect(spotlight.focused, 's#1');
    // The agent finishes: calm, the mark stays on the card, lightly.
    speaking = false;
    choreo.speechEnded();
    expect(spotlight.focused, 's#1');
    expect(marks.marks, hasLength(1));
    expect(marks.dimmed, isTrue);
    expect(choreo.log.last, 'calm');
    // A few seconds later it fades.
    await t.pump(const Duration(seconds: 3));
    expect(marks.marks, hasLength(1));
    await t.pump(const Duration(seconds: 2));
    expect(marks.marks, isEmpty);
    await rest(t);
  });

  testWidgets('end_surface with nothing being said is calm at once', (t) async {
    speaking = false;
    spotlight.focus('s#1');
    marks.add(const AgentMark(itemId: 's#1', phrase: '历史'));
    choreo.end();
    expect(spotlight.focused, 's#1');
    expect(marks.dimmed, isTrue);
    await t.pump(const Duration(seconds: 5));
    expect(marks.marks, isEmpty);
  });

  testWidgets('a new screen drops what was waiting for the speaker', (t) async {
    choreo.added('s#1', 'Aria 在做 历史上拉');
    expect(reveal.isHeld('s#1'), isTrue);
    choreo.newScreen();
    expect(reveal.isHeld('s#1'), isFalse);
    await hear(t, 'Aria 在做历史上拉');
    expect(spotlight.focused, isNull);
  });

  group('in the widget tree', () {
    Widget app() => MaterialApp(
      theme: raftTheme(RaftFamily.brutal),
      home: Scaffold(
        body: AgentSpotlight(
          controller: spotlight,
          child: ListView(
            children: [
              for (var n = 1; n <= 3; n++)
                AgentFocusable(
                  id: 'layer#$n',
                  child: SizedBox(
                    height: 90,
                    child: Center(child: Text('Item $n')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    testWidgets('the current item is lit in its slot: nothing is lifted or '
        'copied, and the slot never moves', (t) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(app());
      final slot = t.getRect(find.text('Item 2'));
      spotlight.focus('layer#2', enter: true);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Item 2'), findsOneWidget);
      expect(t.getRect(find.text('Item 2')), slot);
      spotlight.release();
      await t.pumpAndSettle();
      expect(find.text('Item 2'), findsOneWidget);
      expect(t.getRect(find.text('Item 2')), slot);
      expect(spotlight.entering, isFalse);
    });
  });
}
